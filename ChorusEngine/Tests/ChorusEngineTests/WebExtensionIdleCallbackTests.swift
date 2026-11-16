import WebKit
import XCTest
@testable import ChorusEngine

/// WebKit leaves `requestIdleCallback` off in WKWebView, and Chrome and
/// Firefox have it. Proton Pass's page script waits on it before it looks
/// for login forms, so it threw and never looked. The compatibility script
/// adds it in extension windows only: pages and isolated content scripts,
/// not a site's own world.
@MainActor
final class WebExtensionIdleCallbackTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-idle-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    /// Asks for three idle callbacks and cancels one, then reports every
    /// call in order: how much time each deadline gave, read inside the
    /// callback, and whether the cancelled one ran. Each use sits in a block:
    /// an injected script shares the content script's world and its
    /// top-level names.
    private static let probe = """
    const report = (write) => {
      if (typeof requestIdleCallback !== "function") return write("missing");
      const events = [];
      const cancelled = requestIdleCallback(() => events.push("cancelled one ran"));
      cancelIdleCallback(cancelled);
      requestIdleCallback((deadline) => events.push({kind: "timeout", enough: deadline.timeRemaining() > 10, didTimeout: deadline.didTimeout}), {timeout: 1000});
      requestIdleCallback((deadline) => events.push({kind: "plain", enough: deadline.timeRemaining() > 10}));
      setTimeout(() => write(JSON.stringify(events)), 300);
    };
    """

    private static let expected = #"[{"kind":"timeout","enough":true,"didTimeout":false},{"kind":"plain","enough":true}]"#

    private func makeProbe() throws -> String {
        let folder = root.appending(path: "idle-probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files: [String: String] = [
            "manifest.json": """
            { "manifest_version": 3, "name": "Idle Probe", "version": "1.0",
              "permissions": ["storage", "scripting"], "host_permissions": ["<all_urls>"],
              "background": { "service_worker": "bg.js" },
              "content_scripts": [{ "matches": ["<all_urls>"], "js": ["cs.js"], "run_at": "document_end" },
                                  { "matches": ["<all_urls>"], "js": ["main.js"], "world": "MAIN", "run_at": "document_end" }] }
            """,
            "bg.js": """
            chrome.runtime.onMessage.addListener((message, sender, send) => {
              if (!message || !message.inject) return;
              chrome.scripting.executeScript({target: {tabId: sender.tab.id}, files: ["injected.js"]})
                .then(() => send("injected"), (error) => send("err " + error.message));
              return true;
            });
            """,
            "cs.js": """
            { \(Self.probe)
            report((text) => document.documentElement.setAttribute('data-idle-isolated', text)); }
            chrome.runtime.sendMessage({inject: true}).then((answer) => document.documentElement.setAttribute('data-inject', String(answer)));
            """,
            "injected.js": "{ \(Self.probe)\nreport((text) => document.documentElement.setAttribute('data-idle-injected', text)); }",
            "main.js": "document.documentElement.setAttribute('data-idle-main', typeof window.requestIdleCallback);",
            "idle.html": #"<!doctype html><html><head><script src="idle.js"></script></head><body>idle</body></html>"#,
            "idle.js": "\(Self.probe)\nreport((text) => { window.idleAnswer = text; });",
        ]
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appending(path: name))
        }
        return try library.importPackage(from: folder)
    }

    func testExtensionWindowsHaveIdleCallbacks() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = WebExtensionRecord(source: .package(folder: try makeProbe()), name: "Idle Probe",
                                        grantedPermissions: ["storage", "scripting"], grantedMatchPatterns: ["<all_urls>"])
        try await host.load(record, library: library)
        let context = try XCTUnwrap(host.contexts[record.id])
        context.hasAccessToPrivateData = true

        let extensionPage = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        extensionPage.load(URLRequest(url: context.baseURL.appending(path: "idle.html")))
        let pageAnswer = try await poll(extensionPage, "location.href.endsWith('idle.html') ? (window.idleAnswer || null) : null")
        XCTAssertEqual(pageAnswer, Self.expected, "extension page")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "https://example.com/")!)
        let isolated = try await poll(webView, "document.documentElement.getAttribute('data-idle-isolated')")
        XCTAssertEqual(isolated, Self.expected, "manifest content script")
        let inject = try await poll(webView, "document.documentElement.getAttribute('data-inject')")
        XCTAssertEqual(inject, "injected", "precondition: the background injected its script")
        let injected = try await poll(webView, "document.documentElement.getAttribute('data-idle-injected')")
        XCTAssertEqual(injected, Self.expected, "a script injected by code, as Proton Pass's page script is")

        // A page with no extension at all says what WebKit gives a site.
        let control = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        control.loadHTMLString("<html><body>control</body></html>", baseURL: URL(string: "https://example.com/")!)
        let native = try await poll(control, "document.readyState === 'complete' ? typeof window.requestIdleCallback : null")
        let siteWorld = try await poll(webView, "document.documentElement.getAttribute('data-idle-main')")
        XCTAssertNotNil(native)
        XCTAssertEqual(siteWorld, native, "the site's own world keeps what WebKit gives it")
        XCTAssertEqual(host.problems(for: record.id).filter { $0.contains("__chorus_compat") }, [])

        host.pageClosed(webView)
        host.unload(record.id)
    }

    private func object(_ json: String?) -> NSDictionary? {
        json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary }
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
