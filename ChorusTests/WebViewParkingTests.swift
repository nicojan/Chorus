import XCTest
import WebKit
@testable import ChorusEngine

/// WebKit suspends a web view that is out of a window or hidden, and a page
/// caught mid-write by that loses its IndexedDB transaction; WhatsApp Web then
/// wipes its databases and signs out. The parking lot keeps chat and Keep
/// Loaded pages in the window while they are off screen.
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

    private func makeLot(in window: NSWindow, parking: WebViewParking) -> WebViewParkingLotView {
        let lot = WebViewParkingLotView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(lot)
        parking.attach(lot)
        return lot
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: config)
    }

    // MARK: - Parking rules

    func testAKeptPageOutOfTheWindowIsParkedAtTheLotsSize() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        let lot = makeLot(in: window, parking: parking)
        let page = makeWebView()

        parking.keepAlive([page])

        XCTAssertTrue(parking.isParked(page))
        XCTAssertTrue(page.window === window)
        XCTAssertEqual(page.frame.size, lot.bounds.size)
    }

    func testAPageParkedBeforeTheLotExistsMovesInWhenItAttaches() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        let page = makeWebView()

        parking.keepAlive([page])
        XCTAssertNil(page.superview)

        _ = makeLot(in: window, parking: parking)
        XCTAssertTrue(parking.isParked(page))
    }

    func testAPageDroppedFromTheSetLeavesTheLot() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        _ = makeLot(in: window, parking: parking)
        let page = makeWebView()

        parking.keepAlive([page])
        parking.keepAlive([])

        XCTAssertNil(page.superview)
        XCTAssertFalse(parking.isKept(page))
    }

    func testAKeptPageShownInTheWindowIsNotTaken() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        _ = makeLot(in: window, parking: parking)
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
        _ = makeLot(in: window, parking: parking)
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

    func testTheLotTakesNoClicksAndShowsNothingToAccessibility() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        let lot = makeLot(in: window, parking: parking)
        parking.keepAlive([makeWebView()])

        XCTAssertNil(lot.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertEqual(lot.accessibilityChildren()?.count, 0)
        XCTAssertEqual(lot.alphaValue, 0)
    }

    // MARK: - The page host

    func testSwitchingAwayParksAKeptPageAndRemovesAnOrdinaryOne() {
        let window = makeWindow()
        defer { window.close() }
        let parking = WebViewParking()
        _ = makeLot(in: window, parking: parking)
        let host = WebViewHostView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(host)
        host.parking = parking
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
        _ = makeLot(in: window, parking: parking)
        let host = WebViewHostView(frame: window.contentView!.bounds)
        host.parking = parking
        let chat = makeWebView()
        parking.keepAlive([chat])

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
        _ = makeLot(in: window, parking: parking)
        let host = WebViewHostView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(host)
        host.parking = parking
        let chat = makeWebView()
        parking.keepAlive([chat])
        host.setWebView(chat)

        host.releaseWebView()

        XCTAssertTrue(parking.isParked(chat))
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

    /// The page in the lot keeps its timers running. Out of the window, the
    /// same page freezes on macOS 26 and later; that half is only printed,
    /// since older systems don't suspend it.
    func testAParkedPageKeepsRunning() async throws {
        let window = makeWindow()
        window.orderFront(nil)
        defer { window.close() }
        let parking = WebViewParking()
        _ = makeLot(in: window, parking: parking)
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
