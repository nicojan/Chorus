import WebKit
import XCTest
@testable import ChorusEngine

/// What `runtime.onInstalled` and `runtime.onStartup` tell an extension in
/// Chorus, read from WebKit's `determineInstallReasonDuringLoad`:
///
/// - A changed version gets "update" with the previous version, at any time.
///   Chorus keeps a record's id across a swap, so the new version is the same
///   extension to WebKit.
/// - For 5 s after a `WKWebExtensionController` is created
///   (`freshlyCreatedTimeout`), every load counts as the browser starting and
///   gets `onStartup`; a new extension then gets no "install".
/// - After those 5 s, a load whose version did not change gets "install",
///   even for an extension installed long ago, and no `onStartup`.
///
/// Each host made on the test's storage stands for one app launch. Package
/// folders have no code signature, so WebKit's bundle hash check, the other
/// way to an "update", never applies to them.
@MainActor
final class WebExtensionInstallEventTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-installed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    /// A probe whose background appends every `runtime.onInstalled` and
    /// `runtime.onStartup` it gets to `events` in `chrome.storage.local`, and
    /// whose `events.html` page reads them back.
    private func makeProbe(version: String) throws -> String {
        let folder = root.appending(path: "probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Installed Probe", "description": "Records install events.",
            "version": version, "permissions": ["storage"],
            "background": ["service_worker": "bg.js"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "manifest.json"))
        // Registered at the top level, as Chrome requires, so no event is
        // missed while the worker starts. One promise chain keeps the events
        // in the order they came; a failed save is saved as an event too, so
        // it shows in the test's message instead of stopping the chain.
        try Data("""
        let saving = Promise.resolve();
        const save = (event) => {
          saving = saving.then(async () => {
            const stored = await chrome.storage.local.get('events');
            await chrome.storage.local.set({events: [...(stored.events ?? []), event]});
          }).catch((error) => {
            saving = Promise.resolve();
            save({reason: 'error: ' + error, previous: null, version: 'none'});
          });
        };
        const version = chrome.runtime.getManifest().version;
        chrome.runtime.onInstalled.addListener((details) => {
          save({reason: details.reason, previous: details.previousVersion ?? null, version});
        });
        chrome.runtime.onStartup.addListener(() => save({reason: 'startup', previous: null, version}));
        """.utf8).write(to: folder.appending(path: "bg.js"))
        try Data(#"<!doctype html><html><head><script src="events.js"></script></head><body></body></html>"#.utf8)
            .write(to: folder.appending(path: "events.html"))
        try Data("""
        window.readEvents = async () => JSON.stringify((await chrome.storage.local.get('events')).events ?? []);
        window.probeReady = 'yes';
        """.utf8).write(to: folder.appending(path: "events.js"))
        return try library.importPackage(from: folder)
    }

    /// The id must stay random: the test's storage outlives each run, and a
    /// fixed id would find the last run's version there.
    private func record(folder: String, version: String) -> WebExtensionRecord {
        WebExtensionRecord(source: .package(folder: folder), name: "Installed Probe",
                           grantedPermissions: ["storage"], grantedMatchPatterns: [],
                           catalogID: "installed-probe", installedVersion: version)
    }

    /// The controller storage these tests use, and only they. WebKit keeps the
    /// version it last saw for each extension there, so each host made on it
    /// is a relaunch of the same app.
    private static let storage = UUID(uuidString: "1A57A11E-D0E5-4B1E-8E2A-0C0FFEE00002")!

    private static func startup(_ version: String) -> Event { Event(reason: "startup", previous: nil, version: version) }

    /// Three launches. The first loads 1.0; the second swaps in 2.0, which
    /// hears "update" from 1.0; the third loads 2.0 again and hears no
    /// second "update". Each load comes right after its host is made, as a
    /// swap does at launch.
    func testSwapAtLaunchSendsUpdateWithThePreviousVersion() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let storeID = UUID()
        addTeardownBlock { @MainActor [weak self] in await self?.removeStore(storeID) }
        let first = record(folder: try makeProbe(version: "1.0"), version: "1.0")
        let cleanUp = fallbackCleanUp(of: first, storeID: storeID)
        let startupWindow = "WebKit counts a load within 5 s of making the controller as a startup (freshlyCreatedTimeout)"

        var launch = launchHost(storeID)
        try await launch.load(first, library: library)
        let firstEvents = try await settledEvents(of: first.id, host: launch, atLeast: 1)
        XCTAssertEqual(firstEvents, [Self.startup("1.0")], startupWindow)
        launch.unload(first.id)

        // Reviewed before the next launch, as the daily check does.
        let newFolder = try makeProbe(version: "2.0")
        let update = try await launchHost(storeID).reviewUpdate(folder: newFolder, version: "2.0", for: first, library: library)
        let trying = first.staging(update).startingUpdateAttempt()
        launch = launchHost(storeID)
        let trial = await launch.loadStagedUpdate(of: trying, library: library)
        XCTAssertEqual(trial, .updated(folder: newFolder, version: "2.0"))
        let settled = trying.settling(trial)
        let swapEvents = try await settledEvents(of: settled.id, host: launch, atLeast: 3)
        let swapUpdate = Event(reason: "update", previous: "1.0", version: "2.0")
        XCTAssertEqual(swapEvents.filter { $0.reason == "update" }, [swapUpdate], "all events: \(swapEvents)")
        XCTAssertEqual(swapEvents, [Self.startup("1.0"), Self.startup("2.0"), swapUpdate], startupWindow)
        launch.unload(settled.id)

        launch = launchHost(storeID)
        try await launch.load(settled, library: library)
        let againEvents = try await settledEvents(of: settled.id, host: launch, atLeast: 4)
        XCTAssertEqual(againEvents.filter { $0.reason == "update" }, [swapUpdate],
                       "an unchanged version is no update: \(againEvents)")
        XCTAssertEqual(againEvents.dropFirst(3), [Self.startup("2.0")], startupWindow)

        await removeData(of: settled, host: launch, cleanUp: cleanUp)
    }

    /// Past the 5 s, WebKit sends "install" for an unchanged version, though
    /// the extension was installed at the launch before. Chorus starts every
    /// extension together at launch, but one turned off and on loads again
    /// after the 5 s and hears "install" again. (The old version reloaded
    /// after a rollback also loads late; with its storage on disk it hears
    /// "update" from the failed version.) If this fails because
    /// WebKit sends nothing or `onStartup`, it changed this behaviour.
    func testUnchangedVersionLoadedAfterStartupWindowHearsInstall() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let storeID = UUID()
        addTeardownBlock { @MainActor [weak self] in await self?.removeStore(storeID) }
        let current = record(folder: try makeProbe(version: "1.0"), version: "1.0")
        let cleanUp = fallbackCleanUp(of: current, storeID: storeID)

        var launch = launchHost(storeID)
        try await launch.load(current, library: library)
        let firstEvents = try await settledEvents(of: current.id, host: launch, atLeast: 1)
        XCTAssertEqual(firstEvents.count, 1, "all events: \(firstEvents)")
        launch.unload(current.id)

        launch = launchHost(storeID)
        try await Task.sleep(for: .seconds(6))
        try await launch.load(current, library: library)
        let events = try await settledEvents(of: current.id, host: launch, atLeast: 2)
        XCTAssertEqual(events.dropFirst(), [Event(reason: "install", previous: nil, version: "1.0")], "all events: \(events)")

        await removeData(of: current, host: launch, cleanUp: cleanUp)
    }

    /// A new controller on the test's storage, as at an app launch.
    @available(macOS 15.4, *)
    private func launchHost(_ storeID: UUID) -> WebExtensionHost {
        WebExtensionHost(storageIdentifier: Self.storage, websiteDataStore: WKWebsiteDataStore(forIdentifier: storeID))
    }

    private struct Event: Decodable, Equatable {
        let reason: String
        let previous: String?
        let version: String
    }

    /// Reads the probe's saved events from its own page once at least
    /// `atLeast` have arrived and two reads a second apart agree, so a later
    /// event still on its way is not missed. Fails the test, naming the last
    /// script error, when they never settle.
    @available(macOS 15.4, *)
    private func settledEvents(of id: UUID, host: WebExtensionHost, atLeast count: Int,
                               file: StaticString = #filePath, line: UInt = #line) async throws -> [Event] {
        let context = try XCTUnwrap(host.contexts[id], file: file, line: line)
        let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration, file: file, line: line))
        page.load(URLRequest(url: context.baseURL.appending(path: "events.html")))
        let deadline = Date().addingTimeInterval(15)
        var previous: [Event]?
        var lastRead: [Event] = []
        var lastError: Error?
        while Date() < deadline {
            do {
                let json = try await page.callAsyncJavaScript(
                    "return window.probeReady === 'yes' && location.href.endsWith('events.html') ? await readEvents() : null",
                    contentWorld: .page
                ) as? String
                if let json {
                    let found = try JSONDecoder().decode([Event].self, from: Data(json.utf8))
                    lastRead = found
                    if found.count >= count, found == previous { return found }
                    previous = found.count >= count ? found : nil
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: previous == nil ? .milliseconds(200) : .seconds(1))
        }
        XCTFail("events never settled at \(count) or more; last read \(lastRead), last error \(String(describing: lastError))",
                file: file, line: line)
        return lastRead
    }

    /// Deletes what the probe stored through the host still running it, so
    /// no new background starts for the removal.
    @available(macOS 15.4, *)
    private func removeData(of record: WebExtensionRecord, host: WebExtensionHost, cleanUp: CleanUp) async {
        let reached = await host.removeStoredData(for: record, library: library)
        XCTAssertTrue(reached, "the probe's stored data was not reached")
        host.unload(record.id)
        cleanUp.isDone = true
    }

    /// Set once the test removed its data itself.
    private final class CleanUp {
        var isDone = false
    }

    /// A fallback for a test that stops early: removes the record's data
    /// through a host of its own after the test. The data is keyed by the
    /// record's id, so any of its versions reaches it.
    private func fallbackCleanUp(of record: WebExtensionRecord, storeID: UUID) -> CleanUp {
        let cleanUp = CleanUp()
        let library = library
        addTeardownBlock { @MainActor [weak self] in
            guard #available(macOS 15.4, *), let self, !cleanUp.isDone else { return }
            let reached = await self.launchHost(storeID).removeStoredData(for: record, library: library)
            if !reached { print("Probe data for \(record.id) not removed") }
        }
        return cleanUp
    }

    /// Removes the test's website data store once the host and its pages are
    /// gone; WebKit refuses while anything still holds it. Main actor on
    /// purpose: removal off the main thread crashes. WebKit keeps one small
    /// state file per extension id in the test's storage, which nothing here
    /// deletes.
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
}
