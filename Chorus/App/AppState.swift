import SwiftUI
import SwiftData
import WebKit

@MainActor
@Observable
final class AppState {
    let modelContainer: ModelContainer
    let webViewPool: WebViewPool
    let dataStoreManager: DataStoreManager
    let userScriptManager: UserScriptManager
    let badgeManager: BadgeManager
    let notificationManager: NotificationManager
    let hibernatedBadgePoller: HibernatedBadgePoller

    var selectedSpaceID: UUID?
    var selectedServiceID: UUID?
    var showAddService = false
    var showQuickSwitcher = false
    var doNotDisturb = false

    /// Non-nil when the persistent store failed and we fell back to in-memory storage.
    /// The UI should display a warning banner when this is set.
    private(set) var storeError: String?

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
            self.storeError = "Your saved data couldn't be loaded. Chorus is running with temporary storage — changes won't be saved. Your data file is at: \(config.url.path)"
        }

        self.dataStoreManager = DataStoreManager()
        self.userScriptManager = UserScriptManager()
        self.badgeManager = BadgeManager()
        self.notificationManager = NotificationManager(badgeManager: badgeManager)
        self.hibernatedBadgePoller = HibernatedBadgePoller(badgeManager: badgeManager)
        self.webViewPool = WebViewPool(
            dataStoreManager: dataStoreManager,
            userScriptManager: userScriptManager
        )

        loadCookieBannerPreference()
        setupNotificationNavigation()
        setupHibernationCallbacks()
        setupMenuBarNavigation()
        seedDefaultDataIfNeeded()
        restoreWindowState()
        fetchMissingAndStaleFavicons()
        fetchCatalogIcons()
        preloadActiveSpaceServices()
        cleanUpOrphanedDataStores()
    }

    /// Deletes any per-service `WKWebsiteDataStore` whose identifier is no
    /// longer referenced by a `ServiceInstance`. Runs at launch and after
    /// a service is deleted so we don't leak cookies, IndexedDB, or cache
    /// for removed services.
    ///
    /// The work is dispatched off the main actor with a short delay so any
    /// in-flight `WKWebView` teardown from a just-deleted service completes
    /// before its data store is removed (WebKit traps if the store goes
    /// away while a live view still holds it).
    func cleanUpOrphanedDataStores() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<ServiceInstance>()
        let inUse: Set<UUID>
        do {
            inUse = Set(try context.fetch(descriptor).map(\.dataStoreIdentifier))
        } catch {
            AppLogger.dataStore.error("Failed to enumerate services for orphan cleanup: \(error.localizedDescription)")
            return
        }

        Task.detached(priority: .utility) {
            // Give SwiftUI a moment to drop any WKWebView that referenced
            // a just-deleted service's data store.
            try? await Task.sleep(for: .seconds(1))
            let allIdentifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
            for identifier in allIdentifiers where !inUse.contains(identifier) {
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                    AppLogger.dataStore.info("Removed orphaned data store \(identifier)")
                } catch {
                    AppLogger.dataStore.warning("Failed to remove orphaned data store \(identifier): \(error.localizedDescription)")
                }
            }
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

        let selected = selectedServiceID
        let ordered = services.sorted { a, _ in a.id == selected }

        Task {
            await webViewPool.preloadAll(ordered)
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

    private func loadCookieBannerPreference() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<AppPreferences>()
        do {
            let prefs = try context.fetch(descriptor).first
            userScriptManager.autoDismissCookieBanners = prefs?.autoDismissCookieBanners ?? true
        } catch {
            AppLogger.dataStore.error("Failed to load cookie banner preference: \(error.localizedDescription)")
            userScriptManager.autoDismissCookieBanners = true
        }
    }

    private func setupHibernationCallbacks() {
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
                isMuted: service.isMuted,
                showBadge: service.showBadge,
                dataStoreIdentifier: service.dataStoreIdentifier
            )
        }

        webViewPool.onServiceWoke = { [weak self] serviceID in
            self?.hibernatedBadgePoller.untrack(serviceID: serviceID)
        }

        webViewPool.onServiceSoftHibernated = { [weak self] serviceID in
            self?.notificationManager.stopPolling(for: serviceID)
        }

        webViewPool.onServiceSoftWoke = { _ in
            // Polling will restart when WebContentView attaches the web view
            // No action needed here — startPolling is called from the view layer
        }

        webViewPool.onServiceRemoved = { [weak self] serviceID in
            guard let self else { return }
            self.notificationManager.stopPolling(for: serviceID)
            self.hibernatedBadgePoller.untrack(serviceID: serviceID)
            self.badgeManager.removeBadge(for: serviceID)
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
            self?.selectedServiceID = serviceID
        }
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
