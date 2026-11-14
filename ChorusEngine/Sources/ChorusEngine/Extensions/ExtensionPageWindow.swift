import AppKit
import WebKit

/// A window for one of an extension's own pages: its settings page, or a
/// welcome page it opens after it is added. Such a page loads only through the
/// configuration its extension context gives, so it cannot reuse
/// `InAppBrowserWindow`.
///
/// Same lifecycle rules as `InAppBrowserWindow`: a strong reference held in a
/// set, `isReleasedWhenClosed = false`, cleanup on `willClose`.
@MainActor
final class ExtensionPageWindow: NSObject, WKUIDelegate {
    private static var openWindows: Set<ExtensionPageWindow> = []

    private let window: NSWindow
    private let webView: WKWebView

    /// Opens `url`, or brings an open window showing it to the front.
    static func open(url: URL, configuration: WKWebViewConfiguration, title: String) {
        if let existing = openWindows.first(where: { $0.webView.url == url }) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        openWindows.insert(ExtensionPageWindow(url: url, configuration: configuration, title: title))
    }

    private init(url: URL, configuration: WKWebViewConfiguration, title: String) {
        let size = NSRect(x: 0, y: 0, width: 760, height: 620)
        webView = WKWebView(frame: size, configuration: configuration)
        window = NSWindow(
            contentRect: size,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        webView.uiDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.title = title
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        webView.load(URLRequest(url: url))
    }

    @objc private func windowWillClose(_ notification: Notification) {
        webView.uiDelegate = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        Task { @MainActor in Self.openWindows.remove(self) }
    }

    /// `window.close()` from the page, which settings pages use for a Done
    /// button.
    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }
}
