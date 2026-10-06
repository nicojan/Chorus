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
    /// When each live page loaded and when the user last left it, and each
    /// page's footprint once it settled. Both feed the memory watch; see
    /// `memoryReadings`.
    private var visits = ServiceVisits()
    private var baselineFootprints: [UUID: UInt64] = [:]
    /// Snapshot ids in the order they were stored, oldest first. Drives the cap
    /// below; `snapshots` alone has no order to evict by.
    private var snapshotOrder: [UUID] = []
    /// How many switch-away snapshots to keep. Each one is a full-window bitmap
    /// at backing scale — on a 1080 point window at 2x, about 13 MB — and before
    /// this cap every service you had ever switched away from held one for the
    /// life of the process. Three covers going back and forth between the
    /// services you are actually working in; a service older than that shows a
    /// plain load, which is what a fully hibernated one already does.
    private static let maxSnapshots: Int = 3
    private let maxLoaded: Int = 15

    /// Guard set: IDs currently being evaluated for eviction.
    private var evictionInFlight: Set<UUID> = []

    /// Services the user has marked as never-hibernate. Exempt from both
    /// soft hibernation (media pause) and full eviction.
    private var neverHibernateIDs: Set<UUID> = []

    /// Services that must stay live for real-time notifications (the Messaging
    /// catalog category). Exempt from FULL hibernation in both sweeps — the idle
    /// timer and the LRU cap sweep — so a chat app is never torn down and can
    /// keep firing instant alerts. The category lives in the catalog, which the
    /// pool doesn't own, so `AppState` classifies via the `isNotificationCritical`
    /// closure and the pool caches the result here at load time.
    private var notificationCriticalIDs: Set<UUID> = []

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

        /// One service's state from all its web views, the page and its tabs.
        /// Only .active counts as live, so a paused (.muted) camera shows no
        /// dot. The mic reads muted only when no view has it live.
        static func combined(camera: [WKMediaCaptureState], microphone: [WKMediaCaptureState]) -> MediaCaptureState {
            var state = MediaCaptureState()
            state.cameraActive = camera.contains(.active)
            state.micActive = microphone.contains(.active)
            state.micMuted = !state.micActive && microphone.contains(.muted)
            return state
        }
    }
    private(set) var mediaCaptureStates: [UUID: MediaCaptureState] = [:]
    private var mediaObservations: [UUID: [NSKeyValueObservation]] = [:]

    /// Services whose page is making sound right now, from WebKit's own
    /// `_isPlayingAudio` — the flag Safari draws its tab speaker from. It is
    /// false for muted media (a looping sticker video), goes false on pause, and
    /// is pushed through KVO, so nothing has to poll the page. Drives the rail's
    /// speaker mark and keeps the service playing when you switch away.
    private(set) var audibleServiceIDs: Set<UUID> = []
    private var audioObservers: [UUID: PlayingAudioObserver] = [:]
    /// Which of a service's web views are making sound. The service counts as
    /// audible while any of them is.
    private var audibleViews: [UUID: Set<ObjectIdentifier>] = [:]

    /// The watchers on each open tab, so a call or music in a tab shows in the
    /// rail and answers Mute All. Keyed by the tab's web view.
    private struct TabWatch {
        let serviceID: UUID
        let observations: [NSKeyValueObservation]
        let audio: PlayingAudioObserver
    }
    private var tabWatches: [ObjectIdentifier: TabWatch] = [:]

    /// Per-service page health, so the rail can mark a service that is still
    /// coming up or that failed — including one you are not looking at, which is
    /// the whole point. Absent ⇒ `.live`, so a healthy service costs no entry.
    private(set) var serviceHealth: [UUID: ServiceHealth] = [:]

    func health(for instanceID: UUID) -> ServiceHealth {
        serviceHealth[instanceID] ?? .live
    }

    /// Folds a navigation event into a service's health. Called by each
    /// coordinator; `.live` is stored as an absent entry.
    func applyHealthEvent(_ event: ServiceHealth.Event, to instanceID: UUID) {
        let next = health(for: instanceID).next(event)
        if next == .live {
            serviceHealth.removeValue(forKey: instanceID)
        } else {
            serviceHealth[instanceID] = next
        }
    }

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

    /// Classifies whether a service must stay live for real-time notifications
    /// (Messaging category). Set by `AppState`, which owns the catalog. Read at
    /// load time to populate `notificationCriticalIDs`. Defaults to "not
    /// critical" when unset, so the pool never over-exempts.
    var isNotificationCritical: ((UUID) -> Bool)?

    /// Called whenever a service's web view is torn down for ANY reason — full
    /// hibernation, rebuild (recreateWebView), LRU eviction, or removal — i.e. the
    /// single `teardownWebView` chokepoint. Distinct from `onServiceRemoved`
    /// (permanent deletion only); used to invalidate a pending media prompt whose
    /// web view is going away.
    var onServiceTornDown: ((UUID) -> Void)?

    /// Wired up at AppState init and applied to every coordinator the pool
    /// creates. Routes cross-domain target=_blank links + Cmd-clicks through
    /// service-aware matching before falling back to the system browser. The
    /// second argument is the source service's id, so AppState can honour that
    /// service's "open links in Chorus" choice.
    var externalLinkHandler: ((URL, UUID?) -> Void)?
    /// Whether some Chorus service owns a URL. Passed to each coordinator.
    var serviceOwnsURL: ((URL, UUID?) -> Bool)?
    /// The app-wide download list. Passed to each coordinator.
    var downloadCenter: DownloadCenter?

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

    /// The tabs a live service has open. Nil when the service has no web view.
    func tabs(for instanceID: UUID) -> ServiceTabs? {
        coordinators[instanceID]?.tabs
    }

    /// The web view on screen for a service: the selected tab, or its own page.
    /// What ⌘R, zoom and Find act on.
    func displayedWebView(for instanceID: UUID) -> WKWebView? {
        tabs(for: instanceID)?.selectedTab?.webView ?? webViews[instanceID]
    }

    /// Closes one of a service's tabs.
    func closeTab(_ tabID: UUID, for instanceID: UUID) {
        coordinators[instanceID]?.closeTab(tabID)
    }

    /// The service's own page and every tab it has open, for settings that
    /// apply to the whole service, such as zoom.
    func allWebViews(for instanceID: UUID) -> [WKWebView] {
        let page = webViews[instanceID].map { [$0] } ?? []
        return page + (tabs(for: instanceID)?.tabs.map(\.webView) ?? [])
    }

    /// Whether a service has tabs open. Such a service is never hibernated by
    /// the idle or memory sweeps, which would close a design the user left open.
    private func hasOpenTabs(_ instanceID: UUID) -> Bool {
        !(coordinators[instanceID]?.tabs.isEmpty ?? true)
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
        // Track the never-hibernate preference. Read the effective policy, not the
        // legacy `neverHibernate` flag, so the exemption can't diverge from what
        // the rest of the app treats as `.never`.
        if instance.hibernationPolicyEffective == .never {
            neverHibernateIDs.insert(instance.id)
        } else {
            neverHibernateIDs.remove(instance.id)
        }

        // Cache whether this service is notification-critical (chat), so both
        // hibernation sweeps can exempt it without consulting the catalog.
        if isNotificationCritical?(instance.id) == true {
            notificationCriticalIDs.insert(instance.id)
        } else {
            notificationCriticalIDs.remove(instance.id)
        }

        // Soft-hibernate the previously active service (suspend media, take snapshot)
        if let previousID = activeServiceID, previousID != instance.id {
            softHibernateService(previousID)
        }
        activeServiceID = instance.id
        visits.activate(instance.id, at: Date())

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
        let webView = WKWebView(frame: CGRect(origin: .zero, size: WebViewHostView.lastSize), configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = instance.userAgent ?? UserAgentProvider.safariDefault
        #if DEBUG
        // Lets Safari's Develop menu attach to the page, to watch a sign-in.
        webView.isInspectable = true
        #endif

        let coordinator = makeCoordinator(for: instance)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinators[instance.id] = coordinator

        webViews[instance.id] = webView
        lastAccessTimes[instance.id] = Date()
        visits.loaded(instance.id, at: Date())
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
        // A Mac-app service has no page to load.
        guard instance.nativeAppBundleID == nil else { return }

        let config = makeConfiguration(for: instance)
        let webView = WKWebView(frame: CGRect(origin: .zero, size: WebViewHostView.lastSize), configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = instance.userAgent ?? UserAgentProvider.safariDefault
        #if DEBUG
        // Lets Safari's Develop menu attach to the page, to watch a sign-in.
        webView.isInspectable = true
        #endif

        let coordinator = makeCoordinator(for: instance)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinators[instance.id] = coordinator

        webViews[instance.id] = webView
        lastAccessTimes[instance.id] = Date()
        visits.loaded(instance.id, at: Date())
        observeCaptureState(webView, id: instance.id)

        // Register the hibernation-exemption flags now, not just on first
        // activation. A service preloaded but never clicked would otherwise be
        // missing from these sets, so the idle sweep and the LRU cap could
        // hibernate or evict a "Keep Loaded" or chat service the user was
        // promised would stay live. Mirrors the same block in `webView(for:)`.
        if instance.hibernationPolicyEffective == .never {
            neverHibernateIDs.insert(instance.id)
        } else {
            neverHibernateIDs.remove(instance.id)
        }
        if isNotificationCritical?(instance.id) == true {
            notificationCriticalIDs.insert(instance.id)
        } else {
            notificationCriticalIDs.remove(instance.id)
        }

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
            visits.activate(nil, at: Date())
        }
        pinnedIDs.remove(instanceID)
        neverHibernateIDs.remove(instanceID)
        notificationCriticalIDs.remove(instanceID)
        evictionInFlight.remove(instanceID)
        userScriptManager.removeHandler(for: instanceID)
        onServiceRemoved?(instanceID)
        dropSnapshot(for: instanceID)
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
    ///
    /// Bounded at 2s: without a real timeout a wedged WebContent process would
    /// leave the id in `evictionInFlight` and out of every future eviction
    /// pass, so the pool would grow past maxLoaded. "No answer" reads as "no
    /// call", so eviction proceeds — a process that can't answer a one-property
    /// read in 2s is wedged and should be reclaimed anyway.
    func hasActiveCall(for instanceID: UUID) async -> Bool {
        guard webViews[instanceID] != nil else { return false }
        return await withDeadline(seconds: 2, fallback: false) {
            await self.probeCallDetection(instanceID)
        }
    }

    /// Every live service web view and open tab, for the quit handoff.
    var liveWebViews: [WKWebView] {
        webViews.keys.flatMap { allWebViews(for: $0) }
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
        guard webViews[id] != nil else { return }
        for webView in allWebViews(for: id) {
            webView.customUserAgent = userAgent ?? UserAgentProvider.safariDefault
            webView.reload()
        }
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

    /// Steps the visible service down when the selection moves to something
    /// with no web view (a Mac app), as `webView(for:)` does on a switch
    /// between pages. Without it the hidden page kept counting as the one on
    /// screen: its poll stopped, its media played on, and ⌘R and camera
    /// requests went to it.
    func deactivateActiveService() {
        guard let id = activeServiceID else { return }
        activeServiceID = nil
        visits.activate(nil, at: Date())
        softHibernateService(id)
    }

    // MARK: - Soft Hibernate (resource offloading without destroying the web view)

    /// Suspends media playback and captures a snapshot.
    /// The WKWebView stays alive so JS continues running (notifications, WebRTC, etc.)
    /// but WebKit releases GPU textures and compositor resources when the view has no superview.
    private func softHibernateService(_ id: UUID) {
        guard let webView = webViews[id] else { return }
        guard !neverHibernateIDs.contains(id) else { return }
        if Self.suspendsMediaOnSwitchAway(
            isCapturing: mediaCaptureStates[id]?.isCapturing ?? false,
            isPlayingAudio: audibleServiceIDs.contains(id)
        ) {
            allWebViews(for: id).forEach { $0.setAllMediaPlaybackSuspended(true) }
        }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let image else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The snapshot completes asynchronously; if the service was
                // removed (deleted) meanwhile, don't re-insert a snapshot for a
                // dead id — that would be a small permanent leak.
                guard self.webViews[id] != nil else { return }
                self.storeSnapshot(image, for: id)
            }
        }
        AppLogger.webView.debug("Soft-hibernated service \(id)")
        onServiceSoftHibernated?(id)
    }

    /// Whether leaving a service suspends its media. A service in a call keeps
    /// it: suspending would silence the other person while the microphone kept
    /// sending. A service making sound keeps it too, so music and a voice
    /// message carry on while you read something else, as in a browser tab.
    /// Anything else is paused, which stops a background page from starting
    /// autoplay. A page that begins to play only after you left gains nothing,
    /// because the check runs once, at the switch.
    nonisolated static func suspendsMediaOnSwitchAway(isCapturing: Bool, isPlayingAudio: Bool) -> Bool {
        !isCapturing && !isPlayingAudio
    }

    /// Whether a service's page is making sound. See `audibleServiceIDs`.
    func isPlayingAudio(_ id: UUID) -> Bool {
        audibleServiceIDs.contains(id)
    }

    /// Pauses every media element on a service's page, from the rail's context
    /// menu. On the service you are looking at it is only a pause, so the
    /// page's own controls and the media keys can start it again. On one in the
    /// background it also suspends playback until you come back, as leaving a
    /// quiet service does: a pause alone does not hold there, because a page
    /// can start playing again by itself, and YouTube does when an ad ends.
    func pauseAudio(for id: UUID) {
        let suspends = Self.suspendsMediaOnPause(isActive: id == activeServiceID)
        for webView in allWebViews(for: id) {
            webView.pauseAllMediaPlayback(completionHandler: nil)
            if suspends { webView.setAllMediaPlaybackSuspended(true) }
        }
    }

    /// Whether Pause Audio also suspends the page's media. See `pauseAudio`.
    nonisolated static func suspendsMediaOnPause(isActive: Bool) -> Bool {
        !isActive
    }

    /// Resumes media playback when a service becomes active again.
    private func wakeService(_ id: UUID) {
        guard webViews[id] != nil else { return }
        allWebViews(for: id).forEach { $0.setAllMediaPlaybackSuspended(false) }
        // The snapshot exists to cover the wake, so it has done its job here.
        // WebContentView reads it before asking for the web view and holds its
        // own reference until the page finishes loading, so this cannot blank
        // the transition. Left in place it would keep one window-sized NSImage
        // per service resident until teardown.
        dropSnapshot(for: id)
        AppLogger.webView.debug("Woke service \(id)")
        onServiceSoftWoke?(id)
    }

    /// Stores a switch-away snapshot and trims the oldest past the cap.
    private func storeSnapshot(_ image: NSImage, for id: UUID) {
        snapshots[id] = image
        snapshotOrder.removeAll { $0 == id }
        snapshotOrder.append(id)
        for stale in Self.snapshotEvictions(order: snapshotOrder, cap: Self.maxSnapshots) {
            snapshots.removeValue(forKey: stale)
            snapshotOrder.removeAll { $0 == stale }
        }
        let megabytes = snapshots.values.reduce(0) { $0 + Self.approximateBytes($1) } / 1_048_576
        AppLogger.webView.debug("Snapshots: \(self.snapshots.count) holding about \(megabytes) MB")
    }

    /// Forgets a service's snapshot, keeping the order list in step.
    private func dropSnapshot(for id: UUID) {
        snapshots.removeValue(forKey: id)
        snapshotOrder.removeAll { $0 == id }
    }

    /// The ids to drop, oldest first, once `order` runs past `cap`. Pure so the
    /// cap can be tested without a web view to snapshot.
    static func snapshotEvictions(order: [UUID], cap: Int) -> [UUID] {
        guard cap >= 0, order.count > cap else { return [] }
        return Array(order.prefix(order.count - cap))
    }

    /// Roughly what a snapshot costs in memory: its representations at four
    /// bytes a pixel. `NSImage` reports no byte count of its own, so this is for
    /// the log line rather than for any decision the code makes.
    static func approximateBytes(_ image: NSImage) -> Int {
        image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
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
                    self.refreshMediaCaptureState(id: id)
                }
            },
            webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self, let live = self.webViews[id],
                          ObjectIdentifier(live) == token else { return }
                    self.refreshMediaCaptureState(id: id)
                }
            },
            // Only the rising edge is reported. A load ending is left to the
            // coordinator's didFinish/didFail, which are the two callbacks that
            // know whether it ended well — `isLoading` going false says only
            // that it stopped, and treating that as success would clear a
            // failure the instant it happened.
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                guard change.newValue == true else { return }
                DispatchQueue.main.async {
                    guard let self, let live = self.webViews[id],
                          ObjectIdentifier(live) == token else { return }
                    self.applyHealthEvent(.startedLoading, to: id)
                }
            },
        ]
        audioObservers[id]?.invalidate()
        audioObservers[id] = PlayingAudioObserver(webView: webView) { [weak self] isPlaying in
            guard let self, let live = self.webViews[id],
                  ObjectIdentifier(live) == token else { return }
            self.setAudible(isPlaying, view: token, service: id)
        }
    }

    /// Records whether one of a service's web views is making sound, and keeps
    /// `audibleServiceIDs` true while any of them is.
    private func setAudible(_ isPlaying: Bool, view: ObjectIdentifier, service id: UUID) {
        let current = audibleViews[id] ?? []
        let updated = isPlaying ? current.union([view]) : current.subtracting([view])
        audibleViews[id] = updated.isEmpty ? nil : updated
        if updated.isEmpty {
            audibleServiceIDs.remove(id)
        } else {
            audibleServiceIDs.insert(id)
        }
    }

    /// Starts watching a tab's camera, microphone and sound. Same discipline as
    /// the page's watchers: the callbacks capture Sendable values only and
    /// check the tab is still open before touching state.
    private func watchTab(_ webView: WKWebView, service id: UUID) {
        let token = ObjectIdentifier(webView)
        tabWatches[token] = TabWatch(
            serviceID: id,
            observations: [
                webView.observe(\.cameraCaptureState, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async {
                        guard let self, self.tabWatches[token] != nil else { return }
                        self.refreshMediaCaptureState(id: id)
                    }
                },
                webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async {
                        guard let self, self.tabWatches[token] != nil else { return }
                        self.refreshMediaCaptureState(id: id)
                    }
                },
            ],
            audio: PlayingAudioObserver(webView: webView) { [weak self] isPlaying in
                guard let self, self.tabWatches[token] != nil else { return }
                self.setAudible(isPlaying, view: token, service: id)
            }
        )
    }

    /// Stops watching a tab that closed, and drops whatever it was doing from
    /// the service's state.
    private func unwatchTab(_ webView: WKWebView, service id: UUID) {
        let token = ObjectIdentifier(webView)
        guard let watch = tabWatches.removeValue(forKey: token) else { return }
        watch.observations.forEach { $0.invalidate() }
        watch.audio.invalidate()
        setAudible(false, view: token, service: id)
        refreshMediaCaptureState(id: id)
    }

    /// Recomputes and stores a service's capture state from its page and tabs,
    /// dropping the entry entirely when nothing is live.
    private func refreshMediaCaptureState(id: UUID) {
        let views = allWebViews(for: id)
        let state = MediaCaptureState.combined(
            camera: views.map(\.cameraCaptureState),
            microphone: views.map(\.microphoneCaptureState)
        )
        if state.isCapturing {
            mediaCaptureStates[id] = state
        } else {
            mediaCaptureStates.removeValue(forKey: id)
        }
    }

    /// Mutes or unmutes a service's live microphone (host-side, so the far end
    /// sees it). No-op without a live capturing web view.
    func setMicrophoneMuted(_ muted: Bool, for id: UUID) {
        for webView in allWebViews(for: id) where webView.microphoneCaptureState != WKMediaCaptureState.none {
            webView.setMicrophoneCaptureState(muted ? .muted : .active, completionHandler: nil)
        }
    }

    /// Mutes every service whose microphone is currently live. Returns how many
    /// were muted, so a caller can tell when nothing was live.
    @discardableResult
    func muteAllMicrophones() -> Int {
        var count = 0
        let everyView = webViews.keys.flatMap { allWebViews(for: $0) }
        for webView in everyView where webView.microphoneCaptureState == .active {
            webView.setMicrophoneCaptureState(.muted, completionHandler: nil)
            count += 1
        }
        return count
    }

    private func teardownWebView(_ instanceID: UUID) {
        coordinators[instanceID]?.closeAllTabs()
        if let webView = webViews[instanceID] {
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        mediaObservations[instanceID]?.forEach { $0.invalidate() }
        mediaObservations.removeValue(forKey: instanceID)
        mediaCaptureStates.removeValue(forKey: instanceID)
        audioObservers[instanceID]?.invalidate()
        audioObservers.removeValue(forKey: instanceID)
        audibleServiceIDs.remove(instanceID)
        audibleViews.removeValue(forKey: instanceID)
        // A hibernated service has no page, so it has no health to report; the
        // rail draws the moon for it instead. Leaving a stale failed dot on a
        // service that was torn down would outlive the failure.
        serviceHealth.removeValue(forKey: instanceID)
        webViews.removeValue(forKey: instanceID)
        lastAccessTimes.removeValue(forKey: instanceID)
        coordinators.removeValue(forKey: instanceID)
        visits.remove(instanceID)
        baselineFootprints.removeValue(forKey: instanceID)
        dropSnapshot(for: instanceID)
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
        coordinator.serviceOwnsURL = serviceOwnsURL
        coordinator.downloadCenter = downloadCenter
        coordinator.mediaCapturePolicyProvider = mediaCapturePolicyProvider
        coordinator.onNavigationFinished = { [weak self] id in
            self?.onNavigationFinished?(id)
        }
        coordinator.onHealthEvent = { [weak self] id, event in
            self?.applyHealthEvent(event, to: id)
        }
        let id = instance.id
        coordinator.onTabOpened = { [weak self] webView in
            self?.watchTab(webView, service: id)
        }
        coordinator.onTabClosed = { [weak self] webView in
            self?.unwatchTab(webView, service: id)
        }
        coordinator.servicePage = { [weak self] in
            self?.webViews[id]
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
            appDark: effectiveAppearanceDark
        )
        userScriptManager.configureScripts(
            for: instance,
            customCSS: effectiveCSS(for: instance),
            darkInjection: injection,
            stayActiveInBackground: instance.staysActiveInBackgroundEffective,
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

    /// Applies a Light/Dark appearance change to every live web view: recomputes
    /// each service's dark injection and applies it on the current document at
    /// once, re-baking the view's user scripts so its next full navigation
    /// starts in the right state (and without a flash). Mirrors
    /// `reattachContentBlocker`: live views only, in place, no teardown. Views
    /// rebuilt later read the new state via `makeConfiguration`.
    func applyDarkState(isDark: Bool, services: [ServiceInstance]) {
        effectiveAppearanceDark = isDark
        let byID = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, webView) in webViews {
            guard let instance = byID[id] else { continue }
            let inj = DarkReaderSupport.injection(mode: instance.darkMode, appDark: isDark)
            applyInjectionLive(inj, to: webView, instance: instance)
        }
    }

    /// Recomputes and applies a single live service's dark injection — used after
    /// a per-service On/Off edit. A no-op if the view isn't live (it rebuilds via
    /// `makeConfiguration`).
    func refreshDarkMode(for instance: ServiceInstance) {
        guard let webView = webViews[instance.id] else { return }
        let inj = DarkReaderSupport.injection(mode: instance.darkMode, appDark: effectiveAppearanceDark)
        applyInjectionLive(inj, to: webView, instance: instance)
    }

    /// Applies an injection to a live web view in place: enable/disable theming
    /// on the current document, then re-bake the view's user scripts so the next
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
        case .none:
            webView.evaluateJavaScript(DarkReaderSupport.disableJS, in: nil, in: world, completionHandler: nil)
        }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        userScriptManager.installUserScripts(
            for: instance,
            customCSS: effectiveCSS(for: instance),
            darkInjection: injection,
            stayActiveInBackground: instance.staysActiveInBackgroundEffective,
            on: controller
        )
    }

    /// Live services eligible for auto-hibernation, each paired with how long it
    /// has been idle: not the active service, not "Keep Loaded", not chat, not
    /// pinned, and actually loaded. The caller resolves each service's own idle
    /// threshold (its per-service policy, or the global one) and the active-call
    /// exemption — this only does the flag-and-liveness selection the pool can
    /// answer on its own.
    func idleCandidates(now: Date) -> [(id: UUID, idle: TimeInterval)] {
        lastAccessTimes.compactMap { id, accessed in
            guard id != activeServiceID,
                  !neverHibernateIDs.contains(id),
                  !notificationCriticalIDs.contains(id),
                  !pinnedIDs.contains(id),
                  !hasOpenTabs(id),
                  webViews[id] != nil
            else { return nil }
            return (id, now.timeIntervalSince(accessed))
        }
    }

    /// Fully hibernates `id` iff it is still eligible after the async call check.
    ///
    /// `hasActiveCall` is a suspension point (up to its own 2s timeout), and the
    /// user can switch to this service — or pin it, mark it never-hibernate, or
    /// close it — while it's suspended. So the guards are re-checked AFTER the
    /// await, with no further suspension before `hibernate`, so a service the
    /// user is now viewing is never torn down under them. `evictionInFlight`
    /// keeps two passes (the cap sweep and the idle sweep) from racing the same
    /// id. Shared by both callers so the re-validation lives in one place.
    /// Returns true iff it hibernated.
    @discardableResult
    func hibernateIfStillIdle(_ id: UUID) async -> Bool {
        guard webViews[id] != nil,
              id != activeServiceID,
              !pinnedIDs.contains(id),
              !neverHibernateIDs.contains(id),
              !notificationCriticalIDs.contains(id),
              !hasOpenTabs(id),
              !evictionInFlight.contains(id)
        else { return false }

        evictionInFlight.insert(id)
        let hasCall = await hasActiveCall(for: id)
        evictionInFlight.remove(id)

        // Re-validate every guard across the suspension.
        guard webViews[id] != nil,
              id != activeServiceID,
              !pinnedIDs.contains(id),
              !neverHibernateIDs.contains(id),
              !notificationCriticalIDs.contains(id),
              !hasOpenTabs(id)
        else { return false }

        if hasCall {
            AppLogger.webView.info("Skipping hibernation of \(id) — active call detected")
            return false
        }
        // Tearing the page down would stop the music the user left playing.
        if audibleServiceIDs.contains(id) {
            AppLogger.webView.info("Skipping hibernation of \(id) — playing audio")
            return false
        }

        hibernate(id)
        return true
    }

    // MARK: - Memory watch (log only)

    /// The floor under which no page counts as grown, however much it climbed.
    nonisolated static let memoryWatchFloor: UInt64 = 1536 * 1_048_576

    /// How many times its baseline a page must reach to count as grown. The
    /// limit is relative so that a page which simply needs a lot of memory does
    /// not count over and over.
    nonisolated static let memoryWatchGrowthFactor: UInt64 = 2

    /// How long after it loads a page is first measured for its baseline.
    /// Sampled earlier, a page still loading would read small.
    nonisolated static let memoryWatchSettleTime: TimeInterval = 5 * 60

    /// How long a service must have been out of sight, counted from when the
    /// user left it, before it may count. A page left moments ago may hold a
    /// half-typed message.
    nonisolated static let memoryWatchMinimumOutOfSight: TimeInterval = 10 * 60

    /// Whether a page has grown enough, and is far enough from the user, that
    /// a rebuild would be justified. Nothing acts on it yet: the memory watch
    /// only logs it.
    ///
    /// The page has to be past both the floor and twice its baseline, and out
    /// of sight for `memoryWatchMinimumOutOfSight`. Everything that makes a
    /// teardown cost the user something rules it out: the service on screen,
    /// one pinned, one set to Keep Loaded, one using the camera or microphone,
    /// one playing sound, or one with tabs open, since `teardownWebView` closes
    /// them. A footprint or baseline that could not be read rules it out too.
    nonisolated static func wouldRebuild(
        footprint: UInt64?,
        baseline: UInt64?,
        outOfSight: TimeInterval,
        isActive: Bool,
        isPinned: Bool,
        keepLoaded: Bool,
        isCapturing: Bool,
        isPlayingAudio: Bool,
        hasOpenTabs: Bool
    ) -> Bool {
        guard let footprint, let baseline else { return false }
        let (grown, overflow) = baseline.multipliedReportingOverflow(by: memoryWatchGrowthFactor)
        let limit = max(memoryWatchFloor, overflow ? .max : grown)
        return footprint > limit
            && outOfSight >= memoryWatchMinimumOutOfSight
            && !isActive && !isPinned && !keepLoaded && !isCapturing && !isPlayingAudio && !hasOpenTabs
    }

    /// The physical footprint of the WebContent process behind a service, the
    /// figure Activity Monitor shows as Memory. Each service has its own data
    /// store, so the process belongs to that one service, but open tabs run in
    /// it too and count toward it.
    ///
    /// The process id comes from `_webProcessIdentifier`, which is SPI, so it is
    /// probed before use. If a macOS release drops it, this returns nil and the
    /// watch logs nothing.
    func webContentFootprint(for id: UUID) -> UInt64? {
        let key = "_webProcessIdentifier"
        guard let webView = webViews[id],
              webView.responds(to: NSSelectorFromString(key)),
              let pid = (webView.value(forKey: key) as? NSNumber)?.int32Value,
              pid > 0
        else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    struct MemoryReading {
        let id: UUID
        let footprint: UInt64
        let baseline: UInt64?
        let outOfSight: TimeInterval
        let hasOpenTabs: Bool
        let wouldRebuild: Bool
    }

    /// Measures every live page once, for the memory watch to log.
    ///
    /// A page gets its baseline the first time it is read after
    /// `memoryWatchSettleTime`. When a page counts as grown, its footprint
    /// becomes its new baseline, standing in for the rebuild that does not
    /// happen yet. A page that settled heavy therefore counts once, not on
    /// every pass, and the log shows how often each service would really be
    /// rebuilt.
    func memoryReadings(now: Date = Date()) -> [MemoryReading] {
        webViews.keys.compactMap { id in
            guard let footprint = webContentFootprint(for: id) else { return nil }
            if baselineFootprints[id] == nil,
               let age = visits.age(id, now: now), age >= Self.memoryWatchSettleTime {
                baselineFootprints[id] = footprint
            }
            let baseline = baselineFootprints[id]
            let outOfSight = visits.outOfSight(id, now: now)
            let tabs = hasOpenTabs(id)
            let grown = Self.wouldRebuild(
                footprint: footprint,
                baseline: baseline,
                outOfSight: outOfSight,
                isActive: id == activeServiceID,
                isPinned: pinnedIDs.contains(id),
                keepLoaded: neverHibernateIDs.contains(id),
                isCapturing: mediaCaptureStates[id]?.isCapturing ?? false,
                isPlayingAudio: audibleServiceIDs.contains(id),
                hasOpenTabs: tabs
            )
            if grown { baselineFootprints[id] = footprint }
            return MemoryReading(
                id: id, footprint: footprint, baseline: baseline,
                outOfSight: outOfSight, hasOpenTabs: tabs, wouldRebuild: grown
            )
        }
    }

    /// When exceeding maxLoaded web views, fully hibernate the least recently used ones.
    /// Skips services that have an active WebRTC call, via `hibernateIfStillIdle`.
    private func evictIfNeeded() async {
        guard webViews.count > maxLoaded else { return }

        let sorted = lastAccessTimes
            .filter { $0.key != activeServiceID
                   && !evictionInFlight.contains($0.key)
                   && !neverHibernateIDs.contains($0.key)
                   && !notificationCriticalIDs.contains($0.key)
                   && !pinnedIDs.contains($0.key)
                   && !hasOpenTabs($0.key) }
            .sorted { $0.value < $1.value }

        for (id, _) in sorted {
            // Re-check the live count each pass, not a count captured up front:
            // a concurrent pass (they interleave at the await inside
            // hibernateIfStillIdle) may have already hibernated views, and a
            // stale target would evict past the cap, dropping below maxLoaded.
            guard webViews.count > maxLoaded else { break }
            await hibernateIfStillIdle(id)
        }
    }
}

/// Watches WebKit's private `_isPlayingAudio` on one web view. The property is
/// not in the public headers, so it can't go through a `KeyPath` observation;
/// this is the string-keyed form, behind a `responds(to:)` check so a WebKit
/// that drops it leaves the speaker mark off instead of crashing. Each change
/// hops to the main actor before `onChange` runs.
@MainActor
final class PlayingAudioObserver: NSObject {
    private static let key = "_isPlayingAudio"
    private weak var webView: WKWebView?
    private let onChange: @MainActor (Bool) -> Void

    init(webView: WKWebView, onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        super.init()
        guard webView.responds(to: NSSelectorFromString(Self.key)) else { return }
        self.webView = webView
        webView.addObserver(self, forKeyPath: Self.key, options: [.initial, .new], context: nil)
    }

    func invalidate() {
        webView?.removeObserver(self, forKeyPath: Self.key)
        webView = nil
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        let isPlaying = (change?[.newKey] as? NSNumber)?.boolValue ?? false
        Task { @MainActor [weak self] in
            self?.onChange(isPlaying)
        }
    }
}

/// When each service's page loaded and when the user last switched away from
/// it. The memory watch counts "out of sight" from the moment a service was
/// left, not from when it was opened: half an hour in WhatsApp followed by a
/// switch to Slack leaves WhatsApp out of sight for seconds, not half an hour.
struct ServiceVisits {
    private var loadedAt: [UUID: Date] = [:]
    private var leftAt: [UUID: Date] = [:]
    private var active: UUID?

    /// A page came up. Until the user opens and leaves it, a page loaded in
    /// the background counts as out of sight since it loaded.
    mutating func loaded(_ id: UUID, at date: Date) {
        loadedAt[id] = date
        leftAt[id] = date
    }

    /// The user brought `id` on screen, or nil when nothing is. Whatever was on
    /// screen before is left now.
    mutating func activate(_ id: UUID?, at date: Date) {
        if let previous = active, previous != id {
            leftAt[previous] = date
        }
        active = id
    }

    mutating func remove(_ id: UUID) {
        loadedAt.removeValue(forKey: id)
        leftAt.removeValue(forKey: id)
    }

    func age(_ id: UUID, now: Date) -> TimeInterval? {
        loadedAt[id].map { now.timeIntervalSince($0) }
    }

    /// Zero for the page on screen; otherwise the time since the user left it.
    func outOfSight(_ id: UUID, now: Date) -> TimeInterval {
        guard id != active, let left = leftAt[id] else { return 0 }
        return now.timeIntervalSince(left)
    }
}
