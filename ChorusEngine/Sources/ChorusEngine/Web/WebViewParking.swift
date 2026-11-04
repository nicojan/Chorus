import AppKit
import WebKit

/// Keeps chosen pages running while they are off screen, so WebKit does not
/// suspend them.
///
/// WebKit suspends the process behind a web view that is out of a window or
/// `isHidden` within seconds, behind one in a window covered by other windows
/// after about five minutes, and behind one in a minimized window after about
/// four. It wakes the process only for a moment when the app runs JavaScript
/// in it, then suspends it again. A page caught mid-write by that cycle loses
/// its IndexedDB transaction, and WhatsApp Web answers a lost transaction by
/// wiping its databases, which signs the user out. Measured on macOS 27,
/// 2026-11-03.
///
/// Two things keep a page running: it sits in a window that is always ordered
/// in, and its web view ignores window occlusion. The parking lot is such a
/// window, off screen and invisible. A kept page goes there whenever no host
/// shows it; the page on screen keeps running because occlusion is off, and
/// its host hands it to the lot while the main window is minimized.
///
/// The pool says which pages to keep (`keepAlive`), and the page host hands a
/// page back when it stops showing it (`release`).
@MainActor
public final class WebViewParking {
    private struct WeakView {
        weak var view: WKWebView?
    }

    /// WebKit's switch for treating a covered window as hidden. SPI, so it is
    /// probed; a WebKit without it leaves the setting as it is.
    private static let occlusionSetter = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
    private static let occlusionKey = "windowOcclusionDetectionEnabled"

    /// Where the lot window sits: far off every screen.
    static let lotOrigin = NSPoint(x: -30_000, y: -30_000)

    private var kept: [ObjectIdentifier: WeakView] = [:]
    private var lotWindow: NSWindow?
    private var lotView: WebViewParkingLotView?
    private var pageSize = CGSize(width: 1024, height: 700)

    public init() {}

    /// The view parked pages sit in. Made on first use.
    var lot: WebViewParkingLotView {
        if let lotView { return lotView }
        let view = WebViewParkingLotView(frame: NSRect(origin: .zero, size: pageSize))
        lotWindow = Self.makeLotWindow(holding: view)
        lotView = view
        return view
    }

    /// Sets the pages to keep running. A page that drops out of the set leaves
    /// the lot and gets occlusion back; a page that joins it ignores occlusion
    /// from now on and moves into the lot unless a window shows it.
    public func keepAlive(_ webViews: [WKWebView]) {
        let next = Dictionary(
            webViews.map { (ObjectIdentifier($0), WeakView(view: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        for (id, entry) in kept where next[id] == nil {
            guard let view = entry.view else { continue }
            Self.setOcclusionDetection(true, on: view)
            if let lotView, view.superview === lotView {
                view.removeFromSuperview()
            }
        }
        for entry in next.values {
            if let view = entry.view { Self.setOcclusionDetection(false, on: view) }
        }
        kept = next
        parkLooseViews()
    }

    /// Takes back a page its host stopped showing: a kept page goes into the
    /// lot, any other leaves the window.
    public func release(_ webView: WKWebView) {
        if isKept(webView) {
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
        guard let lotView else { return false }
        return webView.superview === lotView
    }

    /// The size parked pages lay out at: the page area's, so a page does not
    /// relayout when it comes back on screen.
    func setPageSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != pageSize else { return }
        pageSize = size
        lotWindow?.setContentSize(size)
    }

    /// The lot window, for tests.
    var lotWindowForTesting: NSWindow? { lotWindow }

    /// Moves each kept page that is out of every window into the lot. A page a
    /// host shows in a window stays where it is.
    private func parkLooseViews() {
        let loose = kept.values.compactMap(\.view).filter { $0.window == nil }
        guard !loose.isEmpty else { return }
        let lotView = lot
        for view in loose {
            lotView.park(view)
        }
    }

    private static func setOcclusionDetection(_ enabled: Bool, on webView: WKWebView) {
        guard webView.responds(to: occlusionSetter) else { return }
        webView.setValue(enabled, forKey: occlusionKey)
    }

    /// A borderless window off every screen, invisible, that takes no clicks,
    /// cannot be hidden with the app, and stays out of the Window menu, ⌘`
    /// and Mission Control. It is ordered in for good so WebKit counts the
    /// pages in it as in a window.
    private static func makeLotWindow(holding view: WebViewParkingLotView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: lotOrigin, size: view.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.canHide = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
        window.hasShadow = false
        window.contentView = view
        window.orderFrontRegardless()
        // AppKit may move a new window onto a screen; put it back.
        window.setFrameOrigin(lotOrigin)
        return window
    }
}

/// The view that holds parked pages, as the lot window's content. Each page
/// fills it, takes no clicks, and shows nothing to accessibility.
public final class WebViewParkingLotView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
