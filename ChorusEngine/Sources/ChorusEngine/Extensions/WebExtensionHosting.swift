import WebKit

/// What `WebViewPool` tells the extension host about its pages. A protocol
/// with no availability attached, so the pool can hold one on macOS 15.0
/// while the host itself needs 15.4.
@MainActor
public protocol WebExtensionHosting: AnyObject {
    /// Gives a new page's configuration the extension controller, when any
    /// extension is on. Must run before the web view is made: WebKit reads the
    /// controller only then.
    func attach(to configuration: WKWebViewConfiguration)
    /// A service's page or one of its tabs now exists. Extensions see it as a
    /// browser tab from here on.
    func pageOpened(_ webView: WKWebView, service: UUID)
    /// The page on screen now, or nil when none is (a Mac app is shown). The
    /// host reads it whenever an extension asks which tab is active, so a tab
    /// switch inside a service needs no event of its own.
    var displayedPage: (() -> WKWebView?)? { get set }
    /// The page on screen may have changed. Fires `tabs.onActivated`.
    func pageActivated(_ webView: WKWebView)
    /// A page is going away.
    func pageClosed(_ webView: WKWebView)
}
