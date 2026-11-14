import WebKit
import XCTest
@testable import ChorusEngine

/// A page whose process has stopped answering, the state Drive was in when it
/// was removed on 2026-11-10 and the Add that followed waited for good.
@MainActor
final class StuckPageTests: XCTestCase {
    /// A page that writes to its store, so the network process holds it.
    /// `stall(_:)` makes it stop answering once it has loaded.
    private static let stuckHTML = """
    <html><body>x<script>localStorage.a = 1</script></body></html>
    """

    /// Waits until `webView` has finished loading its page at example.com. A fixed sleep was too short
    /// on a cold CI runner.
    private func waitForLoad(_ webView: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            // The blank page before the load is "complete" too.
            let script = "document.readyState === 'complete' && location.href === 'https://example.com/'"
            if (try? await PageScript.evaluate(script, in: webView) as? Bool) == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("the page never loaded")
    }

    /// Loads the stuck page and spins its main thread, so its process never
    /// replies to anything again.
    private func loadStuckPage(in webView: WKWebView) async throws {
        webView.loadHTMLString(Self.stuckHTML, baseURL: URL(string: "https://example.com/"))
        try await waitForLoad(webView)
        webView.evaluateJavaScript("setTimeout(() => { while (true) {} }, 0); 1", completionHandler: nil)
        try await Task.sleep(for: .milliseconds(500))
    }

    private func surface(store: UUID) -> WebSurface {
        WebSurface(
            id: UUID(), url: "", dataStore: .persistent(store), userAgent: nil, css: nil,
            darkThemed: false, keepsLoaded: false, staysActiveInBackground: false, label: "Stuck"
        )
    }

    private func makePool(_ manager: DataStoreManager) -> WebViewPool {
        WebViewPool(dataStoreManager: manager, userScriptManager: UserScriptManager(),
                    contentBlocker: ContentBlockerManager(isEnabled: false))
    }

    /// Tries to remove `store` for about ten seconds, as the app's removal
    /// pass does.
    private func removeStore(_ store: UUID) async throws -> Bool {
        for _ in 0..<10 {
            do { try await WKWebsiteDataStore.remove(forIdentifier: store); return true }
            catch { try await Task.sleep(for: .seconds(1)) }
        }
        return false
    }

    /// Removing a service whose page is stuck, while a badge read waits on
    /// that page, frees the web view and the store. The read used to hold the
    /// view until the page answered, which it never does, and the stuck
    /// process kept the store in use even once the view was gone.
    func testRemovingAStuckServiceFreesItsWebViewAndStore() async throws {
        let manager = DataStoreManager()
        let pool = makePool(manager)
        let store = UUID()
        let s = surface(store: store)
        pool.preload(s)
        weak var weakView = pool.liveWebView(for: s.id)
        try await loadStuckPage(in: XCTUnwrap(weakView))

        // A badge poll reads the page as it goes, the way the live poll does.
        let read = Task { @MainActor [weak pool] in
            guard let webView = pool?.liveWebView(for: s.id) else { return "no view" }
            do { _ = try await PageScript.evaluate("document.title", in: webView); return "answered" }
            catch { return "gave up" }
        }
        try await Task.sleep(for: .milliseconds(300))
        pool.removeWebView(for: s.id)
        manager.evict(identifier: store)

        let outcome = await withDeadline(seconds: 3, fallback: "still waiting") { await read.value }
        XCTAssertEqual(outcome, "gave up", "the read ends when its page is torn down")
        let removed = try await removeStore(store)
        XCTAssertNil(weakView, "nothing holds a removed service's web view")
        XCTAssertFalse(PageScript.hasPending)
        XCTAssertTrue(removed, "the removed service's store can be removed")
    }

    /// The same with nothing waiting on the page: the view goes by itself, but
    /// the stuck process alone kept the store in use.
    func testRemovingAStuckServiceWithNoReadFreesItsStore() async throws {
        let manager = DataStoreManager()
        let pool = makePool(manager)
        let store = UUID()
        let s = surface(store: store)
        pool.preload(s)
        try await loadStuckPage(in: XCTUnwrap(pool.liveWebView(for: s.id)))
        pool.removeWebView(for: s.id)
        manager.evict(identifier: store)
        let removed = try await removeStore(store)
        XCTAssertTrue(removed, "the removed service's store can be removed")
    }

    /// A working page answers the check at once, so its view goes straight
    /// away and its store comes free on the first try.
    func testRemovingAWorkingServiceFreesItAtOnce() async throws {
        let manager = DataStoreManager()
        let pool = makePool(manager)
        let store = UUID()
        let s = surface(store: store)
        pool.preload(s)
        weak var weakView = pool.liveWebView(for: s.id)
        try XCTUnwrap(weakView).loadHTMLString("<html><body>fine<script>localStorage.a = 1</script></body></html>", baseURL: URL(string: "https://example.com/"))
        try await waitForLoad(XCTUnwrap(weakView))
        pool.removeWebView(for: s.id)
        manager.evict(identifier: store)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(weakView)
        var removedFirstTime = false
        do { try await WKWebsiteDataStore.remove(forIdentifier: store); removedFirstTime = true } catch {}
        XCTAssertTrue(removedFirstTime)
    }

    /// Cancelling a read on a stuck page ends it, so a stopped poll lets go of
    /// its web view too.
    func testCancellingAReadOnAStuckPageEndsIt() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        try await loadStuckPage(in: webView)

        let read = Task { @MainActor in
            do { _ = try await PageScript.evaluate("document.title", in: webView); return "answered" }
            catch { return "gave up" }
        }
        try await Task.sleep(for: .milliseconds(300))
        read.cancel()
        let outcome = await withDeadline(seconds: 3, fallback: "still waiting") { await read.value }
        XCTAssertEqual(outcome, "gave up")
    }

    /// A page that answers still gets its result through.
    func testAReadOnAWorkingPageAnswers() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.loadHTMLString("<html><head><title>Inbox (3)</title></head><body>x</body></html>", baseURL: URL(string: "https://example.com/"))
        try await waitForLoad(webView)
        let title = try await PageScript.evaluate("document.title", in: webView) as? String
        XCTAssertEqual(title, "Inbox (3)")
    }

    /// Clearing a store waits on every process that uses it, and a stuck one
    /// never answers. The clear gives up after its limit instead of holding
    /// Add Service forever.
    func testClearingAStoreGivesUpOnAStuckPage() async throws {
        let manager = DataStoreManager()
        let store = UUID()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = manager.dataStore(forIdentifier: store)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        try await loadStuckPage(in: webView)

        let started = Date()
        let cleared = await withDeadline(seconds: 6, fallback: nil as Bool?) {
            await manager.clearAllData(identifier: store, within: 2)
        }
        XCTAssertEqual(cleared, false, "the clear reports that it gave up")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        _ = webView
    }

    /// A store nobody has stuck clears and says so.
    func testClearingAnUnusedStoreFinishes() async throws {
        let manager = DataStoreManager()
        let cleared = await manager.clearAllData(identifier: UUID(), within: 5)
        XCTAssertTrue(cleared)
    }
}
