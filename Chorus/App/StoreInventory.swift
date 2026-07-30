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
    /// Opened via `openReadOnly`, whose doc explains why the plain read-only
    /// open never uses `immutable=1`, and the narrow case where the fallback
    /// does.
    static func readContent(at url: URL) -> StoreContent? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let db = openReadOnly(url) else { return nil }
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
        guard let db = openReadOnly(url) else { return false }
        defer { sqlite3_close(db) }
        return scalarText(db, "PRAGMA integrity_check(1);") == "ok"
    }

    // MARK: - SQLite helpers

    /// Opens `url` read-only with a busy timeout, or nil if that fails. Not
    /// `private`: `StoreRepair.spaceCount` shares this opener rather than
    /// keeping its own copy, so the fallback below only has to be written once.
    ///
    /// Tries a plain read-only open first — never URI-style, never
    /// `immutable=1` on this path: a `.bak` can sit beside a `-wal` holding
    /// committed-but-uncheckpointed rows, and an immutable open ignores the
    /// WAL, which would silently under-count it.
    ///
    /// A WAL-mode SQLite file's header records that fact permanently, even
    /// after its `-wal`/`-shm` siblings are gone (a clean close checkpoints
    /// and can remove them, and `StoreRepair.snapshot` only copies the
    /// suffixes that exist at backup time). On at least this SQLite build,
    /// such a file's plain `SQLITE_OPEN_READONLY` connection opens without
    /// error (`sqlite3_open_v2` is lazy) but then fails with `SQLITE_CANTOPEN`
    /// on the *first real read* — a read-only connection can't create the
    /// `-shm` it needs. `probeOpens` forces that first read immediately, so
    /// this can be detected here rather than surfacing later as a mysterious
    /// nil count. If the probe fails AND no `-wal` sibling exists, retry once
    /// with `immutable=1`. That retry can never hide committed rows in this
    /// specific case, because there is no `-wal` for it to ignore — the
    /// "no -wal" check is what keeps this fallback from ever applying to the
    /// case the plain-open rule above exists to protect.
    static func openReadOnly(_ url: URL) -> OpaquePointer? {
        if let db = rawOpen(url.path, flags: SQLITE_OPEN_READONLY) {
            if probeOpens(db) { return db }
            sqlite3_close(db)
        }

        guard !FileManager.default.fileExists(atPath: url.path + "-wal") else { return nil }

        guard let fallback = rawOpen("file:\(url.path)?immutable=1", flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI) else {
            return nil
        }
        guard probeOpens(fallback) else {
            sqlite3_close(fallback)
            return nil
        }
        return fallback
    }

    /// Opens `path` with `flags` and a busy timeout, or nil if `sqlite3_open_v2`
    /// itself reports failure. Closes any handle SQLite allocates even on
    /// failure; callers own closing the handle they get back on success.
    private static func rawOpen(_ path: String, flags: Int32) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let opened = db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(opened, 3000)
        return opened
    }

    /// Forces the lazy `sqlite3_open_v2` to actually touch the file, by
    /// reading its first page. `sqlite3_open_v2` alone can report success on a
    /// file it will fail to open once a query actually runs, which is exactly
    /// the WAL-header/no-`-shm` case this function exists to catch early.
    private static func probeOpens(_ db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

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

/// One store the user could be running on: the live file, or a backup Chorus
/// kept. `content` is nil when the file could not be read. `Hashable` so the
/// picker's `List` can bind its selection to a candidate directly.
struct StoreCandidate: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        /// The store the app is running on now.
        case live
        /// A pre-update snapshot. Version is the build it preceded, when the
        /// filename parses.
        case snapshot(version: String?)
        /// The store set aside by an earlier restore.
        case prerestore
        /// The store set aside before dangling-link repair. Damaged by
        /// definition, so never preselected.
        case corrupt
    }

    let url: URL
    let kind: Kind
    let takenAt: Date?
    let content: StoreContent?
    let isDamaged: Bool

    var id: String { url.path }

    /// Whether this can be restored from: a backup (not the live store) whose
    /// content is known and whose file is intact.
    var isRestorable: Bool {
        kind != .live && content != nil && !isDamaged
    }
}

extension StoreInventory {
    /// Filename infixes of the three backup families, all of which are copies of
    /// the user's own store and so all worth offering.
    private static let backupInfixes = [".snapshot-", ".prerestore-", ".corrupt-"]

    /// Every candidate for `storeURL`: the live store (whose content the caller
    /// supplies, since it is already open) plus each backup sibling. Unreadable
    /// and damaged files are included so the user can see they exist; the
    /// ranking excludes them.
    static func candidates(for storeURL: URL, liveContent: StoreContent?) -> [StoreCandidate] {
        var result: [StoreCandidate] = [
            StoreCandidate(
                url: storeURL,
                kind: .live,
                takenAt: (try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.modificationDate]) as? Date,
                content: liveContent,
                isDamaged: false
            )
        ]

        let dir = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return result
        }

        for name in names.sorted() where name.hasSuffix(".bak") {
            guard let infix = backupInfixes.first(where: { name.hasPrefix(base + $0) }) else { continue }
            let url = dir.appending(path: name)
            // Shared with StoreRepair rather than reimplemented; see the task's
            // "Reuse, not duplication" note.
            let parsed = StoreRepair.stampAndVersion(name, prefix: base + infix)
            let kind: StoreCandidate.Kind
            switch infix {
            case ".snapshot-": kind = .snapshot(version: parsed.version)
            case ".prerestore-": kind = .prerestore
            default: kind = .corrupt
            }
            let content = readContent(at: url)
            result.append(StoreCandidate(
                url: url,
                kind: kind,
                takenAt: parsed.stamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                content: content,
                // Only pay for an integrity check on a file we could read at all.
                isDamaged: content == nil || !passesIntegrityCheck(at: url)
            ))
        }
        return result
    }

}
