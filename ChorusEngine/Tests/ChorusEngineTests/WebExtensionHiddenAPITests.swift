import WebKit
import XCTest
@testable import ChorusEngine

/// WebKit hands each event to a page by reading the page's `browser` global,
/// then `chrome` (`enumerateFramesAndNamespaceObjects`), and skips the page
/// when neither is its own API object. Proton Pass replaces both with
/// Proxies just after it starts and keeps a reference of its own, so its
/// background never heard its popup. The compatibility script keeps both
/// names on WebKit's object in extension worlds and ignores writes to them.
@MainActor
final class WebExtensionHiddenAPITests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-hidden-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    /// Proton Pass's swap, run right after start: every global API name
    /// becomes a Proxy that answers nothing. `done` runs once it has.
    private static let hide = """
    const hide = () => setTimeout(() => {
      for (const [name, api] of Object.entries({chrome: globalThis.chrome, browser: globalThis.browser})) {
        if (api) globalThis[name] = new Proxy(api, { get(target, key) { return key === "app" ? target[key] : undefined; }, set: () => false });
      }
      hid = true;
      done();
    }, 0);
    """

    /// An extension whose background (a page or a service worker) and
    /// `hidden.html` both hide their API the way Proton Pass does, with a
    /// main-world content script and pages that assign the API globals.
    private func makeHidingProbe(backgroundPage: Bool) throws -> String {
        let folder = root.appending(path: "hiding-probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let background = backgroundPage ? #"{ "scripts": ["bg.js"] }"# : #"{ "service_worker": "bg.js" }"#
        let files: [String: String] = [
            "manifest.json": """
            { "manifest_version": 3, "name": "Hiding Probe", "version": "1.0",
              "permissions": ["storage"], "host_permissions": ["<all_urls>"],
              "externally_connectable": { "matches": ["https://example.com/*"] },
              "background": \(background),
              "content_scripts": [{ "matches": ["<all_urls>"], "js": ["main.js"], "world": "MAIN", "run_at": "document_end" }] }
            """,
            "bg.js": """
            "use strict";
            const api = globalThis.browser;
            let hid = false;
            const done = () => api.storage.local.set({hid: true});
            api.runtime.onMessage.addListener((message, sender, send) => {
              if (message && message.ping) { send({pong: 1}); return; }
              if (message && message.hidden) {
                api.runtime.sendMessage({back: 1}).then(
                  (answer) => send({pong: 1, hid, page: answer === undefined ? "no reply" : answer}),
                  (error) => send({pong: 1, hid, page: "err " + error.message}));
                return true;
              }
            });
            \(Self.hide)
            hide();
            """,
            "hidden.html": #"<!doctype html><html><head><script src="hidden.js"></script></head><body>hidden</body></html>"#,
            "hidden.js": """
            "use strict";
            const api = globalThis.browser;
            let hid = false;
            const done = () => {};
            api.runtime.onMessage.addListener((message, sender, send) => { if (message && message.back) send("page heard"); });
            \(Self.hide)
            hide();
            window.reply = (async () => {
              // Wait until the background has hidden its API, then for this page's own swap.
              for (let tries = 0; tries < 200; tries++) {
                if ((await api.storage.local.get("hid")).hid) break;
                await new Promise((resolve) => setTimeout(resolve, 50));
              }
              await new Promise((resolve) => setTimeout(resolve, 50));
              try {
                const answer = await api.runtime.sendMessage({hidden: 1});
                return answer === undefined ? "no reply" : JSON.stringify(answer);
              } catch (error) {
                return "err " + error.message;
              }
            })();
            """,
            "assign.html": """
            <!doctype html><html><head>
            <script src="assign.js"></script><script src="assign2.js"></script><script type="module" src="assign.mjs"></script>
            </head><body>assign</body></html>
            """,
            "assign.js": """
            window.assignResults = window.assignResults || [];
            var browser = globalThis.browser;
            window.assignResults.push("var ok");
            try { globalThis.browser = chrome; window.assignResults.push("assign ok"); } catch (error) { window.assignResults.push("threw " + error.message); }
            try { window.chrome = {runtime: {id: "wrapper"}}; window.assignResults.push("wrapper ok"); } catch (error) { window.assignResults.push("threw " + error.message); }
            """,
            "assign2.js": """
            const chrome = 1;
            window.assignResults.push("lexical " + chrome);
            """,
            "assign.mjs": """
            try { globalThis.browser = {runtime: {}}; window.assignResults.push("module ok"); } catch (error) { window.assignResults.push("threw " + error.message); }
            window.assignResults.push(typeof globalThis.browser.runtime.getURL);
            window.assignResults.push(typeof globalThis.chrome.runtime.getURL);
            try { window.assignResults.push(JSON.stringify(await globalThis.browser.runtime.sendMessage({ping: 1}))); } catch (error) { window.assignResults.push("err " + error.message); }
            window.assignDone = true;
            """,
            "main.js": "document.documentElement.setAttribute('data-main', 'ran');",
        ]
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appending(path: name))
        }
        return try library.importPackage(from: folder)
    }

    private func record(folder: String) -> WebExtensionRecord {
        WebExtensionRecord(source: .package(folder: folder), name: "Hiding Probe",
                           grantedPermissions: ["storage"], grantedMatchPatterns: ["<all_urls>"])
    }

    /// Loads the probe, opens `page` as an extension page, and polls
    /// `script` there. Returns its answer and the compatibility script's
    /// errors.
    @available(macOS 15.4, *)
    private func extensionPageAnswer(backgroundPage: Bool, page: String, script: String,
                                     timeout: TimeInterval = 20) async throws -> (answer: String?, problems: [String]) {
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = record(folder: try makeHidingProbe(backgroundPage: backgroundPage))
        try await host.load(record, library: library)
        let context = try XCTUnwrap(host.contexts[record.id])
        context.hasAccessToPrivateData = true
        let webView = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        webView.load(URLRequest(url: context.baseURL.appending(path: page)))
        let answer = try await poll(webView, script, timeout: timeout)
        let problems = host.problems(for: record.id).filter { $0.contains("__chorus_compat") }
        host.unload(record.id)
        return (answer, problems)
    }

    private static let hiddenReply = """
    location.href.endsWith('hidden.html') && document.readyState === 'complete'
      ? (window.hiddenAnswer || (window.reply.then((answer) => { window.hiddenAnswer = answer; }), null)) : null
    """

    func testBackgroundPageHearsAPageThatHidItsAPI() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let (reply, problems) = try await extensionPageAnswer(backgroundPage: true, page: "hidden.html", script: Self.hiddenReply)
        XCTAssertEqual(object(reply), ["pong": 1, "hid": true, "page": "page heard"], reply ?? "nil")
        XCTAssertEqual(problems, [])
    }

    func testServiceWorkerHearsAPageThatHidItsAPI() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let (reply, problems) = try await extensionPageAnswer(backgroundPage: false, page: "hidden.html", script: Self.hiddenReply)
        XCTAssertEqual(object(reply), ["pong": 1, "hid": true, "page": "page heard"], reply ?? "nil")
        XCTAssertEqual(problems, [])
    }

    /// Writes to the API globals neither throw, in sloppy, strict or module
    /// code, nor stop a top-level `const chrome`, and reads still find
    /// WebKit's API.
    func testAssigningTheAPIGlobalsDoesNotThrow() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let script = "location.href.endsWith('assign.html') && window.assignDone ? JSON.stringify(window.assignResults) : null"
        let (results, problems) = try await extensionPageAnswer(backgroundPage: false, page: "assign.html", script: script)
        XCTAssertEqual(results, #"["var ok","assign ok","wrapper ok","lexical 1","module ok","function","function","{\"pong\":1}"]"#)
        XCTAssertEqual(problems, [])
    }

    /// A main-world content script runs the compatibility script in the
    /// site's own world, where `browser` and `chrome` are the site's to set.
    /// Passes before the fix too; it keeps the fix out of web pages, which
    /// hold WebKit's web-page `browser` (no `getURL`) when the extension
    /// lists the site in `externally_connectable`.
    func testMainWorldContentScriptLeavesThePageGlobalsAlone() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = record(folder: try makeHidingProbe(backgroundPage: false))
        try await host.load(record, library: library)
        host.contexts[record.id]?.hasAccessToPrivateData = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        webView.loadHTMLString("<script>window.chrome = {runtime: {getURL() {}}};</script><body>page</body>",
                               baseURL: URL(string: "https://example.com/")!)
        let ran = try await poll(webView, "document.documentElement.getAttribute('data-main')")
        XCTAssertEqual(ran, "ran", "the main-world content script ran")
        // The site may talk to the extension, so WebKit gives its world a
        // `browser` with a runtime: the case the check has to tell apart.
        let pageAPI = try await webView.evaluateJavaScript("typeof (window.browser && window.browser.runtime && window.browser.runtime.sendMessage)") as? String
        XCTAssertEqual(pageAPI, "function", "WebKit's web-page API is in the site's world")
        let globals = try await webView.evaluateJavaScript("window.chrome = 'site'; window.browser = 'site'; String(window.chrome) + ',' + String(window.browser)") as? String
        XCTAssertEqual(globals, "site,site")
        host.pageClosed(webView)
        host.unload(record.id)
    }

    /// A reply as a dictionary; macOS 15 orders keys differently.
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
