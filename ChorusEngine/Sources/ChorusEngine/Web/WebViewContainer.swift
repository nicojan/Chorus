import SwiftUI
import WebKit

public struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    /// The rounding of the page's corners.
    var cornerRadius: CGFloat = 0

    public init(webView: WKWebView, cornerRadius: CGFloat = 0) {
        self.webView = webView
        self.cornerRadius = cornerRadius
    }

    public func makeNSView(context: Context) -> WebViewHostView {
        let host = WebViewHostView()
        host.cornerRadius = cornerRadius
        host.setWebView(webView)
        return host
    }

    public func updateNSView(_ nsView: WebViewHostView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.setWebView(webView)
    }
}

/// Holds the current service's web view, clipped to the content card's
/// rounded corners.
public final class WebViewHostView: NSView {
    private weak var currentWebView: WKWebView?

    /// The size the page area last had, for the pool to make new web views at.
    /// A web view made at zero size loads its page against a 0 by 0 window, and
    /// some pages keep what they measured then: Gmail can leave its top bar
    /// above the visible area until the window moves. The default stands in
    /// before the first layout, when the launch preload makes its views.
    static private(set) var lastSize = CGSize(width: 1024, height: 700)

    public override func layout() {
        super.layout()
        if bounds.width > 0, bounds.height > 0 {
            Self.lastSize = bounds.size
        }
    }

    /// The rounding of the page's corners, which the host clips to.
    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
