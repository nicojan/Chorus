import SwiftUI
import WebKit

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WebViewHostView {
        let host = WebViewHostView()
        host.setWebView(webView)
        return host
    }

    func updateNSView(_ nsView: WebViewHostView, context: Context) {
        nsView.setWebView(webView)
    }
}

/// Holds the current service's web view, clipped to the content card's
/// rounded corners.
final class WebViewHostView: NSView {
    private weak var currentWebView: WKWebView?
    private var pendingDetachments: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// The size the page area last had, for the pool to make new web views at.
    /// A web view made at zero size loads its page against a 0 by 0 window, and
    /// some pages keep what they measured then: Gmail can leave its top bar
    /// above the visible area until the window moves. The default stands in
    /// before the first layout, when the launch preload makes its views.
    static private(set) var lastSize = CGSize(width: 1024, height: 700)

    override func layout() {
        super.layout()
        if bounds.width > 0, bounds.height > 0 {
            Self.lastSize = bounds.size
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ChorusCard.webCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setWebView(_ webView: WKWebView) {
        guard webView !== currentWebView || webView.superview !== self else { return }

        // A quick return (even through a different host) cancels the old
        // removal. Its pending task must not detach the now-active view.
        if let previousHost = webView.superview as? WebViewHostView {
            previousHost.cancelDetachment(of: webView)
        }
        let outgoing = currentWebView
        let focused = window?.firstResponder as? NSView
        let transfersFocus = outgoing.map { focused === $0 || focused?.isDescendant(of: $0) == true } ?? false
        currentWebView = webView

        let alreadyAttached = webView.superview === self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setAccessibilityHidden(false)
        addSubview(webView)
        if !alreadyAttached {
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: topAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        // Retaining the old view must not leave keyboard input routed to it.
        // Do not steal focus when the user is navigating the rail instead.
        if transfersFocus { window?.makeFirstResponder(webView) }

        if let outgoing, outgoing !== webView {
            outgoing.setAccessibilityHidden(true)
            let id = ObjectIdentifier(outgoing)
            // Show the new page at once. Keep the old one attached underneath
            // until its native exit and any resulting page work can run.
            pendingDetachments[id] = Task { @MainActor [weak self] in
                await WebViewDeparture.prepareForDestruction(in: [outgoing])
                guard !Task.isCancelled, let self else { return }
                defer { self.pendingDetachments.removeValue(forKey: id) }
                guard outgoing !== self.currentWebView,
                      outgoing.superview === self else { return }
                outgoing.removeFromSuperview()
            }
        }
    }

    private func cancelDetachment(of webView: WKWebView) {
        pendingDetachments.removeValue(forKey: ObjectIdentifier(webView))?.cancel()
    }
}
