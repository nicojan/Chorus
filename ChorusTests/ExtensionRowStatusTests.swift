import XCTest
@testable import Chorus
@testable import ChorusEngine

/// The installed row's status ladder: one test per rung, then which rung
/// wins when several match.
final class ExtensionRowStatusTests: XCTestCase {
    private let staged = "STAGED-FOLDER"

    private func record(catalog: Bool = true, enabled: Bool = true, installed: String? = "1.0",
                        update: WebExtensionRecord.StagedUpdate? = nil,
                        source: WebExtensionRecord.Source = .package(folder: "CURRENT")) -> WebExtensionRecord {
        WebExtensionRecord(id: UUID(), source: source, name: "Probe", isEnabled: enabled,
                           grantedPermissions: [], grantedMatchPatterns: [], addedAt: Date(),
                           catalogID: catalog ? "probe" : nil, installedVersion: installed,
                           stagedUpdate: update, skippedVersion: nil)
    }

    private func update(_ version: String = "2.0", needsOK: Bool) -> WebExtensionRecord.StagedUpdate {
        .init(folder: staged, version: version, newPermissions: needsOK ? ["tabs"] : [], newMatchPatterns: [])
    }

    private func release(_ version: String) -> WebExtensionRelease {
        WebExtensionRelease(version: version, downloadURL: URL(string: "https://addons.mozilla.org/firefox/downloads/file/1/p.xpi")!,
                            sha256: String(repeating: "0", count: 64))
    }

    private func status(_ record: WebExtensionRecord, failure: String? = nil, running: String? = nil,
                        downloading: String? = nil, available: WebExtensionRelease? = nil,
                        trial: WebExtensionUpdateTrial? = nil, inCatalog: Bool = true) -> ExtensionRowStatus {
        .make(record: record, failure: failure, runningVersion: running, downloadingVersion: downloading,
              available: available, lastTrial: trial, isInCatalog: inCatalog)
    }

    // MARK: - Rungs

    func testFailure() {
        XCTAssertEqual(status(record(), failure: "It broke."), ExtensionRowStatus("It broke.", tone: .failure))
    }

    func testDownloading() {
        XCTAssertEqual(status(record(), downloading: "2.0"),
                       ExtensionRowStatus("Downloading version 2.0\u{2026}", showsSpinner: true))
    }

    func testNeedsOK() {
        XCTAssertEqual(status(record(update: update(needsOK: true))),
                       ExtensionRowStatus("Version 2.0 needs your OK", tone: .warning, action: .review(folder: staged)))
    }

    func testOff() {
        XCTAssertEqual(status(record(enabled: false)), ExtensionRowStatus("Off"))
        XCTAssertEqual(status(record(enabled: false, update: update(needsOK: false))),
                       ExtensionRowStatus("Off \u{00B7} Version 2.0 installs when you turn it on"))
    }

    func testReadyUpdateWaitsForRestart() {
        XCTAssertEqual(status(record(update: update(needsOK: false))),
                       ExtensionRowStatus("Version 2.0 installs when Chorus restarts"))
    }

    func testAvailable() {
        XCTAssertEqual(status(record(), available: release("2.0")),
                       ExtensionRowStatus("Version 2.0 is available", action: .update))
    }

    func testAvailableNoLongerWantedIsIgnored() {
        XCTAssertEqual(status(record(installed: "2.0"), available: release("2.0")), ExtensionRowStatus("Version 2.0"))
    }

    func testRolledBack() {
        XCTAssertEqual(status(record(), trial: .rolledBack(folder: staged, version: "2.0", reason: "boom")),
                       ExtensionRowStatus("Version 2.0 wouldn't start, so Chorus kept version 1.0", tone: .warning))
    }

    func testUpdated() {
        XCTAssertEqual(status(record(installed: "2.0"), trial: .updated(folder: staged, version: "2.0")),
                       ExtensionRowStatus("Updated to version 2.0"))
    }

    func testCatalogBase() {
        XCTAssertEqual(status(record(), running: "1.0 beta"), ExtensionRowStatus("Version 1.0"),
                       "the record's version before the manifest's display version")
        XCTAssertEqual(status(record(installed: nil), running: "1.0"), ExtensionRowStatus("Version 1.0"))
        XCTAssertEqual(status(record(), inCatalog: false),
                       ExtensionRowStatus("Version 1.0 \u{00B7} Chorus no longer updates it"))
    }

    func testHandAddedBaseIsUnchanged() {
        XCTAssertEqual(status(record(catalog: false, installed: nil), running: "3.1"),
                       ExtensionRowStatus("Version 3.1 \u{00B7} Added from a file"))
        XCTAssertEqual(status(record(catalog: false, installed: nil, source: .appExtension(path: "/x.appex"))),
                       ExtensionRowStatus("Safari extension"))
    }

    // MARK: - Precedence

    func testFailureBeatsEverything() {
        let busy = record(enabled: false, update: update(needsOK: true))
        XCTAssertEqual(status(busy, failure: "It broke.", downloading: "3.0", available: release("3.0"),
                              trial: .updated(folder: staged, version: "2.0")).tone, .failure)
    }

    func testNeedsOKBeatsOff() {
        XCTAssertEqual(status(record(enabled: false, update: update(needsOK: true))).action, .review(folder: staged))
    }

    func testAvailableBeatsRolledBack() {
        XCTAssertEqual(status(record(), available: release("3.0"),
                              trial: .rolledBack(folder: staged, version: "2.0", reason: "boom")).action, .update)
    }
}
