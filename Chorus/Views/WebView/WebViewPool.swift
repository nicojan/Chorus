import Foundation
import WebKit

@Observable
final class WebViewPool {
    private var webViews: [UUID: WKWebView] = [:]
    private var lastAccessTimes: [UUID: Date] = [:]
    private var coordinators: [UUID: WebViewCoordinator] = [:]
    private let maxLoaded: Int = 15

    private let dataStoreManager: DataStoreManager
    private let processPoolManager: ProcessPoolManager
    private let userScriptManager: UserScriptManager

    init(
        dataStoreManager: DataStoreManager,
        processPoolManager: ProcessPoolManager,
        userScriptManager: UserScriptManager
    ) {
        self.dataStoreManager = dataStoreManager
        self.processPoolManager = processPoolManager
        self.userScriptManager = userScriptManager
    }

    func webView(for instance: ServiceInstance) -> WKWebView {
        if let existing = webViews[instance.id] {
            lastAccessTimes[instance.id] = Date()
            return existing
        }

        let config = makeConfiguration(for: instance)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = instance.userAgent

        let coordinator = WebViewCoordinator()
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinators[instance.id] = coordinator

        webViews[instance.id] = webView
        lastAccessTimes[instance.id] = Date()

        if let url = URL(string: instance.url) {
            webView.load(URLRequest(url: url))
        }

        evictIfNeeded()
        return webView
    }

    func removeWebView(for instanceID: UUID) {
        if let webView = webViews[instanceID] {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        webViews.removeValue(forKey: instanceID)
        lastAccessTimes.removeValue(forKey: instanceID)
        coordinators.removeValue(forKey: instanceID)
    }

    func hasWebView(for instanceID: UUID) -> Bool {
        webViews[instanceID] != nil
    }

    private func makeConfiguration(for instance: ServiceInstance) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStoreManager.dataStore(for: instance)

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let controller = WKUserContentController()
        userScriptManager.configureScripts(for: instance, on: controller)
        config.userContentController = controller

        return config
    }

    private func evictIfNeeded() {
        guard webViews.count > maxLoaded else { return }
        let sorted = lastAccessTimes.sorted { $0.value < $1.value }
        let toEvict = sorted.prefix(webViews.count - maxLoaded)
        for (id, _) in toEvict {
            if let webView = webViews[id] {
                webView.stopLoading()
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
            }
            webViews.removeValue(forKey: id)
            lastAccessTimes.removeValue(forKey: id)
            coordinators.removeValue(forKey: id)
        }
    }
}
