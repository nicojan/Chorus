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
/// open container for the live store. `Hashable` because `StoreCandidate`
/// carries one and tests compare values directly; ranking is done by
/// `holdsMore(than:)` below and by `StoreInventory.isRankedAbove(_:_:)`, not by
/// `Comparable` conformance — this type has none.
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
/// kept. `content` is nil when the file could not be read. `Hashable` for
/// equality in tests and set-backed lookups; the picker's `List` binds
/// selection to `StoreCandidate.ID` (a plain `String`), not to the candidate
/// itself — see `selectionID` in `StoreRecoveryView`.
struct StoreCandidate: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        /// The store the app is running on now.
        case live
        /// A pre-update snapshot. Version is the build it preceded, when the
        /// filename parses.
        case snapshot(version: String?)
        /// The store set aside by an earlier *automatic* restore
        /// (`StoreRepair.restoreFromSnapshot`).
        case prerestore
        /// The store set aside before dangling-link repair. Damaged by
        /// definition, so never preselected.
        case corrupt
        /// The store set aside by `StoreRepair.applyPendingRestore` just
        /// before putting the user's deliberately chosen backup in place.
        /// Its own family, separate from `.prerestore`: `restoreFromSnapshot`
        /// tests for the presence of any `.prerestore-`-prefixed file as its
        /// "already backed up" sentinel, and a deliberate restore's aside must
        /// never satisfy that check.
        case prepick
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

/// The picker row's two display strings. Hoisted out of `StoreRecoveryView` so
/// the label matrix — five kinds, singular/plural counts, the unknown-date and
/// nil-content fallbacks, the damaged marker, and the live row's own rule — is
/// unit-testable without a running `AppState` or any SwiftUI machinery.
extension StoreCandidate {
    /// A one-line label naming which store this candidate is. Exhaustive over
    /// `Kind`, deliberately with no `default:` case: a new backup family added
    /// there must get its own label rather than silently falling through to
    /// the wrong text.
    var displayTitle: String {
        switch kind {
        case .live: return "Your data now"
        case .snapshot(let version): return version.map { "Backup from before \($0)" } ?? "Backup from before an update"
        case .prerestore: return "Backup from an earlier restore"
        case .corrupt: return "Backup from before a repair"
        case .prepick: return "Your data before you restored a backup"
        }
    }

    /// The row's secondary line: what the store holds, plus when it was taken
    /// for a backup.
    ///
    /// The live row omits the date entirely. `takenAt` for `.live` is the main
    /// `.store` file's modification time (see `StoreInventory.candidates`),
    /// and under WAL journaling that timestamp lags the real last write — the
    /// live row could show an older date than a backup while actually holding
    /// the newer data, which argues for restoring the wrong copy. The `Current`
    /// capsule already marks which row this is, so nothing is lost by leaving
    /// the date off.
    var displayDetail: String {
        let counts: String
        if let content {
            let spaces = content.spaces == 1 ? "1 space" : "\(content.spaces) spaces"
            let services = content.services == 1 ? "1 service" : "\(content.services) services"
            // `content == nil` is the only unreadable case (see below), so a
            // damaged-but-readable file is the only place this marker applies;
            // it can never double up with the nil-content "can't be read" text.
            let damaged = isDamaged ? " — damaged" : ""
            counts = "\(spaces), \(services)\(damaged)"
        } else {
            counts = "can't be read"
        }
        guard kind != .live else { return counts }
        return "\(dateDescription) — \(counts)"
    }

    private var dateDescription: String {
        guard let takenAt else { return "date unknown" }
        return Self.dateFormatter.string(from: takenAt)
    }

    /// One formatter, not one per row per redraw.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

extension StoreInventory {
    /// The four backup families, all of which are copies of the user's own
    /// store and so all worth offering. An enum, not bare strings, so the
    /// switch in `candidates(for:liveContent:)` is exhaustive: adding a family
    /// here without giving it a `StoreCandidate.Kind` case is a compile error,
    /// not a silent fall-through to `.corrupt`.
    private enum BackupFamily: String, CaseIterable {
        case snapshot = ".snapshot-"
        case prerestore = ".prerestore-"
        case corrupt = ".corrupt-"
        case prepick = ".prepick-"
    }

    /// Filename infixes of the backup families, derived from `BackupFamily` so
    /// there is exactly one list of them. Not `private`: `StoreRepair
    /// .validatedRestoreName` reuses this rather than keeping its own
    /// hand-written literal, so a new family added to `BackupFamily` can't
    /// silently fail to be validated.
    static var backupInfixes: [String] { BackupFamily.allCases.map(\.rawValue) }

    /// Every candidate for `storeURL`: the live store (whose content the caller
    /// supplies, since it is already open) plus each backup sibling, ordered
    /// most-complete-first (see `isRankedAbove`). Unreadable and damaged files
    /// are included so the user can see they exist, but sort to the bottom of
    /// the backups; the live row always leads regardless of ranking.
    static func candidates(for storeURL: URL, liveContent: StoreContent?) -> [StoreCandidate] {
        let live = StoreCandidate(
            url: storeURL,
            kind: .live,
            takenAt: (try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.modificationDate]) as? Date,
            content: liveContent,
            isDamaged: false
        )

        let dir = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return [live]
        }

        var backups: [StoreCandidate] = []
        for name in names where name.hasSuffix(".bak") {
            guard let infix = backupInfixes.first(where: { name.hasPrefix(base + $0) }),
                  let family = BackupFamily(rawValue: infix) else { continue }
            let url = dir.appending(path: name)
            // Shared with StoreRepair rather than reimplemented; see the task's
            // "Reuse, not duplication" note.
            let parsed = StoreRepair.stampAndVersion(name, prefix: base + infix)
            let kind: StoreCandidate.Kind
            switch family {
            case .snapshot: kind = .snapshot(version: parsed.version)
            case .prerestore: kind = .prerestore
            case .corrupt: kind = .corrupt
            case .prepick: kind = .prepick
            }
            let content = readContent(at: url)
            backups.append(StoreCandidate(
                url: url,
                kind: kind,
                takenAt: parsed.stamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                content: content,
                // Only pay for an integrity check on a file we could read at all.
                isDamaged: content == nil || !passesIntegrityCheck(at: url)
            ))
        }
        // Most-complete-first, the same rule the picker uses to choose a
        // winner — not filename order, which put the always-damaged
        // `.corrupt-` family directly under "Current" and buried the newest
        // snapshot at the bottom (review Finding 4).
        backups.sort(by: isRankedAbove)
        return [live] + backups
    }

}

extension StoreInventory {
    /// Whether `lhs` ranks above `rhs` for display and selection: restorable
    /// candidates always outrank non-restorable ones (unreadable or damaged),
    /// and among restorable candidates, more services wins, then more spaces,
    /// then more links, then the more recent one.
    ///
    /// Shared by `best(among:)`, which picks the single winner, and
    /// `candidates(for:liveContent:)`, which orders the whole displayed list —
    /// so "more complete" means the same thing wherever a candidate is ranked,
    /// and a damaged `.corrupt-` backup can never sort above a good
    /// `.snapshot-` the way a plain filename sort did.
    static func isRankedAbove(_ lhs: StoreCandidate, _ rhs: StoreCandidate) -> Bool {
        switch (lhs.isRestorable, rhs.isRestorable) {
        case (true, false): return true
        case (false, true): return false
        case (false, false): return false
        case (true, true): break
        }
        // Both restorable, so both have non-nil content by definition.
        let l = lhs.content!
        let r = rhs.content!
        if l.services != r.services { return l.services > r.services }
        if l.spaces != r.spaces { return l.spaces > r.spaces }
        if l.links != r.links { return l.links > r.links }
        return (lhs.takenAt ?? .distantPast) > (rhs.takenAt ?? .distantPast)
    }

    /// The fullest restorable candidate: most services, then most spaces, then
    /// most links, then the most recent. Excludes the live store, damaged files,
    /// and files whose content is unknown.
    static func best(among candidates: [StoreCandidate]) -> StoreCandidate? {
        candidates
            .filter(\.isRestorable)
            .sorted(by: isRankedAbove)
            .first
    }

    /// The candidate to preselect in the picker, or nil to make the user choose.
    ///
    /// Deliberately narrower than `best`. Preselecting is only safe when the live
    /// store holds nothing of the user's: empty, unreadable, or the untouched
    /// seed. When they still have their own spaces, restoring a fuller but older
    /// backup would discard everything they did since, and only they can weigh
    /// that. A `.corrupt` backup is never preselected because that store was
    /// damaged when it was set aside — but that only rules out `.corrupt`
    /// itself, not preselection outright: the next-best non-corrupt candidate is
    /// still considered, since preselection only runs when the live store holds
    /// nothing of the user's, which is exactly when handing back "nothing
    /// selected" is worst.
    static func preselection(among candidates: [StoreCandidate], liveContent: StoreContent?) -> StoreCandidate? {
        let liveHoldsUsersData = liveContent.map { !$0.isEmpty && !$0.looksLikeUntouchedSeed } ?? false
        guard !liveHoldsUsersData else { return nil }
        guard let winner = best(among: candidates.filter { $0.kind != .corrupt }) else { return nil }
        // Nothing to gain from a backup that holds no more than what is there.
        if let live = liveContent, let content = winner.content, !content.holdsMore(than: live) { return nil }
        return winner
    }
}

/// Why Chorus is offering to restore.
enum StoreRecoveryOffer: Equatable, Sendable {
    /// The live store holds less than Chorus recorded for it: some of the
    /// user's data went missing between launches.
    case belowRecord
    /// There is no record to compare against and the live store holds nothing
    /// of the user's, so there is nothing to weigh against restoring.
    case nothingToLose
}

extension StoreInventory {
    /// Whether to offer a restore, and why.
    ///
    /// Two conditions always hold: a backup exists holding more than the live
    /// store, and the user has not already declined this same pairing. Then one
    /// of two triggers fires.
    ///
    /// Trigger 2 is not redundant. Someone who lost their spaces on 1.5.14 or
    /// earlier has no record on their first launch of a build that writes one,
    /// and their store holds the seed, so trigger 1 can never fire for them.
    /// Without trigger 2 this feature would miss the user who reported the bug.
    static func offer(
        liveContent: StoreContent?,
        best: StoreCandidate?,
        record: StoreContent?,
        declinedKeys: Set<String>
    ) -> StoreRecoveryOffer? {
        guard let best, let backup = best.content, best.isRestorable else { return nil }
        // A backup has to actually cover the gap. An unreadable live store
        // counts as covered: anything readable beats nothing.
        if let live = liveContent, !backup.holdsMore(than: live) { return nil }
        if declinedKeys.contains(declineKey(live: liveContent, candidate: best)) { return nil }

        if let record, let live = liveContent, record.holdsMore(than: live) { return .belowRecord }
        if let record, liveContent == nil, !record.isEmpty { return .belowRecord }

        let liveHoldsUsersData = liveContent.map { !$0.isEmpty && !$0.looksLikeUntouchedSeed } ?? false
        if !liveHoldsUsersData { return .nothingToLose }
        return nil
    }

    /// Identifies one pairing of backup and live state, so declining is
    /// remembered for that pairing only. When either side changes, Chorus may
    /// ask again, which is what makes a stale decline self-correcting.
    static func declineKey(live: StoreContent?, candidate: StoreCandidate) -> String {
        let liveSignature = live.map { "\($0.spaces)-\($0.services)-\($0.links)" } ?? "unknown"
        return "\(candidate.url.lastPathComponent)|\(liveSignature)"
    }

    /// The record's string form, kept readable so `defaults read` shows
    /// something meaningful during support.
    static func encodeRecord(_ content: StoreContent) -> String {
        "\(content.spaces)-\(content.services)-\(content.links)"
    }

    /// Parses `encodeRecord`'s output. Anything else is treated as no record,
    /// never as an empty store.
    static func decodeRecord(_ raw: String?) -> StoreContent? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "-").map(String.init)
        guard parts.count == 3,
              let spaces = Int(parts[0]),
              let services = Int(parts[1]),
              let links = Int(parts[2]) else { return nil }
        return StoreContent(spaces: spaces, services: services, links: links, spaceNames: [], serviceLabels: [])
    }
}
