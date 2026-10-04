import SwiftData
import WebKit

/// Construction only. Persistence recovery, observers and preloading belong to
/// the production launch path, not to these shared dependencies.
@MainActor
struct AppDependencies {
    let dataStoreManager: DataStoreManager
    let userScriptManager: UserScriptManager
    let badgeManager: BadgeManager
    let notificationManager: NotificationManager
    let transientBadgeFetcher: TransientBadgeFetcher
    let contentBlocker: ContentBlockerManager
    let webViewPool: WebViewPool
    let networkMonitor: NetworkMonitor

    init(
        modelContainer: ModelContainer,
        dataStoreManager: DataStoreManager,
        loadMailComposer: @escaping (WKWebView, URL) -> Void = { view, url in view.load(URLRequest(url: url)) }
    ) {
        self.dataStoreManager = dataStoreManager
        let scripts = UserScriptManager()
        let badges = BadgeManager()
        userScriptManager = scripts
        badgeManager = badges
        scripts.isServiceMuted = { @Sendable serviceID in
            MainActor.assumeIsolated {
                var descriptor = FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == serviceID })
                descriptor.fetchLimit = 1
                return (try? modelContainer.mainContext.fetch(descriptor).first)?.isEffectivelyMuted ?? false
            }
        }
        scripts.isServiceNotifyingOS = { @Sendable serviceID in
            MainActor.assumeIsolated {
                var descriptor = FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == serviceID })
                descriptor.fetchLimit = 1
                return (try? modelContainer.mainContext.fetch(descriptor).first)?.notifiesOSEffective ?? false
            }
        }
        scripts.isDoNotDisturbActive = { @Sendable in
            MainActor.assumeIsolated { badges.doNotDisturb }
        }
        notificationManager = NotificationManager(badgeManager: badges)
        transientBadgeFetcher = TransientBadgeFetcher(badgeManager: badges, dataStoreManager: dataStoreManager)
        let blocker = ContentBlockerManager()
        contentBlocker = blocker
        webViewPool = WebViewPool(
            dataStoreManager: dataStoreManager, userScriptManager: scripts,
            contentBlocker: blocker, loadMailComposer: loadMailComposer
        )
        networkMonitor = NetworkMonitor()
    }
}
