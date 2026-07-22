import Foundation
import WebKit
import UserNotifications

@MainActor
@Observable
final class NotificationManager {
    private var pollTasks: [UUID: Task<Void, Never>] = [:]
    private let badgeManager: BadgeManager
    /// Notification taps that arrived before `onServiceRequested` was wired
    /// (a tap can launch the app). Buffered in order and drained once the
    /// handler is set, so a burst of cold-launch taps isn't reduced to just the
    /// last one.
    private var pendingServiceIDs: [UUID] = []

    var onServiceRequested: (@MainActor (UUID) -> Void)?

    init(badgeManager: BadgeManager) {
        self.badgeManager = badgeManager
        configureNotificationDelegate()
    }

    /// Polling cadence for a service.
    /// - `active`: adaptive 5s→30s title polling + 2× DOM badge polling for
    ///   the service currently displayed to the user.
    /// - `background`: flat 30s title polling for preloaded or soft-hibernated
    ///   services. No DOM badge polling because hidden views may have skipped
    ///   rendering; the page title is enough signal for "(N)" badges.
    enum PollMode {
        case active
        case background
    }

    /// Title poll interval starts at 5s and steps up by 5s (capped at 30s) after
    /// each run of 120 consecutive unchanged polls, so a quiet service gradually
    /// slows down — reaching the 30s cap takes well over an hour of no change,
    /// not 10 minutes — and it snaps back to 5s the moment the count changes. DOM
    /// badge poll runs at 2× the title interval. `isMuted`/`showBadge` are passed
    /// as closures so live toggles take effect on the next tick instead of
    /// waiting for the polling task to be restarted.
    func startPolling(
        for instanceID: UUID,
        webView: WKWebView,
        isMuted: @escaping @Sendable () -> Bool,
        showBadge: @escaping @Sendable () -> Bool,
        catalogEntry: ServiceCatalogEntry?,
        mode: PollMode = .active
    ) {
        stopPolling(for: instanceID)

        let task = Task { @MainActor [weak self, weak webView] in
            switch mode {
            case .active:
                await Self.runActivePoll(
                    instanceID: instanceID,
                    weakSelf: { [weak self] in self },
                    weakWebView: { [weak webView] in webView },
                    isMuted: isMuted,
                    showBadge: showBadge,
                    catalogEntry: catalogEntry
                )
            case .background:
                await Self.runBackgroundPoll(
                    instanceID: instanceID,
                    weakSelf: { [weak self] in self },
                    weakWebView: { [weak webView] in webView },
                    isMuted: isMuted,
                    showBadge: showBadge,
                    catalogEntry: catalogEntry
                )
            }
        }
        pollTasks[instanceID] = task
    }

    private static func runActivePoll(
        instanceID: UUID,
        weakSelf: @MainActor () -> NotificationManager?,
        weakWebView: @MainActor () -> WKWebView?,
        isMuted: @Sendable () -> Bool,
        showBadge: @Sendable () -> Bool,
        catalogEntry: ServiceCatalogEntry?
    ) async {
        var interval = 5
        var tick = 0
        var unchangedCycles = 0

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard let manager = weakSelf(), let webView = weakWebView(), !Task.isCancelled else { break }

            tick += 1

            if tick % interval == 0 {
                let previousCount = manager.badgeManager.rawCount(for: instanceID)
                // Authoritative source (DOM selector if defined, else title).
                // resetToZero: true — the user is looking, so an empty inbox
                // clearing to 0 is correct.
                await manager.pollPrimaryCount(webView: webView, instanceID: instanceID, isMuted: isMuted(), showBadge: showBadge(), catalogEntry: catalogEntry, resetToZero: true)
                let newCount = manager.badgeManager.rawCount(for: instanceID)

                if newCount == previousCount {
                    unchangedCycles += 1
                    if unchangedCycles >= 120 {
                        interval = min(interval + 5, 30)
                        unchangedCycles = 0
                    }
                } else {
                    interval = 5
                    unchangedCycles = 0
                }
            }
        }
    }

    private static func runBackgroundPoll(
        instanceID: UUID,
        weakSelf: @MainActor () -> NotificationManager?,
        weakWebView: @MainActor () -> WKWebView?,
        isMuted: @Sendable () -> Bool,
        showBadge: @Sendable () -> Bool,
        catalogEntry: ServiceCatalogEntry?
    ) async {
        // A DOM selector, when defined, is authoritative — but a hidden view's
        // selector may not have hydrated, so a background read of 0 stays
        // raise-only (won't clear). A title-based service reads its (reliable)
        // title with the normal clearing behavior.
        let hasSelector = catalogEntry?.badgeJS != nil
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard let manager = weakSelf(), let webView = weakWebView(), !Task.isCancelled else { break }
            await manager.pollPrimaryCount(webView: webView, instanceID: instanceID, isMuted: isMuted(), showBadge: showBadge(), catalogEntry: catalogEntry, resetToZero: !hasSelector)
        }
    }

    func stopPolling(for instanceID: UUID) {
        pollTasks[instanceID]?.cancel()
        pollTasks.removeValue(forKey: instanceID)
    }

    func stopAllPolling() {
        for task in pollTasks.values {
            task.cancel()
        }
        pollTasks.removeAll()
    }

    /// Fires a single immediate poll (title + optional DOM badge) for a service
    /// without starting or disturbing its recurring poll task. Used to populate
    /// a badge the moment a page finishes loading — on startup or right after a
    /// login redirect completes — instead of waiting for the next poll tick.
    ///
    /// Uses `resetToZero: false`: this opportunistic poll only ever *raises* a
    /// badge, never clears one, so firing on an error page or login interstitial
    /// can't wipe a correct count. The recurring poll handles authoritative
    /// clearing.
    func pollNow(
        for instanceID: UUID,
        webView: WKWebView,
        isMuted: Bool,
        showBadge: Bool,
        catalogEntry: ServiceCatalogEntry?
    ) async {
        await pollPrimaryCount(webView: webView, instanceID: instanceID, isMuted: isMuted, showBadge: showBadge, catalogEntry: catalogEntry, resetToZero: false)
    }

    /// Reads the badge from the service's authoritative source: its DOM `badgeJS`
    /// selector when defined (Gmail Inbox, LinkedIn messaging), otherwise the page
    /// title. A service WITH a selector never falls back to the title — so a title
    /// count for a different view (another Gmail label, or LinkedIn's global
    /// notification count) can't override the intended number.
    private func pollPrimaryCount(webView: WKWebView, instanceID: UUID, isMuted: Bool, showBadge: Bool, catalogEntry: ServiceCatalogEntry?, resetToZero: Bool) async {
        if let entry = catalogEntry, entry.badgeJS != nil {
            await pollBadge(webView: webView, instanceID: instanceID, isMuted: isMuted, showBadge: showBadge, catalogEntry: entry, resetToZero: resetToZero)
        } else {
            await pollTitle(webView: webView, instanceID: instanceID, isMuted: isMuted, showBadge: showBadge, resetToZero: resetToZero)
        }
    }

    /// Routes a notification tap to the navigation handler, or buffers it if
    /// the handler isn't wired yet (a notification can launch the app before
    /// AppState finishes setting `onServiceRequested`). Drained via
    /// `handlePendingNotification()`.
    func routeServiceRequest(_ serviceID: UUID) {
        if let handler = onServiceRequested {
            handler(serviceID)
        } else {
            pendingServiceIDs.append(serviceID)
        }
    }

    /// Returns and clears every buffered cold-launch tap, in arrival order.
    func drainPendingNotifications() -> [UUID] {
        let ids = pendingServiceIDs
        pendingServiceIDs = []
        return ids
    }

    // MARK: - Polling

    /// `resetToZero: false` makes a count of 0 a no-op instead of clearing the
    /// badge. The eager post-load poll (`pollNow`) uses this so a login/redirect
    /// interstitial or in-app error page — none of which carry an "(N)" in the
    /// title — can't wipe a correct unread badge. The recurring live poll keeps
    /// the default (true): reading your inbox empty authoritatively clears it.
    private func pollTitle(webView: WKWebView, instanceID: UUID, isMuted: Bool, showBadge: Bool, resetToZero: Bool = true) async {
        do {
            let result = try await webView.evaluateJavaScript("document.title")
            // The JS await is a suspension point: the poll task may have been
            // cancelled (service switched away / hibernated) while it ran. Drop
            // the result so a stale tick can't write a badge after cancellation.
            guard !Task.isCancelled else { return }
            if let title = result as? String {
                let count = Self.extractBadgeCount(from: title)
                guard count > 0 || resetToZero else { return }
                badgeManager.updateBadge(for: instanceID, count: count, isMuted: isMuted, showBadge: showBadge)
            }
        } catch {
            // Page may not be ready yet
        }
    }

    private func pollBadge(webView: WKWebView, instanceID: UUID, isMuted: Bool, showBadge: Bool, catalogEntry: ServiceCatalogEntry, resetToZero: Bool = true) async {
        guard let badgeJS = catalogEntry.badgeJS else { return }
        do {
            let result = try await webView.evaluateJavaScript(badgeJS)
            // Drop the result if the poll task was cancelled during the JS await,
            // so a stale tick can't write a badge after cancellation.
            guard !Task.isCancelled else { return }
            let count: Int
            if let intResult = result as? Int {
                count = intResult
            } else if let stringResult = result as? String, let parsed = Int(stringResult) {
                count = parsed
            } else {
                return
            }
            guard count > 0 || resetToZero else { return }
            badgeManager.updateBadge(for: instanceID, count: count, isMuted: isMuted, showBadge: showBadge)
        } catch {
            // Badge extraction failed — page may have changed
        }
    }

    nonisolated static func extractBadgeCount(from title: String) -> Int {
        // Look only at the part of the title before the first common
        // separator. Empirically: Gmail = "(3) Inbox - user - Gmail",
        // Discord = "(3) Discord", WhatsApp = "(3) WhatsApp Web". Folder
        // and document titles like "Annual Report (2024) - Drive" or
        // "Photos (2023) — Drive" carry years in parens that look like
        // huge unread counts; bound the value and exclude likely years.
        let separators = [" - ", " | ", " — ", " : ", " · "]
        var head = title
        for sep in separators {
            if let range = head.range(of: sep) {
                head = String(head[..<range.lowerBound])
            }
        }
        let pattern = /\((\d+)\)/
        guard let match = head.firstMatch(of: pattern),
              let count = Int(match.1),
              count > 0, count <= 999,
              !(1900...2099).contains(count)
        else { return 0 }
        return count
    }

    /// Whether the view layer should stop the outgoing service's poll when the
    /// displayed service changes. The pool is the authority on poll mode for a
    /// service it has transitioned: on a normal sidebar switch the pool hasn't
    /// moved yet (its `activeServiceID` still equals the outgoing service), so
    /// this is the right place to stop that service's active poll before the
    /// pool soft-hibernates it onto a background poll. On a deep-link switch,
    /// `AppState.switchToService` has already made the incoming service active
    /// and downgraded the outgoing one to a background poll, so `poolActiveID`
    /// no longer equals `previousID` — stopping here would wrongly kill that
    /// background poll and leave the outgoing service silent. Reconciling
    /// against the pool's active id (rather than trusting the last writer)
    /// fixes the deep-link race. See OPEN-ITEMS item 1.
    nonisolated static func shouldStopOutgoingPoll(
        previousID: UUID?,
        poolActiveID: UUID?
    ) -> Bool {
        guard let previousID else { return false }
        return poolActiveID == previousID
    }

    /// Whether a service's intercepted web notification should be forwarded to
    /// macOS Notification Center. Pure, so the gating policy is unit-testable.
    /// A notification fires only when the service is not muted, has OS
    /// notifications enabled, and Do Not Disturb is off. `notifyOS` is the
    /// per-service toggle; `isMuted` (the master override) and DND each veto.
    nonisolated static func shouldPostOSNotification(
        isMuted: Bool,
        notifyOS: Bool,
        doNotDisturb: Bool
    ) -> Bool {
        !isMuted && notifyOS && !doNotDisturb
    }

    // MARK: - Notifications

    /// Requests notification authorization from macOS. Call this AFTER the app
    /// has finished launching (from the root view's `.task`) — never from
    /// `App.init`/`AppState.init`. Requesting during launch, before the app's
    /// scene exists, can fail with "Notifications are not allowed for this
    /// application" and leave the app unregistered, so no banner ever appears.
    /// Idempotent: macOS ignores repeat calls once the choice has been made.
    func requestAuthorization() {
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                let status = await center.notificationSettings().authorizationStatus
                AppLogger.notifications.info(
                    "Notification authorization: granted=\(granted), status=\(status.rawValue)")
            } catch {
                // Not fatal, but never silent: swallowing this is what makes "no
                // banners ever appear" undiagnosable. The common cause is the app
                // failing to register at all (see the note above), which surfaces
                // only here.
                AppLogger.notifications.error(
                    "Notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    private func configureNotificationDelegate() {
        // Read DND from the thread-safe snapshot, not MainActor.assumeIsolated:
        // willPresent/didReceive aren't contractually delivered on the main
        // thread, and an off-main assumeIsolated would hard-crash.
        let dndSnapshot = badgeManager.doNotDisturbSnapshot
        let delegate = NotificationCenterDelegate(
            onServiceRequested: { [weak self] serviceID in
                Task { @MainActor in
                    self?.routeServiceRequest(serviceID)
                }
            },
            isDoNotDisturb: {
                dndSnapshot.value
            }
        )
        UNUserNotificationCenter.current().delegate = delegate
        NotificationCenterDelegate.retained = delegate
    }
}

// MARK: - Notification Center Delegate

private final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    let onServiceRequested: @Sendable (UUID) -> Void
    let isDoNotDisturb: @Sendable () -> Bool
    // Keeps the delegate alive (UNUserNotificationCenter holds it weakly).
    // Written once from the main-actor `configureNotificationDelegate()`, so
    // it's main-actor state rather than free-floating mutable global state.
    @MainActor static var retained: NotificationCenterDelegate?

    init(
        onServiceRequested: @escaping @Sendable (UUID) -> Void,
        isDoNotDisturb: @escaping @Sendable () -> Bool
    ) {
        self.onServiceRequested = onServiceRequested
        self.isDoNotDisturb = isDoNotDisturb
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let serviceIDString = response.notification.request.content.userInfo["serviceID"] as? String,
           let serviceID = UUID(uuidString: serviceIDString) {
            onServiceRequested(serviceID)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Suppress all banners and sounds while Do Not Disturb is active.
        if isDoNotDisturb() {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }
}
