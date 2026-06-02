import Foundation
import WebKit
import UserNotifications

@MainActor
@Observable
final class NotificationManager {
    private var pollTasks: [UUID: Task<Void, Never>] = [:]
    private let badgeManager: BadgeManager
    private var pendingServiceID: UUID?

    var onServiceRequested: (@MainActor (UUID) -> Void)?

    init(badgeManager: BadgeManager) {
        self.badgeManager = badgeManager
        requestNotificationPermission()
        configureNotificationDelegate()
    }

    /// Title poll interval starts at 5s and backs off to 30s after 10 minutes of no badge changes.
    /// DOM badge poll runs at 2x the title interval. Resets to fast polling when badge count changes.
    func startPolling(
        for instanceID: UUID,
        webView: WKWebView,
        isMuted: Bool,
        showBadge: Bool,
        catalogEntry: ServiceCatalogEntry?
    ) {
        stopPolling(for: instanceID)

        let task = Task { @MainActor [weak self, weak webView] in
            var titleInterval = 5   // seconds between title polls — starts fast
            var tick = 0
            var unchangedCycles = 0 // how many title polls returned the same count

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let webView, !Task.isCancelled else { break }

                tick += 1

                // Title polling at adaptive interval
                if tick % titleInterval == 0 {
                    // Use raw counts here so the DND mask doesn't make every
                    // poll appear "unchanged" and prematurely back off the
                    // interval while DND is active.
                    let previousCount = self.badgeManager.rawCount(for: instanceID)
                    await pollTitle(webView: webView, instanceID: instanceID, isMuted: isMuted, showBadge: showBadge)
                    let newCount = self.badgeManager.rawCount(for: instanceID)

                    if newCount == previousCount {
                        unchangedCycles += 1
                        // Back off: 5s → 10s → 15s → 20s → 30s (cap)
                        if unchangedCycles >= 120 { // ~10 min at 5s
                            titleInterval = min(titleInterval + 5, 30)
                            unchangedCycles = 0
                        }
                    } else {
                        // Badge changed — reset to fast polling
                        titleInterval = 5
                        unchangedCycles = 0
                    }
                }

                // DOM badge polling at 2x the title interval
                let badgeInterval = titleInterval * 2
                if tick % badgeInterval == 0, let entry = catalogEntry, entry.badgeJS != nil {
                    await pollBadge(webView: webView, instanceID: instanceID, isMuted: isMuted, showBadge: showBadge, catalogEntry: entry)
                }
            }
        }
        pollTasks[instanceID] = task
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

    func handlePendingNotification() -> UUID? {
        let id = pendingServiceID
        pendingServiceID = nil
        return id
    }

    // MARK: - Polling

    private func pollTitle(webView: WKWebView, instanceID: UUID, isMuted: Bool, showBadge: Bool) async {
        do {
            let result = try await webView.evaluateJavaScript("document.title")
            if let title = result as? String {
                let count = Self.extractBadgeCount(from: title)
                badgeManager.updateBadge(for: instanceID, count: count, isMuted: isMuted, showBadge: showBadge)
            }
        } catch {
            // Page may not be ready yet
        }
    }

    private func pollBadge(webView: WKWebView, instanceID: UUID, isMuted: Bool, showBadge: Bool, catalogEntry: ServiceCatalogEntry) async {
        guard let badgeJS = catalogEntry.badgeJS else { return }
        do {
            let result = try await webView.evaluateJavaScript(badgeJS)
            let count: Int
            if let intResult = result as? Int {
                count = intResult
            } else if let stringResult = result as? String, let parsed = Int(stringResult) {
                count = parsed
            } else {
                return
            }
            badgeManager.updateBadge(for: instanceID, count: count, isMuted: isMuted, showBadge: showBadge)
        } catch {
            // Badge extraction failed — page may have changed
        }
    }

    static func extractBadgeCount(from title: String) -> Int {
        let pattern = /\((\d+)\)/
        if let match = title.firstMatch(of: pattern),
           let count = Int(match.1) {
            return count
        }
        return 0
    }

    // MARK: - Notifications

    private nonisolated func requestNotificationPermission() {
        Task {
            do {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                // Permission denied or error — non-critical
            }
        }
    }

    private func configureNotificationDelegate() {
        let badgeManager = self.badgeManager
        let delegate = NotificationCenterDelegate(
            onServiceRequested: { [weak self] serviceID in
                Task { @MainActor in
                    self?.onServiceRequested?(serviceID)
                }
            },
            isDoNotDisturb: {
                MainActor.assumeIsolated { badgeManager.doNotDisturb }
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
    static var retained: NotificationCenterDelegate?

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
