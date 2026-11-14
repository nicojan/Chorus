import XCTest
@testable import Chorus
@testable import ChorusEngine

/// Get, the daily pass, Update Now and the toggle, against a stubbed network
/// that refuses every URL it was not given. Nothing here reaches the internet.
@MainActor
final class ExtensionCatalogControllerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "ChorusTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        setLibraryWritable(true)
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private let probe = ExtensionCatalogEntry(
        id: "probe", name: "Probe", summary: "A test extension.", category: .privacy, licence: "MIT",
        source: .amo(slug: "probe"), testedVersion: "1.0", knownGaps: nil
    )

    private func githubEntry(_ id: String, repo: String) -> ExtensionCatalogEntry {
        ExtensionCatalogEntry(id: id, name: id, summary: "A test extension.", category: .privacy, licence: "MIT",
                              source: .github(owner: "o", repo: repo, assetPattern: "probe-*.zip", tagPrefix: nil),
                              testedVersion: "1.0", knownGaps: nil)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    private var probeAPI: String { ExtensionFixtures.amoAPIURL(slug: "probe") }

    private func makeManager() -> ExtensionManager {
        ExtensionManager(library: library, storageIdentifier: nil)
    }

    private func makeController(_ manager: ExtensionManager, network: StubNetwork,
                                entries: [ExtensionCatalogEntry]? = nil,
                                allowUnderTests: Bool = true, now: (() -> Date)? = nil,
                                review: ExtensionCatalogController.Review? = nil) -> ExtensionCatalogController {
        ExtensionCatalogController(manager: manager, catalog: ExtensionCatalog(entries: entries ?? [probe]),
                                   fetcher: network.fetcher, defaults: defaults, now: now ?? { [fixedNow] in fixedNow },
                                   allowUnderTests: allowUnderTests, review: review)
    }

    /// A review that asks for nothing new, so a test needs no WebKit.
    private let readyReview: ExtensionCatalogController.Review = { folder, version, _ in
        .init(folder: folder, version: version, newPermissions: [], newMatchPatterns: [])
    }

    /// A review that WebKit refused.
    private let failingReview: ExtensionCatalogController.Review = { _, _, _ in
        throw CocoaError(.fileReadCorruptFile)
    }

    /// A library folder the list cannot be saved into.
    private func setLibraryWritable(_ writable: Bool) {
        try? FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555],
                                               ofItemAtPath: library.directory.path)
    }

    private func makePackage(version: String, background: Bool = false) throws -> String {
        try library.importPackage(from: ExtensionFixtures.folder(in: root, version: version, background: background))
    }

    /// Saves catalog records at 1.0 and returns them as read back.
    private func saveRecords(_ specs: [(catalogID: String?, enabled: Bool)], background: Bool = false) throws -> [WebExtensionRecord] {
        let records = try specs.map { spec in
            WebExtensionRecord(source: .package(folder: try makePackage(version: "1.0", background: background)),
                               name: "Probe", isEnabled: spec.enabled, grantedPermissions: ["storage"],
                               grantedMatchPatterns: [], catalogID: spec.catalogID, installedVersion: "1.0")
        }
        try library.saveRecords(records)
        return library.loadRecords()
    }

    private func saveProbeRecord() throws -> WebExtensionRecord {
        try XCTUnwrap(saveRecords([("probe", true)]).first)
    }

    /// Publishes Probe `version` on AMO as file `file`.
    private func publish(_ version: String, file: Int = 2, permissions: [String] = ["storage"],
                         manifestVersion: String? = nil, on network: StubNetwork) throws {
        let folder = try ExtensionFixtures.folder(in: root, version: manifestVersion ?? version, permissions: permissions)
        let zip = try ExtensionFixtures.zip(of: folder)
        network.answer(probeAPI, with: .init(body: ExtensionFixtures.amoAnswer(version: version, file: file, zip: zip)))
        network.answer(ExtensionFixtures.amoDownloadURL(file: file), with: .init(body: zip.data))
    }

    private var downloadPrefix: String { "https://addons.mozilla.org/firefox/downloads/" }

    private var packages: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: library.directory.appending(path: "Packages").path)) ?? [])
    }

    private var namedFolders: Set<String> {
        Set(library.loadRecords().flatMap(\.packageFolders))
    }

    private func requireExtensions() throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
    }

    // MARK: - The pass

    func testPassStagesANewerReleaseThatAsksNothingNewAsReady() async throws {
        try requireExtensions()
        let record = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network)

        let outcome = await controller.runPass()

        XCTAssertEqual(outcome, .complete)
        let staged = try XCTUnwrap(library.loadRecords().first?.stagedUpdate)
        XCTAssertEqual(staged.version, "2.0")
        XCTAssertTrue(staged.isReady)
        XCTAssertEqual(packages, namedFolders, "the list on disk names the staged folder, and nothing else is left")
        XCTAssertNil(controller.available[record.id])
        XCTAssertTrue(controller.downloading.isEmpty)
    }

    func testPassStagesANewAskAsNeedingOK() async throws {
        try requireExtensions()
        _ = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", permissions: ["storage", "tabs"], on: network)
        let controller = makeController(makeManager(), network: network)

        _ = await controller.runPass()

        let staged = try XCTUnwrap(library.loadRecords().first?.stagedUpdate)
        XCTAssertEqual(staged.newPermissions, ["tabs"])
        XCTAssertFalse(staged.isReady)
    }

    func testPassWithAutomaticOffOnlyRemembers() async throws {
        let record = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network)
        controller.setAutomatic(false)

        let outcome = await controller.runPass()
        XCTAssertEqual(outcome, .complete)

        XCTAssertEqual(network.requests, [probeAPI], "no download")
        XCTAssertEqual(controller.available[record.id]?.version, "2.0")
        XCTAssertNil(library.loadRecords().first?.stagedUpdate)
    }

    func testUpdateNowStagesTheRememberedRelease() async throws {
        try requireExtensions()
        let record = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network)
        controller.setAutomatic(false)
        _ = await controller.runPass()

        let update = try await controller.updateNow(record.id)

        XCTAssertEqual(update?.version, "2.0")
        XCTAssertEqual(network.requests(to: probeAPI).count, 1, "no second API request")
        XCTAssertEqual(library.loadRecords().first?.stagedUpdate?.version, "2.0")
        XCTAssertNil(controller.available[record.id])
    }

    func testTurningAutomaticOnStagesRememberedReleasesWithoutAPICalls() async throws {
        try requireExtensions()
        _ = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network)
        controller.setAutomatic(false)
        _ = await controller.runPass()

        await controller.setAutomatic(true)?.value

        XCTAssertEqual(network.requests(to: probeAPI).count, 1)
        XCTAssertEqual(library.loadRecords().first?.stagedUpdate?.version, "2.0")
        XCTAssertTrue(controller.available.isEmpty)
    }

    func testRemoveDuringDownloadLeavesNoFolder() async throws {
        let record = try saveProbeRecord()
        let gate = DownloadGate()
        let network = StubNetwork(scratch: root, downloadGate: gate)
        try publish("2.0", on: network)
        let manager = makeManager()
        let controller = makeController(manager, network: network)

        let pass = Task { await controller.runPass() }
        try await gate.waitForArrivals(1)
        XCTAssertEqual(controller.downloading[record.id], "2.0")
        await manager.remove(record.id)
        await gate.open()
        _ = await pass.value

        XCTAssertEqual(packages, namedFolders, "Packages holds only named folders")
        XCTAssertTrue(packages.isEmpty)
        XCTAssertTrue(controller.downloading.isEmpty)
    }

    func testTurningAutomaticOffDuringDownloadDiscards() async throws {
        let record = try saveProbeRecord()
        let gate = DownloadGate()
        let network = StubNetwork(scratch: root, downloadGate: gate)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network, review: readyReview)

        let pass = Task { await controller.runPass() }
        try await gate.waitForArrivals(1)
        controller.setAutomatic(false)
        await gate.open()
        _ = await pass.value

        XCTAssertEqual(packages, namedFolders, "the download is gone")
        XCTAssertNil(library.loadRecords().first?.stagedUpdate)
        XCTAssertEqual(controller.available[record.id]?.version, "2.0", "the row offers it instead")
    }

    func testPassMakesNoRequestForABusyRecord() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let record = try XCTUnwrap(saveRecords([("probe", true)], background: true).first)
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let manager = makeManager()
        let controller = makeController(manager, network: network)
        let gate = BackgroundGate()
        gate.install(on: try XCTUnwrap(manager.host))
        let starting = Task { @MainActor in await manager.startEnabled() }
        try await gate.waitForStarts(1)
        XCTAssertTrue(manager.isBusy(record.id), "precondition: its start is held")

        _ = await controller.runPass()

        XCTAssertTrue(network.requests.isEmpty)
        gate.open()
        await starting.value
    }

    func testPassSkipsOffHandAddedAndUnknownCatalogRecords() async throws {
        _ = try saveRecords([("probe", false), (nil, true), ("left-the-catalog", true)])
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network)

        let outcome = await controller.runPass()
        XCTAssertEqual(outcome, .complete)
        XCTAssertTrue(network.requests.isEmpty)
    }

    func testRateLimitSkipsThatHostOnlyAndRetriesLater() async throws {
        let first = githubEntry("first", repo: "one")
        let second = githubEntry("second", repo: "two")
        _ = try saveRecords([("first", true), ("second", true), ("probe", true)])
        let network = StubNetwork(scratch: root)
        network.answer(ExtensionFixtures.githubAPIURL(owner: "o", repo: "one"),
                       with: .init(status: 403, headers: ["x-ratelimit-remaining": "0"]))
        // AMO answers with the installed version, so nothing downloads.
        try publish("1.0", on: network)
        let controller = makeController(makeManager(), network: network, entries: [first, second, probe])

        await controller.checkIfDue()

        XCTAssertTrue(network.requests(to: ExtensionFixtures.githubAPIURL(owner: "o", repo: "two")).isEmpty,
                      "the second GitHub entry is not asked")
        XCTAssertEqual(network.requests(to: probeAPI).count, 1, "AMO is still asked")
        XCTAssertNil(controller.lastCompleteCheck)
        XCTAssertEqual(controller.retryAfter, fixedNow.addingTimeInterval(3_600))
    }

    func testTransportErrorRetriesLater() async throws {
        _ = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        let controller = makeController(makeManager(), network: network)

        let outcome = await controller.runPass()
        XCTAssertEqual(outcome, .retryLater)
        XCTAssertEqual(network.requests, [probeAPI])
    }

    func testCompletePassIsRememberedUntilADayPasses() async throws {
        _ = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("1.0", on: network)
        let controller = makeController(makeManager(), network: network)

        await controller.checkIfDue()
        await controller.checkIfDue()

        XCTAssertEqual(controller.lastCompleteCheck, fixedNow)
        XCTAssertEqual(network.requests.count, 1, "the second call within the day asks nothing")
    }

    /// WebKit reads any manifest the library imports, so this uses the other
    /// lasting failure: a download whose manifest names a different version.
    /// Both mark the version failed for the session.
    func testUnreadableUpdateIsNotDownloadedAgainThisSession() async throws {
        _ = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", manifestVersion: "1.5", on: network)
        let controller = makeController(makeManager(), network: network)

        let outcome = await controller.runPass()
        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(network.requests(to: downloadPrefix).count, 1)
        _ = await controller.runPass()

        XCTAssertEqual(network.requests(to: probeAPI).count, 2, "it still checks")
        XCTAssertEqual(network.requests(to: downloadPrefix).count, 1, "no second download")
        XCTAssertEqual(packages, namedFolders)
    }

    func testControllerDoesNothingUnderTestsUnlessAllowed() async throws {
        _ = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network, allowUnderTests: false)

        controller.launchFinished()
        XCTAssertNil(controller.setAutomatic(true), "the toggle starts nothing either")
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(network.requests.isEmpty)
    }

    // MARK: - Get

    func testGetAddsTheLatestWithCatalogFields() async throws {
        try requireExtensions()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let manager = makeManager()
        let controller = makeController(manager, network: network)

        try await controller.get(probe)
        let pending = try XCTUnwrap(controller.pendingInstall)
        XCTAssertEqual(pending.catalog, CatalogPick(entry: probe, version: "2.0"))
        XCTAssertNil(controller.gettingID)
        try await controller.finishInstall(agreed: true)

        let saved = try XCTUnwrap(library.loadRecords().first)
        XCTAssertEqual(saved.catalogID, "probe")
        XCTAssertEqual(saved.installedVersion, "2.0")
        XCTAssertNil(controller.pendingInstall)
        XCTAssertTrue(manager.isAdded(catalogID: "probe"))
    }

    func testCancellingGetDeletesTheFolder() async throws {
        try requireExtensions()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network)

        try await controller.get(probe)
        XCTAssertEqual(packages.count, 1, "precondition: the download waits at the sheet")
        controller.cancelInstall()
        try await controller.finishInstall(agreed: true)

        XCTAssertTrue(packages.isEmpty)
        XCTAssertTrue(library.loadRecords().isEmpty, "a second answer after cancelling adds nothing")
    }

    func testGetRefusesAnAddedEntry() async throws {
        _ = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network)

        try await controller.get(probe)

        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertNil(controller.pendingInstall)
    }

    // MARK: - Review fixes

    /// R2 runs after the review's await: the toggle turned off while WebKit
    /// read the download still stops it from being staged.
    func testTurningAutomaticOffDuringReviewDiscards() async throws {
        let record = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let reviewGate = DownloadGate()
        let controller = makeController(makeManager(), network: network, review: { folder, version, _ in
            await reviewGate.wait()
            return .init(folder: folder, version: version, newPermissions: [], newMatchPatterns: [])
        })

        let pass = Task { await controller.runPass() }
        try await reviewGate.waitForArrivals(1)
        controller.setAutomatic(false)
        await reviewGate.open()
        _ = await pass.value

        XCTAssertEqual(packages, namedFolders, "the reviewed download is deleted")
        XCTAssertNil(library.loadRecords().first?.stagedUpdate, "nothing is staged")
        XCTAssertEqual(controller.available[record.id]?.version, "2.0", "the row offers it instead")
    }

    func testFailedReviewDeletesTheDownloadAndIsNotRetried() async throws {
        let record = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network, review: failingReview)

        _ = await controller.runPass()
        XCTAssertEqual(packages, namedFolders, "the download is deleted")
        XCTAssertEqual(controller.failedVersions[record.id], "2.0")
        _ = await controller.runPass()

        XCTAssertEqual(network.requests(to: probeAPI).count, 2, "it still checks")
        XCTAssertEqual(network.requests(to: downloadPrefix).count, 1, "no second download")
    }

    func testUpdateNowWhileBusySaysSo() async throws {
        let record = try saveProbeRecord()
        let gate = DownloadGate()
        let network = StubNetwork(scratch: root, downloadGate: gate)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network, review: readyReview)
        let pass = Task { await controller.runPass() }
        try await gate.waitForArrivals(1)

        do {
            _ = try await controller.updateNow(record.id)
            XCTFail("expected Update Now to say the extension is busy")
        } catch {
            XCTAssertEqual(error as? ExtensionCatalogController.UpdateError, .stillStarting(name: "Probe"))
            XCTAssertEqual(error.localizedDescription, "Chorus is still starting Probe. Try again in a moment.")
        }
        await gate.open()
        _ = await pass.value
    }

    func testUpdateNowWhoseSaveFailsSaysSo() async throws {
        let record = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network, review: readyReview)
        setLibraryWritable(false)

        do {
            _ = try await controller.updateNow(record.id)
            XCTFail("expected the failed save to be reported")
        } catch {
            XCTAssertEqual(error as? ExtensionCatalogController.UpdateError, .listNotSaved)
            XCTAssertEqual(error.localizedDescription,
                           "Chorus couldn't save its list of extensions, so nothing changed.")
        }
        setLibraryWritable(true)
        XCTAssertEqual(network.requests(to: downloadPrefix).count, 1, "the update was downloaded")
        XCTAssertNil(library.loadRecords().first?.stagedUpdate)
        XCTAssertEqual(packages, namedFolders, "the download is deleted")
    }

    func testTurningAutomaticOnAgainDoesNotRetryAFailedVersion() async throws {
        let record = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let controller = makeController(makeManager(), network: network, review: failingReview)
        controller.setAutomatic(false)
        _ = await controller.runPass()

        await controller.setAutomatic(true)?.value
        XCTAssertEqual(network.requests(to: downloadPrefix).count, 1, "precondition: one download, which failed")
        controller.setAutomatic(false)
        await controller.setAutomatic(true)?.value
        XCTAssertEqual(network.requests(to: downloadPrefix).count, 1, "the failed version is not downloaded again")

        // The user asking is different: Update Now still tries it.
        _ = try? await controller.updateNow(record.id)
        XCTAssertEqual(network.requests(to: downloadPrefix).count, 2)
        XCTAssertEqual(packages, namedFolders)
    }

    func testLaunchRunsOnePassAndOneLoop() async throws {
        try requireExtensions()
        _ = try saveProbeRecord()
        let network = StubNetwork(scratch: root)
        try publish("1.0", on: network)
        // Two days pass at every reading, so any loop would find a pass due.
        let clock = SteppingClock(start: fixedNow, step: 2 * ExtensionCatalogController.checkInterval)
        let controller = makeController(makeManager(), network: network, now: { clock.next() })
        defer { controller.stop() }

        controller.launchFinished()
        let deadline = Date().addingTimeInterval(5)
        while controller.lastCompleteCheck == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(controller.lastCompleteCheck, "the first pass runs at once")
        controller.launchFinished()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(network.requests(to: probeAPI).count, 1, "one pass, one loop")
    }

    func testFailedSaveWhileFinishingGetSaysSo() async throws {
        try requireExtensions()
        let network = StubNetwork(scratch: root)
        try publish("2.0", on: network)
        let manager = makeManager()
        let controller = makeController(manager, network: network)
        try await controller.get(probe)
        setLibraryWritable(false)

        do {
            try await controller.finishInstall(agreed: true)
            XCTFail("expected the failed save to be reported")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "Chorus couldn't save its list of extensions, so it didn't add Probe.")
        }
        setLibraryWritable(true)
        XCTAssertTrue(manager.records.isEmpty)
        XCTAssertTrue(packages.isEmpty, "the download is deleted")
        XCTAssertNil(controller.pendingInstall)
    }

    // MARK: - Settings and schedule

    func testAutomaticDefaultsOnAndPersists() {
        let network = StubNetwork(scratch: root)
        let manager = makeManager()
        XCTAssertTrue(makeController(manager, network: network).isAutomatic)
        makeController(manager, network: network).setAutomatic(false)
        XCTAssertFalse(makeController(manager, network: network).isAutomatic)
    }

    func testIsDue() {
        let now = fixedNow
        let day = ExtensionCatalogController.checkInterval
        func due(_ last: Date?, _ retry: Date? = nil) -> Bool {
            ExtensionCatalogController.isDue(now: now, lastCompleteCheck: last, retryAfter: retry)
        }
        XCTAssertTrue(due(nil), "never checked")
        XCTAssertFalse(due(now.addingTimeInterval(-day + 60)), "under a day")
        XCTAssertTrue(due(now.addingTimeInterval(-day)), "a day exactly")
        XCTAssertTrue(due(now.addingTimeInterval(-day * 3)), "over a day")
        XCTAssertTrue(due(now.addingTimeInterval(3_600)), "the clock moved back")
        XCTAssertFalse(due(nil, now.addingTimeInterval(60)), "before retryAfter")
        XCTAssertTrue(due(nil, now.addingTimeInterval(-60)), "after retryAfter")
        XCTAssertTrue(due(nil, now), "at retryAfter")
        XCTAssertTrue(due(nil, now.addingTimeInterval(day + 60)), "a retryAfter over a day ahead is stale")
        XCTAssertFalse(due(nil, now.addingTimeInterval(day)), "a retryAfter a day ahead still holds")
    }

    func testRetryDelayDoublesAndCaps() {
        let delays = (1...8).map(ExtensionCatalogController.retryDelay(afterLimitedPasses:))
        XCTAssertEqual(delays, [3_600, 7_200, 14_400, 28_800, 57_600, 86_400, 86_400, 86_400])
        XCTAssertEqual(ExtensionCatalogController.retryDelay(afterLimitedPasses: 1_000), 86_400)
    }
}

/// A clock that moves `step` forward at every reading.
private final class SteppingClock {
    private var current: Date
    private let step: TimeInterval

    init(start: Date, step: TimeInterval) {
        current = start
        self.step = step
    }

    func next() -> Date {
        current = current.addingTimeInterval(step)
        return current
    }
}
