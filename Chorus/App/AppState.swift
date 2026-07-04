import SwiftUI
import SwiftData
import WebKit
import LocalAuthentication

@MainActor
@Observable
final class AppState {
    let modelContainer: ModelContainer
    let webViewPool: WebViewPool
    let dataStoreManager: DataStoreManager
    let userScriptManager: UserScriptManager
    let badgeManager: BadgeManager

    /// Navigation state (back/forward/loading) for the active service's web view,
    /// shared so the top tab bar can host the nav buttons.
    let webViewState = WebViewState()
    let notificationManager: NotificationManager
    let hibernatedBadgePoller: HibernatedBadgePoller
    let networkMonitor: NetworkMonitor

    var selectedSpaceID: UUID?
    var selectedServiceID: UUID?
    var showAddService = false
    var showQuickSwitcher = false
    var doNotDisturb = false
    /// Drives the Find-in-Page overlay in WebContentView. Toggled by Cmd-F.
    var findInPageVisible = false

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

    /// Scheduled "quiet hours" Do Not Disturb, loaded from AppPreferences.
    /// `doNotDisturb` above stays the manual toggle; the effective DND that
    /// gates badges and notifications is `doNotDisturb || scheduledDNDActive`.
    var scheduledDNDEnabled = false
    var dndStartMinutes = 22 * 60
    var dndEndMinutes = 7 * 60
    private var quietHoursTask: Task<Void, Never>?

    /// App lock (Touch ID / password), loaded from AppPreferences. `isLocked`
    /// drives an opaque cover over the window content in ContentView.
    var appLockEnabled = false
    var lockOnLaunch = true
    var lockOnSleep = true
    var isLocked = false

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

        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Never auto-delete the user's persistent store: silent destruction
            // is data loss without consent. Fall back to in-memory storage so
            // the app stays usable, surface a banner with the on-disk path,
            // and let the user choose whether to reset via Settings.
            AppLogger.dataStore.error("Persistent store could not be opened: \(error.localizedDescription). Falling back to in-memory storage; on-disk data is preserved at \(config.url.path).")
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
                let descriptor = FetchDescriptor<ServiceInstance>()
                guard let services = try? context.fetch(descriptor),
                      let service = services.first(where: { $0.id == serviceID })
                else { return false }
                if service.isMuted { return true }
                return service.spaceLinks.contains { $0.space.isMutedEffective }
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
        self.hibernatedBadgePoller = HibernatedBadgePoller(
            badgeManager: badgeManager,
            dataStoreManager: dataStoreManager
        )
        self.webViewPool = WebViewPool(
            dataStoreManager: dataStoreManager,
            userScriptManager: userScriptManager
        )
        self.networkMonitor = NetworkMonitor()

        loadAppPreferences()
        setupNotificationNavigation()
        setupHibernationCallbacks()
        setupMenuBarNavigation()
        setupSystemSleepHandling()
        setupNetworkHandling()
        setupExternalLinkRouting()
        seedDefaultDataIfNeeded()
        reapOrphanedServices()
        restoreWindowState()
        fetchMissingAndStaleFavicons()
        fetchCatalogIcons()
        preloadActiveSpaceServices()
        fetchInitialBadgesForBackgroundServices()
        cleanUpOrphanedDataStores()
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
            NSWorkspace.shared.open(url)
            return
        }

        if let match = findServiceMatching(host: host, preferringSpace: selectedSpaceID) {
            switchToService(match, navigateTo: url)
        } else {
            NSWorkspace.shared.open(url)
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
               service.spaceLinks.contains { $0.space.id == spaceID }
           }) {
            return inCurrentSpace
        }
        return matches.first
    }

    private func switchToService(_ service: ServiceInstance, navigateTo url: URL) {
        // Make sure we're in a space that contains this service so the
        // sidebar selection becomes visible. If the service lives in
        // multiple spaces, pick the first.
        if let firstSpace = service.spaceLinks.first?.space.id {
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
        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.suspendPolling(reason: "system sleep")
            }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumePolling(reason: "system wake")
            }
        }
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
        hibernatedBadgePoller.pause()
        AppLogger.general.info("Paused polling — \(reason)")
    }

    /// Resumes polling: restarts active/background polling for every live web
    /// view and re-arms the hibernated-service poller.
    private func resumePolling(reason: String) {
        AppLogger.general.info("Resuming polling — \(reason)")
        restartPollingAfterWake()
        hibernatedBadgePoller.resume()
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
        MainActor.assumeIsolated {
            fetchService(id: serviceID)?.isEffectivelyMuted ?? false
        }
    }

    /// Single-service fetch by id (predicate + limit 1) instead of fetching the
    /// whole table and scanning. Used by the mute/badge/catalog lookups that
    /// run on every poll tick and every sidebar render.
    private nonisolated func fetchService(id: UUID) -> ServiceInstance? {
        MainActor.assumeIsolated {
            var descriptor = FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try? modelContainer.mainContext.fetch(descriptor).first
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
        userAgentChanged: Bool = false
    ) {
        guard let service = currentServiceInstance(id: serviceID) else { return }
        webViewPool.setNeverHibernate(service.neverHibernate, for: serviceID)

        if cssChanged {
            // Custom CSS is injected when the web view is built, so rebuild it.
            // The rebuild also picks up any user-agent change and the new URL,
            // so those are handled here rather than separately.
            webViewPool.recreateWebView(for: serviceID, preserveURL: !urlChanged)
            webViewRebuildToken &+= 1
        } else {
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
        }
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
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockOnSleepIfNeeded)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockOnSleepIfNeeded)
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
        }
    }

    private func currentServiceInstance(id: UUID) -> ServiceInstance? {
        fetchService(id: id)
    }

    /// Per-service "show badge" flag, queried live so the polling task picks
    /// up toggles without restart.
    nonisolated func isServiceShowingBadge(_ serviceID: UUID) -> Bool {
        MainActor.assumeIsolated {
            fetchService(id: serviceID)?.showBadge ?? true
        }
    }

    /// Re-applies mute/show-badge state immediately after settings changes.
    /// Polling tasks read these values on their next tick, but the UI and dock
    /// badge should update synchronously. Fully hibernated services also need
    /// their lightweight poller state refreshed so stale polls do not re-add
    /// badges after a mute/show-badge toggle.
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
        hibernatedBadgePoller.updateState(
            serviceID: serviceID,
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

        let linkedServices = space.serviceLinks.map(\.service)
        var memberships: [UUID: Set<UUID>] = [:]
        for service in linkedServices {
            memberships[service.id] = Set(service.spaceLinks.map { $0.space.id })
        }
        let orphanedIDs = Self.servicesOrphaned(byDeletingSpace: spaceID, memberships: memberships)

        for service in linkedServices where orphanedIDs.contains(service.id) {
            let dataStoreID = service.dataStoreIdentifier
            webViewPool.removeWebView(for: service.id)
            context.delete(service)
            markDataStoreOrphaned(dataStoreID)
        }

        context.delete(space)

        do {
            try context.save()
            AppLogger.dataStore.info("Deleted space \(spaceID); reclaimed \(orphanedIDs.count) orphaned service(s)")
        } catch {
            AppLogger.dataStore.error("Failed to delete space: \(error.localizedDescription)")
        }

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

        for service in orphans {
            markDataStoreOrphaned(service.dataStoreIdentifier)
            context.delete(service)
        }
        do {
            try context.save()
            AppLogger.dataStore.info("Reaped \(orphans.count) orphaned service(s) at launch")
        } catch {
            AppLogger.dataStore.error("Failed to reap orphaned services: \(error.localizedDescription)")
        }
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
        let orphans = Self.loadOrphanedIdentifiers()
        guard !orphans.isEmpty else { return }

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
            // Let SwiftUI finish dropping any WKWebView that referenced
            // a just-deleted service's data store before removing it —
            // WebKit also traps when an in-use store is removed.
            try? await Task.sleep(for: .seconds(2))

            var removed: Set<UUID> = []
            for identifier in orphans {
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                    removed.insert(identifier)
                    AppLogger.dataStore.info("Removed orphaned data store \(identifier)")
                } catch {
                    AppLogger.dataStore.warning("Failed to remove orphaned data store \(identifier): \(error.localizedDescription)")
                }
            }

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
                .filter { $0.modelContext != nil && $0.service.modelContext != nil && $0.space.id == spaceID }
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

    /// One-shot launch badge fetch for services that won't get a live web view
    /// (i.e. outside the active space, which is preloaded). Populates their
    /// unread badges promptly so per-space aggregate badges are correct at
    /// launch instead of staying blank until first opened. Skips muted services
    /// and services with the badge hidden.
    ///
    /// Active-space services are excluded here: each preloaded web view starts a
    /// recurring background poll (via `onServicePreloaded`) and also fires an
    /// immediate `pollNow` when its page finishes loading (`onNavigationFinished`).
    private func fetchInitialBadgesForBackgroundServices() {
        let activeSpaceID = selectedSpaceID

        let context = modelContainer.mainContext
        let services: [ServiceInstance]
        do {
            services = try context.fetch(FetchDescriptor<ServiceInstance>())
        } catch {
            AppLogger.badges.error("Launch badge sweep fetch failed: \(error.localizedDescription)")
            return
        }

        // Snapshot plain values from the already-fetched objects (no per-entry
        // re-fetch) before the async loop, so we never touch a possibly-deleted
        // @Model object across a suspension point. Membership/mute/show-badge
        // are read directly from the in-hand objects.
        struct SweepEntry { let id: UUID; let url: String; let dataStoreID: UUID }
        let entries: [SweepEntry] = services.compactMap { service in
            let inActiveSpace = activeSpaceID != nil
                && service.spaceLinks.contains { $0.space.id == activeSpaceID }
            guard !inActiveSpace, !service.isEffectivelyMuted, service.showBadge else { return nil }
            return SweepEntry(id: service.id, url: service.url, dataStoreID: service.dataStoreIdentifier)
        }
        guard !entries.isEmpty else { return }

        Task { @MainActor [weak self] in
            for (index, entry) in entries.enumerated() {
                guard let self else { return }
                // Light stagger *between* polls so the sweep doesn't burst
                // alongside preload, favicon, and catalog-icon fetches at launch.
                // No trailing sleep after the final poll.
                if index > 0 { try? await Task.sleep(for: .milliseconds(250)) }
                await self.hibernatedBadgePoller.pollOnce(
                    serviceID: entry.id,
                    url: entry.url,
                    isMuted: false,
                    showBadge: true,
                    dataStoreIdentifier: entry.dataStoreID
                )
            }
        }
    }

    /// Preloads services when the user switches to a different space.
    func preloadServicesForSpace(_ spaceID: UUID) {
        let services = servicesForSpace(spaceID)
        Task {
            await webViewPool.preloadAll(services)
        }
    }

    private func fetchCatalogIcons() {
        let entries = ServiceCatalog.shared.entries
        Task.detached(priority: .utility) {
            await CatalogIconCache.shared.fetchAllIfNeeded(entries: entries)
        }
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
        // Start locked at launch when opted in; ContentView's lock overlay
        // prompts for Touch ID on appear.
        if appLockEnabled && lockOnLaunch {
            isLocked = true
        }

        let resolvedShowBadge = prefs?.showBadgeCountInDock ?? true
        let resolvedPresenceMode = prefs?.appPresenceMode ?? .dock
        Task { @MainActor in
            self.badgeManager.showBadgeCountInDock = resolvedShowBadge
            AppPresenceManager().apply(mode: resolvedPresenceMode)
            // Apply any active quiet-hours schedule now, then keep it current.
            self.refreshEffectiveDoNotDisturb()
            self.startQuietHoursTimer()
            self.setupLockObservers()
        }
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
            guard let self else { return }
            self.notificationManager.stopPolling(for: serviceID)

            let context = self.modelContainer.mainContext
            let descriptor = FetchDescriptor<ServiceInstance>()
            let services: [ServiceInstance]
            do {
                services = try context.fetch(descriptor)
            } catch {
                AppLogger.dataStore.error("Failed to fetch services for hibernation: \(error.localizedDescription)")
                return
            }
            guard let service = services.first(where: { $0.id == serviceID })
            else { return }

            self.hibernatedBadgePoller.track(
                serviceID: serviceID,
                url: service.url,
                isMuted: self.isServiceEffectivelyMuted(serviceID),
                showBadge: service.showBadge,
                dataStoreIdentifier: service.dataStoreIdentifier
            )
        }

        webViewPool.onServiceWoke = { [weak self] serviceID in
            self?.hibernatedBadgePoller.untrack(serviceID: serviceID)
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
            self.hibernatedBadgePoller.untrack(serviceID: serviceID)
            self.badgeManager.removeBadge(for: serviceID)
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
        MainActor.assumeIsolated {
            guard let entryID = fetchService(id: serviceID)?.catalogEntryID else { return nil }
            return ServiceCatalog.shared.entry(for: entryID)
        }
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
        // Drain any notification tap that arrived (e.g. launched the app)
        // before the handler was wired.
        if let pending = notificationManager.handlePendingNotification() {
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
        let inCurrentSpace = service.spaceLinks.contains { $0.space.id == selectedSpaceID }
        if !inCurrentSpace, let firstSpace = service.spaceLinks.first?.space.id {
            selectedSpaceID = firstSpace
        }
        selectedServiceID = serviceID
    }

    private func restoreWindowState() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<AppPreferences>()
        do {
            guard let prefs = try context.fetch(descriptor).first else { return }
            if let savedSpaceID = prefs.selectedSpaceID {
                selectedSpaceID = savedSpaceID
            }
            if let savedServiceID = prefs.selectedServiceID {
                selectedServiceID = savedServiceID
            }
        } catch {
            AppLogger.dataStore.error("Failed to restore window state: \(error.localizedDescription)")
        }
    }

    /// Fetches favicons for services that have none cached, and refreshes
    /// stale favicons (older than 7 days). Runs in a background Task to avoid
    /// blocking app launch.
    private func fetchMissingAndStaleFavicons() {
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
            // No custom icon AND (no cached favicon OR favicon is stale)
            guard service.customIconData == nil else { return false }
            if service.fetchedIconData == nil { return true }
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
                    service.faviconFetchedAt = Date()
                } else if entry.hadIcon {
                    service.faviconFetchedAt = Date()
                }
            }
            do {
                try context.save()
                AppLogger.favicon.info("Favicon refresh complete")
            } catch {
                AppLogger.dataStore.error("Failed to save refreshed favicons: \(error.localizedDescription)")
            }
        }
    }

    private func seedDefaultDataIfNeeded() {
        let context = modelContainer.mainContext

        let descriptor = FetchDescriptor<Space>()
        let existingSpaces: [Space]
        do {
            existingSpaces = try context.fetch(descriptor)
        } catch {
            AppLogger.dataStore.error("Failed to fetch spaces during seeding: \(error.localizedDescription)")
            return
        }

        guard existingSpaces.isEmpty else {
            selectedSpaceID = existingSpaces.first?.id
            return
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
                    }
                }
            } catch {
                AppLogger.dataStore.error("Failed to fetch services for favicon seeding: \(error.localizedDescription)")
            }
        } catch {
            AppLogger.dataStore.error("Failed to seed default data: \(error.localizedDescription)")
        }
    }
}
