import SwiftUI
import WebKit

public struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    /// The rounding of the page's corners.
    var cornerRadius: CGFloat = 0
    /// Takes the pages this host stops showing. Nil removes them from the window.
    var parking: WebViewParking?

    public init(webView: WKWebView, cornerRadius: CGFloat = 0, parking: WebViewParking? = nil) {
        self.webView = webView
        self.cornerRadius = cornerRadius
        self.parking = parking
    }

    public func makeNSView(context: Context) -> WebViewHostView {
        let host = WebViewHostView()
        host.cornerRadius = cornerRadius
        host.parking = parking
        host.setWebView(webView)
        return host
    }

    public func updateNSView(_ nsView: WebViewHostView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.parking = parking
        nsView.setWebView(webView)
    }

    public static func dismantleNSView(_ nsView: WebViewHostView, coordinator: ()) {
        nsView.releaseWebView()
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
            parking?.setPageSize(bounds.size)
        }
    }

    private var miniaturizeObservers: [NSObjectProtocol] = []

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in miniaturizeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        miniaturizeObservers = []
        guard let window else { return }
        parking?.hostAppeared()
        // WebKit suspends a page in a minimized window after about four
        // minutes, so a kept page waits out the minimize in the parking lot.
        let center = NotificationCenter.default
        miniaturizeObservers = [
            center.addObserver(forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.parkForMinimize() }
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.returnFromMinimize() }
            },
        ]
    }

    /// Lends a kept page to the parking lot while the window is minimized.
    func parkForMinimize() {
        guard let current = currentWebView, current.superview === self,
              let parking, parking.isKept(current) else { return }
        parking.release(current)
    }

    /// Takes the page back after the window comes back.
    func returnFromMinimize() {
        guard let current = currentWebView, current.superview !== self else { return }
        setWebView(current)
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

    /// Takes the pages this host stops showing. See `WebViewParking`.
    weak var parking: WebViewParking?

    func setWebView(_ webView: WKWebView) {
        if window != nil { parking?.hostAppeared() }
        // The parking lot can take the page while this host is out of the
        // window, so the same page may need adding back.
        guard webView !== currentWebView || webView.superview !== self else { return }

        if let previous = currentWebView, previous !== webView {
            release(previous)
        }
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

    /// Gives up the page, as when SwiftUI removes this host.
    func releaseWebView() {
        if let current = currentWebView {
            release(current)
        }
        currentWebView = nil
    }

    private func release(_ webView: WKWebView) {
        guard webView.superview === self else { return }
        if let parking {
            parking.release(webView)
        } else {
            webView.removeFromSuperview()
        }
    }
}
