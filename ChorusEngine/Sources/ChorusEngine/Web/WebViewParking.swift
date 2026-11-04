import AppKit
import SwiftUI
import WebKit

/// Keeps chosen pages inside the main window while they are off screen, so
/// WebKit does not suspend them.
///
/// WebKit suspends the process behind a web view that is out of a window or
/// `isHidden`. It wakes the process only for a moment when the app runs
/// JavaScript in it, then suspends it again. A page caught mid-write by that
/// cycle loses its IndexedDB transaction, and WhatsApp Web answers a lost
/// transaction by wiping its databases, which signs the user out. A web view
/// that stays in the window, under a view with alpha 0, keeps running, even
/// while the window is minimized or ordered out.
///
/// The pool says which pages to keep (`keepAlive`), the page host hands a page
/// back when it stops showing it (`release`), and the parking lot view, which
/// sits behind the page area, holds the kept pages it is not showing.
@MainActor
public final class WebViewParking {
    private struct WeakView {
        weak var view: WKWebView?
    }

    private weak var lot: WebViewParkingLotView?
    private var kept: [ObjectIdentifier: WeakView] = [:]

    public init() {}

    /// Sets the pages to keep running. A page that drops out of the set leaves
    /// the lot; a page that joins it moves into the lot unless something else
    /// in a window is showing it.
    public func keepAlive(_ webViews: [WKWebView]) {
        let next = Dictionary(
            webViews.map { (ObjectIdentifier($0), WeakView(view: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        for (id, entry) in kept where next[id] == nil {
            if let view = entry.view, view.superview === lot {
                view.removeFromSuperview()
            }
        }
        kept = next
        parkLooseViews()
    }

    /// Takes back a page its host stopped showing: a kept page goes into the
    /// lot, any other leaves the window.
    public func release(_ webView: WKWebView) {
        if isKept(webView), let lot {
            lot.park(webView)
        } else {
            webView.removeFromSuperview()
        }
    }

    /// Whether the page is in the set to keep running.
    public func isKept(_ webView: WKWebView) -> Bool {
        kept[ObjectIdentifier(webView)]?.view === webView
    }

    /// Whether the page sits in the lot now.
    public func isParked(_ webView: WKWebView) -> Bool {
        lot != nil && webView.superview === lot
    }

    func attach(_ lot: WebViewParkingLotView) {
        self.lot = lot
        parkLooseViews()
    }

    /// Moves each kept page that is out of every window into the lot. A page a
    /// host shows in a window stays where it is.
    private func parkLooseViews() {
        guard let lot else { return }
        for entry in kept.values {
            guard let view = entry.view, view.window == nil, view.superview !== lot else { continue }
            lot.park(view)
        }
    }
}

/// The view that holds parked pages. It fills the page area so a parked page
/// lays out at its real size, draws nothing (alpha 0), takes no clicks, and
/// shows nothing to accessibility.
public final class WebViewParkingLotView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func park(_ webView: WKWebView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func accessibilityChildren() -> [Any]? { [] }
}

/// Places the parking lot in a SwiftUI layout, behind the page area.
public struct WebViewParkingLot: NSViewRepresentable {
    let parking: WebViewParking

    public init(parking: WebViewParking) {
        self.parking = parking
    }

    public func makeNSView(context: Context) -> WebViewParkingLotView {
        let lot = WebViewParkingLotView()
        parking.attach(lot)
        return lot
    }

    public func updateNSView(_ nsView: WebViewParkingLotView, context: Context) {
        parking.attach(nsView)
    }
}
