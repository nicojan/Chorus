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

    /// The currently active/displayed service
    private(set) var activeServiceID: UUID?

    /// Set of service IDs currently fully hibernated (web view destroyed)
    private(set) var hibernatedServiceIDs: Set<UUID> = []

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

    init(
        dataStoreManager: DataStoreManager,
        userScriptManager: UserScriptManager
    ) {
        self.dataStoreManager = dataStoreManager
        self.userScriptManager = userScriptManager
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

        let coordinator = WebViewCoordinator()
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinators[instance.id] = coordinator

        webViews[instance.id] = webView
        lastAccessTimes[instance.id] = Date()

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

        let coordinator = WebViewCoordinator()
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinators[instance.id] = coordinator

        webViews[instance.id] = webView
        lastAccessTimes[instance.id] = Date()

        if let url = URL(string: instance.url) {
            webView.load(URLRequest(url: url))
        }

        AppLogger.webView.debug("Preloaded service \(instance.label)")

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
        guard let webView = webViews[instanceID] else { return false }
        do {
            let result = try await webView.evaluateJavaScript(UserScriptManager.callDetectionQueryJS)
            return (result as? Bool) == true
        } catch {
            return false
        }
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
                self?.snapshots[id] = image
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

    private func teardownWebView(_ instanceID: UUID) {
        if let webView = webViews[instanceID] {
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        webViews.removeValue(forKey: instanceID)
        lastAccessTimes.removeValue(forKey: instanceID)
        coordinators.removeValue(forKey: instanceID)
        snapshots.removeValue(forKey: instanceID)
    }

    private func makeConfiguration(for instance: ServiceInstance) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStoreManager.dataStore(for: instance)
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Enable back-forward cache so swiping back loads instantly from cache
        config.preferences.isElementFullscreenEnabled = true

        let controller = WKUserContentController()
        userScriptManager.configureScripts(for: instance, on: controller)
        config.userContentController = controller

        return config
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

        var evicted = 0
        let needed = webViews.count - maxLoaded

        for (id, _) in sorted {
            guard evicted < needed else { break }
            guard webViews[id] != nil else { continue }

            evictionInFlight.insert(id)
            let hasCall = await hasActiveCall(for: id)
            evictionInFlight.remove(id)

            // Re-check the web view still exists (may have been removed during await)
            guard webViews[id] != nil else { continue }

            if hasCall {
                AppLogger.webView.info("Skipping eviction of \(id) — active call detected")
                continue
            }

            hibernate(id)
            evicted += 1
        }
    }
}
