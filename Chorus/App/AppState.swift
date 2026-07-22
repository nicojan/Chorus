import SwiftUI
import SwiftData
import WebKit
import LocalAuthentication

/// Reasons the persistent store is unusable and `AppState` must fall back to
/// in-memory storage.
private enum StoreError: Error {
    /// `StoreRepair` ran but the opened store still holds dangling links, so
    /// reading one would trap. Treated like an open failure.
    case danglingLinksRemainAfterRepair
}

@MainActor
@Observable
final class AppState {
    let modelContainer: ModelContainer
    let webViewPool: WebViewPool
    let contentBlocker: ContentBlockerManager
    let dataStoreManager: DataStoreManager
    let userScriptManager: UserScriptManager
    let badgeManager: BadgeManager

    /// Navigation state (back/forward/loading) for the active service's web view,
    /// shared so the top tab bar can host the nav buttons.
    let webViewState = WebViewState()
    let notificationManager: NotificationManager
    let transientBadgeFetcher: TransientBadgeFetcher
    let networkMonitor: NetworkMonitor

    var selectedSpaceID: UUID?
    var selectedServiceID: UUID?
    var showAddService = false
    var showQuickSwitcher = false

    /// True once launch-time preference loading has finished. Gates the DND
    /// `didSet`s below so they don't push the effective DND (which touches the
    /// AppKit dock tile) while `loadAppPreferences` is still assigning them
    /// during init — the same early-AppKit race that code defers a runloop tick.
    @ObservationIgnored private var isLaunchComplete = false

    /// Manual Do Not Disturb toggle. `didSet` re-pushes the effective DND so any
    /// writer (menu command, Settings) keeps the badge/dock/notification gate in
    /// sync without having to remember to call `refreshEffectiveDoNotDisturb()`.
    var doNotDisturb = false {
        didSet { if isLaunchComplete { refreshEffectiveDoNotDisturb() } }
    }
    /// Drives the Find-in-Page overlay in WebContentView. Toggled by Cmd-F.
    var findInPageVisible = false

    /// The head of the camera/microphone permission-prompt queue, or nil when no
    /// prompt is showing. Drives the alert in ContentView. Only ever set on the
    /// main actor; answered via `answerMediaRequest(allow:)`.
    private(set) var pendingMediaRequest: MediaPermissionRequest?

    /// The public, UI-facing shape of a pending capture prompt (no continuation).
    struct MediaPermissionRequest: Identifiable, Equatable {
        let id: UUID
        let serviceLabel: String
        /// The requesting origin's host when it differs from the service's own site
        /// (a cross-domain page inside the service's web view). nil means the
        /// request came from the service's own origin.
        let originHost: String?
        /// The device(s) actually being asked about (kind-involved and currently
        /// `.ask`), so the prompt copy names only what's in question — never more.
        let camAsked: Bool
        let micAsked: Bool

        var kindLabel: String {
            switch (camAsked, micAsked) {
            case (true, true): return "camera and microphone"
            case (false, true): return "microphone"
            case (true, false): return "camera"
            case (false, false): return "camera or microphone"  // not reached: a prompt always asks something
            }
        }

        /// Prompt title, naming the real requester: the origin host for a
        /// cross-domain request, otherwise the service.
        var title: String {
            "Allow \(originHost ?? serviceLabel) to use your \(kindLabel)?"
        }

        /// Prompt body. A cross-domain request says which service opened the
        /// origin, so the user isn't misled about who is asking.
        var message: String {
            if let originHost {
                return "\(originHost), opened by \(serviceLabel), wants to use your \(kindLabel)."
            }
            return "\(serviceLabel) wants to use your \(kindLabel). Change this anytime in the service's settings."
        }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    /// Queue entry: the public request (which carries the asked-field flags used
    /// for both the prompt copy and persistence) plus its awaiting continuation.
    private struct PendingMediaEntry {
        let request: MediaPermissionRequest
        let serviceID: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    @ObservationIgnored private var mediaQueue: [PendingMediaEntry] = []

    /// Bumped when a service's web view is rebuilt for an edit that only takes
    /// effect at creation time (custom CSS). WebContentView observes this and
    /// re-fetches the active service's web view so the change shows at once.
    var webViewRebuildToken = 0

    /// Chorus-wide default page zoom, applied to services without an explicit
    /// per-service zoom. Loaded from AppPreferences at launch.
    var defaultZoom: Double = 1.0

    /// Where the spaces/services rails sit. Loaded from AppPreferences at
    /// launch; the Settings picker writes both this and the persisted value.
    var railLayout: RailLayout = .sidebar

    /// App-level appearance override, loaded from AppPreferences.
    var appearanceMode: AppearanceMode = .system

    /// The color scheme to force on the app, or nil to follow the system.
    var appearanceColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The effective Light/Dark the app is showing right now, resolving `.system`
    /// against the current macOS appearance. Drives Dark Reader theming. Reads
    /// AppKit for the `.system` case, so call it on the main actor after launch,
    /// not during AppState.init.
    var isEffectiveAppearanceDark: Bool {
        switch appearanceMode {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    /// Last effective dark state pushed to the web-view pool, so appearance
    /// notifications that don't actually change Light/Dark are ignored.
    private var lastKnownAppearanceDark: Bool?

    /// Tokens for the NSWorkspace sleep/wake observers, removed in `deinit`.
    /// AppState is a process-lifetime singleton, so this is hygiene rather than a
    /// live leak, but keeping registration and teardown symmetric avoids a
    /// dangling observer if that ever changes. Not observed UI state, so
    /// `@ObservationIgnored`; `nonisolated(unsafe)` so the nonisolated deinit can
    /// read it — it's only mutated during main-actor setup and read once at
    /// teardown, so there's no real concurrency exposure.
    @ObservationIgnored nonisolated(unsafe) private var systemObserverTokens: [NSObjectProtocol] = []

    /// Tokens for `DistributedNotificationCenter` observers (screen-lock,
    /// appearance-change), removed in `deinit` for the same symmetry as the
    /// workspace tokens above.
    @ObservationIgnored nonisolated(unsafe) private var distributedObserverTokens: [NSObjectProtocol] = []

    /// Data-store identifiers a `cleanUpOrphanedDataStores` invocation is
    /// currently processing, so overlapping calls don't both run the backoff loop
    /// and issue `WKWebsiteDataStore.remove(...)` for the same store at once.
    /// Main-actor only.
    @ObservationIgnored private var dataStoresBeingRemoved: Set<UUID> = []

    /// Scheduled "quiet hours" Do Not Disturb, loaded from AppPreferences.
    /// `doNotDisturb` above stays the manual toggle; the effective DND that
    /// gates badges and notifications is `doNotDisturb || scheduledDNDActive`.
    var scheduledDNDEnabled = false {
        didSet { if isLaunchComplete { refreshEffectiveDoNotDisturb() } }
    }
    var dndStartMinutes = 22 * 60 {
        didSet { if isLaunchComplete { refreshEffectiveDoNotDisturb() } }
    }
    var dndEndMinutes = 7 * 60 {
        didSet { if isLaunchComplete { refreshEffectiveDoNotDisturb() } }
    }
    @ObservationIgnored nonisolated(unsafe) private var quietHoursTask: Task<Void, Never>?

    /// App lock (Touch ID / password), loaded from AppPreferences. `isLocked`
    /// drives an opaque cover over the window content in ContentView.
    var appLockEnabled = false
    var lockOnLaunch = true
    var lockOnSleep = true
    var isLocked = false

    /// Global content-blocking toggle, mirrored from AppPreferences at launch.
    /// The Settings switch writes both this and the persisted value via
    /// `setContentBlockingEnabled(_:)`.
    var contentBlockingEnabled = true

    /// "Hide annoyances" toggle, mirrored from AppPreferences at launch. Written
    /// via `setAnnoyanceBlockingEnabled(_:)`.
    var annoyanceBlockingEnabled = false

    /// Global "dark-theme services without one" toggle, mirrored from
    /// AppPreferences at launch. Written via `setAutoDarkModeEnabled(_:)`.
    var autoDarkModeEnabled = false

    /// Default camera/microphone permission for services that haven't pinned
    /// their own, mirrored from AppPreferences at launch. Written via
    /// `setDefaultCameraPolicy(_:)` / `setDefaultMicrophonePolicy(_:)`. Read on
    /// the permission hot path, so kept in memory rather than re-fetched.
    var defaultCameraPolicy: MediaPermissionPolicy = .ask
    var defaultMicrophonePolicy: MediaPermissionPolicy = .ask

    /// Non-nil when the persistent store failed and we fell back to in-memory storage.
    /// The UI should display a warning banner when this is set.
    private(set) var storeError: String?

    /// On-disk location of the persistent store that failed to open. Lets the
    /// UI offer a "Reveal in Finder" action so the user can back up or remove
    /// the file themselves — we never delete it for them.
    private(set) var storeFileURL: URL?

    init() {
        let schema = Schema([
            ServiceInstance.self,
            Space.self,
            SpaceServiceLink.self,
            AppPreferences.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        // Repair a store corrupted by a pre-inverse build BEFORE opening it.
        // The dangling `SpaceServiceLink` rows such a build leaves cannot be
        // removed once SwiftData faults them (it traps on the deleted space),
        // so the cleanup has to happen on the raw file first. See StoreRepair.
        StoreRepair.repairDanglingLinks(at: config.url)

        do {
            let opened = try ModelContainer(for: schema, configurations: [config])
            // Verify StoreRepair fully cleaned the store. If any dangling link
            // remains (repair skipped an unrecognized schema, or its write
            // failed), a later unguarded `.space`/`.service` read would fault
            // the deleted model and brick the app — so don't run on it. Fall
            // through to the in-memory store, exactly as an open failure does.
            guard !Self.storeHasDanglingLinks(opened) else {
                throw StoreError.danglingLinksRemainAfterRepair
            }
            self.modelContainer = opened
        } catch {
            // Never auto-delete the user's persistent store: silent destruction
            // is data loss without consent. Fall back to in-memory storage so
            // the app stays usable, surface a banner with the on-disk path,
            // and let the user choose whether to reset via Settings.
            AppLogger.dataStore.error("Persistent store unusable: \(error.localizedDescription). Falling back to in-memory storage; on-disk data is preserved at \(config.url.path).")
            let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                self.modelContainer = try ModelContainer(for: schema, configurations: [inMemoryConfig])
            } catch {
                // In-memory containers should never fail with this schema; if
                // they do the app cannot run at all.
                AppLogger.dataStore.fault("In-memory model container failed: \(error.localizedDescription)")
                fatalError("Failed to initialize any model container: \(error.localizedDescription)")
            }
            self.storeError = "Your saved data couldn't be loaded. Chorus is running with temporary storage, so changes won't be saved. Your data file is at: \(config.url.path)"
            self.storeFileURL = config.url
        }

        self.dataStoreManager = DataStoreManager()
        self.userScriptManager = UserScriptManager()
        self.badgeManager = BadgeManager()

        // Capture the modelContainer locally so the @Sendable closure below
        // doesn't capture `self` before all stored properties are assigned.
        let container = self.modelContainer
        let badgeManager = self.badgeManager
        self.userScriptManager.isServiceMuted = { @Sendable serviceID in
            // WKScriptMessageHandler.didReceive is invoked on the main
            // thread, so we can safely hop into the main actor here to
            // read the persisted mute state. A service is muted when its
            // own isMuted flag is true *or* any of its parent spaces is
            // muted (mute-the-space cascades to its members).
            MainActor.assumeIsolated {
                let context = container.mainContext
                // Indexed single-row fetch, not a full-table scan — this runs on
                // every intercepted web notification (matches isServiceNotifyingOS).
                var descriptor = FetchDescriptor<ServiceInstance>(
                    predicate: #Predicate { $0.id == serviceID }
                )
                descriptor.fetchLimit = 1
                guard let service = try? context.fetch(descriptor).first else { return false }
                return service.isEffectivelyMuted
            }
        }
        self.userScriptManager.isServiceNotifyingOS = { @Sendable serviceID in
            // Per-service flag (not cascaded, unlike mute); nil → enabled. Runs
            // on every intercepted web notification, so use an indexed single-row
            // fetch rather than a full-table scan. Fails silent: a missing or
            // deleted service does not post a banner.
            MainActor.assumeIsolated {
                let context = container.mainContext
                var descriptor = FetchDescriptor<ServiceInstance>(
                    predicate: #Predicate { $0.id == serviceID }
                )
                descriptor.fetchLimit = 1
                guard let service = try? context.fetch(descriptor).first else { return false }
                return service.notifiesOSEffective
            }
        }
        self.userScriptManager.isDoNotDisturbActive = { @Sendable in
            MainActor.assumeIsolated { badgeManager.doNotDisturb }
        }
        self.notificationManager = NotificationManager(badgeManager: badgeManager)
        self.transientBadgeFetcher = TransientBadgeFetcher(
            badgeManager: badgeManager,
            dataStoreManager: dataStoreManager
        )
        self.contentBlocker = ContentBlockerManager()
        self.webViewPool = WebViewPool(
            dataStoreManager: dataStoreManager,
            userScriptManager: userScriptManager,
            contentBlocker: contentBlocker
        )
        self.networkMonitor = NetworkMonitor()

        // Self is fully initialized here, so the pool (a Sendable @MainActor
        // class) can be captured. A dark-detection probe caches its verdict once
        // and applies it live. didReceive runs on the main thread, so hop onto
        // the main actor for SwiftData + the pool.
        let container2 = self.modelContainer
        let pool = self.webViewPool
        self.userScriptManager.onDarkProbeVerdict = { @Sendable serviceID, lacksDark in
            MainActor.assumeIsolated {
                let context = container2.mainContext
                var descriptor = FetchDescriptor<ServiceInstance>(
                    predicate: #Predicate { $0.id == serviceID }
                )
                descriptor.fetchLimit = 1
                guard let service = try? context.fetch(descriptor).first,
                      service.detectedLacksDarkTheme == nil else { return }
                service.detectedLacksDarkTheme = lacksDark
                try? context.save()
                pool.refreshDarkMode(for: service)
            }
        }

        // A themed service exports its generated Dark Reader CSS after its live
        // pass settles; cache it for a fast dark first paint next load. The
        // handler fires on the main thread, so hop onto the main actor for the
        // pool.
        self.userScriptManager.onDarkCSSExport = { @Sendable serviceID, css in
            MainActor.assumeIsolated {
                pool.cacheDarkTheme(css, for: serviceID)
            }
        }

        loadAppPreferences()
        startContentBlocker()
        setupNotificationNavigation()
        setupHibernationCallbacks()
        setupMenuBarNavigation()
        setupSystemSleepHandling()
        setupNetworkHandling()
        setupExternalLinkRouting()
        setupMediaPermissions()
        let didSeedDefaults = seedDefaultDataIfNeeded()
        backfillPasskeyNoticeIfNeeded(freshInstall: didSeedDefaults)
        reapOrphanedServices()
        restoreWindowState()
        let didUpdate = Self.recordLaunchVersionAndCheckUpdate()
        fetchMissingAndStaleFavicons(force: didUpdate)
        fetchCatalogIcons(force: didUpdate)
        preloadActiveSpaceServices()
        startTransientBadgeFetcher()
        cleanUpOrphanedDataStores()
    }

    deinit {
        for token in systemObserverTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        for token in distributedObserverTokens {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        quietHoursTask?.cancel()
    }

    /// Wires the WebViewPool's external-link handler so that cross-domain
    /// target=_blank navigations route through `handleExternalLink(_:)` —
    /// which prefers switching to a matching Chorus service over opening
    /// Safari, but falls back to NSWorkspace when no service matches.
    private func setupExternalLinkRouting() {
        webViewPool.externalLinkHandler = { [weak self] url in
            self?.handleExternalLink(url)
        }
    }

    /// Wires the WebViewPool's media-capture handler so every service's
    /// `getUserMedia()` is resolved against the persisted per-service policy.
    private func setupMediaPermissions() {
        webViewPool.mediaCapturePolicyProvider = { [weak self] serviceID, type, frame in
            await self?.resolveMediaPermission(serviceID: serviceID, type: type, frame: frame) ?? .deny
        }
        // Any teardown of a service's web view (hibernate, recreate, evict, or
        // remove) invalidates a pending prompt for it — deny + drain so a stale
        // prompt can't linger and block a later service's prompt.
        webViewPool.onServiceTornDown = { [weak self] serviceID in
            self?.drainMediaRequests(for: serviceID)
        }
    }

    /// Resolves a service's camera/microphone request into a WebKit decision from
    /// the persisted per-service policy (falling back to the global default, then
    /// `.ask`). Fails closed (`.deny`) whenever anything is uncertain: unknown
    /// service, a persisted grant reached from a cross-origin subframe, or — until
    /// the prompt lands in the next step — an `.ask` outcome.
    @MainActor
    func resolveMediaPermission(
        serviceID: UUID,
        type: WKMediaCaptureType,
        frame: WKFrameInfo
    ) async -> WKPermissionDecision {
        guard let service = fetchService(id: serviceID) else { return .deny }
        let camera = MediaPermissionResolver.effectivePolicy(
            serviceRaw: service.cameraPolicyRaw, globalRaw: defaultCameraPolicy.rawValue)
        let microphone = MediaPermissionResolver.effectivePolicy(
            serviceRaw: service.microphonePolicyRaw, globalRaw: defaultMicrophonePolicy.rawValue)

        let kind = Self.captureKind(from: type)
        let resolution = MediaPermissionResolver.resolve(kind, camera: camera, microphone: microphone)
        if resolution == .deny { return .deny }  // an explicit Deny blocks any origin

        // Never grant or prompt behind the lock screen, or for a service the user
        // isn't actively viewing — a preloaded/background service must not grab the
        // camera/mic or throw a surprise prompt. Both fail closed.
        guard !isLocked else {
            AppLogger.webView.info("Media capture denied: app is locked")
            return .deny
        }
        guard webViewPool.activeServiceID == serviceID else {
            AppLogger.webView.info("Media capture denied: \(service.label) isn't the active service")
            return .deny
        }

        if isCaptureFrameTrusted(frame, service: service) {
            // The service's own origin: honor its policy. `.ask` prompts and
            // remembers the answer on ONLY the device(s) actually asked about
            // (kind-gated), so a mic-only prompt can't silently pin the camera.
            if resolution == .grant { return .grant }
            let asked = MediaPermissionResolver.askedFields(kind, camera: camera, microphone: microphone)
            let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                enqueueMediaRequest(
                    serviceID: serviceID, serviceLabel: service.label, originHost: nil,
                    camAsked: asked.camera, micAsked: asked.microphone, continuation: continuation)
            }
            persistMediaAnswer(serviceID: serviceID, allow: allowed, camAsked: asked.camera, micAsked: asked.microphone)
            return allowed ? .grant : .deny
        }

        // A foreign origin inside the service's own web view (e.g. a call service
        // whose media host differs from its home host). Decide per the
        // foreign-origin rules.
        let originHost = frame.securityOrigin.host
        switch Self.foreignCaptureOutcome(
            isMainFrame: frame.isMainFrame,
            originHost: originHost,
            isFirstParty: isFirstPartyService(service),
            resolution: resolution
        ) {
        case .deny:
            logMediaDenyUntrusted(frame, service: service)
            return .deny
        case .grantSilently:
            return .grant
        case .promptNamingOrigin:
            let asked = MediaPermissionResolver.askedFields(kind, camera: .ask, microphone: .ask)
            let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                enqueueMediaRequest(
                    serviceID: serviceID, serviceLabel: service.label, originHost: originHost,
                    camAsked: asked.camera, micAsked: asked.microphone, continuation: continuation)
            }
            return allowed ? .grant : .deny
        }
    }

    /// Appends a prompt to the queue and shows it if none is currently up.
    private func enqueueMediaRequest(
        serviceID: UUID,
        serviceLabel: String,
        originHost: String?,
        camAsked: Bool,
        micAsked: Bool,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        let request = MediaPermissionRequest(
            id: UUID(), serviceLabel: serviceLabel, originHost: originHost,
            camAsked: camAsked, micAsked: micAsked)
        mediaQueue.append(PendingMediaEntry(
            request: request,
            serviceID: serviceID,
            continuation: continuation
        ))
        if pendingMediaRequest == nil {
            pendingMediaRequest = mediaQueue.first?.request
        }
    }

    /// Answers the shown prompt (from the alert's buttons), resumes its awaiting
    /// resolver, and presents the next queued prompt. Takes the request id so a
    /// stray tap can only answer the prompt it was shown for — never the next one.
    func answerMediaRequest(_ id: UUID, allow: Bool) {
        guard mediaQueue.first?.request.id == id else { return }
        let entry = mediaQueue.removeFirst()
        entry.continuation.resume(returning: allow)
        presentNextMediaRequest()
    }

    /// Resumes (with deny) and clears any prompts queued for a service that's
    /// being removed, so a delete mid-prompt can't strand a continuation.
    private func drainMediaRequests(for serviceID: UUID) {
        guard mediaQueue.contains(where: { $0.serviceID == serviceID }) else { return }
        let headWasStranded = mediaQueue.first?.serviceID == serviceID
        let stranded = mediaQueue.filter { $0.serviceID == serviceID }
        mediaQueue.removeAll { $0.serviceID == serviceID }
        for entry in stranded { entry.continuation.resume(returning: false) }
        // Only re-present if the prompt currently on screen was one we just
        // drained; a drained non-head entry leaves the visible prompt alone.
        if headWasStranded { presentNextMediaRequest() }
    }

    /// Denies and clears every queued prompt. Used when the app locks — a capture
    /// prompt must not sit above the lock screen leaking a service name or letting
    /// the user grant capture without unlocking.
    private func drainAllMediaRequests() {
        guard !mediaQueue.isEmpty else { return }
        let all = mediaQueue
        mediaQueue.removeAll()
        for entry in all { entry.continuation.resume(returning: false) }
        pendingMediaRequest = nil
    }

    /// Dismisses the current prompt and shows the next queued one on the following
    /// runloop tick. SwiftUI won't re-present an alert while `isPresented` stays
    /// true, so the binding must go false → true between entries.
    private func presentNextMediaRequest() {
        pendingMediaRequest = nil
        guard let next = mediaQueue.first?.request else { return }
        Task { @MainActor [weak self] in
            guard let self, self.pendingMediaRequest == nil,
                  self.mediaQueue.first?.request.id == next.id else { return }
            self.pendingMediaRequest = next
        }
    }

    /// Persists an "ask" answer as an explicit allow/deny, on only the fields that
    /// were asked (leaving an already-explicit camera or mic policy untouched).
    private func persistMediaAnswer(serviceID: UUID, allow: Bool, camAsked: Bool, micAsked: Bool) {
        guard let service = fetchService(id: serviceID) else { return }
        let policy: MediaPermissionPolicy = allow ? .allow : .deny
        if camAsked { service.cameraPolicy = policy }
        if micAsked { service.microphonePolicy = policy }
        do {
            try modelContainer.mainContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to persist media permission: \(error.localizedDescription)")
            modelContainer.mainContext.rollback()
        }
    }

    /// Sets and persists the global default camera policy for services without
    /// a per-service value. Mirrors the other global-toggle setters.
    func setDefaultCameraPolicy(_ policy: MediaPermissionPolicy) {
        defaultCameraPolicy = policy
        persistDefaultMediaPolicies()
    }

    /// Sets and persists the global default microphone policy.
    func setDefaultMicrophonePolicy(_ policy: MediaPermissionPolicy) {
        defaultMicrophonePolicy = policy
        persistDefaultMediaPolicies()
    }

    private func persistDefaultMediaPolicies() {
        let prefs = ensurePreferences()
        prefs.defaultCameraPolicyRaw = defaultCameraPolicy.rawValue
        prefs.defaultMicrophonePolicyRaw = defaultMicrophonePolicy.rawValue
        do {
            try modelContainer.mainContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save default media policies: \(error.localizedDescription)")
            modelContainer.mainContext.rollback()
        }
    }

    /// Mutes every service whose microphone is currently live (⇧⌘M). Logs the
    /// count so the action isn't silent when nothing was muted.
    func muteAllMicrophones() {
        let count = webViewPool.muteAllMicrophones()
        AppLogger.general.info("Muted \(count) live microphone(s)")
    }

    /// Logs a capture denial caused by the requesting origin not belonging to the
    /// service, naming both hosts — so a cross-domain call that's being wrongly
    /// blocked is diagnosable in Console rather than a silent nothing.
    private func logMediaDenyUntrusted(_ frame: WKFrameInfo, service: ServiceInstance) {
        let frameHost = frame.securityOrigin.host
        let serviceHost = URL(string: service.url)?.host ?? service.url
        AppLogger.webView.info(
            "Media capture denied: request origin \(frameHost, privacy: .public) doesn't belong to \(service.label, privacy: .public) (\(serviceHost, privacy: .public))")
    }

    private func isCaptureFrameTrusted(_ frame: WKFrameInfo, service: ServiceInstance) -> Bool {
        guard let serviceHost = URL(string: service.url)?.host else { return false }
        let frameHost = frame.securityOrigin.host
        guard !frameHost.isEmpty else { return false }
        // Stricter capture-specific same-site test (not the link-routing one): two
        // owners on a shared hosting suffix (*.web.app, *.github.io, …) are NOT the
        // same site, so an Allow-pinned service can't leak its grant to another site
        // there. First-party cross-domain trust is handled separately, on the
        // foreign-origin path in resolveMediaPermission.
        return WebViewCoordinator.captureOriginBelongsToService(frameHost, serviceHost: serviceHost)
    }

    /// What to do with a capture request whose origin is NOT the service's own site
    /// — a foreign origin inside the service's own web view. Pure, so it's
    /// unit-testable without a live `WKFrameInfo`. `resolution` is already known to
    /// be `.grant` or `.ask` here (an explicit `.deny` is short-circuited earlier).
    /// - A third-party SUBFRAME (can't meaningfully consent, the spoofiest case) or
    ///   an empty origin fails closed.
    /// - A first-party vendor pinned to Allow grants silently. This is the ONE
    ///   cross-domain silent grant — the seamless-call case the flag exists for —
    ///   and its accepted risk: the vendor's own main frame, navigated to a foreign
    ///   origin, gets the grant.
    /// - Everything else prompts NAMING THE REAL ORIGIN and does not persist: a
    ///   non-first-party service, or a first-party vendor still on Ask. Naming the
    ///   real origin (not the service) stops a hijacked main frame from borrowing
    ///   the vendor's name; not persisting keeps a one-off foreign answer from
    ///   pinning a blanket service Allow.
    enum ForeignCaptureOutcome: Equatable { case grantSilently, promptNamingOrigin, deny }

    static func foreignCaptureOutcome(
        isMainFrame: Bool,
        originHost: String,
        isFirstParty: Bool,
        resolution: MediaPermissionResolver.Resolution
    ) -> ForeignCaptureOutcome {
        guard isMainFrame, !originHost.isEmpty else { return .deny }
        if isFirstParty, resolution == .grant { return .grantSilently }
        return .promptNamingOrigin
    }

    /// Whether `service` is a curated first-party vendor: the catalog entry carries
    /// the `firstParty` flag AND the service still points at that vendor's own site.
    /// The second check means a user who edits the service's URL elsewhere doesn't
    /// carry the vendor's cross-domain trust to the new site. Custom, non-catalog
    /// services are never first-party.
    private func isFirstPartyService(_ service: ServiceInstance) -> Bool {
        guard let id = service.catalogEntryID,
              let entry = ServiceCatalog.shared.entry(for: id),
              entry.firstParty == true,
              let serviceHost = URL(string: service.url)?.host,
              let entryHost = URL(string: entry.url)?.host else { return false }
        return WebViewCoordinator.captureOriginBelongsToService(serviceHost, serviceHost: entryHost)
    }

    private static func captureKind(from type: WKMediaCaptureType) -> MediaCaptureKind {
        switch type {
        case .camera: return .camera
        case .microphone: return .microphone
        case .cameraAndMicrophone: return .cameraAndMicrophone
        @unknown default: return .cameraAndMicrophone  // unknown ⇒ most restrictive
        }
    }

    /// Decides what to do with a link that the user clicked in one service
    /// and which targets a different origin. If any other Chorus service owns
    /// that domain (same registrable domain, or the exact host for
    /// shared-umbrella domains like google.com) we switch to it (preserving
    /// auth/space context) and navigate to the deep URL. Otherwise we hand off
    /// to the system default browser.
    ///
    /// Multi-account aware: when several services match the same host (e.g.
    /// personal + work Notion), we prefer the match in the current space so
    /// "click a Notion link from Work Slack" lands in Work Notion. Only
    /// crosses spaces when the current space has no match.
    private func handleExternalLink(_ url: URL) {
        guard let host = url.host else {
            WebViewCoordinator.openExternally(url)
            return
        }

        if let match = findServiceMatching(host: host, preferringSpace: selectedSpaceID) {
            switchToService(match, navigateTo: url)
        } else {
            WebViewCoordinator.openExternally(url)
        }
    }

    private func findServiceMatching(host: String, preferringSpace spaceID: UUID?) -> ServiceInstance? {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<ServiceInstance>()
        guard let services = try? context.fetch(descriptor) else { return nil }

        let matches = services.filter { service in
            guard let serviceHost = URL(string: service.url)?.host else { return false }
            return WebViewCoordinator.belongsToService(host, serviceHost: serviceHost)
        }
        if matches.isEmpty { return nil }
        if matches.count == 1 { return matches.first }

        // Multiple instances of the same site (e.g. personal + work Notion).
        // Prefer one inside the current space; fall back to any match.
        if let spaceID,
           let inCurrentSpace = matches.first(where: { service in
               service.spaceLinks.contains {
                   $0.modelContext != nil && $0.space.modelContext != nil && $0.space.id == spaceID
               }
           }) {
            return inCurrentSpace
        }
        return matches.first
    }

    private func switchToService(_ service: ServiceInstance, navigateTo url: URL) {
        // Make sure we're in a space that contains this service so the
        // sidebar selection becomes visible. If the service lives in
        // multiple spaces, pick the first.
        if let firstSpace = service.spaceLinks.first(where: {
            $0.modelContext != nil && $0.space.modelContext != nil
        })?.space.id {
            selectedSpaceID = firstSpace
        }
        selectedServiceID = service.id

        // Acquire (or wake) the web view and load the deep URL. webView(for:)
        // marks the service active and handles soft-hibernation of whatever
        // was previously displayed.
        let webView = webViewPool.webView(for: service)
        webView.load(URLRequest(url: url))
    }

    /// Hooks NSWorkspace sleep/wake notifications so polling tasks pause
    /// while the Mac is asleep (otherwise their `Task.sleep` calls keep
    /// firing on wake-up and stack up missed work). On wake we restart
    /// polling for every live WKWebView — active mode for the currently
    /// displayed service, background mode for the rest.
    private func setupSystemSleepHandling() {
        let center = NSWorkspace.shared.notificationCenter
        systemObserverTokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.suspendPolling(reason: "system sleep")
            }
        })
        systemObserverTokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumePolling(reason: "system wake")
            }
        })
    }

    /// Pauses or resumes polling when network connectivity toggles. While
    /// offline every poll (active, background, and hibernated) would only fire
    /// doomed requests, draining battery for nothing; on reconnect we restart
    /// so badges refresh promptly.
    private func setupNetworkHandling() {
        networkMonitor.onChange = { [weak self] online in
            Task { @MainActor in
                guard let self else { return }
                if online {
                    self.resumePolling(reason: "network reachable")
                } else {
                    self.suspendPolling(reason: "network unreachable")
                }
            }
        }
    }

    /// Suspends all polling subsystems. Used for both system sleep and loss of
    /// network connectivity — in either case continued polling is wasted work.
    private func suspendPolling(reason: String) {
        notificationManager.stopAllPolling()
        transientBadgeFetcher.pause()
        AppLogger.general.info("Paused polling — \(reason)")
    }

    /// Resumes polling: restarts active/background polling for every live web
    /// view and re-arms the hibernated-service poller.
    private func resumePolling(reason: String) {
        // Sleep/wake and network changes both drive suspend/resume. Waking while
        // still offline must not restart polling: NWPathMonitor only fires on a
        // change, so a still-unsatisfied path delivers no event to re-suspend,
        // and pollers would hammer a dead network until the next transition.
        guard networkMonitor.isOnline else {
            AppLogger.general.info("Not resuming polling — offline (\(reason))")
            return
        }
        AppLogger.general.info("Resuming polling — \(reason)")
        restartPollingAfterWake()
        transientBadgeFetcher.resume()
    }

    private func restartPollingAfterWake() {
        let activeID = webViewPool.activeServiceID
        for id in webViewPool.liveServiceIDs {
            guard let webView = webViewPool.liveWebView(for: id) else { continue }
            let catalog = catalogEntry(for: id)
            notificationManager.startPolling(
                for: id,
                webView: webView,
                isMuted: { [weak self] in self?.isServiceEffectivelyMuted(id) ?? false },
                showBadge: { [weak self] in self?.isServiceShowingBadge(id) ?? true },
                catalogEntry: catalog,
                mode: (id == activeID) ? .active : .background
            )
        }
        AppLogger.general.info("System wake — restarted polling for \(self.webViewPool.liveServiceIDs.count) service(s)")
    }

    /// Effective mute state for a service: true if its own `isMuted` flag is
    /// set, or any space it belongs to has `isMuted` set. Used by polling and
    /// notification gating so that a muted space cascades to every member.
    nonisolated func isServiceEffectivelyMuted(_ serviceID: UUID) -> Bool {
        withService(id: serviceID) { $0.isEffectivelyMuted } ?? false
    }

    /// Single-service fetch by id (predicate + limit 1) instead of fetching the
    /// whole table and scanning. Main-actor only, since it hands back a SwiftData
    /// model; nonisolated callers use `withService` to extract Sendable values.
    private func fetchService(id: UUID) -> ServiceInstance? {
        var descriptor = FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContainer.mainContext.fetch(descriptor).first
    }

    /// Runs `body` against the service with `id` on the main actor and returns
    /// only the Sendable value it produces, so the SwiftData model never crosses
    /// the actor boundary. Used by the nonisolated mute/badge/catalog lookups on
    /// the poll and render paths. Returns nil when the service is gone.
    private nonisolated func withService<T: Sendable>(id: UUID, _ body: @MainActor (ServiceInstance) -> T) -> T? {
        MainActor.assumeIsolated {
            guard let service = fetchService(id: id) else { return nil }
            return body(service)
        }
    }

    // MARK: - Active service actions (driven by keyboard shortcuts)

    /// Reload the currently displayed service's web view. Triggered by Cmd-R.
    func reloadActiveService() {
        guard let id = webViewPool.activeServiceID,
              let webView = webViewPool.liveWebView(for: id) else { return }
        webView.reload()
    }

    /// Applies user edits to a service: persists label/URL/keep-loaded, syncs
    /// the pool's never-hibernate set, and navigates the live web view to the
    /// new URL when it changed. The caller has already mutated the model;
    /// this performs the runtime side effects and saves.
    func applyServiceEdits(
        serviceID: UUID,
        urlChanged: Bool,
        cssChanged: Bool = false,
        userAgentChanged: Bool = false,
        darkModeChanged: Bool = false
    ) {
        guard let service = currentServiceInstance(id: serviceID) else { return }
        webViewPool.setNeverHibernate(service.neverHibernate, for: serviceID)

        if cssChanged {
            // Custom CSS is injected when the web view is built, so rebuild it.
            // The rebuild also re-bakes the dark-mode scripts and picks up any
            // user-agent change and the new URL, so those are handled here.
            webViewPool.recreateWebView(for: serviceID, preserveURL: !urlChanged)
            webViewRebuildToken &+= 1
        } else {
            // Dark-mode change applies live without a rebuild — the pool
            // recomputes the injection from the service's new mode.
            if darkModeChanged {
                webViewPool.refreshDarkMode(for: service)
            }
            if userAgentChanged {
                webViewPool.setUserAgent(service.userAgent, for: serviceID)
            }
            if urlChanged, let url = URL(string: service.url) {
                webViewPool.navigate(serviceID, to: url)
            }
        }

        do {
            try modelContainer.mainContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save service edits: \(error.localizedDescription)")
            // Discard the failed mutation so it can't silently ride along on the
            // next unrelated successful save.
            modelContainer.mainContext.rollback()
        }
    }

    /// Clears a service's cached dark-theme detection verdict and rebuilds its
    /// web view so the probe runs again on the next load. Backs the "Re-detect
    /// dark theme" button for Auto-mode services: use it after switching a site
    /// to its own dark theme, so Chorus re-checks and stops layering Dark Reader
    /// on top.
    func redetectDarkTheme(for serviceID: UUID) {
        guard let service = currentServiceInstance(id: serviceID) else { return }
        // Clear the sticky verdict so the pool picks the `.probe` injection
        // again — `onDarkProbeVerdict` only records a result while it's nil.
        service.detectedLacksDarkTheme = nil
        do {
            try modelContainer.mainContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to reset dark verdict: \(error.localizedDescription)")
            // Discard the failed mutation so it can't ride along on a later save.
            modelContainer.mainContext.rollback()
            return
        }
        // Rebuild the view so it reloads and re-runs detection from the fresh
        // state (verdict now nil → `.probe` bakes into the next navigation).
        webViewPool.recreateWebView(for: serviceID, preserveURL: true)
        webViewRebuildToken &+= 1
    }

    /// Wipes all website data (cookies, local/session storage, caches) for a
    /// service's data store — effectively logging the user out — then reloads
    /// the live web view so the logged-out state is visible immediately. The
    /// service itself, its links, and its place in every space are preserved.
    func clearSession(for serviceID: UUID) {
        guard let service = currentServiceInstance(id: serviceID) else { return }
        let store = dataStoreManager.dataStore(forIdentifier: service.dataStoreIdentifier)
        let homeURL = URL(string: service.url)
        let pool = webViewPool
        Task { @MainActor in
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            await store.removeData(ofTypes: types, modifiedSince: .distantPast)
            if let webView = pool.liveWebView(for: serviceID) {
                if let homeURL {
                    webView.load(URLRequest(url: homeURL))
                } else {
                    webView.reload()
                }
            }
            AppLogger.dataStore.info("Cleared session for service \(serviceID)")
        }
    }

    /// Multiply the active service's page zoom by `factor`, clamped to 0.5x–3.0x.
    /// The new zoom is persisted on the ServiceInstance so it survives
    /// hibernation, relaunch, and switching back and forth.
    func adjustActiveServiceZoom(by factor: Double) {
        guard let id = webViewPool.activeServiceID,
              let webView = webViewPool.liveWebView(for: id),
              let service = currentServiceInstance(id: id) else { return }
        let target = max(0.5, min(3.0, Self.effectiveZoom(pageZoom: service.pageZoom, defaultZoom: defaultZoom) * factor))
        applyZoom(target, to: webView, service: service)
    }

    /// The zoom a service should render at: its own explicit zoom if set,
    /// otherwise the Chorus-wide default. Pure so it can be unit-tested.
    static func effectiveZoom(pageZoom: Double?, defaultZoom: Double) -> Double {
        pageZoom ?? defaultZoom
    }

    /// The effective zoom for a specific service, using the current global default.
    func effectiveZoom(for service: ServiceInstance) -> Double {
        Self.effectiveZoom(pageZoom: service.pageZoom, defaultZoom: defaultZoom)
    }

    /// Applies a new Chorus-wide default zoom in memory and to every open
    /// service that has no explicit per-service zoom. Persistence is handled by
    /// the Settings view (mirrors the badge/presence preferences). Clamped to
    /// the same 0.5x–3.0x range as manual zoom.
    func applyDefaultZoom(_ zoom: Double) {
        let clamped = max(0.5, min(3.0, zoom))
        defaultZoom = clamped
        let services = (try? modelContainer.mainContext.fetch(FetchDescriptor<ServiceInstance>())) ?? []
        for service in services where service.pageZoom == nil {
            webViewPool.liveWebView(for: service.id)?.pageZoom = CGFloat(clamped)
        }
    }

    // MARK: - Scheduled Do Not Disturb (quiet hours)

    /// True when `nowMinutes` (minutes since midnight) falls inside the
    /// quiet-hours window, handling the midnight wrap-around (e.g. 22:00→07:00).
    /// A zero-length window (start == end) is treated as no window. Pure, for
    /// unit testing.
    static func isWithinQuietHours(nowMinutes: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end { return nowMinutes >= start && nowMinutes < end }
        return nowMinutes >= start || nowMinutes < end
    }

    /// Whether the schedule currently puts Chorus into Do Not Disturb.
    var scheduledDNDActive: Bool {
        guard scheduledDNDEnabled else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let mins = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return Self.isWithinQuietHours(nowMinutes: mins, start: dndStartMinutes, end: dndEndMinutes)
    }

    /// Pushes the effective DND (manual toggle OR active schedule) into the
    /// badge manager, which the notification gate also reads. Call whenever the
    /// manual toggle or the schedule changes, and on the minute timer.
    func refreshEffectiveDoNotDisturb() {
        badgeManager.doNotDisturb = doNotDisturb || scheduledDNDActive
        badgeManager.updateDockBadge()
    }

    /// Re-evaluates the quiet-hours schedule every minute so effective DND flips
    /// at the window boundaries without the user touching anything.
    private func startQuietHoursTimer() {
        quietHoursTask?.cancel()
        quietHoursTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.refreshEffectiveDoNotDisturb()
            }
        }
    }

    // MARK: - App lock

    /// Shows the lock screen. No-op unless the lock is enabled, so a stray
    /// "Lock Now" can't trap a user who never set it up.
    func lock() {
        guard appLockEnabled else { return }
        isLocked = true
        // Don't leave a capture prompt hanging over the lock screen.
        drainAllMediaRequests()
    }

    /// Prompts for Touch ID (with the login password as fallback) and unlocks on
    /// success. If the device can't evaluate the policy at all (no password set),
    /// unlock rather than trap the user out of their app.
    func authenticate() {
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            AppLogger.general.error("App lock: cannot evaluate policy (\(policyError?.localizedDescription ?? "unknown")); unlocking to avoid lockout")
            isLocked = false
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Chorus") { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if success {
                    self.isLocked = false
                } else {
                    AppLogger.general.info("App lock: authentication did not succeed (\(error?.localizedDescription ?? "cancelled"))")
                }
            }
        }
    }

    /// Locks when the Mac sleeps or the screen locks, if the user opted in.
    private func setupLockObservers() {
        let lockOnSleepIfNeeded: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.appLockEnabled, self.lockOnSleep else { return }
                self.lock()
            }
        }
        systemObserverTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockOnSleepIfNeeded))
        distributedObserverTokens.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockOnSleepIfNeeded))
    }



    /// Reset the active service's zoom to 1.0. Triggered by Cmd-0.
    func resetActiveServiceZoom() {
        guard let id = webViewPool.activeServiceID,
              let webView = webViewPool.liveWebView(for: id),
              let service = currentServiceInstance(id: id) else { return }
        applyZoom(1.0, to: webView, service: service)
    }

    private func applyZoom(_ value: Double, to webView: WKWebView, service: ServiceInstance) {
        webView.pageZoom = CGFloat(value)
        service.pageZoom = value
        do { try modelContainer.mainContext.save() } catch {
            AppLogger.dataStore.error("Failed to persist zoom: \(error.localizedDescription)")
            modelContainer.mainContext.rollback()
        }
    }

    private func currentServiceInstance(id: UUID) -> ServiceInstance? {
        fetchService(id: id)
    }

    /// Per-service "show badge" flag, queried live so the polling task picks
    /// up toggles without restart.
    nonisolated func isServiceShowingBadge(_ serviceID: UUID) -> Bool {
        withService(id: serviceID) { $0.showBadge } ?? true
    }

    /// Re-applies mute/show-badge state immediately after settings changes.
    /// Polling tasks read these values on their next tick, but the UI and dock
    /// badge should update synchronously. The transient badge fetcher re-reads
    /// mute/show-badge at write time, so it needs no per-service state sync here.
    func refreshBadgeState(for serviceID: UUID) {
        guard let service = currentServiceInstance(id: serviceID) else { return }
        let count = badgeManager.rawCount(for: serviceID)
        let isMuted = isServiceEffectivelyMuted(serviceID)
        let showBadge = service.showBadge
        badgeManager.updateBadge(
            for: serviceID,
            count: count,
            isMuted: isMuted,
            showBadge: showBadge
        )
    }

    /// Tombstone list of `WKWebsiteDataStore` identifiers for services the
    /// user deleted but whose on-disk data hasn't been removed yet. Tracked
    /// in UserDefaults rather than via `WKWebsiteDataStore.allDataStoreIdentifiers`
    /// — that API has been observed to crash on macOS 26 when WebKit
    /// hands the returned `Vector<UUID>` to the Swift bridge (`BridgeObjectBox`
    /// initializeWithTake EXC_BAD_ACCESS during preload).
    private static let orphanedDataStoresKey = "chorus.orphanedDataStoreIdentifiers"

    /// Pure helper: given each service's set of parent-space IDs, returns the
    /// services that would be left with no space at all once `spaceID` is
    /// removed (i.e. they belong *only* to the space being deleted). Factored
    /// out so the orphan rule is unit-testable without SwiftData.
    nonisolated static func servicesOrphaned(
        byDeletingSpace spaceID: UUID,
        memberships: [UUID: Set<UUID>]
    ) -> Set<UUID> {
        var orphaned: Set<UUID> = []
        for (serviceID, spaces) in memberships
        where spaces.contains(spaceID) && spaces.subtracting([spaceID]).isEmpty {
            orphaned.insert(serviceID)
        }
        return orphaned
    }

    /// Deletes a space and reclaims any services that lived *only* in it.
    /// A service linked to other spaces is preserved (the delete-confirmation
    /// dialog promises this); a service orphaned by the deletion has its web
    /// view torn down and its on-disk `WKWebsiteDataStore` scheduled for
    /// removal, so deleting a space never leaves invisible orphan records or
    /// leaks per-service storage. Selection is moved off the deleted space.
    func deleteSpace(_ spaceID: UUID) {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Space>(predicate: #Predicate { $0.id == spaceID })
        guard let space = try? context.fetch(descriptor).first else { return }

        // Never delete the last space. With zero spaces the content area is
        // blank and ⌘N would present an Add-Service sheet with no space to add
        // to. The UI hides the delete action when only one space remains; this
        // is the safety net.
        let spaceCount = (try? context.fetchCount(FetchDescriptor<Space>())) ?? 0
        guard spaceCount > 1 else {
            AppLogger.dataStore.warning("Refusing to delete the last remaining space")
            return
        }

        // Guard against dangling links on both sides before materializing
        // `.service`/`.space` — reading a deleted model traps.
        let linkedServices = space.serviceLinks
            .filter { $0.modelContext != nil && $0.service.modelContext != nil }
            .map(\.service)
        var memberships: [UUID: Set<UUID>] = [:]
        for service in linkedServices {
            memberships[service.id] = Set(
                service.spaceLinks
                    .filter { $0.modelContext != nil && $0.space.modelContext != nil }
                    .map { $0.space.id }
            )
        }
        let orphanedIDs = Self.servicesOrphaned(byDeletingSpace: spaceID, memberships: memberships)

        // Delete the models and their orphaned services, but hold off on every
        // irreversible side effect (tearing down web views, wiping on-disk data
        // stores) until the save succeeds. Doing them first meant a failed save
        // left the service still in the store yet logged out with its cookies
        // deleted 2s later — data loss the rest of the code is careful to avoid.
        let reclaimed = linkedServices.filter { orphanedIDs.contains($0.id) }
        // Capture the identifiers BEFORE deleting — reading them off the models
        // after they're deleted would fault the freed backing data and trap.
        let reclaimedServiceIDs = reclaimed.map(\.id)
        let orphanedDataStoreIDs = reclaimed.map(\.dataStoreIdentifier)
        for service in reclaimed { context.delete(service) }
        context.delete(space)

        do {
            try context.save()
            AppLogger.dataStore.info("Deleted space \(spaceID); reclaimed \(reclaimed.count) orphaned service(s)")
        } catch {
            // Undo the pending deletes so the store, web views, and data stores
            // stay consistent with each other; nothing destructive has run yet.
            context.rollback()
            AppLogger.dataStore.error("Failed to delete space \(spaceID); rolled back: \(error.localizedDescription)")
            return
        }

        // Save committed — now the destructive cleanup is safe.
        for serviceID in reclaimedServiceIDs { webViewPool.removeWebView(for: serviceID) }
        for dataStoreID in orphanedDataStoreIDs { markDataStoreOrphaned(dataStoreID) }

        // Fix up selection: clear a selected service that was just reclaimed,
        // and move off the deleted space to the first remaining one.
        if let selected = selectedServiceID, orphanedIDs.contains(selected) {
            selectedServiceID = nil
        }
        if selectedSpaceID == spaceID {
            let remaining = (try? context.fetch(
                FetchDescriptor<Space>(sortBy: [SortDescriptor(\.sortOrder)])
            ))?.first
            selectedSpaceID = remaining?.id
            selectedServiceID = nil
        }

        cleanUpOrphanedDataStores()
    }

    /// Post-open sanity check for dangling `SpaceServiceLink` rows — join rows
    /// whose non-optional `space` points at a deleted `Space`, left behind by a
    /// build that shipped before `Space.serviceLinks` declared its inverse (the
    /// `.cascade` rule never fired). Reading such a link's `space` faults the
    /// deleted row and traps, crashing the app at launch, so the actual cleanup
    /// runs on the raw store file BEFORE it opens (`StoreRepair`, called from
    /// `init`). By the time this runs the store should already be clean; this
    /// only detects and logs anything that slipped through — deliberately
    /// without ever touching a link's `space`/`service`. It walks outward from
    /// live spaces and services (reading link `id`s only) and treats any link
    /// not reachable from BOTH sides as dangling. It does NOT delete: an
    /// object-graph delete faults the dead space on save (the very crash we
    /// avoid), which is why removal is the raw-file repair's job.
    /// Whether the store still holds any dangling `SpaceServiceLink` — a join
    /// row whose non-optional `space` or `service` points at a deleted row.
    /// Reading such a link's relationship faults the deleted model and traps
    /// ("backing data could no longer be found"), which is the launch/keystroke
    /// crash `StoreRepair` exists to prevent. `StoreRepair` runs on the raw file
    /// before the container opens; this is the post-open verification. If it
    /// returns true, the store is unsafe to run on and `init` falls back to the
    /// in-memory store rather than let a later unguarded `.space`/`.service`
    /// read brick the app.
    ///
    /// It never touches a dangling relationship: it walks outward only from
    /// live spaces and services, reading link `id`s (a stored attribute), and
    /// treats any link not reachable from BOTH sides as dangling.
    static func storeHasDanglingLinks(_ container: ModelContainer) -> Bool {
        let context = container.mainContext
        let links: [SpaceServiceLink]
        let spaces: [Space]
        let services: [ServiceInstance]
        do {
            links = try context.fetch(FetchDescriptor<SpaceServiceLink>())
            guard !links.isEmpty else { return false }
            spaces = try context.fetch(FetchDescriptor<Space>())
            services = try context.fetch(FetchDescriptor<ServiceInstance>())
        } catch {
            // Fail CLOSED: if we can't verify the store is clean, assume it
            // isn't. Returning false here would open a possibly-corrupt store
            // live, and the inline `.modelContext` guards are only a backstop —
            // treating an unverifiable store as unsafe (→ in-memory fallback) is
            // the safe default.
            AppLogger.dataStore.error("Dangling-link check failed; treating store as unsafe: \(error.localizedDescription)")
            return true
        }

        var reachableFromSpace: Set<UUID> = []
        for space in spaces {
            for link in space.serviceLinks { reachableFromSpace.insert(link.id) }
        }
        var reachableFromService: Set<UUID> = []
        for service in services {
            for link in service.spaceLinks { reachableFromService.insert(link.id) }
        }
        return links.contains {
            !reachableFromSpace.contains($0.id) || !reachableFromService.contains($0.id)
        }
    }

    /// Safety net for crash-mid-delete (or stores written by a build that
    /// predates `deleteSpace`'s reclaim logic): deletes any `ServiceInstance`
    /// that no longer belongs to any space and schedules its data store for
    /// removal. Runs once at launch, before preloading.
    private func reapOrphanedServices() {
        let context = modelContainer.mainContext
        let services: [ServiceInstance]
        do {
            services = try context.fetch(FetchDescriptor<ServiceInstance>())
        } catch {
            AppLogger.dataStore.error("Failed to fetch services for orphan reaping: \(error.localizedDescription)")
            return
        }

        let orphans = services.filter { $0.spaceLinks.isEmpty }
        guard !orphans.isEmpty else { return }

        // Capture identifiers before deleting; tombstoning + removing the on-disk
        // stores is irreversible, so defer it until the delete actually commits
        // (matches deleteSpace). A failed save rolls back so nothing is wiped.
        let orphanedIDs = orphans.map(\.dataStoreIdentifier)
        let orphanedInstanceIDs = orphans.map(\.id)
        for service in orphans {
            context.delete(service)
        }
        do {
            try context.save()
            AppLogger.dataStore.info("Reaped \(orphans.count) orphaned service(s) at launch")
        } catch {
            context.rollback()
            AppLogger.dataStore.error("Failed to reap orphaned services; rolled back: \(error.localizedDescription)")
            return
        }
        for id in orphanedIDs { markDataStoreOrphaned(id) }
        // This delete path doesn't go through removeWebView (orphans have no live
        // web view at launch), so drop each reaped service's theme cache here so
        // its snapshot file doesn't linger.
        for id in orphanedInstanceIDs { webViewPool.dropDarkThemeCache(for: id) }
        cleanUpOrphanedDataStores()
    }

    /// Mark a per-service data store identifier as orphaned. Called from
    /// the delete paths; the actual `WKWebsiteDataStore.remove(...)` is
    /// deferred to `cleanUpOrphanedDataStores()` so the live WKWebView has
    /// time to tear down first.
    func markDataStoreOrphaned(_ identifier: UUID) {
        var orphans = Self.loadOrphanedIdentifiers()
        orphans.insert(identifier)
        Self.saveOrphanedIdentifiers(orphans)
    }

    /// Removes any data store identifiers previously marked as orphaned.
    /// Runs at launch (deferred) and after the user deletes a service.
    func cleanUpOrphanedDataStores() {
        // Exclude identifiers a prior invocation is already processing, so two
        // overlapping calls (e.g. two deletes soon after launch) don't both run
        // the backoff loop and call `remove(...)` on the same store concurrently.
        let orphans = Self.loadOrphanedIdentifiers().subtracting(dataStoresBeingRemoved)
        guard !orphans.isEmpty else { return }
        dataStoresBeingRemoved.formUnion(orphans)

        // Drop cached handles so a live instance can't keep the on-disk store
        // alive while we try to remove it.
        for identifier in orphans {
            dataStoreManager.evict(identifier: identifier)
        }

        // Must stay on the main actor. WKWebsiteDataStore's internal
        // `allDataStores` registry asserts main-thread access, so calling
        // `remove(forIdentifier:)` from a background thread traps inside WebKit
        // (EXC_BREAKPOINT). Both `Task.sleep` and the async `remove` suspend
        // rather than block, so running here doesn't stall the UI.
        Task { @MainActor in
            // Removing a store while its WKWebView is still retained traps inside
            // WebKit, so removal must wait for the view to drop. The pool has
            // already released its own reference by the time this runs; the last
            // lingering one is SwiftUI's view hierarchy, which the pool can't see
            // — so we can't cheaply gate on "pool has no live view for this id".
            // Rather than trust one fixed delay (too short on a slow machine →
            // trap; too long always → sluggish), wait a conservative beat, then
            // retry with backoff, re-attempting only the stores WebKit still
            // reports as in use. Anything that never succeeds stays in the
            // tombstone list and is retried at the next launch, so no store leaks.
            var removed: Set<UUID> = []
            let backoff: [Duration] = [.seconds(2), .seconds(3), .seconds(5)]
            for delay in backoff {
                try? await Task.sleep(for: delay)
                let pending = orphans.subtracting(removed)
                guard !pending.isEmpty else { break }
                for identifier in pending {
                    do {
                        try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                        removed.insert(identifier)
                        AppLogger.dataStore.info("Removed orphaned data store \(identifier)")
                    } catch {
                        AppLogger.dataStore.warning("Data store \(identifier) not yet removable, will retry: \(error.localizedDescription)")
                    }
                }
            }

            // Release the in-flight claim so a later delete of the same store
            // (should one somehow re-orphan) isn't blocked.
            dataStoresBeingRemoved.subtract(orphans)

            // Read-modify-write rather than overwriting with a stale snapshot:
            // another delete may have appended new orphans while we slept, and
            // blindly saving `orphans − removed` would drop them, leaking those
            // stores permanently.
            let current = Self.loadOrphanedIdentifiers()
            Self.saveOrphanedIdentifiers(current.subtracting(removed))
        }
    }

    private static func loadOrphanedIdentifiers() -> Set<UUID> {
        guard let raw = UserDefaults.standard.array(forKey: orphanedDataStoresKey) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private static func saveOrphanedIdentifiers(_ identifiers: Set<UUID>) {
        if identifiers.isEmpty {
            UserDefaults.standard.removeObject(forKey: orphanedDataStoresKey)
        } else {
            UserDefaults.standard.set(identifiers.map(\.uuidString), forKey: orphanedDataStoresKey)
        }
    }

    /// Preloads web views for all services in the currently selected space.
    /// Runs after window state is restored so `selectedSpaceID` is already set.
    /// The selected service (if any) loads first, then the rest stagger at 500ms intervals.
    /// Returns services for a space, safely skipping any links with dangling relationships
    /// (can happen if the previous session crashed mid-delete).
    func servicesForSpace(_ spaceID: UUID) -> [ServiceInstance] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<SpaceServiceLink>()
        do {
            return try context.fetch(descriptor)
                // Guard both relationships: a link that outlived its deleted
                // service *or* its deleted space (crash mid-delete) would trap
                // when we materialize the non-optional relationship to read its
                // id. Reading `.modelContext` is safe (nil once deleted); read it
                // before `.space.id`.
                .filter {
                    $0.modelContext != nil
                        && $0.service.modelContext != nil
                        && $0.space.modelContext != nil
                        && $0.space.id == spaceID
                }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.service)
        } catch {
            AppLogger.dataStore.error("Failed to fetch links for space \(spaceID): \(error.localizedDescription)")
            return []
        }
    }

    private func preloadActiveSpaceServices() {
        guard let spaceID = selectedSpaceID else { return }
        let services = servicesForSpace(spaceID)
        guard !services.isEmpty else { return }

        // Move the selected service to the front so it preloads first.
        // We can't use sorted { a,_ in a.id == selected } — that violates
        // Swift's strict-weak-ordering and the sort is undefined.
        let selected = selectedServiceID
        var ordered = services
        if let selected, let idx = ordered.firstIndex(where: { $0.id == selected }) {
            let item = ordered.remove(at: idx)
            ordered.insert(item, at: 0)
        }

        // Pin the selected service so the LRU sweep that fires after each
        // preload can't evict it before WebContentView attaches and sets
        // `activeServiceID` (which would otherwise protect it).
        if let selected {
            webViewPool.pin(selected)
        }

        Task {
            await webViewPool.preloadAll(ordered)
            if let selected {
                webViewPool.unpin(selected)
            }
        }
    }

    /// Wires the transient badge fetcher's collaborators and starts its
    /// launch + slow-periodic sweep. The fetcher renders each service that has no
    /// live web view (everything outside the active space, plus anything the pool
    /// evicted) once in a short-lived offscreen view, reads its badge, and tears
    /// it down — so per-space aggregate badges are correct at launch and stay
    /// roughly current, instead of staying blank until each service is opened.
    private func startTransientBadgeFetcher() {
        // Fresh target list each sweep. Built synchronously on the main actor so
        // no @Model object is held across a suspension point; the fetcher only
        // ever sees the plain-value `Target` snapshots.
        transientBadgeFetcher.targetsProvider = { [weak self] in
            guard let self else { return [] }
            let services: [ServiceInstance]
            do {
                services = try self.modelContainer.mainContext.fetch(FetchDescriptor<ServiceInstance>())
            } catch {
                AppLogger.badges.error("Badge sweep fetch failed: \(error.localizedDescription)")
                return []
            }
            return services.compactMap { service in
                // A live web view already runs a poll that covers the badge, so
                // skip it; muted / badge-hidden services never show a count.
                guard !self.webViewPool.hasWebView(for: service.id),
                      !service.isEffectivelyMuted,
                      service.showBadge
                else { return nil }
                let badgeJS = service.catalogEntryID
                    .flatMap { ServiceCatalog.shared.entry(for: $0) }?.badgeJS
                return TransientBadgeFetcher.Target(
                    id: service.id,
                    url: service.url,
                    dataStoreIdentifier: service.dataStoreIdentifier,
                    userAgent: service.userAgent,
                    badgeJS: badgeJS
                )
            }
        }

        transientBadgeFetcher.hasLiveWebView = { [weak self] id in
            self?.webViewPool.hasWebView(for: id) ?? false
        }

        transientBadgeFetcher.currentBadgeParams = { [weak self] id in
            guard let self, let service = self.currentServiceInstance(id: id) else { return nil }
            return (self.isServiceEffectivelyMuted(id), service.showBadge)
        }

        transientBadgeFetcher.enabledContentRuleLists = { [weak self] in
            self?.contentBlocker.enabledLists() ?? []
        }

        transientBadgeFetcher.start()
    }

    /// Preloads services when the user switches to a different space.
    func preloadServicesForSpace(_ spaceID: UUID) {
        let services = servicesForSpace(spaceID)
        Task {
            await webViewPool.preloadAll(services)
        }
    }

    private func fetchCatalogIcons(force: Bool = false) {
        let entries = ServiceCatalog.shared.entries
        Task.detached(priority: .utility) {
            await CatalogIconCache.shared.fetchAllIfNeeded(entries: entries, force: force)
        }
    }

    private static let lastRunVersionKey = "chorus.lastRunAppVersion"

    /// Records the current app version and reports whether this launch follows an
    /// update (a different version ran last time). Used to refresh the icon caches
    /// so a release that adds or changes icons shows them at once, instead of
    /// waiting out the weekly staleness timer.
    private static func recordLaunchVersionAndCheckUpdate() -> Bool {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let previous = UserDefaults.standard.string(forKey: lastRunVersionKey)
        if !current.isEmpty {
            UserDefaults.standard.set(current, forKey: lastRunVersionKey)
        }
        return shouldBustCachesOnLaunch(previousVersion: previous, currentVersion: current)
    }

    /// Pure launch-vs-update decision: bust caches only when a real, different
    /// prior version is known. A fresh install (no previous) has no stale cache,
    /// and an unknown current version can't be compared, so both leave caches be.
    static func shouldBustCachesOnLaunch(previousVersion: String?, currentVersion: String) -> Bool {
        guard !currentVersion.isEmpty, let previousVersion, !previousVersion.isEmpty else { return false }
        return previousVersion != currentVersion
    }

    /// The single AppPreferences row, created (and inserted) once if missing.
    /// All preference *writes* must go through this: unlike a per-view @Query
    /// existence check, a fresh fetch here sees pending inserts, so two
    /// first-time setters in the same tick reuse one row instead of each
    /// inserting a duplicate (which then makes `.first` read nondeterministically
    /// and settings appear to reset). Reads may still use @Query.
    @discardableResult
    func ensurePreferences() -> AppPreferences {
        let context = modelContainer.mainContext
        if let existing = try? context.fetch(FetchDescriptor<AppPreferences>()).first {
            return existing
        }
        let prefs = AppPreferences()
        context.insert(prefs)
        return prefs
    }

    private func loadAppPreferences() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<AppPreferences>()
        let prefs: AppPreferences?
        do {
            prefs = try context.fetch(descriptor).first
        } catch {
            AppLogger.dataStore.error("Failed to load preferences: \(error.localizedDescription)")
            prefs = nil
        }

        // No AppKit/dockTile/setActivationPolicy access in this scope — it
        // runs inside AppState.init via @State, which fires before the
        // SwiftUI App scene has finished wiring up NSApp. Touching AppKit
        // there can race with NSApplication bootstrap. Defer the
        // AppKit-facing mutations to the next runloop tick.
        userScriptManager.autoDismissCookieBanners = prefs?.autoDismissCookieBanners ?? true
        defaultZoom = prefs?.defaultZoomEffective ?? 1.0
        railLayout = prefs?.railLayout ?? .sidebar
        appearanceMode = prefs?.appearanceMode ?? .system
        scheduledDNDEnabled = prefs?.scheduledDNDEnabled ?? false
        dndStartMinutes = prefs?.dndStartMinutes ?? (22 * 60)
        dndEndMinutes = prefs?.dndEndMinutes ?? (7 * 60)

        appLockEnabled = prefs?.appLockEnabled ?? false
        lockOnLaunch = prefs?.lockOnLaunch ?? true
        lockOnSleep = prefs?.lockOnSleep ?? true
        contentBlockingEnabled = prefs?.contentBlockingEnabledEffective ?? true
        annoyanceBlockingEnabled = prefs?.annoyanceBlockingEnabledEffective ?? false
        autoDarkModeEnabled = prefs?.autoDarkModeEnabledEffective ?? false
        let googleFallback = prefs?.googleFaviconFallbackEnabledEffective ?? false
        Task { await FaviconFetcher.shared.setGoogleFallbackEnabled(googleFallback) }
        defaultCameraPolicy = prefs?.defaultCameraPolicyRaw.flatMap(MediaPermissionPolicy.init(rawValue:)) ?? .ask
        defaultMicrophonePolicy = prefs?.defaultMicrophonePolicyRaw.flatMap(MediaPermissionPolicy.init(rawValue:)) ?? .ask
        // Start locked at launch when opted in; ContentView's lock overlay
        // prompts for Touch ID on appear.
        if appLockEnabled && lockOnLaunch {
            isLocked = true
        }

        let resolvedShowBadge = prefs?.showBadgeCountInDock ?? true
        let resolvedPresenceMode = prefs?.appPresenceMode ?? .dock
        Task { @MainActor in
            // Launch AppKit-facing setup is now safe (past the init runloop tick).
            // Flip the flag first so the DND `didSet`s become live from here on.
            self.isLaunchComplete = true
            self.badgeManager.showBadgeCountInDock = resolvedShowBadge
            AppPresenceManager().apply(mode: resolvedPresenceMode)
            // Apply any active quiet-hours schedule now, then keep it current.
            self.refreshEffectiveDoNotDisturb()
            self.startQuietHoursTimer()
            self.setupLockObservers()
            self.startDarkMode()
        }
    }

    /// Pushes the initial effective appearance to the pool (so dark-opted-in
    /// services theme correctly) and observes macOS appearance changes for when
    /// the app follows the system. Runs after launch, on the main actor.
    private func startDarkMode() {
        applyEffectiveAppearanceChange()
        distributedObserverTokens.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyEffectiveAppearanceChange() }
        })
    }

    /// Re-evaluates the effective Light/Dark appearance and, when it actually
    /// changed, re-applies dark theming across all live web views. Called at
    /// launch, when the user picks an appearance, and when the OS theme flips in
    /// System mode.
    func applyEffectiveAppearanceChange() {
        let dark = isEffectiveAppearanceDark
        guard dark != lastKnownAppearanceDark else { return }
        lastKnownAppearanceDark = dark
        webViewPool.applyDarkState(isDark: dark, autoEnabled: autoDarkModeEnabled, services: allServices())
    }

    /// Flips the global auto-dark setting and re-applies dark theming live. The
    /// Settings binding persists the value; this drives the in-memory state and
    /// the web views.
    func setAutoDarkModeEnabled(_ enabled: Bool) {
        autoDarkModeEnabled = enabled
        webViewPool.applyDarkState(isDark: isEffectiveAppearanceDark, autoEnabled: enabled, services: allServices())
    }

    /// All services (the pool skips those without a live web view). `.auto`
    /// services need re-evaluating on an appearance/global change, so this can't
    /// pre-filter to only the explicitly-marked ones.
    private func allServices() -> [ServiceInstance] {
        let context = modelContainer.mainContext
        return (try? context.fetch(FetchDescriptor<ServiceInstance>())) ?? []
    }

    /// Kicks off content-blocklist compilation at launch (before preload, so it
    /// usually finishes before the first web view is built). Syncs the enabled
    /// state from prefs and, once the lists are ready, re-attaches them to any
    /// web views that were built first.
    private func startContentBlocker() {
        contentBlocker.isEnabled = contentBlockingEnabled
        contentBlocker.annoyanceEnabled = annoyanceBlockingEnabled
        contentBlocker.onReady = { [weak self] in
            // Lists finished compiling after some web views were already built —
            // attach them in place (no teardown, no reload, no lost polling).
            self?.webViewPool.reattachContentBlocker()
        }
        contentBlocker.start()
    }

    /// Flips the global content blocker, persists it, and rebuilds live web
    /// views so the change takes effect immediately.
    func setContentBlockingEnabled(_ enabled: Bool) {
        contentBlockingEnabled = enabled
        contentBlocker.isEnabled = enabled
        let prefs = ensurePreferences()
        prefs.contentBlockingEnabled = enabled
        do {
            try modelContainer.mainContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save content-blocking toggle: \(error.localizedDescription)")
            modelContainer.mainContext.rollback()
        }
        webViewPool.reattachContentBlocker()
    }

    /// Opts in or out of the Google favicon fallback and persists the choice.
    /// Pushes the flag into the fetcher actor so later fetches pick it up.
    func setGoogleFaviconFallbackEnabled(_ enabled: Bool) {
        let prefs = ensurePreferences()
        prefs.googleFaviconFallbackEnabled = enabled
        do {
            try modelContainer.mainContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save favicon fallback toggle: \(error.localizedDescription)")
            modelContainer.mainContext.rollback()
        }
        Task { await FaviconFetcher.shared.setGoogleFallbackEnabled(enabled) }
    }

    /// Flips annoyance hiding, persists it, and re-attaches lists to live views.
    func setAnnoyanceBlockingEnabled(_ enabled: Bool) {
        annoyanceBlockingEnabled = enabled
        contentBlocker.annoyanceEnabled = enabled
        let prefs = ensurePreferences()
        prefs.annoyanceBlockingEnabled = enabled
        do {
            try modelContainer.mainContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save annoyance-blocking toggle: \(error.localizedDescription)")
            modelContainer.mainContext.rollback()
        }
        webViewPool.reattachContentBlocker()
    }

    private func setupHibernationCallbacks() {
        // When a service's page finishes loading (startup or login redirect),
        // poll its badge immediately instead of waiting for the next tick.
        webViewPool.onNavigationFinished = { [weak self] serviceID in
            guard let self,
                  let webView = self.webViewPool.liveWebView(for: serviceID) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.notificationManager.pollNow(
                    for: serviceID,
                    webView: webView,
                    isMuted: self.isServiceEffectivelyMuted(serviceID),
                    showBadge: self.isServiceShowingBadge(serviceID),
                    catalogEntry: self.catalogEntry(for: serviceID)
                )
            }
        }

        webViewPool.onServiceHibernated = { [weak self] serviceID in
            // The web view is gone, so its live poll can't run. The transient
            // badge fetcher's periodic sweep now covers this service (it targets
            // anything without a live web view); the badge holds its last value
            // until the next sweep.
            self?.notificationManager.stopPolling(for: serviceID)
        }

        webViewPool.onServiceSoftHibernated = { [weak self] serviceID in
            guard let self else { return }
            // Downgrade the active 5s-adaptive poll to a flat 30s background
            // poll. We keep the WKWebView around (soft hibernation) so we can
            // still read its `document.title` without waking the service.
            guard let webView = self.webViewPool.liveWebView(for: serviceID) else {
                self.notificationManager.stopPolling(for: serviceID)
                return
            }
            self.startBackgroundPolling(for: serviceID, webView: webView)
        }

        webViewPool.onServiceSoftWoke = { _ in
            // Polling will restart when WebContentView attaches the web view
            // No action needed here — startPolling is called from the view layer
        }

        webViewPool.onServicePreloaded = { [weak self] serviceID, webView in
            // A freshly-preloaded service has a live WKWebView but isn't on
            // screen. Start it on the background poll so its <title>-based
            // badge count contributes to the sidebar and the per-space
            // aggregate as soon as the page finishes loading.
            self?.startBackgroundPolling(for: serviceID, webView: webView)
        }

        webViewPool.onServiceRemoved = { [weak self] serviceID in
            guard let self else { return }
            self.notificationManager.stopPolling(for: serviceID)
            self.badgeManager.removeBadge(for: serviceID)
            self.drainMediaRequests(for: serviceID)
        }
    }

    /// Starts (or replaces) a background-mode poll for a service with a live
    /// WKWebView that isn't currently displayed.
    private func startBackgroundPolling(for serviceID: UUID, webView: WKWebView) {
        let catalogEntry = catalogEntry(for: serviceID)
        notificationManager.startPolling(
            for: serviceID,
            webView: webView,
            isMuted: { [weak self] in self?.isServiceEffectivelyMuted(serviceID) ?? false },
            showBadge: { [weak self] in self?.isServiceShowingBadge(serviceID) ?? true },
            catalogEntry: catalogEntry,
            mode: .background
        )
    }

    private nonisolated func catalogEntry(for serviceID: UUID) -> ServiceCatalogEntry? {
        withService(id: serviceID) { service -> ServiceCatalogEntry? in
            guard let entryID = service.catalogEntryID else { return nil }
            return ServiceCatalog.shared.entry(for: entryID)
        } ?? nil
    }

    private func setupMenuBarNavigation() {
        NotificationCenter.default.addObserver(
            forName: .menuBarServiceActivated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let serviceID = userInfo["serviceID"] as? UUID,
                  let spaceID = userInfo["spaceID"] as? UUID
            else { return }
            Task { @MainActor in
                self?.selectedSpaceID = spaceID
                self?.selectedServiceID = serviceID
            }
        }
    }

    private func setupNotificationNavigation() {
        notificationManager.onServiceRequested = { [weak self] serviceID in
            self?.navigateToServiceFromNotification(serviceID)
        }
        // Drain any notification taps that arrived (e.g. launched the app)
        // before the handler was wired, in order. The last one wins the final
        // selection, but each is processed rather than silently dropped.
        for pending in notificationManager.drainPendingNotifications() {
            navigateToServiceFromNotification(pending)
        }
    }

    /// Selects the service a notification refers to, and switches to a space
    /// that contains it so the selection is actually visible in the sidebar.
    private func navigateToServiceFromNotification(_ serviceID: UUID) {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == serviceID })
        guard let service = try? context.fetch(descriptor).first else { return }

        // If the service isn't in the current space, move to one that has it.
        // Guard the link relationships first: reading `$0.space.id` on a link
        // whose Space was deleted (a dangling link that outlived StoreRepair)
        // faults the freed model and traps. Reading `.modelContext` is safe.
        let liveLinks = service.spaceLinks.filter {
            $0.modelContext != nil && $0.space.modelContext != nil
        }
        let inCurrentSpace = liveLinks.contains { $0.space.id == selectedSpaceID }
        if !inCurrentSpace, let firstSpace = liveLinks.first?.space.id {
            selectedSpaceID = firstSpace
        }
        selectedServiceID = serviceID
    }

    private func restoreWindowState() {
        let context = modelContainer.mainContext
        do {
            let prefs = try context.fetch(FetchDescriptor<AppPreferences>()).first

            // Apply a saved space only if it still exists. A nil/invalid saved
            // value leaves the seeded selection in place.
            let existingSpaceIDs = Set(try context.fetch(FetchDescriptor<Space>()).map(\.id))
            if let savedSpaceID = prefs?.selectedSpaceID, existingSpaceIDs.contains(savedSpaceID) {
                selectedSpaceID = savedSpaceID
            }

            // Validate the service selection against the current space. A space
            // or service selected last session may have been deleted (or reaped
            // at launch); ContentView's onChange fix-up doesn't run for the
            // initial value, so a dangling id would strand the app on a blank
            // pane until the user clicked. Fall back to the space's first service.
            guard let spaceID = selectedSpaceID else {
                selectedServiceID = nil
                return
            }
            let servicesInSpace = servicesForSpace(spaceID)
            if let savedServiceID = prefs?.selectedServiceID,
               servicesInSpace.contains(where: { $0.id == savedServiceID }) {
                selectedServiceID = savedServiceID
            } else if selectedServiceID == nil
                        || !servicesInSpace.contains(where: { $0.id == selectedServiceID }) {
                selectedServiceID = servicesInSpace.first?.id
            }
        } catch {
            AppLogger.dataStore.error("Failed to restore window state: \(error.localizedDescription)")
        }
    }

    /// Fetches favicons for services that have none cached, and refreshes
    /// stale favicons (older than 7 days). Runs in a background Task to avoid
    /// blocking app launch.
    private func fetchMissingAndStaleFavicons(force: Bool = false) {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<ServiceInstance>()
        let services: [ServiceInstance]
        do {
            services = try context.fetch(descriptor)
        } catch {
            AppLogger.favicon.error("Failed to fetch services for favicon refresh: \(error.localizedDescription)")
            return
        }

        let staleThreshold = Date().addingTimeInterval(-7 * 24 * 60 * 60) // 7 days

        let needsFetch = services.filter { service in
            guard service.customIconData == nil else { return false }
            // After an app update, refresh every service's favicon regardless of
            // age. Otherwise back off on the timestamp for both "never fetched"
            // and "stale": a service whose favicon keeps failing gets stamped on
            // failure (below), so it retries at most weekly instead of every launch.
            if force { return true }
            guard let fetchedAt = service.faviconFetchedAt else { return true }
            return fetchedAt < staleThreshold
        }

        guard !needsFetch.isEmpty else { return }
        AppLogger.favicon.info("Fetching favicons for \(needsFetch.count) service(s)")

        // Capture IDs before the Task — model objects may be deleted during await
        let fetchEntries = needsFetch.map { (id: $0.id, url: $0.url, hadIcon: $0.fetchedIconData != nil) }

        Task {
            for entry in fetchEntries {
                let data = await FaviconFetcher.shared.fetchFavicon(for: entry.url)
                // Re-fetch the model — it may have been deleted while we were awaiting
                let entryID = entry.id
                let descriptor = FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == entryID })
                guard let service = try? context.fetch(descriptor).first else { continue }

                if let data {
                    service.fetchedIconData = data
                }
                // Stamp on every attempt, success or failure, so a service whose
                // favicon can't be fetched backs off instead of retrying every
                // launch (a nil icon with a recent timestamp is "recently tried").
                service.faviconFetchedAt = Date()
            }
            do {
                try context.save()
                AppLogger.favicon.info("Favicon refresh complete")
            } catch {
                AppLogger.dataStore.error("Failed to save refreshed favicons: \(error.localizedDescription)")
                context.rollback()
            }
        }
    }

    /// Seeds the default spaces and services on a first launch. Returns `true`
    /// if it seeded (a fresh install), `false` if data already existed or the
    /// fetch failed — the caller uses this to decide whether to backfill the
    /// passkey notice.
    @discardableResult
    private func seedDefaultDataIfNeeded() -> Bool {
        let context = modelContainer.mainContext

        // Sorted so the fallback selection is the top space (sortOrder 0), not a
        // nondeterministic one — matches deleteSpace's remaining-space pick.
        let descriptor = FetchDescriptor<Space>(sortBy: [SortDescriptor(\.sortOrder)])
        let existingSpaces: [Space]
        do {
            existingSpaces = try context.fetch(descriptor)
        } catch {
            AppLogger.dataStore.error("Failed to fetch spaces during seeding: \(error.localizedDescription)")
            return false
        }

        guard existingSpaces.isEmpty else {
            selectedSpaceID = existingSpaces.first?.id
            return false
        }

        let personalSpace = Space(name: "Personal", emoji: "🏠", sortOrder: 0)
        let workSpace = Space(name: "Work", emoji: "💼", sortOrder: 1)
        context.insert(personalSpace)
        context.insert(workSpace)

        // Each space gets its own ServiceInstance — even for the same service URL —
        // so cookies, sessions, and login state are fully isolated between spaces.
        let personalServices: [(String, String, String)] = [
            ("Gmail", "https://mail.google.com/mail/u/0/#inbox", "gmail"),
            ("Discord", "https://discord.com/channels/@me", "discord"),
            ("ChatGPT", "https://chatgpt.com", "chatgpt"),
            ("Claude", "https://claude.ai", "claude"),
        ]

        let workServices: [(String, String, String)] = [
            ("Gmail", "https://mail.google.com/mail/u/0/#inbox", "gmail"),
            ("Slack", "https://app.slack.com/client", "slack"),
            ("Outlook", "https://outlook.cloud.microsoft/mail/", "outlook"),
        ]

        for (index, (label, url, catalogID)) in personalServices.enumerated() {
            let service = ServiceInstance(label: label, url: url, catalogEntryID: catalogID)
            context.insert(service)
            context.insert(SpaceServiceLink(sortOrder: index, space: personalSpace, service: service))
        }

        for (index, (label, url, catalogID)) in workServices.enumerated() {
            let service = ServiceInstance(label: label, url: url, catalogEntryID: catalogID)
            context.insert(service)
            context.insert(SpaceServiceLink(sortOrder: index, space: workSpace, service: service))
        }

        do {
            try context.save()
            selectedSpaceID = personalSpace.id
            AppLogger.dataStore.info("Seeded default spaces: Personal and Work")

            // Fetch favicons for all seeded services — capture IDs before the Task
            let allServicesDescriptor = FetchDescriptor<ServiceInstance>()
            do {
                let entries = try context.fetch(allServicesDescriptor).map { (id: $0.id, url: $0.url) }
                Task {
                    for entry in entries {
                        let data = await FaviconFetcher.shared.fetchFavicon(for: entry.url)
                        guard let data else { continue }
                        let entryID = entry.id
                        let desc = FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == entryID })
                        guard let service = try? context.fetch(desc).first else { continue }
                        service.fetchedIconData = data
                        service.faviconFetchedAt = Date()
                    }
                    do {
                        try context.save()
                    } catch {
                        AppLogger.dataStore.error("Failed to save seeded favicons: \(error.localizedDescription)")
                        context.rollback()
                    }
                }
            } catch {
                AppLogger.dataStore.error("Failed to fetch services for favicon seeding: \(error.localizedDescription)")
            }
            return true
        } catch {
            AppLogger.dataStore.error("Failed to seed default data: \(error.localizedDescription)")
            return false
        }
    }

    private static let passkeyNoticeBackfilledKey = "passkeyNoticeBackfilled"

    /// Runs once, the first time a build with the passkey notice launches. For a
    /// pre-existing install it marks every current service as having seen the
    /// notice, so the banner only appears for services added afterward rather
    /// than for every service the user already had. On a fresh install
    /// (`freshInstall == true`) it skips the marking, so the notice still shows
    /// the first time each seeded service is opened.
    private func backfillPasskeyNoticeIfNeeded(freshInstall: Bool) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.passkeyNoticeBackfilledKey) else { return }
        // Set the flag first so a failure below doesn't re-run (and re-suppress)
        // the notice on a later launch after the user has added new services.
        defaults.set(true, forKey: Self.passkeyNoticeBackfilledKey)

        guard !freshInstall else { return }

        let context = modelContainer.mainContext
        let services: [ServiceInstance]
        do {
            services = try context.fetch(FetchDescriptor<ServiceInstance>())
        } catch {
            AppLogger.dataStore.error("Failed to fetch services for passkey-notice backfill: \(error.localizedDescription)")
            return
        }

        var changed = false
        for service in services where service.hasSeenPasskeyNotice == nil {
            service.hasSeenPasskeyNotice = true
            changed = true
        }
        guard changed else { return }
        do {
            try context.save()
            AppLogger.dataStore.info("Backfilled passkey notice for \(services.count) existing service(s)")
        } catch {
            AppLogger.dataStore.error("Failed to backfill passkey notice: \(error.localizedDescription)")
            context.rollback()
        }
    }

    /// Whether the passkey-limitation banner should show for `service` — true
    /// until the notice has been seen once for that service.
    func shouldShowPasskeyNotice(for service: ServiceInstance) -> Bool {
        service.needsPasskeyNotice
    }

    /// Records that the passkey notice has been shown for the given service so
    /// it never appears again for it.
    func markPasskeyNoticeSeen(for serviceID: UUID) {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == serviceID })
        descriptor.fetchLimit = 1
        guard let service = try? context.fetch(descriptor).first, service.needsPasskeyNotice else { return }
        service.hasSeenPasskeyNotice = true
        do {
            try context.save()
        } catch {
            AppLogger.dataStore.error("Failed to persist passkey notice dismissal: \(error.localizedDescription)")
            context.rollback()
        }
    }
}
