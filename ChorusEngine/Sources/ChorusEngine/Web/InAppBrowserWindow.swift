import AppKit
import WebKit

/// A small in-app browser window for links that leave a service, used when the
/// user has turned on "open links in Chorus" for that service.
///
/// Deliberately separate from the OAuth popup path in `WebViewCoordinator`: that
/// one is a `PopupChain`, reloads its opener when it closes, and shares the
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
public final class InAppBrowserWindow: NSObject, WKNavigationDelegate, WKUIDelegate {

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
    public static func open(_ url: URL) {
        openWindows.insert(InAppBrowserWindow(url: url))
    }

    private init(url: URL) {
        // An ephemeral (non-persistent) store per window: external browsing stays
        // out of the services' per-service sessions AND leaves nothing on disk, so
        // each throwaway link window starts clean and two of them can't be
        // correlated through a shared cookie jar.
        let size = NSRect(x: 0, y: 0, width: 1100, height: 800)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: size, configuration: config)
        // WebKit's default agent makes Google and others call the browser
        // unsupported. The service web views and their popups carry Safari's.
        webView.customUserAgent = UserAgentProvider.safariDefault
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

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else { return .cancel }
        // Web content loads in this window, and so do the page's own internal
        // documents: editors, payment forms and sign-ins build frames from
        // `about:blank`, `about:srcdoc`, `blob:`, and `data:` inside a frame
        // (never as the whole page, a known phishing trick). A non-web scheme (mailto:,
        // tel:, …) goes to the system handler, gated by the same vetted-scheme
        // rule the main views use, and only on a click: a page that sets
        // `location` to `facetime-audio:` in a loop must not raise a call
        // prompt each time. Anything else is dropped.
        if scheme == "about" || scheme == "blob" { return .allow }
        if scheme == "data" {
            return navigationAction.targetFrame?.isMainFrame == false ? .allow : .cancel
        }
        if scheme == "http" || scheme == "https" {
            // An `<a download>` click: hand the file to the browser, below.
            if navigationAction.shouldPerformDownload {
                WebViewCoordinator.openExternally(url)
                return .cancel
            }
            return .allow
        }
        if navigationAction.navigationType == .linkActivated {
            WebViewCoordinator.openExternally(url)
        }
        return .cancel
    }

    /// A file this window can't show goes to the user's browser to download.
    /// This window has no download handling of its own, so without this a
    /// click on a zip did nothing at all. The browser fetches it again with its
    /// own session; the throwaway one here has nothing worth keeping.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        let isFile = WebViewCoordinator.isAttachment(navigationResponse.response)
            || !navigationResponse.canShowMIMEType
        guard navigationResponse.isForMainFrame, isFile else { return .allow }
        if let url = navigationResponse.response.url {
            WebViewCoordinator.openExternally(url)
        }
        return .cancel
    }

    /// `window.open` inside the in-app browser loads in the same window rather
    /// than spawning more.
    public func webView(
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
