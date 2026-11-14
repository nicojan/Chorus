import XCTest
import WebKit
@testable import Chorus
@testable import ChorusEngine

/// Adding, switching off and removing extensions through the app's manager,
/// against a library in a temporary folder.
@MainActor
final class ExtensionManagerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-manager-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        setLibraryWritable(true)
        try? FileManager.default.removeItem(at: root)
    }

    /// A library folder the list cannot be saved into, so a save fails.
    private func setLibraryWritable(_ writable: Bool) {
        try? FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555],
                                               ofItemAtPath: library.directory.path)
    }

    private func makeManager() -> ExtensionManager {
        ExtensionManager(
            library: WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory)),
            storageIdentifier: nil
        )
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    private func makeExtensionFolder(permissions: [String] = ["storage"], version: String = "2.1",
                                     background: Bool = false) throws -> URL {
        let folder = root.appending(path: "ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let worker = background ? #", "background": {"service_worker": "bg.js"}"# : ""
        let manifest = #"{"manifest_version": 3, "name": "Probe", "version": "\#(version)", "permissions": [\#(list)], "action": {}\#(worker)}"#
        try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
        if background {
            try Data("self.started = true;".utf8).write(to: folder.appending(path: "bg.js"))
        }
        return folder
    }

    func testAddSwitchOffAndRemove() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let manager = makeManager()
        XCTAssertFalse(manager.host?.isActive ?? true, "no extensions, no controller on pages")

        let source = try await manager.importPackage(at: makeExtensionFolder(permissions: ["storage", "nativeMessaging"]))
        let summary = try await manager.inspect(source)
        XCTAssertTrue(summary.needsNativeApp)
        let record = await manager.add(source, summary: summary)

        XCTAssertEqual(record.grantedPermissions, ["storage"], "talking to the Mac app is never granted")
        XCTAssertTrue(manager.isRunning(record.id))
        XCTAssertTrue(manager.host?.isActive ?? false)
        XCTAssertTrue(manager.needsRestart, "pages built before the first extension need a restart")
        XCTAssertEqual(makeManager().records.map(\.id), [record.id], "the list is saved")

        await manager.setEnabled(record.id, false)
        XCTAssertFalse(manager.isRunning(record.id))
        XCTAssertEqual(makeManager().records.first?.isEnabled, false)

        guard case .package(let folder) = source else { return XCTFail("expected a package") }
        let packageURL = manager.library.packageURL(folder: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
        await manager.remove(record.id)
        XCTAssertTrue(manager.records.isEmpty)
        XCTAssertFalse(manager.isRunning(record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path), "the copied files go with it")
        XCTAssertTrue(makeManager().records.isEmpty)
    }

    func testDiscardDropsAPackageNobodyAdded() async throws {
        let manager = makeManager()
        let source = try await manager.importPackage(at: makeExtensionFolder())
        guard case .package(let folder) = source else { return XCTFail("expected a package") }
        manager.discard(source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.library.packageURL(folder: folder).path))
    }

    func testAMissingSafariExtensionShowsWhy() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let library = WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
        let gone = WebExtensionRecord(
            source: .appExtension(path: root.appending(path: "Gone.app/Contents/PlugIns/Gone.appex").path),
            name: "Gone", grantedPermissions: [], grantedMatchPatterns: []
        )
        try library.saveRecords([gone])
        let manager = ExtensionManager(library: library, storageIdentifier: nil)
        await manager.startEnabled()
        XCTAssertFalse(manager.isRunning(gone.id))
        XCTAssertNotNil(manager.failures[gone.id], "Settings shows why it is not running")
    }

    func testDebugAndReleaseKeepSeparateLists() {
        XCTAssertTrue(ExtensionManager.defaultDirectory.path.contains("Chorus-debug"),
                      "tests run Debug, which must never read the release list")
    }

    // MARK: - Staged updates

    /// A package in the library, as a folder name. It has a background, so a
    /// test can hold a load at the background start with a `BackgroundGate`.
    private func makePackage(version: String) throws -> String {
        try library.importPackage(from: makeExtensionFolder(version: version, background: true))
    }

    private func exists(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: library.packageURL(folder: folder).path)
    }

    /// A catalog record running `current` at 1.0, with `staged` waiting as
    /// 2.0 and asking for nothing new, saved to the library.
    private func saveStagedRecord(current: String, staged: String, newPermissions: [String] = []) throws -> WebExtensionRecord {
        let record = WebExtensionRecord(
            source: .package(folder: current), name: "Probe",
            grantedPermissions: ["storage"], grantedMatchPatterns: [],
            catalogID: "probe", installedVersion: "1.0"
        ).staging(.init(folder: staged, version: "2.0", newPermissions: newPermissions, newMatchPatterns: [],
                        isApproved: !newPermissions.isEmpty))
        try library.saveRecords([record])
        return record
    }

    /// The list as saved, read without a second manager: a manager's launch
    /// sweep would delete folders and hide whether the first one did.
    private var savedRecord: WebExtensionRecord? { library.loadRecords().first }

    /// Starts `manager`'s launch in a task and returns once its trial is held
    /// at the background start by `gate`, with the attempt marker saved.
    @available(macOS 15.4, *)
    private func startTrial(_ manager: ExtensionManager, gate: BackgroundGate, file: StaticString = #filePath,
                            line: UInt = #line) async throws -> Task<Void, Never> {
        let host = try XCTUnwrap(manager.host, file: file, line: line)
        gate.install(on: host)
        let starting = Task { @MainActor in await manager.startEnabled() }
        let deadline = Date().addingTimeInterval(5)
        while gate.starts == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(gate.starts, 1, "precondition: the trial reached its background", file: file, line: line)
        XCTAssertEqual(manager.records.first?.stagedUpdate?.attempts, 1,
                       "precondition: the trial began and has not settled", file: file, line: line)
        return starting
    }

    func testInitKeepsStagedFolder() throws {
        let current = try makePackage(version: "1.0")
        let staged = try makePackage(version: "2.0")
        let stray = try makePackage(version: "3.0")
        _ = try saveStagedRecord(current: current, staged: staged)
        _ = makeManager()
        XCTAssertTrue(exists(current))
        XCTAssertTrue(exists(staged), "the launch sweep keeps a staged update's folder")
        XCTAssertFalse(exists(stray), "a folder no record names still goes")
    }

    func testRemoveDeletesCurrentAndStagedFolders() async throws {
        let current = try makePackage(version: "1.0")
        let staged = try makePackage(version: "2.0")
        let record = try saveStagedRecord(current: current, staged: staged)
        let manager = makeManager()
        XCTAssertTrue(exists(staged), "precondition: launch kept the staged folder")
        await manager.remove(record.id)
        XCTAssertFalse(exists(current))
        XCTAssertFalse(exists(staged), "the staged folder goes with the extension")
        XCTAssertTrue(makeManager().records.isEmpty)
    }

    func testDiscardRefusesStagedFolder() throws {
        let current = try makePackage(version: "1.0")
        let staged = try makePackage(version: "2.0")
        _ = try saveStagedRecord(current: current, staged: staged)
        let manager = makeManager()
        manager.discard(.package(folder: staged))
        manager.discard(.package(folder: current))
        XCTAssertTrue(exists(staged), "a record's staged folder is not a leftover")
        XCTAssertTrue(exists(current))
    }

    func testStartAppliesReadyUpdate() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let current = try makePackage(version: "1.0")
        let staged = try makePackage(version: "2.0")
        let record = try saveStagedRecord(current: current, staged: staged)
        let manager = makeManager()
        await manager.startEnabled()

        let saved = try XCTUnwrap(savedRecord)
        XCTAssertEqual(saved.id, record.id)
        XCTAssertEqual(saved.source, .package(folder: staged), "the saved list names the new folder")
        XCTAssertEqual(saved.installedVersion, "2.0")
        XCTAssertNil(saved.stagedUpdate)
        XCTAssertFalse(exists(current), "the old folder goes once the list is saved")
        XCTAssertTrue(exists(staged))
        XCTAssertTrue(manager.isRunning(record.id))
        XCTAssertEqual(manager.host?.details(for: record.id)?.version, "2.0")
        XCTAssertNil(manager.failures[record.id])
    }

    func testStartRollsBackBrokenUpdate() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let current = try makePackage(version: "1.0")
        let staged = try makePackage(version: "2.0")
        try Data("{ not json".utf8).write(to: library.packageURL(folder: staged).appending(path: "manifest.json"))
        let record = try saveStagedRecord(current: current, staged: staged)
        let manager = makeManager()
        await manager.startEnabled()

        let saved = try XCTUnwrap(savedRecord)
        XCTAssertEqual(saved.source, .package(folder: current))
        XCTAssertEqual(saved.installedVersion, "1.0")
        XCTAssertEqual(saved.skippedVersion, "2.0", "a failed version is not offered again")
        XCTAssertNil(saved.stagedUpdate)
        XCTAssertFalse(exists(staged), "the broken folder goes once the list is saved")
        XCTAssertTrue(exists(current))
        XCTAssertTrue(manager.isRunning(record.id), "the old version runs instead")
        XCTAssertEqual(manager.host?.details(for: record.id)?.version, "1.0")
        XCTAssertNil(manager.failures[record.id])
    }

    /// Write 1 must reach disk before the trial: a version that crashes the
    /// app at load would otherwise crash it at every launch.
    func testFailedMarkerSaveSkipsTrial() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let current = try makePackage(version: "1.0")
        let staged = try makePackage(version: "2.0")
        let record = try saveStagedRecord(current: current, staged: staged)
        let manager = makeManager()
        setLibraryWritable(false)
        await manager.startEnabled()
        setLibraryWritable(true)

        XCTAssertEqual(manager.host?.details(for: record.id)?.version, "1.0", "no trial without a saved marker")
        XCTAssertEqual(manager.records.first?.stagedUpdate?.attempts, 0, "memory keeps what the disk holds")
        XCTAssertEqual(savedRecord?.stagedUpdate?.attempts, 0)
        XCTAssertTrue(exists(current))
        XCTAssertTrue(exists(staged))
    }

    /// A result that does not save deletes no folder, and the list in memory
    /// stays the one on disk; the next launch retries.
    func testFailedResultSaveKeepsFolders() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let current = try makePackage(version: "1.0")
        let staged = try makePackage(version: "2.0")
        let record = try saveStagedRecord(current: current, staged: staged)
        let manager = makeManager()
        let gate = BackgroundGate()
        let starting = try await startTrial(manager, gate: gate)
        setLibraryWritable(false)
        gate.open()
        await starting.value
        setLibraryWritable(true)

        XCTAssertEqual(manager.host?.details(for: record.id)?.version, "2.0", "the new version runs")
        XCTAssertTrue(exists(current), "the old folder stays while the saved list names it")
        XCTAssertTrue(exists(staged))
        XCTAssertEqual(savedRecord?.source, .package(folder: current))
        XCTAssertEqual(savedRecord?.stagedUpdate?.attempts, 1)
        XCTAssertEqual(manager.records.first, savedRecord, "memory keeps what the disk holds")
    }

    /// Turning the extension off during its trial cancels it, and then
    /// nothing loads: not the new version, and not the old one either.
    func testTurningOffDuringTrialLoadsNothing() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let current = try makePackage(version: "1.0")
        let staged = try makePackage(version: "2.0")
        let record = try saveStagedRecord(current: current, staged: staged)
        let manager = makeManager()
        let gate = BackgroundGate()
        let starting = try await startTrial(manager, gate: gate)
        await manager.setEnabled(record.id, false)
        await starting.value
        gate.open()

        XCTAssertEqual(gate.starts, 1, "the old version was not loaded after the cancelled trial")
        XCTAssertFalse(manager.isRunning(record.id))
        XCTAssertTrue(manager.failures.isEmpty)
        XCTAssertEqual(savedRecord?.isEnabled, false, "the result lands on the current record, which is off")
        XCTAssertEqual(savedRecord?.stagedUpdate?.attempts, 0, "a cancelled trial is taken back")
        XCTAssertTrue(exists(staged))
    }

    /// A second start for an id whose trial is running finds the host busy.
    /// It must take back the attempt it saved, or the count drifts up until
    /// a healthy version is rolled back as crashing.
    func testOverlappingStartKeepsAttemptCount() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let record = try saveStagedRecord(current: try makePackage(version: "1.0"), staged: try makePackage(version: "2.0"))
        let manager = makeManager()
        let gate = BackgroundGate()
        let starting = try await startTrial(manager, gate: gate)
        await manager.startEnabled()
        XCTAssertEqual(savedRecord?.stagedUpdate?.attempts, 1, "one trial running, one attempt saved")
        await manager.setEnabled(record.id, false)
        await starting.value
        gate.open()
        XCTAssertEqual(savedRecord?.stagedUpdate?.attempts, 0)
    }

    /// A grant the new version gave up during its trial stays given up once
    /// the update lands, rather than coming back as one of its new asks.
    func testGrantDroppedDuringTrialStaysDropped() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let staged = try makePackage(version: "2.0")
        let record = try saveStagedRecord(current: try makePackage(version: "1.0"), staged: staged, newPermissions: ["tabs"])
        let manager = makeManager()
        let gate = BackgroundGate()
        let starting = try await startTrial(manager, gate: gate)
        manager.updateGrants(record.id, permissions: ["storage"], matchPatterns: [])
        gate.open()
        await starting.value

        XCTAssertEqual(savedRecord?.source, .package(folder: staged))
        XCTAssertEqual(savedRecord?.grantedPermissions, ["storage"])
        XCTAssertEqual(manager.records.first?.grantedPermissions, ["storage"])
    }

    /// Grants the candidate gained during a trial that rolled back are not
    /// kept for the old version, which never asked for them.
    func testGrantGainedDuringFailedTrialIsDropped() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let staged = try makePackage(version: "2.0")
        let record = try saveStagedRecord(current: try makePackage(version: "1.0"), staged: staged, newPermissions: ["tabs"])
        let manager = makeManager()
        let gate = BackgroundGate()
        let starting = try await startTrial(manager, gate: gate)
        manager.updateGrants(record.id, permissions: ["storage", "tabs"], matchPatterns: [])
        gate.open(failing: NSError(domain: "ChorusTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        await starting.value

        XCTAssertEqual(savedRecord?.skippedVersion, "2.0", "precondition: the trial rolled back")
        XCTAssertEqual(savedRecord?.grantedPermissions, ["storage"])
        XCTAssertEqual(manager.records.first?.grantedPermissions, ["storage"])
        // A failed background unloads the new version, and the same id then
        // loads the old one.
        XCTAssertEqual(manager.host?.details(for: record.id)?.version, "1.0")
        XCTAssertFalse(exists(staged))
        XCTAssertNil(manager.failures[record.id])
    }

    /// A staged folder gone from disk (an older Chorus swept it, or someone
    /// deleted it) drops the update at launch without skipping its version.
    func testInitDropsStagedUpdateWhoseFolderIsGone() async throws {
        let current = try makePackage(version: "1.0")
        _ = try saveStagedRecord(current: current, staged: UUID().uuidString)
        let manager = makeManager()
        XCTAssertNil(manager.records.first?.stagedUpdate)
        XCTAssertNil(manager.records.first?.skippedVersion, "nothing was wrong with that version")
        XCTAssertNil(savedRecord?.stagedUpdate, "the fixed list is saved")
        XCTAssertNil(savedRecord?.skippedVersion)
        XCTAssertTrue(exists(current))
    }
}

/// Holds every extension background start until the test opens it, through
/// the host's test seam. Once open, it lets later starts through at once,
/// with the same result.
@available(macOS 15.4, *)
@MainActor
private final class BackgroundGate {
    private(set) var starts = 0
    private var waiting: [CheckedContinuation<Void, Error>] = []
    private var result: Result<Void, Error>?

    func install(on host: WebExtensionHost) {
        host.startBackgroundContent = { [self] _ in try await self.pass() }
    }

    func open(failing failure: Error? = nil) {
        let outcome: Result<Void, Error> = failure.map { .failure($0) } ?? .success(())
        result = outcome
        let held = waiting
        waiting = []
        held.forEach { $0.resume(with: outcome) }
    }

    private func pass() async throws {
        starts += 1
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { waiting.append($0) }
    }
}
