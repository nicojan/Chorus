import Foundation
import SQLite3

/// The spaces and services `seedDefaultDataIfNeeded` writes on a genuine fresh
/// install. Shared with `StoreContent.looksLikeUntouchedSeed` so the seeder and
/// the fingerprint can never drift apart; `testSeededStoreIsFingerprintedAsSeed`
/// fails if they do.
enum DefaultSeed {
    static let spaces: [(name: String, emoji: String)] = [
        (name: "Personal", emoji: "🏠"),
        (name: "Work", emoji: "💼"),
    ]

    static let personalServices: [(label: String, url: String, catalogID: String)] = [
        (label: "Gmail", url: "https://mail.google.com/mail/u/0/#inbox", catalogID: "gmail"),
        (label: "Discord", url: "https://discord.com/channels/@me", catalogID: "discord"),
        (label: "ChatGPT", url: "https://chatgpt.com", catalogID: "chatgpt"),
        (label: "Claude", url: "https://claude.ai", catalogID: "claude"),
    ]

    static let workServices: [(label: String, url: String, catalogID: String)] = [
        (label: "Gmail", url: "https://mail.google.com/mail/u/0/#inbox", catalogID: "gmail"),
        (label: "Slack", url: "https://app.slack.com/client", catalogID: "slack"),
        (label: "Outlook", url: "https://outlook.cloud.microsoft/mail/", catalogID: "outlook"),
    ]

    /// Every seeded service label, including the duplicate Gmail that appears in
    /// both spaces. Compared as a multiset, so the duplicate matters.
    static var allServiceLabels: [String] {
        (personalServices + workServices).map(\.label)
    }
}

/// What a store holds. Read from a raw SQLite file for a backup, or from the
/// open container for the live store. Comparable so candidates can be ranked
/// without opening anything. `Hashable` because `StoreCandidate` carries one and
/// the picker's `List` selection binds to the candidate itself.
struct StoreContent: Hashable, Sendable {
    let spaces: Int
    let services: Int
    let links: Int
    /// Space names and service labels, used only to recognize the untouched
    /// default seed. Order is not significant; both are compared as multisets.
    let spaceNames: [String]
    let serviceLabels: [String]

    var isEmpty: Bool { spaces == 0 && services == 0 }

    /// Whether this store holds more than `other`: more services, or the same
    /// services spread over more spaces. The single comparison the ranking and
    /// both offer triggers share, so "more complete" means one thing everywhere.
    func holdsMore(than other: StoreContent) -> Bool {
        if services != other.services { return services > other.services }
        return spaces > other.spaces
    }

    /// True only when the store is exactly what `seedDefaultDataIfNeeded`
    /// writes: the two seeded spaces, the seven seeded services, nothing added,
    /// nothing renamed. A store like this holds nothing of the user's, which is
    /// what makes it safe to preselect a backup over.
    var looksLikeUntouchedSeed: Bool {
        spaces == DefaultSeed.spaces.count
            && services == DefaultSeed.allServiceLabels.count
            && spaceNames.sorted() == DefaultSeed.spaces.map(\.name).sorted()
            && serviceLabels.sorted() == DefaultSeed.allServiceLabels.sorted()
    }
}

/// Reads store files without opening a `ModelContainer`, so candidates can be
/// inspected and ranked before anything migrates or locks them. Read-only
/// throughout: nothing here writes to a store.
enum StoreInventory {
    private static let spaceTable = "ZSPACE"
    private static let serviceTable = "ZSERVICEINSTANCE"
    private static let linkTable = "ZSPACESERVICELINK"

    /// What the store at `url` holds, or nil when that cannot be established:
    /// no file, a file that is not a database, or a schema without the tables
    /// this app owns. Nil is "unknown" and callers must not read it as empty.
    ///
    /// Opened read-only and deliberately WITHOUT `immutable=1`: a `.bak` can sit
    /// beside a `-wal` holding committed rows, and an immutable open ignores the
    /// WAL, which would under-count a backup and could cost it the ranking.
    static func readContent(at url: URL) -> StoreContent? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        defer { sqlite3_close(db) }

        // Require this app's tables before counting; an unrecognized schema is
        // unknown, not empty.
        let known = scalarInt(db, """
            SELECT COUNT(*) FROM sqlite_master WHERE type='table'
             AND name IN ('\(spaceTable)','\(serviceTable)','\(linkTable)');
            """) ?? 0
        guard known == 3 else { return nil }

        guard let spaces = scalarInt(db, "SELECT COUNT(*) FROM \(spaceTable);"),
              let services = scalarInt(db, "SELECT COUNT(*) FROM \(serviceTable);"),
              let links = scalarInt(db, "SELECT COUNT(*) FROM \(linkTable);") else {
            return nil
        }
        return StoreContent(
            spaces: spaces,
            services: services,
            links: links,
            spaceNames: textColumn(db, "SELECT ZNAME FROM \(spaceTable);"),
            serviceLabels: textColumn(db, "SELECT ZLABEL FROM \(serviceTable);")
        )
    }

    /// Whether the store at `url` passes an integrity check. `(1)` stops at the
    /// first error, which bounds the cost when several candidates are checked at
    /// launch.
    static func passesIntegrityCheck(at url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return false
        }
        sqlite3_busy_timeout(db, 3000)
        defer { sqlite3_close(db) }
        return scalarText(db, "PRAGMA integrity_check(1);") == "ok"
    }

    // MARK: - SQLite helpers

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func scalarText(_ db: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    /// Every non-null value of a single text column. Nulls are skipped rather
    /// than turned into empty strings, so a null name cannot look like a rename.
    private static func textColumn(_ db: OpaquePointer, _ sql: String) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var values: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                values.append(String(cString: cString))
            }
        }
        return values
    }
}
