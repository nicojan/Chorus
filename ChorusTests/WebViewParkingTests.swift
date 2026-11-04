import XCTest
import WebKit
@testable import ChorusEngine

/// WebKit suspends a web view that is out of a window, hidden, in a covered
/// window or in a minimized one, and a page caught mid-write by that loses its
/// IndexedDB transaction; WhatsApp Web then wipes its databases and signs out.
/// The parking lot keeps chat and Keep Loaded pages running.
@MainActor
final class WebViewParkingTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: config)
    }

    private func occlusionDetection(of webView: WKWebView) -> Bool? {
        guard webView.responds(to: NSSelectorFromString("_windowOcclusionDetectionEnabled")) else { return nil }
        return (webView.value(forKey: "_windowOcclusionDetectionEnabled") as? NSNumber)?.boolValue
    }

    private func makeHost(in window: NSWindow, parking: WebViewParking) -> WebViewHostView {
        let host = WebViewHostView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(host)
        host.parking = parking
        return host
    }

    // MARK: - The lot window

    func testAKeptPageOutOfEveryWindowGoesToTheLot() throws {
        let parking = WebViewParking()
        let page = makeWebView()

        parking.keepAlive([page])

        XCTAssertTrue(parking.isParked(page))
        let lot = try XCTUnwrap(parking.lotWindowForTesting)
        XCTAssertTrue(page.window === lot)
        XCTAssertEqual(page.frame.size, lot.contentView?.bounds.size)
    }

    func testTheLotWindowIsInvisibleOffScreenAndStaysWhenTheAppHides() throws {
        let parking = WebViewParking()
        parking.keepAlive([makeWebView()])
        let lot = try XCTUnwrap(parking.lotWindowForTesting)

        XCTAssertTrue(lot.isVisible)
        XCTAssertEqual(lot.alphaValue, 0)
        XCTAssertFalse(lot.canHide)
        XCTAssertTrue(lot.ignoresMouseEvents)
        XCTAssertTrue(lot.isExcludedFromWindowsMenu)
        XCTAssertFalse(lot.canBecomeKey)
        XCTAssertFalse(lot.styleMask.contains(.titled))
        for screen in NSScreen.screens {
            XCTAssertFalse(screen.frame.intersects(lot.frame), "lot window is on a screen")
        }
        XCTAssertNil(lot.contentView?.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertEqual(lot.contentView?.accessibilityChildren()?.count, 0)
    }

    func testParkedPagesLayOutAtThePageAreasSize() throws {
        let parking = WebViewParking()
        let page = makeWebView()
        parking.keepAlive([page])

        parking.setPageSize(CGSize(width: 900, height: 640))

        XCTAssertEqual(page.frame.size, CGSize(width: 900, height: 640))
    }

    func testNoPageNoLotWindow() {
        let parking = WebViewParking()
        parking.keepAlive([])
        XCTAssertNil(parking.lotWindowForTesting)
    }

    // MARK: - Keeping and dropping

    func testAKeptPageIgnoresOcclusionAndGetsItBackWhenDropped() throws {
        let parking = WebViewParking()
        let page = makeWebView()
        try XCTSkipIf(occlusionDetection(of: page) == nil, "WebKit has no occlusion switch")
        XCTAssertEqual(occlusionDetection(of: page), true)

        parking.keepAlive([page])
        XCTAssertEqual(occlusionDetection(of: page), false)

        parking.keepAlive([])
        XCTAssertEqual(occlusionDetection(of: page), true)
        XCTAssertNil(page.superview)
        XCTAssertFalse(parking.isKept(page))
    }

    func testAKeptPageShownInAWindowIsNotTaken() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        let shown = makeWebView()
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(host)
        host.addSubview(shown)

        parking.keepAlive([shown])

        XCTAssertTrue(shown.superview === host)
    }

    func testReleaseParksAKeptPageAndRemovesAnyOther() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        let kept = makeWebView()
        let other = makeWebView()
        let host = NSView()
        window.contentView!.addSubview(host)
        host.addSubview(kept)
        host.addSubview(other)
        parking.keepAlive([kept])

        parking.release(kept)
        parking.release(other)

        XCTAssertTrue(parking.isParked(kept))
        XCTAssertNil(other.superview)
    }

    // MARK: - The page host

    func testSwitchingAwayParksAKeptPageAndRemovesAnOrdinaryOne() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        let host = makeHost(in: window, parking: parking)
        let chat = makeWebView()
        let ordinary = makeWebView()
        let third = makeWebView()
        parking.keepAlive([chat])

        host.setWebView(chat)
        XCTAssertTrue(chat.superview === host)
        host.setWebView(ordinary)
        XCTAssertTrue(parking.isParked(chat))
        host.setWebView(third)
        XCTAssertNil(ordinary.superview)
        host.setWebView(chat)
        XCTAssertTrue(chat.superview === host)
    }

    func testAHostTakesBackAPageTheLotParkedWhileItWasAway() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        let host = WebViewHostView(frame: window.contentView!.bounds)
        host.parking = parking
        let chat = makeWebView()

        // The host shows the page while out of the window, so the lot takes it.
        host.setWebView(chat)
        parking.keepAlive([chat])
        XCTAssertTrue(parking.isParked(chat))

        window.contentView!.addSubview(host)
        host.setWebView(chat)
        XCTAssertTrue(chat.superview === host)
    }

    func testARemovedHostHandsItsPageToTheLot() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        let host = makeHost(in: window, parking: parking)
        let chat = makeWebView()
        parking.keepAlive([chat])
        host.setWebView(chat)

        host.releaseWebView()

        XCTAssertTrue(parking.isParked(chat))
    }

    func testAKeptPageWaitsOutAMinimizeInTheLot() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        let host = makeHost(in: window, parking: parking)
        let chat = makeWebView()
        parking.keepAlive([chat])
        host.setWebView(chat)

        host.parkForMinimize()
        XCTAssertTrue(parking.isParked(chat))

        host.returnFromMinimize()
        XCTAssertTrue(chat.superview === host)
    }

    func testAnOrdinaryPageStaysPutThroughAMinimize() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        let host = makeHost(in: window, parking: parking)
        let page = makeWebView()
        host.setWebView(page)

        host.parkForMinimize()
        XCTAssertTrue(page.superview === host)
    }

    // MARK: - The pool

    func testThePoolKeepsChatAndKeepLoadedPagesAndNotOthers() throws {
        let pool = WebViewPool(
            dataStoreManager: DataStoreManager(),
            userScriptManager: UserScriptManager(),
            contentBlocker: ContentBlockerManager(isEnabled: false)
        )
        func surface(keepsLoaded: Bool) -> WebSurface {
            WebSurface(
                id: UUID(), url: "", dataStore: .persistent(UUID()), userAgent: nil, css: nil,
                darkThemed: false, keepsLoaded: keepsLoaded, staysActiveInBackground: false, label: "Test"
            )
        }
        let chat = surface(keepsLoaded: false)
        let kept = surface(keepsLoaded: true)
        let plain = surface(keepsLoaded: false)
        pool.isNotificationCritical = { $0 == chat.id }
        for surface in [chat, kept, plain] {
            pool.preload(surface)
        }
        defer { [chat, kept, plain].forEach { pool.removeWebView(for: $0.id) } }

        let chatView = try XCTUnwrap(pool.liveWebView(for: chat.id))
        let keptView = try XCTUnwrap(pool.liveWebView(for: kept.id))
        let plainView = try XCTUnwrap(pool.liveWebView(for: plain.id))
        XCTAssertTrue(pool.parking.isKept(chatView))
        XCTAssertTrue(pool.parking.isKept(keptView))
        XCTAssertFalse(pool.parking.isKept(plainView))

        pool.setNeverHibernate(false, for: kept.id)
        XCTAssertFalse(pool.parking.isKept(keptView))

        pool.hibernate(chat.id)
        XCTAssertFalse(pool.parking.isKept(chatView))
    }

    // MARK: - Live

    /// A page in the lot keeps its timers running. Out of every window, the
    /// same page freezes on macOS 26 and later; that half is only printed,
    /// since older systems don't suspend it.
    func testAParkedPageKeepsRunning() async throws {
        let parking = WebViewParking()
        let page = """
        <html><body><script>
        window.maxGap = 0; let last = Date.now();
        setInterval(() => { const n = Date.now(); window.maxGap = Math.max(window.maxGap, n - last); last = n; }, 100);
        </script></body></html>
        """
        let parked = makeWebView()
        let loose = makeWebView()
        for view in [parked, loose] {
            view.loadHTMLString(page, baseURL: URL(string: "https://example.com/"))
        }
        parking.keepAlive([parked])
        try await Task.sleep(for: .seconds(3))
        for view in [parked, loose] { _ = try? await view.evaluateJavaScript("window.maxGap = 0") }

        try await Task.sleep(for: .seconds(15))

        let parkedResult = try await parked.evaluateJavaScript("window.maxGap")
        let parkedGap = try XCTUnwrap((parkedResult as? NSNumber)?.doubleValue)
        let looseGap = try? await loose.evaluateJavaScript("window.maxGap")
        print("Parking: parked page's longest gap \(parkedGap) ms, loose page's \(looseGap ?? "nil") ms")
        XCTAssertLessThan(parkedGap, 5_000)
    }
}
