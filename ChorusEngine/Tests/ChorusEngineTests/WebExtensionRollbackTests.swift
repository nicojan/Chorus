import WebKit
import XCTest
@testable import ChorusEngine

/// What runs after a rollback: the old version, loaded under the same record
/// right after the new version's worker threw while it started.
@MainActor
final class WebExtensionRollbackTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-rollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    /// A probe whose worker answers `{pong, version}`, or throws on its first
    /// line when `broken`. Its content script asks the worker as a page loads;
    /// its `data.html` page offers `write(t)` and `read()` on
    /// `chrome.storage.local`.
    private func makeProbe(version: String, broken: Bool = false) throws -> String {
        let folder = root.appending(path: "probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = """
        { "manifest_version": 3, "name": "Probe", "version": "\(version)",
          "permissions": ["storage"], "host_permissions": ["<all_urls>"],
          "background": { "service_worker": "bg.js" },
          "content_scripts": [{ "matches": ["<all_urls>"], "js": ["cs.js"], "run_at": "document_end" }] }
        """
        try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
        let worker = """
        browser.runtime.onMessage.addListener((msg, sender, send) => {
          send({pong: 1, version: chrome.runtime.getManifest().version});
        });
        """
        try Data(((broken ? "throw new Error('boom');\n" : "") + worker).utf8).write(to: folder.appending(path: "bg.js"))
        try Data("""
        browser.runtime.sendMessage({ping: 1})
          .then(r => document.documentElement.setAttribute('data-probe-bg', r === undefined ? 'no reply' : JSON.stringify(r)))
          .catch(e => document.documentElement.setAttribute('data-probe-bg', 'err ' + e));
        """.utf8).write(to: folder.appending(path: "cs.js"))
        try Data(#"<!doctype html><html><head><script src="data.js"></script></head><body></body></html>"#.utf8)
            .write(to: folder.appending(path: "data.html"))
        try Data("""
        window.write = async (token) => { await chrome.storage.local.set({token}); return 'ok'; };
        window.read = async () => String((await chrome.storage.local.get('token')).token ?? 'none');
        window.probeReady = 'yes';
        """.utf8).write(to: folder.appending(path: "data.js"))
        return try library.importPackage(from: folder)
    }

    private func record(folder: String, staged: String) -> WebExtensionRecord {
        let update = WebExtensionRecord.StagedUpdate(folder: staged, version: "2.0", newPermissions: [],
                                                     newMatchPatterns: [], attempts: 1)
        return WebExtensionRecord(source: .package(folder: folder), name: "Probe",
                                  grantedPermissions: ["storage"], grantedMatchPatterns: ["<all_urls>"],
                                  catalogID: "probe", installedVersion: "1.0")
            .staging(update)
    }

    /// The by-hand pass of 2026-11-14 saw the old version's load wait out the
    /// full background limit after a rollback; its worker then never
    /// answered for the rest of the session. WebKit keeps the origin's
    /// service worker process for 10 s after the failed version unloads,
    /// and a worker started in that time fails in it. The trial now ends as
    /// soon as WebKit records the failure, and the old version's load waits
    /// for the origin to be free.
    func testOldVersionsBackgroundRunsAfterRollback() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let current = record(folder: try makeProbe(version: "1.0"), staged: try makeProbe(version: "2.0", broken: true))

        let trialStart = ContinuousClock.now
        let trial = await host.loadStagedUpdate(of: current, library: library)
        let trialTime = ContinuousClock.now - trialStart
        guard case .rolledBack = trial else { return XCTFail("got \(trial)") }

        let loadStart = ContinuousClock.now
        try await host.load(current.settling(trial), library: library)
        let loadTime = ContinuousClock.now - loadStart
        let context = try XCTUnwrap(host.contexts[current.id])
        print("ROLLBACK-PROBE trial \(trialTime), old load \(loadTime), old errors: \(context.errors.map { ($0 as NSError).code })")
        XCTAssertNil(WebExtensionHost.backgroundLoadFailure(in: context), "the old version's background started")

        let askStart = ContinuousClock.now
        let reply = try await askWorker(host: host, id: current.id)
        print("ROLLBACK-PROBE reply after \(ContinuousClock.now - askStart): \(reply ?? "nil")")
        XCTAssertEqual(object(reply), ["pong": 1, "version": "1.0"], "the old version's worker answers")
        XCTAssertLessThan(trialTime, .seconds(5), "the trial ends when WebKit records the failure, not at the time limit")
        XCTAssertLessThan(trialTime + loadTime, WebExtensionHost.failedWorkerReleaseDelay + .seconds(5),
                          "the old version waits for the origin, not for a time limit on top")
        host.unload(current.id)
    }

    /// Turning the extension off and on while its load waits for WebKit to
    /// let go of the failed version must leave it running. The wait used to
    /// hold the id as loading, so the second load gave up at once and the
    /// first, waking to the cancel, gave up too.
    func testOffAndOnDuringTheWaitLeavesItRunning() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.isActive = true
        let settled = try await rolledBack(host)
        let library = library
        let first = Task { @MainActor in try await host.load(settled, library: library) }
        try await Task.sleep(for: .milliseconds(200))
        host.unload(settled.id)
        let second = Task { @MainActor in try await host.load(settled, library: library) }
        try await first.value
        try await second.value
        XCTAssertTrue(host.loadedIDs.contains(settled.id), "on after off: it runs")
        let reply = try await askWorker(host: host, id: settled.id)
        XCTAssertEqual(object(reply), ["pong": 1, "version": "1.0"], "and its background answers")
        host.unload(settled.id)
    }

    /// Removing the extension while its load waits must reach its data
    /// at once, not give up because the id is loading, and must not wait out
    /// the release itself: removal starts no background.
    func testRemoveDuringTheWaitDeletesTheData() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        // Persistent: a controller that keeps nothing would lose the data
        // for the wrong reason. A fixed controller id, so runs reuse one
        // storage location; the test deletes what it writes.
        let storeID = UUID()
        addTeardownBlock { @MainActor [weak self] in await self?.removeStore(storeID) }
        let host = WebExtensionHost(storageIdentifier: Self.dataTestStorage, websiteDataStore: WKWebsiteDataStore(forIdentifier: storeID))
        let current = record(folder: try makeProbe(version: "1.0"), staged: try makeProbe(version: "2.0", broken: true))
        let token = UUID().uuidString
        try await host.load(current, library: library)
        _ = try await callData(host: host, id: current.id, "return await write('\(token)')")
        host.unload(current.id)
        try await host.load(current, library: library)
        let control = try await callData(host: host, id: current.id, "return await read()")
        XCTAssertEqual(control, token, "control: the data outlives an unload in this controller")
        host.unload(current.id)

        let trial = await host.loadStagedUpdate(of: current, library: library)
        guard case .rolledBack = trial else { return XCTFail("got \(trial)") }
        let settled = current.settling(trial)
        let library = library
        // The launch's start, waiting for WebKit.
        let pending = Task { @MainActor in try await host.load(settled, library: library) }
        try await Task.sleep(for: .milliseconds(200))

        // What ExtensionManager.remove does.
        let removeStart = ContinuousClock.now
        host.unload(settled.id)
        let removed = await host.removeStoredData(for: settled, library: library)
        let removeTime = ContinuousClock.now - removeStart
        print("ROLLBACK-PROBE remove during the wait took \(removeTime)")
        XCTAssertTrue(removed, "the data was reached")
        XCTAssertLessThan(removeTime, .seconds(5), "removal does not wait out the release")
        guard case .package(let folder) = settled.source else { return XCTFail("not a package") }
        try FileManager.default.removeItem(at: library.packageURL(folder: folder))
        do {
            try await pending.value
            XCTFail("the waiting load must not start a removed extension")
        } catch {}
        XCTAssertFalse(host.loadedIDs.contains(settled.id))

        // Same id, a fresh copy of its files: the data is gone.
        let reader = WebExtensionRecord(id: settled.id, source: .package(folder: try makeProbe(version: "1.0")), name: "Probe",
                                        grantedPermissions: ["storage"], grantedMatchPatterns: ["<all_urls>"])
        try await host.load(reader, library: library)
        let after = try await callData(host: host, id: reader.id, "return await read()")
        XCTAssertEqual(after, "none", "the stored data was deleted")
        host.unload(reader.id)
    }

    /// The controller storage the data test uses, and only it.
    private static let dataTestStorage = UUID(uuidString: "5E1E7A11-0B5A-4C7E-9D2F-0FF1CE0DA7A0")!

    /// Removes the test's website data store once the host and its pages are
    /// gone; WebKit refuses while anything still holds it. Main actor on
    /// purpose: removal off the main thread crashes.
    private func removeStore(_ id: UUID) async {
        for _ in 0..<20 {
            if (try? await WKWebsiteDataStore.remove(forIdentifier: id)) != nil { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        print("Test store \(id) not removed")
    }

    /// A record whose trial of a broken 2.0 just rolled back, settled on 1.0.
    @available(macOS 15.4, *)
    private func rolledBack(_ host: WebExtensionHost) async throws -> WebExtensionRecord {
        let current = record(folder: try makeProbe(version: "1.0"), staged: try makeProbe(version: "2.0", broken: true))
        let trial = await host.loadStagedUpdate(of: current, library: library)
        guard case .rolledBack = trial else {
            XCTFail("got \(trial)")
            throw CancellationError()
        }
        return current.settling(trial)
    }

    /// Runs `script` in the extension's `data.html`.
    @available(macOS 15.4, *)
    @discardableResult
    private func callData(host: WebExtensionHost, id: UUID, _ script: String) async throws -> String? {
        let context = try XCTUnwrap(host.contexts[id])
        let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        page.load(URLRequest(url: context.baseURL.appending(path: "data.html")))
        let ready = try await poll(page, "location.href.endsWith('data.html') && document.readyState === 'complete' ? window.probeReady : null", timeout: 15)
        XCTAssertEqual(ready, "yes", "the extension page loaded")
        return try await page.callAsyncJavaScript(script, contentWorld: .page) as? String
    }

    @available(macOS 15.4, *)
    private func askWorker(host: WebExtensionHost, id: UUID) async throws -> String? {
        // This page's store is non-persistent, which WebKit treats as private
        // browsing; service stores never are.
        host.contexts[id]?.hasAccessToPrivateData = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        host.attach(to: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        host.pageOpened(webView, service: UUID())
        host.pageActivated(webView)
        defer { host.pageClosed(webView) }
        webView.loadHTMLString("<html><body>page</body></html>", baseURL: URL(string: "https://example.com/")!)
        return try await poll(webView, "document.documentElement.getAttribute('data-probe-bg')", timeout: 30)
    }

    private func object(_ json: String?) -> NSDictionary? {
        json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary }
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
