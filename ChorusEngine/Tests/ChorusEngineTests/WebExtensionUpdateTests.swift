import WebKit
import XCTest
@testable import ChorusEngine

/// The host trying a staged update: reviewing what a new version asks for,
/// loading it under the same record, and leaving the old version in place
/// when the new one will not start.
@MainActor
final class WebExtensionUpdateTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    /// Writes a probe extension to a fresh folder and imports it. Its
    /// `data.html` page offers `writeToken(t)` and `readAll()`, which touch
    /// `chrome.storage.local`, `localStorage` and IndexedDB.
    private func makeProbe(
        version: String,
        permissions: [String] = ["storage"],
        hostPermissions: [String] = ["<all_urls>"],
        optionalPermissions: [String] = [],
        optionalHostPermissions: [String] = [],
        brokenBackground: Bool = false
    ) throws -> String {
        let folder = root.appending(path: "probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Probe", "version": version,
            "permissions": permissions,
            "host_permissions": hostPermissions,
            "optional_permissions": optionalPermissions,
            "optional_host_permissions": optionalHostPermissions,
            "background": ["service_worker": "bg.js"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "manifest.json"))
        let background = brokenBackground ? "throw new Error('boom');" : "self.started = true;"
        try Data(background.utf8).write(to: folder.appending(path: "bg.js"))
        try Data(#"<!doctype html><html><head><script src="data.js"></script></head><body></body></html>"#.utf8)
            .write(to: folder.appending(path: "data.html"))
        try Data("""
        function openDB() {
          return new Promise((resolve, reject) => {
            const request = indexedDB.open('probe', 1);
            request.onupgradeneeded = () => request.result.createObjectStore('kv');
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
          });
        }
        window.writeToken = async (token) => {
          await chrome.storage.local.set({token});
          localStorage.setItem('token', token);
          const db = await openDB();
          await new Promise((resolve, reject) => {
            const tx = db.transaction('kv', 'readwrite');
            tx.objectStore('kv').put(token, 'token');
            tx.oncomplete = resolve;
            tx.onerror = () => reject(tx.error);
          });
          db.close();
          return 'ok';
        };
        window.readAll = async () => {
          const stored = await chrome.storage.local.get('token');
          const db = await openDB();
          const kept = await new Promise((resolve, reject) => {
            const request = db.transaction('kv').objectStore('kv').get('token');
            request.onsuccess = () => resolve(request.result ?? null);
            request.onerror = () => reject(request.error);
          });
          db.close();
          return JSON.stringify({storage: stored.token ?? null, local: localStorage.getItem('token'),
                                 idb: kept, version: chrome.runtime.getManifest().version});
        };
        window.probeReady = 'yes';
        """.utf8).write(to: folder.appending(path: "data.js"))
        return try library.importPackage(from: folder)
    }

    private func record(folder: String, id: UUID = UUID()) -> WebExtensionRecord {
        WebExtensionRecord(id: id, source: .package(folder: folder), name: "Probe",
                           grantedPermissions: ["storage"], grantedMatchPatterns: ["<all_urls>"],
                           catalogID: "probe", installedVersion: "1.0")
    }

    /// A record on `current` with a ready update to `staged` and one attempt
    /// marked, as the app saves it before a trial.
    private func markedRecord(current: String, staged: String, version: String = "2.0",
                              attempts: Int = 1) -> WebExtensionRecord {
        let update = WebExtensionRecord.StagedUpdate(folder: staged, version: version, newPermissions: [],
                                                     newMatchPatterns: [], attempts: attempts)
        return record(folder: current).staging(update)
    }

    // MARK: - Review

    func testReviewFindsNewPermission() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let current = record(folder: try makeProbe(version: "1.0"))
        let newFolder = try makeProbe(version: "2.0", permissions: ["storage", "tabs"])
        let update = try await host.reviewUpdate(folder: newFolder, version: "2.0", for: current, library: library)
        XCTAssertEqual(update.newPermissions, ["tabs"])
        XCTAssertEqual(update.newMatchPatterns, [])
        XCTAssertFalse(update.isReady)
        XCTAssertEqual(update.folder, newFolder)
        XCTAssertEqual(update.version, "2.0")
        XCTAssertFalse(update.isApproved)
        XCTAssertEqual(update.attempts, 0)
    }

    func testReviewReadyWithSameAsks() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let current = record(folder: try makeProbe(version: "1.0"))
        let newFolder = try makeProbe(version: "2.0", hostPermissions: ["https://a.example/*"])
        let update = try await host.reviewUpdate(folder: newFolder, version: "2.0", for: current, library: library)
        XCTAssertEqual(update.newPermissions, [])
        XCTAssertEqual(update.newMatchPatterns, [], "<all_urls> covers a narrower site")
        XCTAssertTrue(update.isReady)
    }

    /// Optional permissions are asked for at runtime, through WebKit's own
    /// prompt, so an update that only adds them waits for nobody. This also
    /// pins that WebKit leaves `optional_host_permissions` out of
    /// `allRequestedMatchPatterns`.
    func testOptionalPermissionsAreNotAsks() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let current = WebExtensionRecord(source: .package(folder: try makeProbe(version: "1.0", hostPermissions: [])),
                                         name: "Probe", grantedPermissions: ["storage"], grantedMatchPatterns: [])
        let newFolder = try makeProbe(version: "2.0", hostPermissions: [], optionalPermissions: ["tabs"],
                                      optionalHostPermissions: ["https://b.example/*"])
        let summary = try await host.inspect(.package(folder: newFolder), library: library)
        XCTAssertEqual(summary.matchPatterns, [], "optional host permissions are not in allRequestedMatchPatterns")
        let update = try await host.reviewUpdate(folder: newFolder, version: "2.0", for: current, library: library)
        XCTAssertEqual(update.newPermissions, [])
        XCTAssertEqual(update.newMatchPatterns, [])
        XCTAssertTrue(update.isReady)
    }

    // MARK: - Trial guards

    func testUnreadyUpdateIsNotTried() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let update = WebExtensionRecord.StagedUpdate(folder: try makeProbe(version: "2.0"), version: "2.0",
                                                     newPermissions: ["tabs"], newMatchPatterns: [], attempts: 1)
        let current = record(folder: try makeProbe(version: "1.0")).staging(update)
        let trial = await host.loadStagedUpdate(of: current, library: library)
        XCTAssertEqual(trial, .notAttempted)
        XCTAssertTrue(host.loadedIDs.isEmpty)
    }

    func testTrialNeedsAttemptMarker() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let current = markedRecord(current: try makeProbe(version: "1.0"), staged: try makeProbe(version: "2.0"), attempts: 0)
        let trial = await host.loadStagedUpdate(of: current, library: library)
        XCTAssertEqual(trial, .notAttempted, "no trial runs before its attempt is saved")
        XCTAssertTrue(host.loadedIDs.isEmpty)
    }

    func testTooManyAttemptsRollsBack() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let staged = try makeProbe(version: "2.0")
        let current = markedRecord(current: try makeProbe(version: "1.0"), staged: staged, attempts: 3)
        let trial = await host.loadStagedUpdate(of: current, library: library)
        XCTAssertEqual(trial, .rolledBack(folder: staged, version: "2.0", reason: "interrupted 2 times"))
        XCTAssertTrue(host.loadedIDs.isEmpty, "a version that keeps crashing the app is not loaded again")
    }

    /// Two tries are allowed: a trial interrupted once (a quit, or a crash
    /// with another cause) still loads at the next launch.
    func testSecondAttemptStillLoads() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let staged = try makeProbe(version: "2.0")
        let current = markedRecord(current: try makeProbe(version: "1.0"), staged: staged,
                                   attempts: WebExtensionRecord.StagedUpdate.maxAttempts)
        let trial = await host.loadStagedUpdate(of: current, library: library)
        XCTAssertEqual(trial, .updated(folder: staged, version: "2.0"))
        XCTAssertEqual(host.details(for: current.id)?.version, "2.0")
        host.unload(current.id)
    }

    // MARK: - Rollback

    func testBadManifestRollsBack() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let staged = try makeProbe(version: "2.0")
        try Data("{ not json".utf8).write(to: library.packageURL(folder: staged).appending(path: "manifest.json"))
        let current = markedRecord(current: try makeProbe(version: "1.0"), staged: staged)
        let trial = await host.loadStagedUpdate(of: current, library: library)
        guard case .rolledBack(let folder, let version, _) = trial else { return XCTFail("got \(trial)") }
        XCTAssertEqual(folder, staged)
        XCTAssertEqual(version, "2.0")
        XCTAssertTrue(host.loadedIDs.isEmpty)
        try await assertOldVersionRuns(current.settling(trial), host: host)
    }

    func testMissingFolderRollsBack() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let missing = UUID().uuidString
        let current = markedRecord(current: try makeProbe(version: "1.0"), staged: missing)
        let trial = await host.loadStagedUpdate(of: current, library: library)
        guard case .rolledBack(let folder, _, _) = trial else { return XCTFail("got \(trial)") }
        XCTAssertEqual(folder, missing)
        XCTAssertTrue(host.loadedIDs.isEmpty)
        try await assertOldVersionRuns(current.settling(trial), host: host)
    }

    /// WebKit never answers `loadBackgroundContent` for a service worker
    /// that throws while it starts. It does record backgroundContentFailedToLoad
    /// in the context's errors (seen on macOS 15, 26 and 27.2); the host's
    /// wait ends there, and the trial rolls back on that one code. Other
    /// listed errors are not failures: Raindrop and DeArrow run fine with
    /// errors listed. `WebExtensionRollbackTests` checks the old version's
    /// background then runs.
    func testBrokenBackgroundRollsBack() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let staged = try makeProbe(version: "2.0", brokenBackground: true)
        let current = markedRecord(current: try makeProbe(version: "1.0"), staged: staged)
        let trial = await host.loadStagedUpdate(of: current, library: library)
        guard case .rolledBack(let folder, _, let reason) = trial else { return XCTFail("got \(trial)") }
        XCTAssertEqual(folder, staged)
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("background"), reason)
        XCTAssertTrue(host.loadedIDs.isEmpty)
        try await assertOldVersionRuns(current.settling(trial), host: host)
    }

    /// This makes the start itself fail through the host's seam, the other
    /// way a background can fail.
    func testBackgroundFailureRollsBack() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.startBackgroundContent = { _ in throw Self.backgroundError }
        let staged = try makeProbe(version: "2.0")
        let current = markedRecord(current: try makeProbe(version: "1.0"), staged: staged)
        let trial = await host.loadStagedUpdate(of: current, library: library)
        XCTAssertEqual(trial, .rolledBack(folder: staged, version: "2.0", reason: "boom"), "WebKit's reason is kept")
        XCTAssertTrue(host.loadedIDs.isEmpty, "the new version is not left running")
        XCTAssertNil(host.contexts[current.id])
        try await assertOldVersionRuns(current.settling(trial), host: host)
    }

    /// The plain load only logs a failed background: the extension still runs.
    func testPlainLoadKeepsExtensionWhoseBackgroundFails() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        host.startBackgroundContent = { _ in throw Self.backgroundError }
        let current = record(folder: try makeProbe(version: "1.0"))
        try await host.load(current, library: library)
        XCTAssertTrue(host.loadedIDs.contains(current.id))
        host.unload(current.id)
    }

    private static let backgroundError = NSError(domain: "ChorusTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])

    /// The settled record is back on 1.0 with 2.0 skipped, and loads 1.0.
    @available(macOS 15.4, *)
    private func assertOldVersionRuns(_ settled: WebExtensionRecord, host: WebExtensionHost,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertNil(settled.stagedUpdate, file: file, line: line)
        XCTAssertEqual(settled.skippedVersion, "2.0", file: file, line: line)
        XCTAssertEqual(settled.installedVersion, "1.0", file: file, line: line)
        try await host.load(settled, library: library)
        XCTAssertEqual(host.details(for: settled.id)?.version, "1.0", file: file, line: line)
        host.unload(settled.id)
    }

    func testTurningOffDuringTrialCancels() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let staged = try makeProbe(version: "2.0")
        let current = markedRecord(current: try makeProbe(version: "1.0"), staged: staged)
        let library = library
        let trying = Task { @MainActor in await host.loadStagedUpdate(of: current, library: library) }
        await Task.yield()
        host.unload(current.id)
        let trial = await trying.value
        XCTAssertEqual(trial, .cancelled(folder: staged))
        XCTAssertTrue(host.loadedIDs.isEmpty, "an extension turned off during its trial must not start")
    }

    func testPlainLoadIgnoresStagedUpdate() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let host = WebExtensionHost(storageIdentifier: nil)
        let current = markedRecord(current: try makeProbe(version: "1.0"), staged: try makeProbe(version: "2.0"))
        try await host.load(current, library: library)
        XCTAssertEqual(host.details(for: current.id)?.version, "1.0")
        host.unload(current.id)
    }

    // MARK: - Data

    /// The new version runs under the old record's id, so it finds what the
    /// old one stored: through the storage API, in `localStorage` and in
    /// IndexedDB. This runs in one process. It proves the data is keyed by
    /// the record's id, not that it reaches disk across a relaunch; the
    /// by-hand pass covers that.
    func testDataSurvivesAVersionSwap() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let storeID = UUID()
        // Runs after the test whether or not it throws, once the host and its
        // pages are gone.
        addTeardownBlock { @MainActor [weak self] in await self?.removeStore(storeID) }
        // Persistent on purpose: a store that keeps nothing would lose the
        // data for the wrong reason. A fixed controller id, so runs reuse one
        // storage location instead of leaving a new one each time.
        let host = WebExtensionHost(storageIdentifier: Self.dataTestStorage, websiteDataStore: WKWebsiteDataStore(forIdentifier: storeID))
        let current = record(folder: try makeProbe(version: "1.0"))
        let control = record(folder: try makeProbe(version: "2.0"))
        do {
            try await swapVersions(current, control: control, host: host)
        } catch {
            await removeData(of: [current, control], host: host)
            throw error
        }
    }

    /// The controller storage the data test uses, and only it.
    private static let dataTestStorage = UUID(uuidString: "0D5A7A11-7E57-4C0D-9B1E-5A1D0C0FFEE0")!

    @available(macOS 15.4, *)
    private func removeData(of records: [WebExtensionRecord], host: WebExtensionHost) async {
        for record in records {
            _ = await host.removeStoredData(for: record, library: library)
            host.unload(record.id)
        }
    }

    @available(macOS 15.4, *)
    private func swapVersions(_ start: WebExtensionRecord, control: WebExtensionRecord, host: WebExtensionHost) async throws {
        let newFolder = try makeProbe(version: "2.0")
        let token = UUID().uuidString
        var current = start

        try await host.load(current, library: library)
        var page = try await openDataPage(current.id, host: host)
        let written = try await page.callAsyncJavaScript("return await writeToken(token)", arguments: ["token": token], contentWorld: .page) as? String
        XCTAssertEqual(written, "ok")
        page = WKWebView()
        host.unload(current.id)

        let update = try await host.reviewUpdate(folder: newFolder, version: "2.0", for: current, library: library)
        XCTAssertTrue(update.isReady)
        current = current.staging(update).startingUpdateAttempt()
        let trial = await host.loadStagedUpdate(of: current, library: library)
        XCTAssertEqual(trial, .updated(folder: newFolder, version: "2.0"))
        let settled = current.settling(trial)
        XCTAssertEqual(settled.source, .package(folder: newFolder))
        XCTAssertEqual(settled.id, current.id)
        XCTAssertEqual(host.details(for: settled.id)?.version, "2.0")

        page = try await openDataPage(settled.id, host: host)
        let read = try await page.callAsyncJavaScript("return await readAll()", contentWorld: .page) as? String
        XCTAssertEqual(object(read), ["storage": token, "local": token, "idb": token, "version": "2.0"], read ?? "nil")

        try await host.load(control, library: library)
        let controlPage = try await openDataPage(control.id, host: host)
        let controlRead = try await controlPage.callAsyncJavaScript("return await readAll()", contentWorld: .page) as? String
        XCTAssertEqual(object(controlRead), ["storage": NSNull(), "local": NSNull(), "idb": NSNull(), "version": "2.0"],
                       "another record id sees none of it: \(controlRead ?? "nil")")

        await removeData(of: [settled, control], host: host)
    }

    /// Removes the test's website data store once the host and its pages are
    /// gone. WebKit refuses while anything still holds the store, and lets
    /// go of it a moment after the last page closes. Main actor on purpose:
    /// removal off the main thread crashes.
    private func removeStore(_ id: UUID) async {
        var lastError: Error?
        for _ in 0..<20 {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        print("Test store \(id) not removed: \(lastError?.localizedDescription ?? "unknown")")
    }

    @available(macOS 15.4, *)
    private func openDataPage(_ id: UUID, host: WebExtensionHost) async throws -> WKWebView {
        let context = try XCTUnwrap(host.contexts[id])
        let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        page.load(URLRequest(url: context.baseURL.appending(path: "data.html")))
        let ready = try await poll(page, "location.href.endsWith('data.html') && document.readyState === 'complete' ? window.probeReady : null")
        XCTAssertEqual(ready, "yes", "the extension page loaded")
        return page
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
