import AppKit
import WebKit

/// A small in-app browser window for links that leave a service, used when the
/// user has turned on "open links in Chorus" for that service.
///
/// Deliberately separate from the OAuth popup path in `WebViewCoordinator`: that
/// one is single-slot, reloads its opener when it closes, and shares the
/// service's data store so a sign-in lands its cookies. None of that fits a
/// plain external link, which wants its own window and no session tie to the
/// service. Each opened link gets its own window.
///
/// The lifecycle mirrors the OAuth popup's hard-won rules: hold the window in a
/// strong reference and set `isReleasedWhenClosed = false` so AppKit doesn't
/// also release it (an over-release crash), clean up on `willClose` even when
/// the OS close button is used, and mirror the page `<title>` from the KVO
/// change value rather than reaching back into the web view off the main actor.
@MainActor
final class InAppBrowserWindow: NSObject, WKNavigationDelegate, WKUIDelegate {

    /// Strong references to the open windows. Removing an entry on close drops the
    /// last reference and deallocates the window and its web view; while it sits
    /// here the window stays alive without a controller to own it.
    private static var openWindows: Set<InAppBrowserWindow> = []

    private let window: NSWindow
    private let webView: WKWebView
    private var titleObservation: NSKeyValueObservation?

    /// Opens `url` in a new in-app browser window. Callers gate the scheme (see
    /// `WebViewCoordinator.shouldOpenInAppBrowser`); only http/https should reach
    /// here.
    static func open(_ url: URL) {
        openWindows.insert(InAppBrowserWindow(url: url))
    }

    private init(url: URL) {
        // A default configuration, so external browsing uses the app's default
        // store and stays out of the services' per-service sessions.
        let size = NSRect(x: 0, y: 0, width: 1100, height: 800)
        webView = WKWebView(frame: size, configuration: WKWebViewConfiguration())
        window = NSWindow(
            contentRect: size,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self

        // We keep the window alive via `openWindows` and close it ourselves, so
        // stop AppKit from also releasing it on close.
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.title = url.host ?? "Chorus"
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Read the new title from the (Sendable) KVO change value; touching the
        // main-actor WKWebView from this nonisolated closure would be a data race
        // under Swift 6. An empty title leaves the bar on its current text.
        titleObservation = webView.observe(\.title, options: [.new]) { [weak window] _, change in
            guard let newTitle = change.newValue ?? nil, !newTitle.isEmpty else { return }
            Task { @MainActor in window?.title = newTitle }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        webView.load(URLRequest(url: url))
    }

    deinit {
        // Thread-safe; a backstop if the window is torn down without willClose.
        titleObservation?.invalidate()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        titleObservation?.invalidate()
        titleObservation = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: window)
        // Drop the last strong reference. Do it on the next tick so we're not
        // mutating the set from inside the window's own close notification.
        Task { @MainActor in Self.openWindows.remove(self) }
    }

    // MARK: - Navigation

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else { return .cancel }
        // Web content loads in this window; a non-web scheme (mailto:, tel:, …)
        // goes to the system handler, gated by the same vetted-scheme rule the
        // main views use. Anything else is dropped.
        if scheme == "http" || scheme == "https" { return .allow }
        WebViewCoordinator.openExternally(url)
        return .cancel
    }

    /// `window.open` inside the in-app browser loads in the same window rather
    /// than spawning more.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
