import Foundation
import ChorusEngine

/// One line for every launch and every quit, kept in a small file next to the
/// store (`quit-log.jsonl`), so a quit that cut a page off can be read about
/// later. The system log was meant to hold this, but it had already dropped
/// Chorus's lines by the time anyone looked: WhatsApp showed "A database error
/// occurred" on 1.5.31, and how the run before it had quit could no longer be
/// told.
///
/// A launch that finds the last line is a launch with no quit after it writes
/// a `missedQuit` line: that run crashed, was force quit or was killed, and
/// never got to wait for its pages' writes.
enum QuitRecord {
    static let fileName = "quit-log.jsonl"

    /// The newest lines kept. A few a day, so this covers months.
    static let maxLines = 500

    enum Event: String, Codable, Equatable {
        case launch
        case quit
        case missedQuit
    }

    /// What asked for the quit.
    enum Reason: String, Codable, Equatable {
        /// The Quit menu item or ⌘Q, in the app menu or the menu bar extra.
        case menu
        /// A quit Apple Event with no reason given: the Dock's Quit or a script.
        case quitEvent
        case logOut
        case restart
        case shutDown
        /// A restart Chorus arms itself, after a store restore or fresh start.
        case relaunch
        /// Anything that calls `terminate` directly, which is Sparkle
        /// installing an update.
        case other

        /// The reason the quit Apple Event carries in `kAEQuitReason`.
        init(quitEventReason: OSType?) {
            switch quitEventReason {
            case kAELogOut, kAEReallyLogOut: self = .logOut
            case kAEShowRestartDialog, kAERestart: self = .restart
            case kAEShowShutdownDialog, kAEShutDown: self = .shutDown
            default: self = .quitEvent
            }
        }
    }

    struct Entry: Codable, Equatable {
        var event: Event
        var at: Date
        var version: String
        var pid: Int32
        var reason: String?
        /// Live pages when the quit began.
        var pages: Int?
        /// How long the quit waited for IndexedDB writes to finish.
        var writeWaitMs: Int?
        /// False when the writes were still going at the limit.
        var settled: Bool?
        /// From the quit being asked for to the app being let go.
        var totalMs: Int?
        /// For `missedQuit`: when the run that never quit had launched.
        var launchedAt: Date?

        static func launch(at: Date, version: String, pid: Int32) -> Entry {
            Entry(event: .launch, at: at, version: version, pid: pid)
        }
    }

    // MARK: - Pure

    /// The line to add at launch when the last run never quit, or nil.
    static func missedQuit(in entries: [Entry], now: Date) -> Entry? {
        guard let last = entries.last, last.event == .launch else { return nil }
        return Entry(event: .missedQuit, at: now, version: last.version, pid: last.pid, launchedAt: last.at)
    }

    /// Dates as ISO 8601, so the file reads as it is.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func line(for entry: Entry) -> String {
        guard let data = try? encoder.encode(entry), let text = String(data: data, encoding: .utf8) else { return "" }
        return text + "\n"
    }

    static func entries(from text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    static func trimmed(_ text: String, keeping count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > count else { return text }
        return lines.suffix(count).map { $0 + "\n" }.joined()
    }

    // MARK: - File

    /// Beside the store: `Chorus-debug` for a Debug build, `Chorus` for a
    /// release build. Debug and release never write each other's record.
    static var fileURL: URL {
        #if DEBUG
        let folder = "Chorus-debug"
        #else
        let folder = StoreRelocation.folderName
        #endif
        return URL.applicationSupportDirectory.appending(path: folder).appending(path: fileName)
    }

    static func read(_ file: URL = fileURL) -> [Entry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return entries(from: text)
    }

    /// Adds `entry` and drops the oldest lines past `maxLines`. A failure is
    /// logged and otherwise ignored: the record must never stand in the way of
    /// a launch or a quit.
    static func append(_ entry: Entry, to file: URL = fileURL) {
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let text = trimmed(existing + line(for: entry), keeping: maxLines)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            AppLogger.general.error("Could not write the quit record: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - App

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static var pid: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// Called once at launch: notes a run that never quit, then this launch.
    static func noteLaunch(now: Date = .now) {
        if let missed = missedQuit(in: read(), now: now) {
            AppLogger.general.error("The last run (pid \(missed.pid, privacy: .public), launched \(missed.launchedAt?.description ?? "?", privacy: .public)) ended without quitting")
            append(missed)
        }
        append(.launch(at: now, version: version, pid: pid))
    }

    /// Called once the quit has done its waiting, right before the app goes.
    static func noteQuit(reason: Reason, pages: Int, wait: WriteWait?, since start: ContinuousClock.Instant) {
        let total = ContinuousClock.now - start
        append(Entry(
            event: .quit, at: .now, version: version, pid: pid,
            reason: reason.rawValue, pages: pages,
            writeWaitMs: wait.map { milliseconds($0.waited) }, settled: wait?.settled,
            totalMs: milliseconds(total)
        ))
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }

    /// What the wait for IndexedDB writes saw. See `AppState.releasePagesForQuit`.
    struct WriteWait: Equatable {
        var waited: Duration
        var settled: Bool
    }
}
