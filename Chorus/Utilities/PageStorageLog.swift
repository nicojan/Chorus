import Foundation
import ChorusEngine

/// What each page did with IndexedDB that could explain lost data, one JSON
/// line per event in `page-storage-log.jsonl`, next to the quit record.
///
/// WhatsApp Web showed "A database error occurred … relink" on 1.5.32 after a
/// clean quit. It deleted and rebuilt its databases 35 s after launch, and
/// WebKit logged no error. The page's own error was the missing piece; this
/// file keeps it. Read it alongside `quit-log.jsonl`, whose launch lines carry
/// the same pid.
enum PageStorageLog {
    static let fileName = "page-storage-log.jsonl"

    /// The newest lines kept, trimmed at launch. A page logs a handful of
    /// lines a load, so this covers weeks.
    static let maxLines = 3000

    struct Entry: Codable, Equatable {
        var at: Date
        var pid: Int32
        var service: String
        var label: String?
        var event: PageStorageEvent
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static func line(for entry: Entry) -> String {
        guard let data = try? encoder.encode(entry), let text = String(data: data, encoding: .utf8) else { return "" }
        return text + "\n"
    }

    /// Beside the quit record, so Debug and release keep separate files.
    static var fileURL: URL {
        QuitRecord.fileURL.deletingLastPathComponent().appending(path: fileName)
    }

    /// Adds one line to the end of the file. Events can come in bursts, so
    /// this appends rather than rewriting; `trim` keeps the size down. A
    /// failure is logged and otherwise ignored.
    static func append(_ entry: Entry, to file: URL = fileURL) {
        let data = Data(line(for: entry).utf8)
        do {
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            }
        } catch {
            AppLogger.general.error("Could not write the page storage log: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops the oldest lines past `maxLines`. Called once at launch.
    static func trim(_ file: URL = fileURL, keeping count: Int = maxLines) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let trimmed = QuitRecord.trimmed(text, keeping: count)
        guard trimmed != text else { return }
        do {
            try trimmed.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            AppLogger.general.error("Could not trim the page storage log: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records one event from a page.
    static func note(_ event: PageStorageEvent, service: UUID, label: String?, now: Date = .now) {
        append(Entry(at: now, pid: QuitRecord.pid, service: service.uuidString, label: label, event: event))
    }
}
