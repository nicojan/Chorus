import Foundation
import WebKit
import AppKit

@MainActor
@Observable
final class WebViewPool {
    private var webViews: [UUID: WKWebView] = [:]
    private var lastAccessTimes: [UUID: Date] = [:]
    private var coordinators: [UUID: WebViewCoordinator] = [:]
    private var suspendedURLs: [UUID: String] = [:]
    private var snapshots: [UUID: NSImage] = [:]
    private let maxLoaded: Int = 15

    /// Guard set: IDs currently being evaluated for eviction.
    private var evictionInFlight: Set<UUID> = []

    /// Services the user has marked as never-hibernate. Exempt from both
    /// soft hibernation (media pause) and full eviction.
    private var neverHibernateIDs: Set<UUID> = []

    /// Services pinned by external callers (e.g. the selected service
    /// during initial preload, before WebContentView attaches and sets
    /// `activeServiceID`). Exempt from eviction.
    private var pinnedIDs: Set<UUID> = []

    private let dataStoreManager: DataStoreManager
    private let userScriptManager: UserScriptManager
    private let contentBlocker: ContentBlockerManager

    /// The app's current effective Light/Dark appearance, pushed by AppState.
    /// Baked into each web view's Dark Reader scripts at build time so a service
    /// opted into dark theming starts in the right state.
    private(set) var effectiveAppearanceDark = false

    /// Whether the global "dark-theme services without one" setting is on, pushed
    /// by AppState. Drives detection for services in `.auto` mode.
    private(set) var autoDarkModeEnabled = false

    /// The currently active/displayed service
    private(set) var activeServiceID: UUID?

    /// Set of service IDs currently fully hibernated (web view destroyed)
    private(set) var hibernatedServiceIDs: Set<UUID> = []

    /// Per-service camera/microphone capture state, driven by KVO on each web
    /// view. Populated for background services too (a call on a service you're
    /// not viewing), so the rail can show an in-use dot. Absent ⇒ nothing live.
    struct MediaCaptureState: Equatable {
        var cameraActive = false   // camera live (capturing, not paused); a
                                   // paused (.muted) camera shows no dot, matching
                                   // the mic's distinct muted state below
        var micActive = false      // microphone live
        var micMuted = false       // microphone engaged but muted
        var isCapturing: Bool { cameraActive || micActive || micMuted }
    }
    private(set) var mediaCaptureStates: [UUID: MediaCaptureState] = [:]
    private var mediaObservations: [UUID: [NSKeyValueObservation]] = [:]

    /// Called when a service is fully hibernated (for badge poller tracking)
    var onServiceHibernated: ((UUID) -> Void)?

    /// Called when a service wakes from full hibernation (for badge poller untracking)
    var onServiceWoke: ((UUID) -> Void)?

    /// Called when a service is soft-hibernated (for pausing notification polling)
    var onServiceSoftHibernated: ((UUID) -> Void)?

    /// Called when a service wakes from soft hibernation
    var onServiceSoftWoke: ((UUID) -> Void)?

    /// Called when a service's web view is permanently removed (deletion, not hibernation)
    var onServiceRemoved: ((UUID) -> Void)?

    /// Called whenever a service's web view is torn down for ANY reason — full
    /// hibernation, rebuild (recreateWebView), LRU eviction, or removal — i.e. the
    /// single `teardownWebView` chokepoint. Distinct from `onServiceRemoved`
    /// (permanent deletion only); used to invalidate a pending media prompt whose
    /// web view is going away.
    var onServiceTornDown: ((UUID) -> Void)?

    /// Wired up at AppState init and applied to every coordinator the pool
    /// creates. Routes cross-domain target=_blank links + Cmd-clicks through
    /// service-aware matching before falling back to the system browser.
    var externalLinkHandler: ((URL) -> Void)?

    /// Wired up at AppState init and applied to every coordinator. Resolves a
    /// camera/microphone capture request to a WebKit decision from the persisted
    /// per-service policy. The pool is a pass-through — it owns neither the policy
    /// nor the prompt UI.
    var mediaCapturePolicyProvider: ((UUID, WKMediaCaptureType, WKFrameInfo) async -> WKPermissionDecision)?

    /// Called after a service has been preloaded (web view created and load
    /// dispatched, but not yet displayed). Allows callers to start background
    /// polling so the service can collect badge counts before the user clicks it.
    var onServicePreloaded: ((UUID, WKWebView) -> Void)?

    /// Called when a service's main web view finishes a top-level navigation
    /// (fresh load or login redirect), so callers can fire an immediate badge
    /// poll. Forwarded from each coordinator's `onNavigationFinished`.
    var onNavigationFinished: ((UUID) -> Void)?

    /// Exposes the live `WKWebView` for a service, if one currently exists.
    /// Used by callers that need to attach background polling to a soft-
    /// hibernated or preloaded webview without going through `webView(for:)`,
    /// which has the side-effect of marking the service active.
    func liveWebView(for instanceID: UUID) -> WKWebView? {
        webViews[instanceID]
    }

    /// Snapshot of all service IDs whose WKWebViews are currently alive.
    /// Used after system wake to restart polling for everything that survived
    /// the sleep cycle.
    var liveServiceIDs: [UUID] {
        Array(webViews.keys)
    }

    init(
        dataStoreManager: DataStoreManager,
        userScriptManager: UserScriptManager,
        contentBlocker: ContentBlockerManager
    ) {
        self.dataStoreManager = dataStoreManager
        self.userScriptManager = userScriptManager
        self.contentBlocker = contentBlocker
    }

    func webView(for instance: ServiceInstance) -> WKWebView {
        // Track the never-hibernate preference
        if instance.neverHibernate {
            neverHibernateIDs.insert(instance.id)
        } else {
            neverHibernateIDs.remove(instance.id)
        }

        // Soft-hibernate the previously active service (suspend media, take snapshot)
        if let previousID = activeServiceID, previousID != instance.id {
            softHibernateService(previousID)
        }
        activeServiceID = instance.id

        // Wake from full hibernation if needed
        if hibernatedServiceIDs.contains(instance.id) {
            hibernatedServiceIDs.remove(instance.id)
            onServiceWoke?(instance.id)
        }

        if let existing = webViews[instance.id] {
            lastAccessTimes[instance.id] = Date()
            wakeService(instance.id)
            return existing
        }

        let config = makeConfiguration(for: instance)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = instance.userAgent ?? UserAgentProvider.safariDefault

        let coordinator = makeCoordinator(for: instance)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinators[instance.id] = coordinator

        webViews[instance.id] = webView
        lastAccessTimes[instance.id] = Date()
        observeCaptureState(webView, id: instance.id)

        // Restore the last-visited URL when waking from full hibernation
        // so the user lands back where they left off, not at the home URL.
        // Falls back to the service home URL on first creation or when no
        // suspended URL is recorded.
        let resumeURLString = suspendedURLs.removeValue(forKey: instance.id) ?? instance.url
        if let url = URL(string: resumeURLString), !resumeURLString.isEmpty {
            webView.load(URLRequest(url: url))
        } else if let homeURL = URL(string: instance.url) {
            webView.load(URLRequest(url: homeURL))
        }

        // Check eviction asynchronously (needs to query JS for active calls)
        Task {
            await self.evictIfNeeded()
        }

        return webView
    }

    /// Preloads a web view for a service in the background without making it active.
    /// The web view is created and starts loading, but no soft-hibernation of other
    /// services is triggered and no notification polling starts. This makes the service
    /// feel instant when the user eventually selects it.
    /// Skips services that already have a web view or are fully hibernated-by-user.
    func preload(_ instance: ServiceInstance) {
        guard webViews[instance.id] == nil else { return }
        guard instance.modelContext != nil else { return }

        let config = makeConfiguration(for: instance)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = instance.userAgent ?? UserAgentProvider.safariDefault

        let coordinator = makeCoordinator(for: instance)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinators[instance.id] = coordinator

        webViews[instance.id] = webView
        lastAccessTimes[instance.id] = Date()
        observeCaptureState(webView, id: instance.id)

        if let url = URL(string: instance.url) {
            webView.load(URLRequest(url: url))
        }

        AppLogger.webView.debug("Preloaded service \(instance.label)")
        onServicePreloaded?(instance.id, webView)

        Task {
            await evictIfNeeded()
        }
    }

    /// Preloads web views for multiple services with a staggered delay to avoid
    /// overwhelming the network and CPU on startup.
    /// Captures references before the loop so deleted SwiftData objects don't
    /// cause issues across await suspension points.
    func preloadAll(_ instances: [ServiceInstance], delayBetween: Duration = .milliseconds(500)) async {
        // Snapshot the list before any suspension points — a service could be
        // deleted during the staggered sleep, and accessing a deleted @Model
        // object's properties is undefined.
        struct PreloadEntry { let id: UUID; let instance: ServiceInstance }
        let entries = instances.map { PreloadEntry(id: $0.id, instance: $0) }

        for entry in entries {
            guard !Task.isCancelled else { break }
            guard webViews[entry.id] == nil else { continue }
            // Verify the model object is still in a valid context before accessing it
            guard entry.instance.modelContext != nil else { continue }
            preload(entry.instance)
            try? await Task.sleep(for: delayBetween)
        }
    }

    /// Returns a snapshot of the service's last visible state (captured on switch-away)
    func snapshot(for id: UUID) -> NSImage? {
        snapshots[id]
    }

    func removeWebView(for instanceID: UUID) {
        teardownWebView(instanceID)
        suspendedURLs.removeValue(forKey: instanceID)
        hibernatedServiceIDs.remove(instanceID)
        // Permanent removal (deletion, not hibernation): drop every trace of
        // the service so stale IDs can't dangle. The active pointer must be
        // cleared or keyboard shortcuts / eviction would target a ghost; the
        // pin/never-hibernate/in-flight sets and the script message handler
        // would otherwise grow unbounded across create/delete cycles.
        if activeServiceID == instanceID {
            activeServiceID = nil
        }
        pinnedIDs.remove(instanceID)
        neverHibernateIDs.remove(instanceID)
        evictionInFlight.remove(instanceID)
        userScriptManager.removeHandler(for: instanceID)
        onServiceRemoved?(instanceID)
        snapshots.removeValue(forKey: instanceID)
    }

    func hasWebView(for instanceID: UUID) -> Bool {
        webViews[instanceID] != nil
    }

    func isHibernated(_ instanceID: UUID) -> Bool {
        hibernatedServiceIDs.contains(instanceID)
    }

    /// Manually hibernate a service — fully destroys the web view to reclaim all memory.
    /// The service reloads its home URL when next accessed.
    func hibernate(_ instanceID: UUID) {
        guard let webView = webViews[instanceID] else { return }
        suspendedURLs[instanceID] = webView.url?.absoluteString ?? ""
        teardownWebView(instanceID)
        hibernatedServiceIDs.insert(instanceID)
        onServiceHibernated?(instanceID)
        AppLogger.webView.info("Fully hibernated service \(instanceID)")
    }

    /// Check if a service currently has an active WebRTC call.
    func hasActiveCall(for instanceID: UUID) async -> Bool {
        guard webViews[instanceID] != nil else { return false }
        // Bound the JS check. A wedged WebContent process can leave
        // evaluateJavaScript's continuation pending forever; without a real
        // timeout the id would stay in `evictionInFlight` and be excluded from
        // every future eviction pass, so the pool would grow past maxLoaded.
        // Treat "no answer within the window" as "no call" so eviction proceeds
        // (a process that can't answer a one-property read in 2s is wedged and
        // should be reclaimed anyway).
        //
        // A structured `withTaskGroup` can't deliver this: it implicitly awaits
        // every child before returning, and evaluateJavaScript isn't
        // cancellation-aware, so `cancelAll()` wouldn't unstick the wedged probe
        // and the group would hang. So race two unstructured main-actor tasks —
        // the probe and a 2s timer — and resume the continuation with whichever
        // answers first, abandoning (not awaiting) the loser. A leaked wedged
        // probe just lingers until the OS reaps the process.
        return await withCheckedContinuation { continuation in
            let gate = CallProbeGate()
            Task { @MainActor in
                let hasCall = await self.probeCallDetection(instanceID)
                if gate.claim() { continuation.resume(returning: hasCall) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if gate.claim() { continuation.resume(returning: false) }
            }
        }
    }

    /// Runs the call-detection JS for a service on the main actor, returning
    /// false if the service has no live web view or the query fails. Re-fetches
    /// the web view by id (rather than capturing it) so `hasActiveCall`'s race
    /// tasks carry only Sendable values.
    private func probeCallDetection(_ instanceID: UUID) async -> Bool {
        guard let webView = webViews[instanceID] else { return false }
        let result = try? await webView.evaluateJavaScript(UserScriptManager.callDetectionQueryJS)
        return (result as? Bool) == true
    }

    /// Memory usage estimate: count of loaded web views
    var loadedCount: Int {
        webViews.count
    }

    /// Mark a service as un-evictable. Used by callers that know a service
    /// will become active soon (e.g. preload of the selected service) but
    /// can't set `activeServiceID` themselves.
    func pin(_ id: UUID) {
        pinnedIDs.insert(id)
    }

    /// Remove the pin set by `pin(_:)`. Safe to call for an unpinned id.
    func unpin(_ id: UUID) {
        pinnedIDs.remove(id)
    }

    /// Sync the never-hibernate flag for a service after the user toggles it
    /// in the editor. The flag is otherwise only read when a web view is
    /// created, so a live service wouldn't pick up the change until next load.
    func setNeverHibernate(_ value: Bool, for id: UUID) {
        if value {
            neverHibernateIDs.insert(id)
        } else {
            neverHibernateIDs.remove(id)
        }
    }

    /// Navigate a service's live web view to a URL. Used when the user edits a
    /// service's URL so the open page follows the change. No-op if the service
    /// has no live web view (it will load the new URL when next opened).
    func navigate(_ id: UUID, to url: URL) {
        webViews[id]?.load(URLRequest(url: url))
    }

    /// Update a live web view's user agent (e.g. the Mobile view toggle) and
    /// reload so the site re-renders for the new agent. No-op without a live
    /// view — the new agent applies when the view is next created.
    func setUserAgent(_ userAgent: String?, for id: UUID) {
        guard let webView = webViews[id] else { return }
        webView.customUserAgent = userAgent ?? UserAgentProvider.safariDefault
        webView.reload()
    }

    /// Rebuilds a service's web view so configuration-time settings — the
    /// injected user scripts, including custom CSS — pick up an edit. The view
    /// is torn down here and recreated on next access; the active pointer and
    /// never-hibernate state are left intact (this is a refresh, not a removal).
    /// With `preserveURL` false the open URL is dropped so the rebuild loads the
    /// service's (possibly just-edited) home URL instead.
    func recreateWebView(for instanceID: UUID, preserveURL: Bool = true) {
        guard let webView = webViews[instanceID] else { return }
        if preserveURL {
            suspendedURLs[instanceID] = webView.url?.absoluteString ?? ""
        } else {
            suspendedURLs.removeValue(forKey: instanceID)
        }
        teardownWebView(instanceID)
    }

    // MARK: - Soft Hibernate (resource offloading without destroying the web view)

    /// Suspends media playback and captures a snapshot.
    /// The WKWebView stays alive so JS continues running (notifications, WebRTC, etc.)
    /// but WebKit releases GPU textures and compositor resources when the view has no superview.
    private func softHibernateService(_ id: UUID) {
        guard let webView = webViews[id] else { return }
        guard !neverHibernateIDs.contains(id) else { return }
        webView.setAllMediaPlaybackSuspended(true)
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let image else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The snapshot completes asynchronously; if the service was
                // removed (deleted) meanwhile, don't re-insert a snapshot for a
                // dead id — that would be a small permanent leak.
                guard self.webViews[id] != nil else { return }
                self.snapshots[id] = image
            }
        }
        AppLogger.webView.debug("Soft-hibernated service \(id)")
        onServiceSoftHibernated?(id)
    }

    /// Resumes media playback when a service becomes active again.
    private func wakeService(_ id: UUID) {
        guard let webView = webViews[id] else { return }
        webView.setAllMediaPlaybackSuspended(false)
        AppLogger.webView.debug("Woke service \(id)")
        onServiceSoftWoke?(id)
    }

    // MARK: - Private

    /// Observes a web view's camera/mic capture state so the rail shows an in-use
    /// dot even for a background service. Mirrors WebViewState's KVO discipline:
    /// the callback captures only Sendable values (the id + an object-identity
    /// token), hops to main, and re-fetches the live view — re-checking identity
    /// so a torn-down view's late callback can't light a dot for a recycled id.
    private func observeCaptureState(_ webView: WKWebView, id: UUID) {
        let token = ObjectIdentifier(webView)
        // Inlined (not a shared local) so each closure literal is inferred
        // @Sendable — a stored non-Sendable function value trips Swift 6's
        // data-race check when handed to `observe`'s @Sendable changeHandler.
        mediaObservations[id] = [
            webView.observe(\.cameraCaptureState, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self, let live = self.webViews[id],
                          ObjectIdentifier(live) == token else { return }
                    self.refreshMediaCaptureState(id: id, webView: live)
                }
            },
            webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self, let live = self.webViews[id],
                          ObjectIdentifier(live) == token else { return }
                    self.refreshMediaCaptureState(id: id, webView: live)
                }
            },
        ]
    }

    /// Recomputes and stores a service's capture state from its live web view,
    /// dropping the entry entirely when nothing is live.
    private func refreshMediaCaptureState(id: UUID, webView: WKWebView) {
        var state = MediaCaptureState()
        // Only .active counts as "live" — a .muted (paused) camera shouldn't show
        // a green in-use dot. Mic tracks active vs. muted separately so the glyph
        // can distinguish "live" from "muted".
        state.cameraActive = (webView.cameraCaptureState == .active)
        state.micActive = (webView.microphoneCaptureState == .active)
        state.micMuted = (webView.microphoneCaptureState == .muted)
        if state.isCapturing {
            mediaCaptureStates[id] = state
        } else {
            mediaCaptureStates.removeValue(forKey: id)
        }
    }

    /// Mutes or unmutes a service's live microphone (host-side, so the far end
    /// sees it). No-op without a live capturing web view.
    func setMicrophoneMuted(_ muted: Bool, for id: UUID) {
        guard let webView = webViews[id],
              webView.microphoneCaptureState != WKMediaCaptureState.none else { return }
        webView.setMicrophoneCaptureState(muted ? .muted : .active, completionHandler: nil)
    }

    /// Mutes every service whose microphone is currently live. Returns how many
    /// were muted, so a caller can tell when nothing was live.
    @discardableResult
    func muteAllMicrophones() -> Int {
        var count = 0
        for (_, webView) in webViews where webView.microphoneCaptureState == .active {
            webView.setMicrophoneCaptureState(.muted, completionHandler: nil)
            count += 1
        }
        return count
    }

    private func teardownWebView(_ instanceID: UUID) {
        if let webView = webViews[instanceID] {
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        mediaObservations[instanceID]?.forEach { $0.invalidate() }
        mediaObservations.removeValue(forKey: instanceID)
        mediaCaptureStates.removeValue(forKey: instanceID)
        webViews.removeValue(forKey: instanceID)
        lastAccessTimes.removeValue(forKey: instanceID)
        coordinators.removeValue(forKey: instanceID)
        snapshots.removeValue(forKey: instanceID)
        onServiceTornDown?(instanceID)
    }

    /// Builds a navigation/UI coordinator wired to this service. Shared by
    /// `webView(for:)` and `preload(_:)` so the instance id, fallback URL,
    /// external-link routing, and navigation-finished callback stay in sync.
    private func makeCoordinator(for instance: ServiceInstance) -> WebViewCoordinator {
        let coordinator = WebViewCoordinator()
        coordinator.instanceID = instance.id
        coordinator.fallbackURL = URL(string: instance.url)
        coordinator.externalLinkHandler = externalLinkHandler
        coordinator.mediaCapturePolicyProvider = mediaCapturePolicyProvider
        coordinator.onNavigationFinished = { [weak self] id in
            self?.onNavigationFinished?(id)
        }
        return coordinator
    }

    private func makeConfiguration(for instance: ServiceInstance) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStoreManager.dataStore(for: instance)
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Enable back-forward cache so swiping back loads instantly from cache
        config.preferences.isElementFullscreenEnabled = true

        // NOTE: no picture-in-picture config flag here. That flag
        // (allowsPictureInPictureMediaPlayback) is iOS-only; on macOS WebKit
        // exposes video PiP through the native media controls automatically.

        let controller = WKUserContentController()
        let injection = DarkReaderSupport.injection(
            mode: instance.darkMode,
            globalAuto: autoDarkModeEnabled,
            appDark: effectiveAppearanceDark,
            detectedLacksDark: instance.detectedLacksDarkTheme,
            nativeDark: nativeDark(for: instance)
        )
        userScriptManager.configureScripts(
            for: instance,
            customCSS: effectiveCSS(for: instance),
            darkInjection: injection,
            on: controller
        )
        // Attach the compiled content-blocking rule lists (ad/tracker domains)
        // when blocking is enabled. Returns empty — a no-op — until the lists
        // finish compiling at launch; those web views pick the lists up via
        // reattachContentBlocker().
        for ruleList in contentBlocker.enabledLists() {
            controller.add(ruleList)
        }

        config.userContentController = controller

        return config
    }

    /// Updates the content-blocking rule lists on every live web view *in place*
    /// — no teardown — so it takes effect without reloading the page, dropping
    /// background badge polls, or discarding preloaded views. Called when the
    /// blocklist finishes compiling after launch and when the global toggle
    /// flips; views built afterward already carry the right lists via
    /// `makeConfiguration`.
    func reattachContentBlocker() {
        let lists = contentBlocker.enabledLists()
        for webView in webViews.values {
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            for ruleList in lists {
                controller.add(ruleList)
            }
        }
    }

    /// The effective per-service CSS (service defaults + any custom CSS), or nil
    /// when there's none. Shared by `makeConfiguration` and the dark-mode
    /// reinstall paths so both bake the same scripts.
    private func effectiveCSS(for instance: ServiceInstance) -> String? {
        let css = ServiceCSSDefaults.effectiveCSS(
            instanceCSS: instance.customCSS,
            catalogID: instance.catalogEntryID
        )
        guard let css, !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return css
    }

    /// Whether a service is a catalog entry known to render dark on its own (see
    /// `ServiceCatalogEntry.nativeDark`). Custom (non-catalog) services and
    /// unmarked ones return false, so they keep the auto/probe behavior.
    private func nativeDark(for instance: ServiceInstance) -> Bool {
        guard let id = instance.catalogEntryID else { return false }
        return ServiceCatalog.shared.entry(for: id)?.nativeDark ?? false
    }

    /// Applies a Light/Dark appearance and global-auto change to every live web
    /// view: recomputes each service's dark injection and applies it on the
    /// current document at once, re-baking the view's user scripts so its next
    /// full navigation starts in the right state (and without a flash). Mirrors
    /// `reattachContentBlocker`: live views only, in place, no teardown. Views
    /// rebuilt later read the new state via `makeConfiguration`. Pass every
    /// service (not just marked ones) — `.auto` services need re-evaluating too.
    func applyDarkState(isDark: Bool, autoEnabled: Bool, services: [ServiceInstance]) {
        effectiveAppearanceDark = isDark
        autoDarkModeEnabled = autoEnabled
        let byID = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, webView) in webViews {
            guard let instance = byID[id] else { continue }
            let inj = DarkReaderSupport.injection(
                mode: instance.darkMode,
                globalAuto: autoEnabled,
                appDark: isDark,
                detectedLacksDark: instance.detectedLacksDarkTheme,
                nativeDark: nativeDark(for: instance)
            )
            applyInjectionLive(inj, to: webView, instance: instance)
        }
    }

    /// Recomputes and applies a single live service's dark injection — used after
    /// a per-service Auto/On/Off edit and after a detection verdict is cached.
    /// A no-op if the view isn't live (it rebuilds via `makeConfiguration`).
    func refreshDarkMode(for instance: ServiceInstance) {
        guard let webView = webViews[instance.id] else { return }
        let inj = DarkReaderSupport.injection(
            mode: instance.darkMode,
            globalAuto: autoDarkModeEnabled,
            appDark: effectiveAppearanceDark,
            detectedLacksDark: instance.detectedLacksDarkTheme,
            nativeDark: nativeDark(for: instance)
        )
        applyInjectionLive(inj, to: webView, instance: instance)
    }

    /// Applies an injection to a live web view in place: enable/disable/probe on
    /// the current document, then re-bake the view's user scripts so the next
    /// navigation matches. `.themed` injects the library before enabling because
    /// the current document's isolated world may not have it yet.
    private func applyInjectionLive(
        _ injection: DarkReaderSupport.DarkInjection,
        to webView: WKWebView,
        instance: ServiceInstance
    ) {
        let world = DarkReaderSupport.world
        switch injection {
        case .themed:
            webView.evaluateJavaScript(DarkReaderSupport.libraryJS, in: nil, in: world, completionHandler: nil)
            webView.evaluateJavaScript(DarkReaderSupport.enableJS, in: nil, in: world, completionHandler: nil)
            // Release a deferred probe-path cover (if any) now that theming is on,
            // so it tracks Dark Reader's settle instead of revealing the still-light
            // page early. A no-op when no cover is present.
            webView.evaluateJavaScript(DarkReaderSupport.beginCoverSettleJS, in: nil, in: world, completionHandler: nil)
        case .none:
            webView.evaluateJavaScript(DarkReaderSupport.disableJS, in: nil, in: world, completionHandler: nil)
        case .probe:
            webView.evaluateJavaScript(
                UserScriptManager.makeDarkProbeScript(serviceID: instance.id.uuidString),
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        userScriptManager.installUserScripts(
            for: instance,
            customCSS: effectiveCSS(for: instance),
            darkInjection: injection,
            on: controller
        )
    }

    /// When exceeding maxLoaded web views, fully hibernate the least recently used ones.
    /// Skips services that have an active WebRTC call.
    /// Uses `evictionInFlight` to prevent race conditions between the async JS check
    /// and the synchronous hibernation — a service won't be hibernated while its call
    /// state is being queried by another eviction pass.
    private func evictIfNeeded() async {
        guard webViews.count > maxLoaded else { return }

        let sorted = lastAccessTimes
            .filter { $0.key != activeServiceID
                   && !evictionInFlight.contains($0.key)
                   && !neverHibernateIDs.contains($0.key)
                   && !pinnedIDs.contains($0.key) }
            .sorted { $0.value < $1.value }

        for (id, _) in sorted {
            // Re-check the live count each pass, not a count captured up front:
            // a concurrent evictIfNeeded (they interleave at the `await` below)
            // may have already hibernated views, and a stale target would evict
            // past the cap, dropping the pool below maxLoaded.
            guard webViews.count > maxLoaded else { break }
            guard webViews[id] != nil else { continue }

            evictionInFlight.insert(id)
            let hasCall = await hasActiveCall(for: id)
            evictionInFlight.remove(id)

            // Re-check the web view still exists (may have been removed during await)
            guard webViews[id] != nil else { continue }

            // The await above is a suspension point: the user may have switched
            // to this service (making it active), or it may have been pinned /
            // marked never-hibernate in the meantime. Re-validate the eviction
            // guards so we never hibernate the service the user is now viewing.
            guard id != activeServiceID,
                  !pinnedIDs.contains(id),
                  !neverHibernateIDs.contains(id)
            else { continue }

            if hasCall {
                AppLogger.webView.info("Skipping eviction of \(id) — active call detected")
                continue
            }

            hibernate(id)
        }
    }
}

/// One-shot guard that lets exactly one of `hasActiveCall`'s two racing tasks
/// resume the continuation. Both racers are `@MainActor`, so the plain flag is
/// only ever touched on the main actor and needs no lock.
@MainActor
private final class CallProbeGate {
    private var used = false
    func claim() -> Bool {
        if used { return false }
        used = true
        return true
    }
}
