import WebKit
import XCTest
@testable import ChorusEngine

/// An extension loaded while service pages are open: added or turned on
/// mid-session, or loaded late at launch. WebKit injects its content scripts
/// into those pages. On macOS 27.2 it also gives the new context every tab of
/// the window, but only when the window names an active tab; with none on
/// screen the context knows no tab, and a script's message fails "Tab not
/// found", even after a reload.
@MainActor
final class WebExtensionOpenPageTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-open-page-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    /// A probe whose content script asks the worker as a page loads and
    /// writes the answer to `data-probe-bg`. The worker answers `{pong: 1}`
    /// with how many `tabs.onCreated` it has heard.
    private func makeRecord() throws -> WebExtensionRecord {
        let folder = root.appending(path: "probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        { "manifest_version": 3, "name": "Probe", "version": "1.0",
          "permissions": ["storage"], "host_permissions": ["<all_urls>"],
          "background": { "service_worker": "bg.js" },
          "content_scripts": [{ "matches": ["<all_urls>"], "js": ["cs.js"], "run_at": "document_end" }] }
        """.utf8).write(to: folder.appending(path: "manifest.json"))
        try Data("""
        const created = [];
        browser.tabs.onCreated.addListener((tab) => { created.push(tab.id); });
        browser.runtime.onMessage.addListener((msg, sender, send) => { send({pong: 1, created: created.length}); });
        """.utf8).write(to: folder.appending(path: "bg.js"))
        try Data("""
        browser.runtime.sendMessage({ping: 1})
          .then(r => document.documentElement.setAttribute('data-probe-bg', r === undefined ? 'no reply' : JSON.stringify(r)))
          .catch(e => document.documentElement.setAttribute('data-probe-bg', 'err ' + e));
        """.utf8).write(to: folder.appending(path: "cs.js"))
        return WebExtensionRecord(source: .package(folder: try library.importPackage(from: folder)), name: "Probe",
                                  grantedPermissions: ["storage"], grantedMatchPatterns: ["<all_urls>"])
    }

    /// A service page on a persistent store of the test's own, opened and
    /// loaded as the pool does it. Not `onScreen`, the window names no active
    /// tab, as when a Mac app is in front.
    @available(macOS 15.4, *)
    private func openPage(in host: WebExtensionHost, onScreen: Bool = true) async throws -> WKWebView {
        let storeID = UUID()
        addTeardownBlock { @MainActor in await Self.removeStore(storeID) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        host.attach(to: configuration)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.displayedPage = { [weak page] in onScreen ? page : nil }
        host.pageOpened(page, service: UUID())
        host.pageActivated(page)
        page.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "https://example.com/")!)
        let loaded = try await poll(page, "document.readyState === 'complete' ? 'yes' : null", timeout: 10)
        XCTAssertEqual(loaded, "yes", "the page loaded")
        return page
    }

    /// Reloads `page` and returns what its content script heard back.
    private func answerAfterReload(_ page: WKWebView) async throws -> String? {
        _ = try await page.evaluateJavaScript("window.__stale = true; 'ok'")
        page.reload()
        return try await poll(page, "!window.__stale && document.readyState === 'complete' ? document.documentElement.getAttribute('data-probe-bg') : null", timeout: 15)
    }

    func testExtensionLoadedWithNoTabOnScreenReachesItsBackground() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        try await assertLateLoadReachesItsBackground(onScreen: false)
    }

    /// WebKit 27.2 fills in the tabs itself here, so the host's own
    /// announcement must not count a tab twice.
    func testExtensionLoadedWithATabOnScreenKnowsItOnce() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        try await assertLateLoadReachesItsBackground(onScreen: true)
    }

    @available(macOS 15.4, *)
    private func assertLateLoadReachesItsBackground(onScreen: Bool, line: UInt = #line) async throws {
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let page = try await openPage(in: host, onScreen: onScreen)
        let record = try makeRecord()

        try await host.load(record, library: library)
        let context = try XCTUnwrap(host.contexts[record.id])
        XCTAssertEqual(context.openTabs.count, 1, "the new context knows the open page, once", line: line)

        let first = try await poll(page, "document.documentElement.getAttribute('data-probe-bg')", timeout: 10)
        print("OPEN-PAGE-PROBE on screen \(onScreen), first message, no reload: \(first ?? "nil")")
        if #available(macOS 27, *) {
            XCTAssertEqual(pong(first), 1, "macOS 27 queues the first message until the background is up", line: line)
        }
        let reloaded = try await answerAfterReload(page)
        print("OPEN-PAGE-PROBE on screen \(onScreen), after reload: \(reloaded ?? "nil")")
        XCTAssertEqual(pong(reloaded), 1, "the page reaches the background", line: line)
        // On macOS 27.2 WebKit's own fill-in sends no tabs.onCreated, and the
        // host's announcement sends one. More would be a double announcement.
        if #available(macOS 27, *) {
            XCTAssertEqual(field("created", reloaded), onScreen ? 0 : 1, "tabs.onCreated heard", line: line)
        } else {
            XCTAssertLessThanOrEqual(field("created", reloaded) ?? 0, 1, "one page, at most one tabs.onCreated", line: line)
        }
        host.pageClosed(page)
        host.unload(record.id)
    }

    /// A page opened while the load waits for the background reaches the
    /// context through the controller. Announcing it a second time would
    /// make it two tabs.
    func testPageOpenedWhileTheBackgroundStartsIsAnnouncedOnce() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let hold = Hold()
        host.startBackgroundContent = { _ in await withCheckedContinuation { hold.release = $0 } }
        let record = try makeRecord()
        let library = library
        let loading = Task { @MainActor in try await host.load(record, library: library) }
        let deadline = Date().addingTimeInterval(5)
        while hold.release == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(hold.release, "precondition: the load waits for the background")

        let page = try await openPage(in: host)
        hold.release?.resume()
        try await loading.value

        XCTAssertEqual(try XCTUnwrap(host.contexts[record.id]).openTabs.count, 1, "one page, one tab")
        let reloaded = try await answerAfterReload(page)
        print("OPEN-PAGE-PROBE opened during the hold, after reload: \(reloaded ?? "nil")")
        XCTAssertEqual(pong(reloaded), 1, "the page reaches the background")
        XCTAssertEqual(field("created", reloaded), 1, "one page, one tabs.onCreated")
        host.pageClosed(page)
        host.unload(record.id)
    }

    /// Where a held background start waits.
    private final class Hold {
        var release: CheckedContinuation<Void, Never>?
    }

    private func pong(_ json: String?) -> Int? { field("pong", json) }

    private func field(_ key: String, _ json: String?) -> Int? {
        let object = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return object?[key] as? Int
    }

    private func poll(_ webView: WKWebView, _ script: String, timeout: TimeInterval) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? await webView.evaluateJavaScript(script) as? String { return value }
            try await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// Main actor on purpose: removal off the main thread crashes. WebKit
    /// refuses while a page still holds the store, so it retries.
    private static func removeStore(_ id: UUID) async {
        for _ in 0..<20 {
            if (try? await WKWebsiteDataStore.remove(forIdentifier: id)) != nil { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        print("Test store \(id) not removed")
    }
}
