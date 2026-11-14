import XCTest
@testable import Chorus
@testable import ChorusEngine

/// The manager's side of catalog updates: adding with catalog fields, staging
/// a reviewed download, and the user's answer to one that needs an OK. Every
/// test checks that a download is either named by the saved list or deleted.
@MainActor
final class ExtensionStagingTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        setLibraryWritable(true)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    private func makeManager() -> ExtensionManager {
        ExtensionManager(library: library, storageIdentifier: nil)
    }

    /// A library folder the list cannot be saved into. Packages, one level
    /// down, stays writable.
    private func setLibraryWritable(_ writable: Bool) {
        try? FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555],
                                               ofItemAtPath: library.directory.path)
    }

    private func makePackage(version: String, permissions: [String] = ["storage"]) throws -> String {
        try library.importPackage(from: ExtensionFixtures.folder(in: root, version: version, permissions: permissions,
                                                                 background: true))
    }

    private func exists(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: library.packageURL(folder: folder).path)
    }

    private var savedRecord: WebExtensionRecord? { library.loadRecords().first }

    private func release(_ version: String) -> WebExtensionRelease {
        WebExtensionRelease(version: version, downloadURL: URL(string: ExtensionFixtures.amoDownloadURL(file: 1))!,
                            sha256: String(repeating: "0", count: 64))
    }

    private func update(_ folder: String, _ version: String, asks: [String] = [],
                        approved: Bool = false) -> WebExtensionRecord.StagedUpdate {
        .init(folder: folder, version: version, newPermissions: asks, newMatchPatterns: [], isApproved: approved)
    }

    /// A catalog record at `installed`, optionally with an update staged and
    /// a version skipped, saved to the library.
    @discardableResult
    private func saveCatalogRecord(current: String, installed: String = "1.0",
                                   staged: WebExtensionRecord.StagedUpdate? = nil,
                                   skipped: String? = nil, catalogID: String? = "probe",
                                   grants: [String] = ["storage"]) throws -> WebExtensionRecord {
        let record = WebExtensionRecord(
            id: UUID(), source: .package(folder: current), name: "Probe", isEnabled: true,
            grantedPermissions: grants, grantedMatchPatterns: [], addedAt: Date(),
            catalogID: catalogID, installedVersion: installed, stagedUpdate: staged, skippedVersion: skipped
        )
        try library.saveRecords([record])
        // As read back: the saved date drops its fraction of a second.
        return try XCTUnwrap(library.loadRecords().first)
    }

    private func summary(_ permissions: [String] = ["storage"]) -> WebExtensionSummary {
        WebExtensionSummary(name: "Probe", version: "1.0", summary: nil, icon: nil, permissions: permissions,
                            matchPatterns: [], needsNativeApp: false, problems: [])
    }

    /// Starts `manager`'s launch in a task and returns once its first start
    /// is held at the background start by `gate`.
    @available(macOS 15.4, *)
    private func holdStart(_ manager: ExtensionManager, gate: BackgroundGate) async throws -> Task<Void, Never> {
        gate.install(on: try XCTUnwrap(manager.host))
        let starting = Task { @MainActor in await manager.startEnabled() }
        try await gate.waitForStarts(1)
        XCTAssertEqual(gate.starts, 1, "precondition: the start reached its background")
        return starting
    }

    // MARK: - Adding

    func testAddKeepsCatalogIDAndVersion() async throws {
        let manager = makeManager()
        let source = try await manager.importPackage(at: ExtensionFixtures.folder(in: root, version: "1.0"))
        let record = await manager.add(source, summary: summary(), catalogID: "probe", installedVersion: "1.0")
        XCTAssertEqual(record?.catalogID, "probe")
        XCTAssertEqual(savedRecord?.catalogID, "probe")
        XCTAssertEqual(savedRecord?.installedVersion, "1.0")
        XCTAssertTrue(manager.isAdded(catalogID: "probe"))
    }

    func testSecondAddOfSameEntryDiscardsTheCopy() async throws {
        let manager = makeManager()
        let first = try await manager.importPackage(at: ExtensionFixtures.folder(in: root, version: "1.0"))
        let added = await manager.add(first, summary: summary(), catalogID: "probe", installedVersion: "1.0")
        let second = try await manager.importPackage(at: ExtensionFixtures.folder(in: root, version: "1.0"))
        let again = await manager.add(second, summary: summary(), catalogID: "probe", installedVersion: "1.0")

        XCTAssertEqual(again?.id, try XCTUnwrap(added).id, "the existing record comes back")
        XCTAssertEqual(manager.records.count, 1)
        XCTAssertEqual(library.loadRecords().count, 1)
        guard case .package(let folder) = second, case .package(let kept) = first else { return XCTFail("packages") }
        XCTAssertFalse(exists(folder), "the second copy is deleted")
        XCTAssertTrue(exists(kept))
    }

    func testFailedSaveWhileAddingAddsNothing() async throws {
        let manager = makeManager()
        let source = try await manager.importPackage(at: ExtensionFixtures.folder(in: root, version: "1.0"))
        guard case .package(let folder) = source else { return XCTFail("expected a package") }
        setLibraryWritable(false)

        let added = await manager.add(source, summary: summary(), catalogID: "probe", installedVersion: "1.0")
        setLibraryWritable(true)

        XCTAssertNil(added, "the caller is told it failed")
        XCTAssertTrue(manager.records.isEmpty, "memory keeps what the disk holds")
        XCTAssertTrue(library.loadRecords().isEmpty)
        XCTAssertFalse(exists(folder), "the copy is discarded")
        XCTAssertFalse(manager.isBusy(UUID()))
        XCTAssertFalse(manager.needsRestart, "nothing was turned on")
        if #available(macOS 15.4, *) {
            XCTAssertFalse(manager.host?.isActive ?? true, "nothing started")
            XCTAssertTrue(manager.host?.loadedIDs.isEmpty ?? false)
        }
    }

    // MARK: - Staging

    func testStageSavesThenDeletesTheReplacedStagedFolder() throws {
        let current = try makePackage(version: "1.0")
        let old = try makePackage(version: "2.0")
        let record = try saveCatalogRecord(current: current, staged: update(old, "2.0"))
        let manager = makeManager()
        let new = try makePackage(version: "3.0")

        let outcome = manager.stage(update(new, "3.0"), of: release("3.0"), for: record.id)

        XCTAssertEqual(outcome, .staged(update(new, "3.0")))
        XCTAssertEqual(savedRecord?.stagedUpdate?.folder, new, "the saved list names the new folder")
        XCTAssertFalse(exists(old), "the replaced staged folder goes after the save")
        XCTAssertTrue(exists(new))
        XCTAssertTrue(exists(current))
    }

    func testStageRefusesAHandAddedRecord() throws {
        let current = try makePackage(version: "1.0")
        let record = try saveCatalogRecord(current: current, catalogID: nil)
        let manager = makeManager()
        let new = try makePackage(version: "3.0")

        XCTAssertEqual(manager.stage(update(new, "3.0"), of: release("3.0"), for: record.id), .discarded(.notCatalog))
        XCTAssertFalse(exists(new))
        XCTAssertNil(savedRecord?.stagedUpdate)
    }

    func testStageRefusesDuringATrial() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let staged = try makePackage(version: "2.0")
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"), staged: update(staged, "2.0"))
        let manager = makeManager()
        let gate = BackgroundGate()
        let starting = try await holdStart(manager, gate: gate)
        XCTAssertEqual(manager.records.first?.stagedUpdate?.attempts, 1, "precondition: the trial is running")
        let new = try makePackage(version: "3.0")

        let outcome = manager.stage(update(new, "3.0"), of: release("3.0"), for: record.id)

        XCTAssertEqual(outcome, .discarded(.busy))
        XCTAssertFalse(exists(new), "the refused download is deleted")
        XCTAssertTrue(exists(staged), "the folder the trial reads stays")
        XCTAssertEqual(manager.records.first?.stagedUpdate?.attempts, 1, "the trial's attempt is not reset")
        gate.open()
        await starting.value
    }

    func testStageRefusesDuringAPlainLoad() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"))
        let manager = makeManager()
        let gate = BackgroundGate()
        let starting = try await holdStart(manager, gate: gate)
        XCTAssertNil(manager.records.first?.stagedUpdate, "precondition: a plain load, not a trial")
        let new = try makePackage(version: "3.0")

        XCTAssertEqual(manager.stage(update(new, "3.0"), of: release("3.0"), for: record.id), .discarded(.busy))
        XCTAssertFalse(exists(new))
        gate.open()
        await starting.value
        XCTAssertFalse(manager.isBusy(record.id), "busy ends with the load")
    }

    /// WebKit's host loads one copy of an id at a time, so an overlapping
    /// second start finds it loading and ends at once, while the first is
    /// still held. A busy flag the second start's end cleared would let the
    /// update check restage under the first.
    func testOverlappingStartsKeepBusyUntilBothEnd() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"))
        let manager = makeManager()
        let gate = BackgroundGate()
        let starting = try await holdStart(manager, gate: gate)
        XCTAssertTrue(manager.isBusy(record.id))

        await manager.startEnabled()
        XCTAssertTrue(manager.isBusy(record.id), "the first start is still loading")

        gate.open()
        await starting.value
        XCTAssertFalse(manager.isBusy(record.id), "both starts ended")
    }

    func testStageRefusesRemovedRecord() throws {
        let manager = makeManager()
        let new = try makePackage(version: "3.0")
        XCTAssertEqual(manager.stage(update(new, "3.0"), of: release("3.0"), for: UUID()), .discarded(.gone))
        XCTAssertFalse(exists(new))
    }

    func testStageRefusesAVersionNoLongerWanted() throws {
        // Installed at the release's version.
        try assertNotWanted(installed: "3.0", staged: nil, skipped: nil, label: "installed")
        // A newer version already staged.
        try assertNotWanted(installed: "1.0", staged: "4.0", skipped: nil, label: "staged newer")
        // The user skipped this version.
        try assertNotWanted(installed: "1.0", staged: nil, skipped: "3.0", label: "skipped")
    }

    private func assertNotWanted(installed: String, staged: String?, skipped: String?, label: String,
                                 line: UInt = #line) throws {
        let current = try makePackage(version: installed)
        let stagedFolder = try staged.map { try makePackage(version: $0) }
        let record = try saveCatalogRecord(current: current, installed: installed,
                                           staged: pair(stagedFolder, staged).map { update($0, $1) }, skipped: skipped)
        let manager = makeManager()
        let new = try makePackage(version: "3.0")

        XCTAssertEqual(manager.stage(update(new, "3.0"), of: release("3.0"), for: record.id),
                       .discarded(.notWanted), label, line: line)
        XCTAssertFalse(exists(new), label, line: line)
        XCTAssertTrue(exists(current), label, line: line)
        if let stagedFolder { XCTAssertTrue(exists(stagedFolder), label, line: line) }
        XCTAssertEqual(savedRecord, record, label, line: line)
    }

    private func pair(_ a: String?, _ b: String?) -> (String, String)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    func testFailedSaveWhileStagingDeletesTheDownload() throws {
        let current = try makePackage(version: "1.0")
        let old = try makePackage(version: "2.0")
        let record = try saveCatalogRecord(current: current, staged: update(old, "2.0"))
        let manager = makeManager()
        let new = try makePackage(version: "3.0")
        setLibraryWritable(false)

        let outcome = manager.stage(update(new, "3.0"), of: release("3.0"), for: record.id)
        setLibraryWritable(true)

        XCTAssertEqual(outcome, .discarded(.saveFailed))
        XCTAssertFalse(exists(new), "the download nobody names is deleted")
        XCTAssertTrue(exists(old))
        XCTAssertTrue(exists(current))
        XCTAssertEqual(manager.records.first, record, "memory keeps what the disk holds")
        XCTAssertEqual(savedRecord, record)
    }

    /// The trial landed but its result did not save: the new version runs
    /// from the staged folder while the list still names it only as staged.
    /// Restaging would delete that folder, so the record stays busy.
    func testUnsavedTrialResultKeepsTheRecordBusy() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let staged = try makePackage(version: "2.0")
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"), staged: update(staged, "2.0"))
        let manager = makeManager()
        let gate = BackgroundGate()
        let starting = try await holdStart(manager, gate: gate)
        setLibraryWritable(false)
        gate.open()
        await starting.value
        setLibraryWritable(true)
        XCTAssertEqual(manager.host?.details(for: record.id)?.version, "2.0", "precondition: the new version runs")
        XCTAssertEqual(savedRecord?.stagedUpdate?.folder, staged, "precondition: the result did not save")

        XCTAssertNil(manager.lastTrials[record.id], "the row does not claim an update that did not save")
        XCTAssertTrue(manager.isBusy(record.id))
        let new = try makePackage(version: "3.0")
        XCTAssertEqual(manager.stage(update(new, "3.0"), of: release("3.0"), for: record.id), .discarded(.busy))
        XCTAssertTrue(exists(staged), "the folder the running version uses stays")
        XCTAssertFalse(exists(new))
    }

    // MARK: - Approval

    func testApprovalCarriesToANewerUpdateWithTheSameAsks() throws {
        let old = try makePackage(version: "2.0")
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"),
                                           staged: update(old, "2.0", asks: ["tabs"], approved: true))
        let manager = makeManager()
        let new = try makePackage(version: "3.0")

        let outcome = manager.stage(update(new, "3.0", asks: ["tabs"]), of: release("3.0"), for: record.id)

        XCTAssertEqual(outcome, .staged(update(new, "3.0", asks: ["tabs"], approved: true)))
        XCTAssertEqual(savedRecord?.stagedUpdate?.isReady, true)
    }

    func testANewerUpdateAskingMoreNeedsOKAgain() throws {
        let old = try makePackage(version: "2.0")
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"),
                                           staged: update(old, "2.0", asks: ["tabs"], approved: true))
        let manager = makeManager()
        let new = try makePackage(version: "3.0")

        let outcome = manager.stage(update(new, "3.0", asks: ["history", "tabs"]), of: release("3.0"), for: record.id)

        XCTAssertEqual(outcome, .staged(update(new, "3.0", asks: ["history", "tabs"])))
        XCTAssertEqual(savedRecord?.stagedUpdate?.isReady, false)
    }

    func testApproveWithAStaleFolderDoesNothing() throws {
        let staged = try makePackage(version: "2.0")
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"),
                                           staged: update(staged, "2.0", asks: ["tabs"]))
        let manager = makeManager()

        XCTAssertFalse(manager.approveStagedUpdate(of: record.id, folder: UUID().uuidString))
        XCTAssertFalse(manager.skipStagedUpdate(of: record.id, folder: UUID().uuidString))
        XCTAssertEqual(savedRecord, record)
        XCTAssertTrue(exists(staged))

        XCTAssertTrue(manager.approveStagedUpdate(of: record.id, folder: staged))
        XCTAssertEqual(savedRecord?.stagedUpdate?.isApproved, true)
    }

    func testApproveOrSkipOfAReadyUpdateDoesNothing() throws {
        let staged = try makePackage(version: "2.0")
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"), staged: update(staged, "2.0"))
        let manager = makeManager()

        XCTAssertFalse(manager.approveStagedUpdate(of: record.id, folder: staged))
        XCTAssertFalse(manager.skipStagedUpdate(of: record.id, folder: staged))
        XCTAssertEqual(savedRecord, record)
        XCTAssertTrue(exists(staged))
    }

    func testSkipRemembersTheVersionAndDeletesTheFolderAfterTheSave() throws {
        let staged = try makePackage(version: "2.0")
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"),
                                           staged: update(staged, "2.0", asks: ["tabs"]))
        let manager = makeManager()

        XCTAssertTrue(manager.skipStagedUpdate(of: record.id, folder: staged))
        XCTAssertNil(savedRecord?.stagedUpdate)
        XCTAssertEqual(savedRecord?.skippedVersion, "2.0")
        XCTAssertFalse(exists(staged))
    }

    func testFailedSkipSaveKeepsTheFolder() throws {
        let staged = try makePackage(version: "2.0")
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"),
                                           staged: update(staged, "2.0", asks: ["tabs"]))
        let manager = makeManager()
        setLibraryWritable(false)

        XCTAssertFalse(manager.skipStagedUpdate(of: record.id, folder: staged))
        setLibraryWritable(true)
        XCTAssertTrue(exists(staged))
        XCTAssertEqual(manager.records.first, record)
        XCTAssertEqual(savedRecord, record)
    }

    /// The review records asks against the grants at the time; applying adds
    /// only those asks to the grants at apply time. A grant revoked between
    /// the two stays revoked.
    func testGrantRevokedDuringReviewStaysRevokedAfterApply() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"), grants: ["storage", "tabs"])
        let manager = makeManager()
        let new = try makePackage(version: "2.0", permissions: ["storage", "tabs", "alarms"])

        let reviewed = try await manager.reviewUpdate(folder: new, version: "2.0", for: record)
        XCTAssertEqual(reviewed.newPermissions, ["alarms"])
        manager.updateGrants(record.id, permissions: ["storage"], matchPatterns: [])
        XCTAssertEqual(manager.stage(reviewed, of: release("2.0"), for: record.id), .staged(reviewed))
        XCTAssertTrue(manager.approveStagedUpdate(of: record.id, folder: new))

        let applied = try XCTUnwrap(manager.record(record.id)?.applyingStagedUpdate())
        XCTAssertEqual(applied.grantedPermissions, ["alarms", "storage"])
        XCTAssertFalse(applied.grantedPermissions.contains("tabs"))
    }

    // MARK: - Trial results

    func testTrialResultIsKeptForTheRow() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let good = try makePackage(version: "2.0")
        let record = try saveCatalogRecord(current: try makePackage(version: "1.0"), staged: update(good, "2.0"))
        let manager = makeManager()
        await manager.startEnabled()
        XCTAssertEqual(manager.lastTrials[record.id], .updated(folder: good, version: "2.0"))
        await manager.remove(record.id)
        XCTAssertNil(manager.lastTrials[record.id], "removing the extension drops its row state")

        let broken = try makePackage(version: "2.0")
        try Data("{ not json".utf8).write(to: library.packageURL(folder: broken).appending(path: "manifest.json"))
        let second = try saveCatalogRecord(current: try makePackage(version: "1.0"), staged: update(broken, "2.0"))
        let other = makeManager()
        await other.startEnabled()
        guard case .rolledBack(let folder, let version, _) = other.lastTrials[second.id] else {
            return XCTFail("expected a rollback, got \(String(describing: other.lastTrials[second.id]))")
        }
        XCTAssertEqual(folder, broken)
        XCTAssertEqual(version, "2.0")
    }
}
