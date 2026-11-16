import XCTest
@testable import ChorusEngine

/// The record's update fields and the pure helpers that stage, approve, apply
/// and drop an update. Nothing here touches WebKit.
final class WebExtensionRecordUpdateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    private let f1 = "11111111-1111-1111-1111-111111111111"
    private let f2 = "22222222-2222-2222-2222-222222222222"

    private func catalogRecord(
        source: WebExtensionRecord.Source? = nil,
        catalogID: String? = "dearrow",
        installedVersion: String? = "1.0"
    ) -> WebExtensionRecord {
        WebExtensionRecord(
            source: source ?? .package(folder: f1), name: "Probe",
            grantedPermissions: ["storage"], grantedMatchPatterns: ["https://a.example/*"],
            // Whole seconds: the list stores dates as ISO 8601, which drops fractions.
            addedAt: Date(timeIntervalSince1970: 1_793_000_000),
            catalogID: catalogID, installedVersion: installedVersion
        )
    }

    private func update(
        folder: String? = nil, version: String = "2.0",
        permissions: [String] = [], patterns: [String] = [],
        approved: Bool = false, attempts: Int = 0
    ) -> WebExtensionRecord.StagedUpdate {
        WebExtensionRecord.StagedUpdate(
            folder: folder ?? f2, version: version,
            newPermissions: permissions, newMatchPatterns: patterns,
            isApproved: approved, attempts: attempts
        )
    }

    private func release(_ version: String) -> WebExtensionRelease {
        WebExtensionRelease(version: version, downloadURL: URL(string: "https://example.com/x.zip")!, sha256: "00")
    }

    // MARK: - Decoding and saving

    func testOldListStillDecodes() throws {
        let id1 = UUID(), id2 = UUID()
        let json = """
        [
          {
            "addedAt" : "2026-11-01T10:00:00Z",
            "grantedMatchPatterns" : [ "<all_urls>" ],
            "grantedPermissions" : [ "storage" ],
            "id" : "\(id1.uuidString)",
            "isEnabled" : true,
            "name" : "Packaged",
            "source" : { "package" : { "folder" : "\(f1)" } }
          },
          {
            "addedAt" : "2026-11-02T10:00:00Z",
            "grantedMatchPatterns" : [ ],
            "grantedPermissions" : [ ],
            "id" : "\(id2.uuidString)",
            "isEnabled" : false,
            "name" : "Safari",
            "source" : { "appExtension" : { "path" : "/Applications/A.app/Contents/PlugIns/A.appex" } }
          }
        ]
        """
        try FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: library.recordsFile)

        let loaded = library.loadRecords()
        XCTAssertEqual(loaded.map(\.id), [id1, id2])
        XCTAssertEqual(loaded.map(\.source), [.package(folder: f1), .appExtension(path: "/Applications/A.app/Contents/PlugIns/A.appex")])
        for record in loaded {
            XCTAssertNil(record.catalogID)
            XCTAssertNil(record.installedVersion)
            XCTAssertNil(record.stagedUpdate)
            XCTAssertNil(record.skippedVersion)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: library.directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix("extensions.unreadable-") }, "today's list must not be moved aside")
    }

    func testUpdateFieldsRoundTrip() throws {
        let record = catalogRecord()
            .staging(update(permissions: ["tabs"], patterns: ["<all_urls>"]))
            .approvingStagedUpdate()
            .startingUpdateAttempt()
            .droppingStagedUpdate(skipping: true)
            .staging(update(version: "3.0", permissions: ["tabs"], approved: true, attempts: 1))
        XCTAssertEqual(record.skippedVersion, "2.0")
        try library.saveRecords([record])
        let loaded = library.loadRecords()
        XCTAssertEqual(loaded, [record])
        XCTAssertEqual(loaded.first?.catalogID, "dearrow")
        XCTAssertEqual(loaded.first?.installedVersion, "1.0")
        XCTAssertEqual(loaded.first?.stagedUpdate?.isApproved, true)
        XCTAssertEqual(loaded.first?.stagedUpdate?.attempts, 1)
        XCTAssertEqual(loaded.first?.skippedVersion, "2.0")
    }

    // MARK: - Helpers keep the update fields

    func testChangesKeepUpdateFields() {
        let record = catalogRecord()
            .staging(update(version: "3.0"))
            .droppingStagedUpdate(skipping: true)
            .staging(update(version: "4.0", permissions: ["tabs"]))
        let changed = [
            record.enabled(false),
            record.granting(permissions: ["tabs"], matchPatterns: ["<all_urls>"]),
        ]
        for other in changed {
            XCTAssertEqual(other.catalogID, "dearrow")
            XCTAssertEqual(other.installedVersion, "1.0")
            XCTAssertEqual(other.stagedUpdate, record.stagedUpdate)
            XCTAssertEqual(other.skippedVersion, "3.0")
        }
    }

    // MARK: - Applying

    func testApplyingStagedUpdate() throws {
        let staged = catalogRecord()
            .droppingStagedUpdate(skipping: false)
            .staging(update(version: "3.0"))
            .droppingStagedUpdate(skipping: true)
            .granting(permissions: ["alarms", "storage"], matchPatterns: ["https://a.example/*"])
            // Only asks not granted yet, as `reviewUpdate` stages them, so a
            // swap that replaced the grants instead of adding to them shows.
            .staging(update(permissions: ["tabs"], patterns: ["<all_urls>"], approved: true))
        XCTAssertEqual(staged.skippedVersion, "3.0")
        let applied = try XCTUnwrap(staged.applyingStagedUpdate())
        XCTAssertEqual(applied.source, .package(folder: f2))
        XCTAssertEqual(applied.installedVersion, "2.0")
        XCTAssertEqual(applied.grantedPermissions, ["alarms", "storage", "tabs"], "the new asks join the grants")
        XCTAssertEqual(applied.grantedMatchPatterns, ["<all_urls>", "https://a.example/*"])
        XCTAssertNil(applied.stagedUpdate)
        XCTAssertNil(applied.skippedVersion)
        XCTAssertEqual(applied.id, staged.id)
        XCTAssertEqual(applied.baseURL, staged.baseURL)
        XCTAssertEqual(applied.catalogID, "dearrow")
        XCTAssertEqual(staged.source, .package(folder: f1), "the old record is unchanged")
    }

    func testApplyingWithNoAsksKeepsGrants() throws {
        let applied = try XCTUnwrap(catalogRecord().staging(update()).applyingStagedUpdate())
        XCTAssertEqual(applied.grantedPermissions, ["storage"], "an update that asks for nothing new keeps every grant")
        XCTAssertEqual(applied.grantedMatchPatterns, ["https://a.example/*"])
    }

    func testApplyingNeedsReadyPackage() {
        XCTAssertNil(catalogRecord().applyingStagedUpdate(), "nothing staged")

        let asking = catalogRecord().staging(update(permissions: ["tabs"]))
        XCTAssertFalse(asking.stagedUpdate?.isReady ?? true)
        XCTAssertNil(asking.applyingStagedUpdate(), "new asks the user has not approved")
        XCTAssertNotNil(asking.approvingStagedUpdate().applyingStagedUpdate(), "approval makes it ready")

        let patternAsk = catalogRecord().staging(update(patterns: ["<all_urls>"]))
        XCTAssertNil(patternAsk.applyingStagedUpdate(), "a new site is an ask too")

        XCTAssertNotNil(catalogRecord().staging(update()).applyingStagedUpdate(), "no new asks is ready without approval")

        let safari = catalogRecord(source: .appExtension(path: "/A.appex")).staging(update())
        XCTAssertNil(safari.stagedUpdate, "staging does nothing for a Safari extension")
        XCTAssertNil(safari.applyingStagedUpdate())
    }

    // MARK: - Dropping and attempts

    func testDroppingAndAttempts() throws {
        let staged = catalogRecord().staging(update(version: "2.5"))
        let skipped = staged.droppingStagedUpdate(skipping: true)
        XCTAssertNil(skipped.stagedUpdate)
        XCTAssertEqual(skipped.skippedVersion, "2.5")
        XCTAssertEqual(skipped.source, .package(folder: f1))

        let dropped = staged.droppingStagedUpdate(skipping: false)
        XCTAssertNil(dropped.stagedUpdate)
        XCTAssertNil(dropped.skippedVersion)

        let twice = staged.startingUpdateAttempt().startingUpdateAttempt()
        XCTAssertEqual(twice.stagedUpdate?.attempts, 2)
        XCTAssertEqual(twice.cancellingUpdateAttempt().stagedUpdate?.attempts, 1)
        XCTAssertEqual(staged.cancellingUpdateAttempt().stagedUpdate?.attempts, 0, "never below zero")
        XCTAssertEqual(staged.stagedUpdate?.attempts, 0, "the old record is unchanged")

        let none = catalogRecord()
        XCTAssertEqual(none.startingUpdateAttempt(), none, "nothing staged, nothing to count")
        XCTAssertEqual(none.droppingStagedUpdate(skipping: true).skippedVersion, nil, "nothing staged, nothing to skip")
    }

    func testStagingReplacesAnEarlierUpdate() {
        let first = catalogRecord().staging(update(folder: f2, version: "2.0", approved: true, attempts: 1))
        let other = "33333333-3333-3333-3333-333333333333"
        let second = first.staging(update(folder: other, version: "2.1"))
        XCTAssertEqual(second.stagedUpdate?.folder, other)
        XCTAssertEqual(second.stagedUpdate?.attempts, 0)
        XCTAssertEqual(second.stagedUpdate?.isApproved, false)
    }

    // MARK: - Settling a trial

    func testSettlingIgnoresStaleTrial() {
        let staged = catalogRecord().staging(update(folder: f2, version: "2.0", attempts: 1))
        let x = "33333333-3333-3333-3333-333333333333"
        let stale: [WebExtensionUpdateTrial] = [
            .notAttempted,
            .updated(folder: x, version: "2.0"),
            .rolledBack(folder: x, version: "2.0", reason: "boom"),
            .cancelled(folder: x),
        ]
        for trial in stale {
            XCTAssertEqual(staged.settling(trial), staged, "\(trial) is for another folder")
        }

        let updated = staged.settling(.updated(folder: f2, version: "2.0"))
        XCTAssertEqual(updated.source, .package(folder: f2))
        XCTAssertNil(updated.stagedUpdate)

        let rolledBack = staged.settling(.rolledBack(folder: f2, version: "2.0", reason: "boom"))
        XCTAssertEqual(rolledBack.source, .package(folder: f1))
        XCTAssertNil(rolledBack.stagedUpdate)
        XCTAssertEqual(rolledBack.skippedVersion, "2.0")

        let cancelled = staged.settling(.cancelled(folder: f2))
        XCTAssertEqual(cancelled.stagedUpdate?.attempts, 0)
        XCTAssertEqual(cancelled.source, .package(folder: f1))
    }

    func testSettlingAnUpdateThatIsNoLongerReadyKeepsTheRecord() {
        // The user's approval can be the thing that changed: an update the
        // record cannot apply is left alone rather than forced through.
        let staged = catalogRecord().staging(update(folder: f2, permissions: ["tabs"], attempts: 1))
        XCTAssertEqual(staged.settling(.updated(folder: f2, version: "2.0")), staged)
    }

    // MARK: - Folders

    func testPackageFolders() {
        XCTAssertEqual(catalogRecord().packageFolders, [f1])
        XCTAssertEqual(catalogRecord().staging(update(folder: f2)).packageFolders, [f1, f2])
        XCTAssertEqual(catalogRecord(source: .appExtension(path: "/A.appex")).packageFolders, [])
    }

    // MARK: - Wanting an update

    func testWantsUpdate() {
        XCTAssertFalse(catalogRecord(catalogID: nil).wantsUpdate(to: release("9.0")), "not from the catalog")
        XCTAssertFalse(catalogRecord(source: .appExtension(path: "/A.appex")).wantsUpdate(to: release("9.0")), "a Safari extension")

        let skipped = catalogRecord().staging(update(version: "3.1")).droppingStagedUpdate(skipping: true)
        XCTAssertFalse(skipped.wantsUpdate(to: release("3.1.0")), "the version the user skipped, written another way")
        XCTAssertTrue(skipped.wantsUpdate(to: release("3.2")), "a later one than the skipped version")

        let staged = catalogRecord().staging(update(version: "2.0"))
        XCTAssertFalse(staged.wantsUpdate(to: release("2.0")), "already staged")
        XCTAssertFalse(staged.wantsUpdate(to: release("1.5")), "older than the staged one")
        XCTAssertTrue(staged.wantsUpdate(to: release("2.1")), "newer than the staged one")

        XCTAssertFalse(catalogRecord().wantsUpdate(to: release("1.0")), "the installed version")
        XCTAssertTrue(catalogRecord().wantsUpdate(to: release("1.1")), "a newer release")
        XCTAssertTrue(catalogRecord(installedVersion: nil).wantsUpdate(to: release("1.0")), "no installed version reads as older")
    }
}
