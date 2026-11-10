import AppKit
import WebKit

/// Errors the tab and window adapters hand back to an extension.
enum WebExtensionAdapterError: LocalizedError {
    case unsupported(String)
    case pageGone

    var errorDescription: String? {
        switch self {
        case .unsupported(let what): return "Chorus does not support \(what)."
        case .pageGone: return "The page is no longer open."
        }
    }
}

/// A service page, or a tab inside a service, as an extension sees it: one
/// browser tab. Chorus's services all count as tabs of one window.
@available(macOS 15.4, *)
@MainActor
final class WebExtensionTab: NSObject, WKWebExtensionTab {
    weak var webView: WKWebView?
    let serviceID: UUID
    weak var host: WebExtensionHost?
    private var observations: [NSKeyValueObservation] = []

    init(webView: WKWebView, serviceID: UUID, host: WebExtensionHost) {
        self.webView = webView
        self.serviceID = serviceID
        self.host = host
        super.init()
    }

    /// Reports address, title and loading changes, which extensions read
    /// through `tabs.onUpdated`.
    func startObserving(onChange: @escaping @MainActor (WebExtensionTab, WKWebExtension.TabChangedProperties) -> Void) {
        guard let webView else { return }
        func watch<Value>(_ keyPath: KeyPath<WKWebView, Value>, _ property: WKWebExtension.TabChangedProperties) -> NSKeyValueObservation {
            webView.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    onChange(self, property)
                }
            }
        }
        observations = [
            watch(\.url, .URL),
            watch(\.title, .title),
            watch(\.isLoading, .loading),
        ]
    }

    func stopObserving() {
        observations.forEach { $0.invalidate() }
        observations = []
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { host?.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { host?.index(of: self) ?? 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { webView?.title }
    func url(for context: WKWebExtensionContext) -> URL? { webView?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(webView?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { host?.activeTab === self }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webView?.pageZoom ?? 1) }
    func size(for context: WKWebExtensionContext) -> CGSize { webView?.bounds.size ?? .zero }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView else { return completionHandler(WebExtensionAdapterError.pageGone) }
        webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let webView else { return completionHandler(WebExtensionAdapterError.pageGone) }
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        webView?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        host?.onActivateService?(serviceID)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(WebExtensionAdapterError.unsupported("closing a service from an extension"))
    }
}

/// Chorus's main window as an extension sees it: the one window, holding every
/// service page as a tab.
@available(macOS 15.4, *)
@MainActor
final class WebExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var host: WebExtensionHost?

    init(host: WebExtensionHost) {
        self.host = host
        super.init()
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { host?.orderedTabs ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { host?.activeTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        mainWindow?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        (mainWindow?.screen ?? NSScreen.main)?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(WebExtensionAdapterError.unsupported("closing the Chorus window from an extension"))
    }

    /// The window holding the service pages: the one the active page is in.
    private var mainWindow: NSWindow? {
        host?.activeTab?.webView?.window ?? NSApp.mainWindow
    }
}
