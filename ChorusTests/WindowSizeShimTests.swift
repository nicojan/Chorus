import XCTest
import WebKit
@testable import ChorusEngine

/// A `WKWebView` reports `window.outerWidth` and `outerHeight` as 0, since
/// WebKit asks the app for the window frame and only Safari answers. Google
/// Sheets and Docs read those numbers to guess the browser zoom, and with 0
/// they draw the document at a fraction of the screen's pixels (issue #43).
@MainActor
final class WindowSizeShimTests: XCTestCase {

    private func makePool() -> WebViewPool {
        WebViewPool(
            dataStoreManager: DataStoreManager(),
            userScriptManager: UserScriptManager(),
            contentBlocker: ContentBlockerManager(isEnabled: false)
        )
    }

    private func surface(url: String) -> WebSurface {
        WebSurface(
            id: UUID(), url: url, dataStore: .persistent(UUID()), userAgent: nil, css: nil,
            darkThemed: false, keepsLoaded: false, staysActiveInBackground: false, label: "Test"
        )
    }

    /// Loads `html` into `webView` and returns what `js` evaluates to.
    private func evaluate(_ js: String, afterLoading html: String, in webView: WKWebView) async throws -> Any? {
        let loaded = expectation(description: "loaded")
        let watcher = LoadWatcher { loaded.fulfill() }
        webView.navigationDelegate = watcher
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        await fulfillment(of: [loaded], timeout: 10)
        return try await webView.evaluateJavaScript(js)
    }

    func testAServiceWebViewReportsAnOuterSize() async throws {
        let pool = makePool()
        let s = surface(url: "")
        pool.preload(s)
        defer { pool.removeWebView(for: s.id) }
        let webView = try XCTUnwrap(pool.liveWebView(for: s.id))

        let size = try await evaluate(
            "[outerWidth, outerHeight, innerWidth, innerHeight]",
            afterLoading: "<html><body>x</body></html>",
            in: webView
        ) as? [Double]
        let values = try XCTUnwrap(size)
        XCTAssertGreaterThan(values[0], 0, "outerWidth")
        XCTAssertGreaterThan(values[1], 0, "outerHeight")
        XCTAssertGreaterThanOrEqual(values[0], values[2], "outer is never narrower than inner")
        XCTAssertGreaterThanOrEqual(values[1], values[3], "outer is never shorter than inner")
    }

    /// Frames get the same values, since Docs can sit inside one.
    func testAFrameReportsAnOuterSize() async throws {
        let pool = makePool()
        let s = surface(url: "")
        pool.preload(s)
        defer { pool.removeWebView(for: s.id) }
        let webView = try XCTUnwrap(pool.liveWebView(for: s.id))

        let width = try await evaluate(
            "document.querySelector('iframe').contentWindow.outerWidth",
            afterLoading: "<html><body><iframe srcdoc='<p>x</p>'></iframe></body></html>",
            in: webView
        ) as? Double
        XCTAssertGreaterThan(try XCTUnwrap(width), 0)
    }
}

private final class LoadWatcher: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
