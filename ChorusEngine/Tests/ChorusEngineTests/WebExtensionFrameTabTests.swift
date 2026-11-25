import WebKit
import XCTest
@testable import ChorusEngine

/// Consent-O-Matic's content script runs in every frame. In a subframe it
/// asks its worker for the tab's address (`GetTabUrl`), the worker answers
/// `sender.tab.url`, and the frame passes the answer to `new URL`. An answer
/// of `undefined` throws `"undefined" cannot be parsed as a URL`, which it
/// logged once on 2026-11-16. The probe below copies that exchange, with the
/// worker's handler as Consent-O-Matic 1.1.5 writes it.
@MainActor
final class WebExtensionFrameTabTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-frame-tab-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    private func makeRecord() throws -> WebExtensionRecord {
        let folder = root.appending(path: "frame-probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files: [String: String] = [
            "manifest.json": """
            { "manifest_version": 3, "name": "Frame Probe", "version": "1.0",
              "permissions": ["tabs", "storage"], "host_permissions": ["<all_urls>"],
              "background": { "service_worker": "service.js" },
              "content_scripts": [{ "matches": ["<all_urls>"], "js": ["content.js"], "all_frames": true,
                                    "match_about_blank": true, "run_at": "document_start" }] }
            """,
            // Consent-O-Matic 1.1.5's handler: a throw is caught and nothing answers.
            "service.js": """
            chrome.runtime.onMessage.addListener(function (message, sender, respond) {
              try {
                switch (message.split("|")[0]) {
                  case "GetTabUrl": return respond(sender.tab.url), false;
                }
              } catch (error) { console.error(error); }
            });
            """,
            "content.js": """
            if (window !== window.parent) {
              chrome.runtime.sendMessage("GetTabUrl", (answer) => {
                const error = chrome.runtime.lastError ? chrome.runtime.lastError.message : null;
                window.parent.postMessage({ tabURL: String(answer), error, frame: location.href }, "*");
              });
            }
            """,
        ]
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appending(path: name))
        }
        return WebExtensionRecord(source: .package(folder: try library.importPackage(from: folder)), name: "Frame Probe",
                                  grantedPermissions: ["tabs", "storage"], grantedMatchPatterns: ["<all_urls>"])
    }

    /// A site page with a frame its script makes from about:blank, which
    /// collects what the frame's content script heard. (WebKit injects no
    /// content script into a `srcdoc` frame, so one would ask nothing.)
    private static let page = """
    <html><head><script>
    window.answers = [];
    addEventListener("message", (event) => { if (event.data && "tabURL" in event.data) answers.push(event.data); });
    </script></head><body>
    <script>
    const blank = document.createElement("iframe");
    document.body.appendChild(blank);
    blank.contentDocument.body.textContent = "blank";
    </script>
    </body></html>
    """

    /// The extension is running before the page opens.
    func testSubframeHearsTheTabAddress() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = try makeRecord()
        try await host.load(record, library: library)
        let webView = openPage(in: host, onScreen: true)
        try assertHeardTheTabAddress(try await answers(in: webView))
        host.pageClosed(webView)
        host.unload(record.id)
    }

    /// The extension is added while the page is open and none is on screen,
    /// as with a Mac app in front. Its content
    /// script reaches the open frame through WebKit and asks at once.
    func testSubframeOpenBeforeTheLoadHearsTheTabAddress() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let webView = openPage(in: host, onScreen: false)
        let loaded = try await poll(webView, "document.readyState === 'complete' && frames.length === 1 ? 'yes' : null", timeout: 10)
        XCTAssertEqual(loaded, "yes", "the page and its frame loaded")
        let record = try makeRecord()
        try await host.load(record, library: library, isNewlyAdded: true)
        let heard = try await answers(in: webView)
        print("FRAME-TAB-PROBE loaded while open: \(heard ?? "nil")")
        try assertHeardTheTabAddress(heard)
        host.pageClosed(webView)
        host.unload(record.id)
    }

    @available(macOS 15.4, *)
    private func openPage(in host: WebExtensionHost, onScreen: Bool) -> WKWebView {
        // A store of the test's own, persistent as every service store is:
        // extensions get no private pages.
        let storeID = UUID()
        addTeardownBlock { @MainActor in await Self.removeStore(storeID) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.displayedPage = { [weak webView] in onScreen ? webView : nil }
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://example.com/")!)
        return webView
    }

    private func answers(in webView: WKWebView) async throws -> String? {
        try await poll(webView, "window.answers && window.answers.length >= 1 ? JSON.stringify(window.answers) : null", timeout: 15)
    }

    private func assertHeardTheTabAddress(_ answers: String?, line: UInt = #line) throws {
        let list = try XCTUnwrap(answers.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]] },
                                 answers ?? "nil", line: line)
        XCTAssertEqual(list.count, 1, "the frame asked once", line: line)
        XCTAssertEqual(list.first?["tabURL"] as? String, "https://example.com/", "\(list)", line: line)
        XCTAssertTrue(list.first?["error"] is NSNull, "\(list)", line: line)
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

    private func poll(_ webView: WKWebView, _ script: String, timeout: TimeInterval) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? await webView.evaluateJavaScript(script) as? String { return value }
            try await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }
}
