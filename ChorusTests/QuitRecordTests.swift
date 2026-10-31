import XCTest
@testable import Chorus

/// The quit record: one line per launch and per quit, kept next to the store,
/// so a quit that cut a page off can be read after the system log has gone.
final class QuitRecordTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func launch(pid: Int32, at offset: TimeInterval = 0) -> QuitRecord.Entry {
        .launch(at: start.addingTimeInterval(offset), version: "1.5.32 (45)", pid: pid)
    }

    private func quit(pid: Int32, at offset: TimeInterval = 10) -> QuitRecord.Entry {
        QuitRecord.Entry(
            event: .quit, at: start.addingTimeInterval(offset), version: "1.5.32 (45)", pid: pid,
            reason: QuitRecord.Reason.menu.rawValue, pages: 12, writeWaitMs: 389, settled: true, totalMs: 940
        )
    }

    func testALaunchAfterAQuitFindsNothingMissing() {
        XCTAssertNil(QuitRecord.missedQuit(in: [launch(pid: 1), quit(pid: 1)], now: start))
    }

    func testALaunchAfterALaunchFindsTheMissedQuit() throws {
        let missed = try XCTUnwrap(QuitRecord.missedQuit(in: [quit(pid: 0), launch(pid: 1)], now: start.addingTimeInterval(60)))
        XCTAssertEqual(missed.event, .missedQuit)
        XCTAssertEqual(missed.pid, 1, "names the run that ended without quitting")
        XCTAssertEqual(missed.at, start.addingTimeInterval(60))
        XCTAssertEqual(missed.launchedAt, start)
    }

    func testAnEmptyRecordFindsNothingMissing() {
        XCTAssertNil(QuitRecord.missedQuit(in: [], now: start))
    }

    func testLinesRoundTrip() throws {
        let entries = [launch(pid: 1), quit(pid: 1)]
        let text = entries.map(QuitRecord.line(for:)).joined()
        XCTAssertEqual(QuitRecord.entries(from: text), entries)
    }

    func testABadLineIsSkipped() {
        let text = QuitRecord.line(for: launch(pid: 1)) + "not json\n" + QuitRecord.line(for: quit(pid: 1))
        XCTAssertEqual(QuitRecord.entries(from: text).count, 2)
    }

    func testTheFileKeepsTheNewestLines() {
        let lines = (0..<10).map { "line \($0)\n" }
        XCTAssertEqual(QuitRecord.trimmed(lines.joined(), keeping: 3), "line 7\nline 8\nline 9\n")
        XCTAssertEqual(QuitRecord.trimmed("a\nb\n", keeping: 3), "a\nb\n")
    }

    func testAppendWritesAndReadsBack() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "QuitRecordTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: QuitRecord.fileName)

        QuitRecord.append(launch(pid: 1), to: file)
        QuitRecord.append(quit(pid: 1), to: file)

        XCTAssertEqual(QuitRecord.read(file), [launch(pid: 1), quit(pid: 1)])
    }

    func testReasonFromTheQuitEvent() {
        XCTAssertEqual(QuitRecord.Reason(quitEventReason: nil), .quitEvent)
        XCTAssertEqual(QuitRecord.Reason(quitEventReason: kAELogOut), .logOut)
        XCTAssertEqual(QuitRecord.Reason(quitEventReason: kAEReallyLogOut), .logOut)
        XCTAssertEqual(QuitRecord.Reason(quitEventReason: kAEShowRestartDialog), .restart)
        XCTAssertEqual(QuitRecord.Reason(quitEventReason: kAERestart), .restart)
        XCTAssertEqual(QuitRecord.Reason(quitEventReason: kAEShowShutdownDialog), .shutDown)
        XCTAssertEqual(QuitRecord.Reason(quitEventReason: kAEShutDown), .shutDown)
    }
}
