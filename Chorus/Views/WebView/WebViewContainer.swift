import SwiftUI
import WebKit

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    /// Rounds the hosted page's corners. Editorial frames the web view as an
    /// inset card; the native look leaves it square at 0.
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> WebViewHostView {
        let host = WebViewHostView()
        host.setWebView(webView)
        host.cornerRadius = cornerRadius
        return host
    }

    func updateNSView(_ nsView: WebViewHostView, context: Context) {
        nsView.setWebView(webView)
        nsView.cornerRadius = cornerRadius
    }
}

final class WebViewHostView: NSView {
    private weak var currentWebView: WKWebView?

    /// A SwiftUI `.clipShape` does not reach a hosted `WKWebView` — the page
    /// renders in its own layer tree and spills straight past it. The rounding
    /// has to happen on this view's layer, which is why the radius is a property
    /// here rather than a modifier at the call site.
    ///
    /// The cost, noted in the UX audit: a page's fixed-position corner element
    /// gets clipped along with everything else. That is the price of the card.
    var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            wantsLayer = true
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = cornerRadius > 0
        }
    }

    func setWebView(_ webView: WKWebView) {
        guard webView !== currentWebView else { return }

        currentWebView?.removeFromSuperview()
        currentWebView = webView

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}
