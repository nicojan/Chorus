import XCTest
@testable import Chorus
@testable import ChorusEngine

/// The launch: plain loads go ahead together, update trials run one at a
/// time, and one extension's slow or failed background holds only itself.
/// Each test calls `startEnabled` right after making the manager, since
/// WebKit's 5 s startup window runs from the controller, made in `init`.
@MainActor
final class ExtensionLaunchTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-launch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    private func makeManager() -> ExtensionManager {
        ExtensionManager(library: library, storageIdentifier: nil)
    }

    private func eventPackage(_ version: String, broken: Bool = false) throws -> String {
        try library.importPackage(from: ExtensionFixtures.eventProbe(in: root, version: version, broken: broken))
    }

    /// A package with a background, so a `BackgroundGate` can hold its load.
    private func plainPackage(_ version: String) throws -> String {
        try library.importPackage(from: ExtensionFixtures.folder(in: root, version: version, background: true))
    }

    private func handAdded(_ folder: String) -> WebExtensionRecord {
        WebExtensionRecord(source: .package(folder: folder), name: "Probe",
                           grantedPermissions: ["storage"], grantedMatchPatterns: [])
    }

    /// A catalog record at 1.0 with `staged` ready as 2.0, asking for nothing new.
    private func catalogRecord(_ current: String, staged: String) -> WebExtensionRecord {
        WebExtensionRecord(source: .package(folder: current), name: "Probe",
                           grantedPermissions: ["storage"], grantedMatchPatterns: [],
                           catalogID: "probe-\(UUID().uuidString)", installedVersion: "1.0")
            .staging(.init(folder: staged, version: "2.0", newPermissions: [], newMatchPatterns: []))
    }

    private func saved(_ id: UUID) -> WebExtensionRecord? {
        library.loadRecords().first { $0.id == id }
    }

    private func exists(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: library.packageURL(folder: folder).path)
    }

    /// Polls every 100 ms until `condition` holds or `timeout` passes.
    private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    // MARK: - Tests

    /// WebKit counts a load within 5 s of making the controller as a startup
    /// (`freshlyCreatedTimeout`). Loaded one after another, an extension
    /// behind a slow background reached WebKit after that and heard
    /// "install" instead.
    func testEveryExtensionHearsStartupWhenOneBackgroundIsSlow() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let records = try (0..<3).map { _ in handAdded(try eventPackage("1.0")) }
        try library.saveRecords(records)
        let manager = makeManager()
        let host = try XCTUnwrap(manager.host)
        let gate = BackgroundGate()
        gate.install(on: host, holding: [records[0].id])

        let starting = Task { @MainActor () -> ContinuousClock.Instant in
            await manager.startEnabled()
            return .now
        }
        try await Task.sleep(for: .seconds(6))
        let openedAt = ContinuousClock.now
        gate.open()
        let returnedAt = await starting.value

        for (name, record) in zip(["A", "B", "C"], records) {
            let events = try await settledEvents(of: record.id, host: host, atLeast: 1)
            XCTAssertEqual(events, [.startup("1.0")], "\(name) reached WebKit after its 5 s startup window")
        }
        XCTAssertGreaterThanOrEqual(returnedAt, openedAt, "the launch still waits for every background, the held one too")
    }

    /// A broken update rolls back, and its old version waits 12 s for WebKit
    /// to let go of the failed worker. Only that extension waits.
    func testRollbackHoldsOnlyItsOwnExtension() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let a = catalogRecord(try eventPackage("1.0"), staged: try eventPackage("2.0", broken: true))
        let c = catalogRecord(try eventPackage("1.0"), staged: try eventPackage("2.0"))
        let b = handAdded(try eventPackage("1.0"))
        try library.saveRecords([a, c, b])
        let manager = makeManager()
        let host = try XCTUnwrap(manager.host)

        let began = ContinuousClock.now
        let starting = Task { @MainActor in await manager.startEnabled() }
        var othersRanAfter: Duration?
        var aSeenBusy = false
        var aWentIdle = false
        let aBack = try await waitUntil(.seconds(30)) {
            if othersRanAfter == nil, manager.isRunning(b.id), host.details(for: c.id)?.version == "2.0" {
                othersRanAfter = ContinuousClock.now - began
            }
            let aRunsOld = host.details(for: a.id)?.version == "1.0"
            // The first poll can run before the launch task does.
            if manager.isBusy(a.id) { aSeenBusy = true } else if aSeenBusy, !aRunsOld { aWentIdle = true }
            return aRunsOld
        }
        await starting.value
        let took = ContinuousClock.now - began

        XCTAssertTrue(aBack, "A's old version never ran")
        // Well under A's 12 s wait, with room for a slow runner.
        XCTAssertLessThan(try XCTUnwrap(othersRanAfter, "B and C never ran"), .seconds(8), "B and C waited for A")
        XCTAssertTrue(aSeenBusy)
        XCTAssertFalse(aWentIdle, "A stayed busy until it ran again")
        XCTAssertEqual(saved(a.id)?.skippedVersion, "2.0")
        guard case .rolledBack = manager.lastTrials[a.id] else {
            return XCTFail("A's trial: \(String(describing: manager.lastTrials[a.id]))")
        }
        XCTAssertGreaterThanOrEqual(took, WebExtensionHost.failedWorkerReleaseDelay)
        XCTAssertNil(WebExtensionHost.backgroundLoadFailure(in: try XCTUnwrap(host.contexts[a.id])))
        XCTAssertTrue(manager.failures.isEmpty, "\(manager.failures)")

        let bEvents = try await settledEvents(of: b.id, host: host, atLeast: 1)
        let cEvents = try await settledEvents(of: c.id, host: host, atLeast: 1)
        let aEvents = try await settledEvents(of: a.id, host: host, atLeast: 1)
        print("LAUNCH-PROBE took \(took); B and C ran after \(String(describing: othersRanAfter)); A heard \(aEvents); C heard \(cEvents)")
        XCTAssertEqual(bEvents, [.startup("1.0")])
        // Pinned on macOS 27 only, so a WebKit difference on 15 or 26 does not
        // turn this test red; there it is printed above.
        guard #available(macOS 27, *) else { return }
        // Observed 2026-11-16 on macOS 27.2. This controller keeps nothing on
        // disk, and the old version, loaded past WebKit's 5 s startup window,
        // hears "install". A controller with storage, as the app's, has
        // saved 2.0 by then: the same probe there heard "update" from 2.0.
        XCTAssertEqual(aEvents, [ProbeEvent(reason: "install", previous: nil, version: "1.0")],
                       "past the 5 s window, with no stored version, WebKit sends \"install\"")
    }

    /// Two ready updates and a plain extension: the second trial waits for
    /// the first, so a crash is blamed on one version, while the plain load
    /// goes ahead.
    func testTrialsRunOneAtATimeWhilePlainLoadsGoAhead() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        try await assertTrialsRunOneAtATime(reversed: false)
    }

    func testTrialsRunOneAtATimeInReverseListOrder() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        try await assertTrialsRunOneAtATime(reversed: true)
    }

    /// Asserts on whichever trial reached the gate first, so it holds
    /// whatever order the starts run in.
    @available(macOS 15.4, *)
    private func assertTrialsRunOneAtATime(reversed: Bool) async throws {
        let staged = [try plainPackage("2.0"), try plainPackage("2.0")]
        let trials = try staged.map { catalogRecord(try plainPackage("1.0"), staged: $0) }
        let c = handAdded(try plainPackage("1.0"))
        try library.saveRecords(reversed ? [c] + trials.reversed() : trials + [c])
        let manager = makeManager()
        let gate = BackgroundGate()
        gate.install(on: try XCTUnwrap(manager.host), holding: Set(trials.map(\.id)))

        let starting = Task { @MainActor in await manager.startEnabled() }
        try await gate.waitForStarts(1)
        let held = try XCTUnwrap(gate.reached.first)
        let queued = try XCTUnwrap(trials.map(\.id).first { $0 != held })
        let cLoaded = try await waitUntil(.seconds(5)) { manager.isRunning(c.id) && !manager.isBusy(c.id) }

        XCTAssertTrue(cLoaded, "C loaded while the first trial was held")
        XCTAssertEqual(gate.starts, 1, "the other trial waits for the held one")
        XCTAssertEqual(saved(held)?.stagedUpdate?.attempts, 1)
        XCTAssertEqual(saved(queued)?.stagedUpdate?.attempts, 0, "no marker until the queued trial runs")
        XCTAssertTrue(manager.isBusy(held))
        XCTAssertTrue(manager.isBusy(queued), "a queued trial is busy, so the update check leaves it alone")

        gate.open()
        await starting.value
        for (record, folder) in zip(trials, staged) {
            XCTAssertEqual(manager.lastTrials[record.id], .updated(folder: folder, version: "2.0"))
            XCTAssertEqual(saved(record.id)?.installedVersion, "2.0")
        }
        XCTAssertFalse((trials + [c]).contains { manager.isBusy($0.id) }, "every start ended")
    }

    /// An extension turned off while its trial waits for another runs no
    /// trial: no marker, no new version, and nothing left running.
    func testTurnedOffWhileQueuedRunsNoTrial() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        try await assertTurnedOffWhileQueuedRunsNoTrial(reversed: false)
    }

    func testTurnedOffWhileQueuedInReverseListOrderRunsNoTrial() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        try await assertTurnedOffWhileQueuedRunsNoTrial(reversed: true)
    }

    /// Both trials are held; the one that did not reach the gate is queued
    /// behind the one that did, and that is the one turned off.
    @available(macOS 15.4, *)
    private func assertTurnedOffWhileQueuedRunsNoTrial(reversed: Bool) async throws {
        let currents = [try plainPackage("1.0"), try plainPackage("1.0")]
        let staged = [try plainPackage("2.0"), try plainPackage("2.0")]
        let trials = zip(currents, staged).map { catalogRecord($0, staged: $1) }
        try library.saveRecords(reversed ? trials.reversed() : trials)
        let manager = makeManager()
        let gate = BackgroundGate()
        gate.install(on: try XCTUnwrap(manager.host), holding: Set(trials.map(\.id)))

        let starting = Task { @MainActor in await manager.startEnabled() }
        try await gate.waitForStarts(1)
        XCTAssertEqual(gate.starts, 1, "precondition: one trial is held, the other queued")
        let held = try XCTUnwrap(gate.reached.first)
        let index = try XCTUnwrap(trials.firstIndex { $0.id != held })
        let queued = trials[index].id
        await manager.setEnabled(queued, false)
        gate.open()
        await starting.value

        XCTAssertEqual(gate.starts, 1, "the queued trial never reached its background")
        XCTAssertEqual(manager.lastTrials[held], .updated(folder: staged[1 - index], version: "2.0"), "the held trial landed")
        XCTAssertFalse(manager.isRunning(queued), "it is off")
        XCTAssertEqual(saved(queued)?.stagedUpdate?.attempts, 0, "no trial, so no attempt")
        XCTAssertEqual(saved(queued)?.source, .package(folder: currents[index]))
        XCTAssertTrue(exists(staged[index]), "the update waits for the next start")
        XCTAssertFalse(manager.isBusy(queued))
    }
}
