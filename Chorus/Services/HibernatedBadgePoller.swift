import Foundation
import WebKit

// NOTE: The file is still named `HibernatedBadgePoller.swift` for build-inclusion
// reasons (new .swift files aren't auto-compiled by the checked-in project; see
// the project notes). The type it holds is `TransientBadgeFetcher` — the URLSession
// title-fetch poller it replaced could not see unread counts, because modern web
// apps inject those counts with JavaScript after load, not into the server HTML.

/// Fetches badge counts for services that have no live `WKWebView` (everything
/// the user isn't currently looking at, plus anything the pool has hibernated or
/// evicted). It renders each service once in a short-lived, offscreen web view —
/// using that service's own authenticated `WKWebsiteDataStore` — waits for the
/// page's JavaScript to write its unread count into the title or a DOM badge,
/// reads it, then tears the web view down to reclaim memory.
///
/// Why render at all: a plain HTTP fetch of the page returns the server HTML,
/// whose `<title>` has no count (Gmail 302-redirects to a login host, WhatsApp
/// ships an empty SPA shell, Facebook serves a "Redirecting…" stub, Slack/Discord
/// titles carry no number). Only a real web view runs the JS that produces the
/// count. A preloaded, never-displayed web view already hydrates its title in
/// this app (the visibility override keeps the page reporting "visible"), so an
/// offscreen frame-zero view is enough — no window attachment needed.
@MainActor
@Observable
final class TransientBadgeFetcher {
    /// Immutable snapshot of everything one fetch needs. Captured from the
    /// `@Model` object BEFORE any suspension point so a service deleted mid-sweep
    /// can never be touched across an `await`.
    struct Target: Sendable {
        let id: UUID
        let url: String
        let dataStoreIdentifier: UUID
        let userAgent: String?
        let badgeJS: String?
    }

    // MARK: - Injected collaborators (wired after AppState finishes init)

    /// Fresh list of services to fetch, built on the main actor each sweep.
    var targetsProvider: (@MainActor () -> [Target])?
    /// True when the service already has a live pooled web view — its own poll
    /// covers the badge, so the transient fetch skips it.
    var hasLiveWebView: (@MainActor (UUID) -> Bool)?
    /// Current mute / show-badge flags read at WRITE time (not from the possibly
    /// 20s-old snapshot), so a toggle during the fetch isn't undone by a late
    /// write. Returns nil if the service no longer exists — then the write is
    /// skipped entirely.
    var currentBadgeParams: (@MainActor (UUID) -> (isMuted: Bool, showBadge: Bool)?)?
    /// The compiled content-blocking rule lists to attach (ad/tracker blocking
    /// speeds the headless load and cuts noise). Empty until the lists compile.
    var enabledContentRuleLists: (@MainActor () -> [WKContentRuleList])?

    // MARK: - Tuning

    private let maxConcurrent = 3
    private let settleTimeout: TimeInterval = 20
    private let pollTick: Duration = .seconds(1)
    /// Once a positive count appears, keep reading only this much longer so a
    /// count that climbs during hydration stabilizes — then stop early instead of
    /// holding the web view for the full timeout.
    private let stabilizeGrace: TimeInterval = 2
    private let stagger: Duration = .milliseconds(400)

    private let badgeManager: BadgeManager
    private let dataStoreManager: DataStoreManager

    /// The repeating launch+periodic driver. `nil` when stopped/paused.
    private var scheduler: Task<Void, Never>?
    /// The sweep currently in flight, if any — cancelled on pause so in-flight
    /// fetches tear their web views down promptly.
    private var currentSweep: Task<Void, Never>?
    private var isPaused = false

    init(badgeManager: BadgeManager, dataStoreManager: DataStoreManager) {
        self.badgeManager = badgeManager
        self.dataStoreManager = dataStoreManager
    }

    // MARK: - Lifecycle

    /// Starts the launch sweep (after a short delay so it doesn't pile onto
    /// preload + favicon + catalog-icon fetches) and a slow periodic refresh.
    func start(initialDelay: Duration = .seconds(4), interval: Duration = .seconds(180)) {
        guard scheduler == nil else { return }
        isPaused = false
        scheduler = Task { @MainActor [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                if let self, !self.isPaused {
                    await self.runSweep()
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Suspend fetching without forgetting configuration. Cancels any in-flight
    /// sweep (its web views tear down as their tasks unwind) and stops the timer.
    func pause() {
        isPaused = true
        currentSweep?.cancel()
        currentSweep = nil
        scheduler?.cancel()
        scheduler = nil
    }

    /// Re-arm after `pause()`. Callers gate this on network reachability.
    func resume() {
        guard scheduler == nil else { return }
        start(initialDelay: .seconds(1))
    }

    // MARK: - Sweep

    private func runSweep() async {
        guard currentSweep == nil else { return }
        guard let targets = targetsProvider?(), !targets.isEmpty else { return }

        let sweep = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sweep(targets)
        }
        currentSweep = sweep
        await sweep.value
        // Only clear if we still own the slot. A prior sweep that was cancelled
        // by pause() may finish unwinding after resume() has already started a new
        // one; without this check it would wipe the new sweep's handle, letting a
        // later tick launch a second concurrent sweep and leaving it uncancellable.
        if currentSweep == sweep {
            currentSweep = nil
        }
    }

    /// Runs `fetchOne` over the targets with at most `maxConcurrent` in flight,
    /// staggering the initial starts so the web views don't spin up all at once.
    private func sweep(_ targets: [Target]) async {
        var index = 0

        await withTaskGroup(of: Void.self) { group in
            func addNext() -> Bool {
                guard index < targets.count else { return false }
                let target = targets[index]
                index += 1
                group.addTask { [weak self] in await self?.fetchOne(target) }
                return true
            }

            for _ in 0..<maxConcurrent {
                guard addNext() else { break }
                // Stagger the initial burst; skip the wait once we've queued the
                // last target.
                if index < targets.count { try? await Task.sleep(for: stagger) }
            }

            while await group.next() != nil {
                if Task.isCancelled { break }
                _ = addNext()
            }
        }
    }

    /// Renders one service offscreen, reads its badge, tears the view down.
    private func fetchOne(_ target: Target) async {
        // The user may have opened it since the sweep started — its live poll
        // covers the badge, so don't spend a web view on it.
        if hasLiveWebView?(target.id) == true { return }
        guard !isPaused, !Task.isCancelled else { return }
        guard let url = URL(string: target.url) else { return }

        let webView = makeTransientWebView(for: target)
        webView.load(URLRequest(url: url))

        let best = await boundedSettle(for: target, webView: webView)

        // Stop the load unconditionally. On the normal path this reaps the web
        // content process as the local reference drops; on the watchdog path it
        // also tends to fail an outstanding evaluateJavaScript, unsticking the
        // abandoned settle task so its own reference releases too.
        webView.stopLoading()

        // Raise-only: a transient view torn down after a bounded window can't tell
        // "authenticated inbox, 0 unread" from "auth wall / didn't hydrate" — both
        // read 0 — so a 0 is treated as no information and never clears a badge.
        // Only the live poll (when the user opens the service) clears
        // authoritatively. This can leave a badge stale-high for one refresh
        // cycle, which beats hiding a real unread count behind a false 0.
        guard best > 0 else { return }
        guard let params = currentBadgeParams?(target.id) else { return }
        badgeManager.updateBadge(
            for: target.id,
            count: best,
            isMuted: params.isMuted,
            showBadge: params.showBadge
        )
    }

    /// Runs the settle loop but guarantees a return within a hard watchdog window,
    /// even though `WKWebView.evaluateJavaScript` is not cancellation-aware and can
    /// park indefinitely on a wedged web-content process. If the watchdog wins, the
    /// settle task is abandoned (it holds its own web-view reference and is reaped
    /// when the call finally returns or the process dies) and we return 0 — so one
    /// hung page can't leak into blocking the whole sweep.
    private func boundedSettle(for target: Target, webView: WKWebView) async -> Int {
        let watchdog = Duration.seconds(settleTimeout + 2)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let once = BadgeFetchResumeGate()
            let work = Task { @MainActor [weak self] in
                let best = await self?.runSettleLoop(for: target, webView: webView) ?? 0
                if once.take() { continuation.resume(returning: best) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: watchdog)
                if once.take() {
                    work.cancel()
                    continuation.resume(returning: 0)
                }
            }
        }
    }

    /// Polls title + DOM badge once per tick until a positive count appears (then
    /// a short grace to let a climbing count stabilize) or the timeout. Returns
    /// the highest count seen. Bails early — handing back what it has — if paused,
    /// cancelled, or the service gained a live web view.
    private func runSettleLoop(for target: Target, webView: WKWebView) async -> Int {
        var best = 0
        let hardDeadline = Date().addingTimeInterval(settleTimeout)
        var deadline = hardDeadline

        while true {
            try? await Task.sleep(for: pollTick)
            // A cancelled sleep returns immediately; the guard below stops the loop
            // from spinning delay-free.
            guard !isPaused, !Task.isCancelled else { return best }
            // The user opened it — hand the badge to the live poll, don't write.
            if hasLiveWebView?(target.id) == true { return 0 }
            if Date() >= deadline { break }

            // Authoritative source: the DOM selector when the service defines one
            // (Gmail Inbox, LinkedIn messaging), otherwise the title. A service
            // with a selector never reads the title, so a title count for another
            // view can't inflate the badge.
            if let js = target.badgeJS {
                if let result = try? await webView.evaluateJavaScript(js) {
                    if let intResult = result as? Int {
                        best = max(best, intResult)
                    } else if let stringResult = result as? String, let parsed = Int(stringResult) {
                        best = max(best, parsed)
                    }
                }
            } else if let title = (try? await webView.evaluateJavaScript("document.title")) as? String {
                best = max(best, NotificationManager.extractBadgeCount(from: title))
            }

            if best > 0 {
                deadline = min(Date().addingTimeInterval(stabilizeGrace), hardDeadline)
            }
        }
        return best
    }

    /// A deliberately minimal configuration: the service's authenticated data
    /// store, the visibility override (so an offscreen page still writes its
    /// count), and content blockers. It OMITS the `chorusNotification` handler on
    /// purpose — a hidden view that spoofs visibility is exactly the state where a
    /// page fires `window.Notification`, and forwarding those would post OS
    /// notifications for services the user isn't looking at. It also omits Dark
    /// Reader, custom CSS, and call detection, none of which a headless read needs.
    private func makeTransientWebView(for target: Target) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStoreManager.dataStore(forIdentifier: target.dataStoreIdentifier)
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: UserScriptManager.makeVisibilityOverrideScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        for ruleList in enabledContentRuleLists?() ?? [] {
            controller.add(ruleList)
        }
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = target.userAgent ?? UserAgentProvider.safariDefault
        return webView
    }
}

/// Ensures a continuation is resumed exactly once when two racers (the settle
/// task and the watchdog) can each try. Main-actor isolated, so the flag check
/// and set never interleave.
@MainActor
private final class BadgeFetchResumeGate {
    private var taken = false
    func take() -> Bool {
        if taken { return false }
        taken = true
        return true
    }
}
