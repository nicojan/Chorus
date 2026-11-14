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
    /// background for a reply, and a toolbar button. `asksForAgent` makes the
    /// content script ask for the background's user agent instead;
    /// `opensSocket` makes the background open a WebSocket to a closed port
    /// and answer when it closes; `listensForUpdates` makes the background
    /// listen to `runtime.onUpdateAvailable` as it starts, as Proton Pass does.
    private func makeProbe(extraPermissions: [String] = [], asksForAgent: Bool = false, opensSocket: Bool = false,
                           asksForDispose: Bool = false, injects: Bool = false, copies: String? = nil,
                           listensForUpdates: Bool = false) throws -> String {
        let folder = root.appending(path: "probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let permissions = (["storage"] + extraPermissions).map { "\"\($0)\"" }.joined(separator: ", ")
        let manifest = """
        { "manifest_version": 3, "name": "Probe", "version": "1.0",
          "permissions": [\(permissions)],
          "host_permissions": ["<all_urls>"],
          "action": { "default_title": "Probe Button" },
          "background": { "service_worker": "bg.js" },
          "content_scripts": [{ "matches": ["<all_urls>"], "js": ["cs.js"], "run_at": "document_end" },
                              { "matches": ["<all_urls>"], "js": ["cs2.js"], "run_at": "document_end" }] }
        """
        try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
        try Data("""
        const onUpdate = () => {};
        if (\(listensForUpdates)) {
          chrome.runtime.onUpdateAvailable.addListener(onUpdate);
          browser.runtime.onUpdateAvailable.addListener(onUpdate);
        }
        browser.runtime.onMessage.addListener((msg, sender, send) => {
          if (msg.updates) {
            const events = [chrome.runtime.onUpdateAvailable, browser.runtime.onUpdateAvailable];
            const listening = events.every((event) => event.hasListener(onUpdate) && event.hasListeners());
            events.forEach((event) => event.removeListener(onUpdate));
            return send({listening, removed: events.every((event) => !event.hasListener(onUpdate) && !event.hasListeners())});
          }
          if (\(opensSocket)) {
            const socket = new WebSocket('wss://127.0.0.1:44301/');
            socket.onclose = (event) => send({pong: 1, closed: event.code});
            return true;
          }
          if (msg.inject) {
            const world = chrome.scripting.ExecutionWorld;
            const run = (w) => chrome.scripting.executeScript({target: {tabId: sender.tab.id}, files: ['inject.js'], injectImmediately: false, world: w})
              .then(() => 'ok', (e) => 'err ' + e.message);
            Promise.all([world ? 'enum' : 'no enum', run(world ? world.ISOLATED : 'ISOLATED'), run(world ? world.MAIN : 'MAIN')])
              .then((parts) => send({inject: parts.join(' | ')}));
            return true;
          }
          if (msg.churn) {
            // Enough garbage for several collections, so a wrapper nothing
            // holds would be rebuilt.
            let keep = 0;
            for (let i = 0; i < 300; i++) { const chunk = new Array(100000).fill(i); keep += chunk.length; }
            return send({churned: keep > 0});
          }
          if (msg.copy) {
            // Bitwarden's way: an offscreen document does the copy, since a
            // service worker has no document.
            (async () => {
              if (!chrome.offscreen) return 'no offscreen';
              if (!(await chrome.offscreen.hasDocument())) {
                await chrome.offscreen.createDocument({url: 'offscreen.html', reasons: [chrome.offscreen.Reason.CLIPBOARD], justification: 'Write text to the clipboard.'});
              }
              const answer = await chrome.runtime.sendMessage({offscreenCopy: msg.copy});
              await chrome.offscreen.closeDocument();
              return answer;
            })().then((r) => send({copy: r}), (e) => send({copy: 'err ' + e.message}));
            return true;
          }
          if (msg.world) return send({world: typeof (chrome.scripting && chrome.scripting.ExecutionWorld), contains: chrome.permissions.contains.name, update: typeof (chrome.runtime.onUpdateAvailable && chrome.runtime.onUpdateAvailable.addListener)});
          if (msg.dispose) return send({dispose: typeof Symbol.dispose, asyncDispose: typeof Symbol.asyncDispose});
          send(msg.ua ? {ua: navigator.userAgent, pinned: String(!/\\[native code\\]/.test(String(Object.getOwnPropertyDescriptor(Object.getPrototypeOf(navigator), "userAgent").get)))} : {pong: 1});
        });
        """.utf8).write(to: folder.appending(path: "bg.js"))
        try Data("""
        document.documentElement.setAttribute('data-probe', 'ran');
        document.documentElement.setAttribute('data-probe-dispose', typeof Symbol.dispose);
        document.documentElement.setAttribute('data-probe-update-event', typeof browser.runtime.onUpdateAvailable + ',' + typeof chrome.runtime.onUpdateAvailable);
        document.addEventListener('probe-churn', () => browser.runtime.sendMessage({churn: 1})
          .then(r => document.documentElement.setAttribute('data-probe-churn', JSON.stringify(r))));
        document.addEventListener('probe-ask-world', () => browser.runtime.sendMessage({world: 1})
          .then(r => document.documentElement.setAttribute('data-probe-world', JSON.stringify(r))));
        browser.runtime.sendMessage(\(asksForAgent ? "{ua: 1}" : asksForDispose ? "{dispose: 1}" : injects ? "{inject: 1}" : listensForUpdates ? "{updates: 1}" : copies.map { "{copy: '\($0)'}" } ?? "{ping: 1}"))
          .then(r => document.documentElement.setAttribute('data-probe-bg', r === undefined ? 'no reply' : JSON.stringify(r)))
          .catch(e => document.documentElement.setAttribute('data-probe-bg', 'err ' + e));
        """.utf8).write(to: folder.appending(path: "cs.js"))
        try Data("document.documentElement.setAttribute('data-probe-second', 'ran');".utf8)
            .write(to: folder.appending(path: "cs2.js"))
        try Data("document.documentElement.setAttribute('data-injected', (document.documentElement.getAttribute('data-injected') || '') + 'x');".utf8)
            .write(to: folder.appending(path: "inject.js"))
        try Data(#"<!doctype html><html><head><script src="page.js"></script></head><body></body></html>"#.utf8)
            .write(to: folder.appending(path: "page.html"))
        try Data(#"<!doctype html><html><head><script src="offscreen.js"></script></head><body></body></html>"#.utf8)
            .write(to: folder.appending(path: "offscreen.html"))
        // Bitwarden's offscreen page: the clipboard API, then execCommand.
        try Data("""
        chrome.runtime.onMessage.addListener((msg, sender, send) => {
          if (!msg.offscreenCopy) return;
          navigator.clipboard.writeText(msg.offscreenCopy).then(() => send('api'), () => {
            const area = document.createElement('textarea');
            area.textContent = msg.offscreenCopy;
            document.body.appendChild(area);
            area.select();
            send(document.execCommand('copy') ? 'legacy' : 'refused');
          });
          return true;
        });
        """.utf8).write(to: folder.appending(path: "offscreen.js"))
        try Data("""
        document.title = typeof Symbol.dispose;
        window.updateEvent = [chrome.runtime.onUpdateAvailable, browser.runtime.onUpdateAvailable]
          .map(event => event ? ['addListener', 'removeListener', 'hasListener', 'hasListeners'].map(name => typeof event[name]).join(',') : 'missing')
          .join(' | ');
        window.permissionAnswers = Promise.all(['privacy', 'nativeMessaging', 'storage', 'tabs'].map(name =>
          new Promise(resolve => {
            try { chrome.permissions.contains({permissions: [name]}, r => resolve(name + '=' + r)); }
            catch (e) { resolve(name + ' threw ' + e.message); }
          }))).then(list => list.join('; '));
        """.utf8).write(to: folder.appending(path: "page.js"))
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

    /// Extensions pick a code path from the user agent. "Safari" alone sends
    /// a Chrome build such as Bitwarden's down its Safari path, which needs
    /// the vendor's Mac app: Bitwarden's background then spun on
    /// `browser.runtime.sendNativeMessage` and its popup never loaded. With
    /// neither name it found no device and its background failed to start.
    func testExtensionBackgroundClaimsChrome() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = record(folder: try makeProbe(asksForAgent: true))
        try await host.load(record, library: library)
        host.contexts[record.id]?.hasAccessToPrivateData = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "https://example.com/")!)

        let reply = try await poll(webView, "document.documentElement.getAttribute('data-probe-bg')")
        let answer = reply.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
        let agent = try XCTUnwrap(answer?["ua"], "the background answered with its user agent: \(reply ?? "nil")")
        // Pinned by the compatibility script, so a page elsewhere in the app
        // cannot change it; WebKit's own getter would follow the last page.
        XCTAssertEqual(answer?["pinned"], "true", "navigator.userAgent is WebKit's own getter")
        XCTAssertTrue(agent.contains(" Chrome/"), agent)
        XCTAssertTrue(agent.contains(" Safari/"), agent)
        XCTAssertEqual(agent, ExtensionCompatibility.backgroundUserAgent)

        host.pageClosed(webView)
        host.unload(record.id)
    }

    /// WebKit runs an extension's service worker on its process's main thread,
    /// and opening a WebSocket from a worker waits for that same thread: the
    /// process stops for good, popups included. Bitwarden opens one to its
    /// notifications server as soon as someone signs in, so its sign-in spun
    /// forever and its popup never opened again. (Port 9 would not show it:
    /// WebKit refuses that port before it builds a channel.)
    func testServiceWorkerSurvivesOpeningAWebSocket() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = record(folder: try makeProbe(opensSocket: true))
        try await host.load(record, library: library)
        host.contexts[record.id]?.hasAccessToPrivateData = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "https://example.com/")!)

        let reply = try await poll(webView, "document.documentElement.getAttribute('data-probe-bg')")
        XCTAssertEqual(object(reply), ["pong": 1, "closed": 1006], "the socket failed and the background still answered: \(reply ?? "nil")")

        host.pageClosed(webView)
        host.unload(record.id)
    }

    /// Chrome 134 has `Symbol.dispose`, and Bitwarden's Chrome build leans on
    /// it through TypeScript's `using` (unlocking, decrypting the vault).
    /// WebKit has neither symbol, so Chorus defines both in each extension's
    /// service worker, pages and content scripts.
    func testExtensionContextsHaveDisposeSymbols() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = record(folder: try makeProbe(asksForDispose: true))
        try await host.load(record, library: library)
        host.contexts[record.id]?.hasAccessToPrivateData = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "https://example.com/")!)

        let reply = try await poll(webView, "document.documentElement.getAttribute('data-probe-bg')")
        XCTAssertEqual(object(reply), ["dispose": "symbol", "asyncDispose": "symbol"], "the service worker has both symbols: \(reply ?? "nil")")
        let contentScript = try await poll(webView, "document.documentElement.getAttribute('data-probe-dispose')")
        XCTAssertEqual(contentScript, "symbol", "the content script has Symbol.dispose")
        // Two content script entries run the compatibility script twice in
        // one world, as Bitwarden's do; the second run must not throw.
        let second = try await poll(webView, "document.documentElement.getAttribute('data-probe-second')")
        XCTAssertEqual(second, "ran")
        XCTAssertEqual(host.problems(for: record.id).filter { $0.contains("__chorus_compat") }, [])

        let context = try XCTUnwrap(host.contexts[record.id])
        let extensionPage = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        extensionPage.load(URLRequest(url: context.baseURL.appending(path: "page.html")))
        let pageResult = try await poll(extensionPage, "location.href.endsWith('page.html') && document.readyState === 'complete' ? document.title : null")
        XCTAssertEqual(pageResult, "symbol", "an extension page has Symbol.dispose")
        // WebKit throws for a permission it does not know, such as Chrome's
        // `privacy`; Chrome answers false. Bitwarden's popup asks about
        // `privacy` on its start screen, and the throw left the popup blank.
        let answers = try await extensionPage.callAsyncJavaScript("return await window.permissionAnswers", contentWorld: .page) as? String
        XCTAssertEqual(answers, "privacy=false; nativeMessaging=false; storage=true; tabs=false")

        host.pageClosed(webView)
        host.unload(record.id)
    }

    /// Proton Pass listens to `runtime.onUpdateAvailable` as its background
    /// starts. WebKit has no such event, so the call threw and the background
    /// stopped. Chorus updates extensions itself, so the event never fires;
    /// extension pages have it too, as in Chrome, and content scripts do not.
    func testBackgroundCanListenForUpdates() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = record(folder: try makeProbe(listensForUpdates: true))
        try await host.load(record, library: library)
        host.contexts[record.id]?.hasAccessToPrivateData = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "https://example.com/")!)

        let reply = try await poll(webView, "document.documentElement.getAttribute('data-probe-bg')")
        XCTAssertEqual(object(reply), ["listening": true, "removed": true],
                       "the background started and its listener came and went: \(reply ?? "nil"); errors: \(host.problems(for: record.id))")
        let contentScript = try await poll(webView, "document.documentElement.getAttribute('data-probe-update-event')")
        XCTAssertEqual(contentScript, "undefined,undefined", "content scripts do not get the event on browser or chrome, as in Chrome")

        let context = try XCTUnwrap(host.contexts[record.id])
        let extensionPage = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        extensionPage.load(URLRequest(url: context.baseURL.appending(path: "page.html")))
        let pageResult = try await poll(extensionPage, "location.href.endsWith('page.html') && document.readyState === 'complete' ? window.updateEvent : null")
        let functions = "function,function,function,function"
        XCTAssertEqual(pageResult, "\(functions) | \(functions)", "an extension page has the event on chrome and browser")

        host.pageClosed(webView)
        host.unload(record.id)
    }

    /// Bitwarden fills a login by injecting its scripts with
    /// `chrome.scripting.executeScript`, naming the world through
    /// `chrome.scripting.ExecutionWorld`, which WebKit does not define.
    func testScriptingExecutionWorldWorks() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = WebExtensionRecord(source: .package(folder: try makeProbe(extraPermissions: ["scripting"], injects: true)),
                                        name: "Probe", grantedPermissions: ["storage", "scripting"], grantedMatchPatterns: ["<all_urls>"])
        try await host.load(record, library: library)
        host.contexts[record.id]?.hasAccessToPrivateData = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "https://example.com/")!)

        let reply = try await poll(webView, "document.documentElement.getAttribute('data-probe-bg')")
        XCTAssertEqual(object(reply), ["inject": "enum | ok | ok"], reply ?? "nil")
        let injected = try await poll(webView, "document.documentElement.getAttribute('data-injected')")
        XCTAssertEqual(injected, "xx", "both scripts ran")

        host.pageClosed(webView)
        host.unload(record.id)
    }

    /// WebKit drops the JavaScript wrapper of an API object nothing refers to
    /// and builds a new one on the next read, without what the compatibility
    /// script added. Bitwarden's popup threw on `privacy` again, and its fill
    /// scripts lost `ExecutionWorld`, once a collection had run.
    func testCompatibilityOutlivesGarbageCollection() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = WebExtensionRecord(source: .package(folder: try makeProbe(extraPermissions: ["scripting", "tabs"])),
                                        name: "Probe", grantedPermissions: ["storage", "scripting"], grantedMatchPatterns: ["<all_urls>"])
        try await host.load(record, library: library)
        let context = try XCTUnwrap(host.contexts[record.id])
        context.hasAccessToPrivateData = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "https://example.com/")!)
        _ = try await poll(webView, "document.documentElement.getAttribute('data-probe-bg')")

        func askWorld() async throws -> String? {
            _ = try await webView.evaluateJavaScript("document.documentElement.removeAttribute('data-probe-world'); document.dispatchEvent(new Event('probe-ask-world')); 1")
            return try await poll(webView, "document.documentElement.getAttribute('data-probe-world')")
        }
        let before = try await askWorld()
        XCTAssertEqual(object(before), ["world": "object", "contains": "answer", "update": "function"], before ?? "nil")

        _ = try await webView.evaluateJavaScript("document.dispatchEvent(new Event('probe-churn')); 1")
        let churned = try await poll(webView, "document.documentElement.getAttribute('data-probe-churn')", timeout: 60)
        XCTAssertEqual(object(churned), ["churned": true])
        let after = try await askWorld()
        XCTAssertEqual(object(after), ["world": "object", "contains": "answer", "update": "function"], after ?? "nil")

        host.pageClosed(webView)
        host.unload(record.id)
    }

    /// Bitwarden copies from its service worker (the right-click items, a
    /// code after a fill) through `chrome.offscreen`, which WebKit lacks; its
    /// fallback reaches for a `document` the worker does not have. Chorus
    /// stands in with a hidden extension page that may write the clipboard.
    func testServiceWorkerCopiesThroughAnOffscreenDocument() async throws {
        let text = "chorus-copy-\(UUID().uuidString)"
        let result = try await copyFromWorker(text, granted: ["storage", "clipboardWrite"])
        XCTAssertEqual(object(result.reply), ["copy": "api"], result.reply ?? "nil")
        XCTAssertEqual(result.pasteboard, text)
    }

    /// Without `clipboardWrite` the page loads but may not write.
    func testOffscreenDocumentNeedsClipboardWrite() async throws {
        let result = try await copyFromWorker("chorus-copy-\(UUID().uuidString)", granted: ["storage"])
        XCTAssertEqual(object(result.reply), ["copy": "refused"], result.reply ?? "nil")
        XCTAssertEqual(result.pasteboard, "before")
    }

    /// Asks the probe's worker to copy `text`, keeping whatever was on the
    /// clipboard before the test.
    private func copyFromWorker(_ text: String, granted: [String]) async throws -> (reply: String?, pasteboard: String?) {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("before", forType: .string)

        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let record = WebExtensionRecord(source: .package(folder: try makeProbe(extraPermissions: ["clipboardWrite", "offscreen"], copies: text)),
                                        name: "Probe", grantedPermissions: granted, grantedMatchPatterns: ["<all_urls>"])
        try await host.load(record, library: library)
        host.contexts[record.id]?.hasAccessToPrivateData = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "https://example.com/")!)

        let reply = try await poll(webView, "document.documentElement.getAttribute('data-probe-bg')", timeout: 20)
        let pasteboard = NSPasteboard.general.string(forType: .string)
        host.pageClosed(webView)
        host.unload(record.id)
        return (reply, pasteboard)
    }

    /// A reply as a dictionary. WebKit on macOS 15 orders a reply's keys
    /// differently from 26 and 27, so replies are compared as objects.
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
