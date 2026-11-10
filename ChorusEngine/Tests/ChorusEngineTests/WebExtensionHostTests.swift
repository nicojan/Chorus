import WebKit
import XCTest
@testable import ChorusEngine

/// The host running a real extension in a real page: the check the
/// 2026-11-09 probe did by hand. Pages here load from a string, so nothing
/// touches the network, and every store is non-persistent.
@MainActor
final class WebExtensionHostTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-host-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    /// The probe extension: a content script that marks the page and asks the
    /// background for a reply, and a toolbar button.
    private func makeProbe(extraPermissions: [String] = []) throws -> String {
        let folder = root.appending(path: "probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let permissions = (["storage"] + extraPermissions).map { "\"\($0)\"" }.joined(separator: ", ")
        let manifest = """
        { "manifest_version": 3, "name": "Probe", "version": "1.0",
          "permissions": [\(permissions)],
          "host_permissions": ["<all_urls>"],
          "action": { "default_title": "Probe Button" },
          "background": { "service_worker": "bg.js" },
          "content_scripts": [{ "matches": ["<all_urls>"], "js": ["cs.js"], "run_at": "document_end" }] }
        """
        try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
        try Data("""
        browser.runtime.onMessage.addListener((msg, sender, send) => { send({pong: 1}); return true; });
        """.utf8).write(to: folder.appending(path: "bg.js"))
        try Data("""
        document.documentElement.setAttribute('data-probe', 'ran');
        browser.runtime.sendMessage({ping: 1})
          .then(r => document.documentElement.setAttribute('data-probe-bg', JSON.stringify(r)))
          .catch(e => document.documentElement.setAttribute('data-probe-bg', 'err ' + e));
        """.utf8).write(to: folder.appending(path: "cs.js"))
        return try library.importPackage(from: folder)
    }

    private func record(folder: String) -> WebExtensionRecord {
        WebExtensionRecord(source: .package(folder: folder), name: "Probe",
                           grantedPermissions: ["storage"], grantedMatchPatterns: ["<all_urls>"])
    }

    func testContentScriptRunsAndReachesItsBackground() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = record(folder: try makeProbe())
        try await host.load(record, library: library)
        XCTAssertTrue(host.loadedIDs.contains(record.id))
        // This page's store is non-persistent, which WebKit treats as private
        // browsing; service stores never are.
        host.contexts[record.id]?.hasAccessToPrivateData = true

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "https://example.com/")!)

        let reply = try await poll(webView, "document.documentElement.getAttribute('data-probe-bg')")
        XCTAssertEqual(reply, #"{"pong":1}"#, "the content script ran and the background answered for a known tab")

        let items = host.toolbarItems(for: webView, order: [record.id])
        XCTAssertEqual(items.map(\.label), ["Probe Button"])

        host.pageClosed(webView)
        host.unload(record.id)
        XCTAssertFalse(host.loadedIDs.contains(record.id))
    }

    func testActiveTabFollowsThePageOnScreen() throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        func page() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            host.attach(to: configuration)
            return WKWebView(frame: .zero, configuration: configuration)
        }
        let service = page(), tab = page()
        var onScreen: WKWebView? = service
        host.displayedPage = { onScreen }
        host.pageOpened(service, service: UUID())
        host.pageOpened(tab, service: UUID())
        XCTAssertTrue(host.activeTab?.webView === service)

        // Picking a tab inside a service sends no event; the host still knows.
        onScreen = tab
        XCTAssertTrue(host.activeTab?.webView === tab)

        // A Mac app on screen: no page is active.
        onScreen = nil
        XCTAssertNil(host.activeTab)

        onScreen = tab
        host.pageClosed(tab)
        XCTAssertNil(host.activeTab, "a closed page is no longer a tab")
        XCTAssertEqual(host.orderedTabs.count, 1)
    }

    func testTurningOffDuringALoadWins() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let record = record(folder: try makeProbe())
        let library = library
        let loading = Task { @MainActor in try await host.load(record, library: library) }
        await Task.yield()
        host.unload(record.id)
        try await loading.value
        XCTAssertFalse(host.loadedIDs.contains(record.id), "an extension turned off while it loaded must not start")
    }

    func testInactiveHostLeavesPagesAlone() throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let configuration = WKWebViewConfiguration()
        host.attach(to: configuration)
        XCTAssertNil(configuration.webExtensionController, "with no extension on, pages are built as before")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        host.pageOpened(webView, service: UUID())
        XCTAssertTrue(host.orderedTabs.isEmpty, "a page without the controller is not a tab")
    }

    func testInspectFlagsAnExtensionThatNeedsItsApp() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let summary = try await host.inspect(.package(folder: try makeProbe(extraPermissions: ["nativeMessaging", "tabs"])), library: library)
        XCTAssertEqual(summary.name, "Probe")
        XCTAssertTrue(summary.needsNativeApp)
        XCTAssertTrue(summary.permissions.contains("tabs"))
        XCTAssertEqual(summary.matchPatterns, ["<all_urls>"])
    }

    func testExtensionPagesClaimSafari() {
        guard #available(macOS 15.4, *) else { return }
        XCTAssertTrue(WebExtensionHost.safariApplicationName.hasPrefix("Version/"))
        XCTAssertTrue(WebExtensionHost.safariApplicationName.contains("Safari/"),
                      "extensions such as Velja pick their Safari code path from this")
    }

    private func poll(_ webView: WKWebView, _ script: String, timeout: TimeInterval = 15) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? await webView.evaluateJavaScript(script) as? String { return value }
            try await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }
}
