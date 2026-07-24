import Foundation
import SQLite3

/// One-time, launch-time repair for stores corrupted by a build that shipped
/// before `Space.serviceLinks` declared its inverse. Without the inverse the
/// `.cascade` delete rule never fired, so deleting a space left its
/// `SpaceServiceLink` rows behind with a dangling `space` — a non-optional
/// to-one pointing at a deleted row. On the next launch, reading that
/// relationship (e.g. the badge sweep's `link.space.id`) faults the deleted
/// `Space`, hits SwiftData's "backing data could no longer be found" assertion,
/// and crashes before any UI — permanently, until the store is deleted by hand.
///
/// The corruption can only be removed *outside* SwiftData: any object-graph
/// delete faults the dead space on save, and a batch delete refuses to nullify
/// the mandatory `service` inverse. So this operates on the SQLite file
/// directly, **before** the `ModelContainer` opens — Core Data never sees the
/// bad rows and so never faults them. It deletes only orphaned join rows
/// (a dangling `space` or `service`); every space, service, and valid link is
/// preserved. It is best-effort: any failure logs and falls through to the
/// normal open, where the existing in-memory fallback + banner remain the last
/// line of defense.
enum StoreRepair {
    /// Column/table names are Core Data-derived and stable for this schema.
    private static let linkTable = "ZSPACESERVICELINK"
    private static let spaceTable = "ZSPACE"
    private static let serviceTable = "ZSERVICEINSTANCE"

    /// Rows whose `space` or `service` foreign key points at a missing row.
    /// `IS NULL` is spelled out because `NULL NOT IN (…)` is NULL, not true, so
    /// `NOT IN` alone would skip a null FK.
    private static let danglingPredicate = """
        ZSPACE IS NULL OR ZSPACE NOT IN (SELECT Z_PK FROM ZSPACE) \
        OR ZSERVICE IS NULL OR ZSERVICE NOT IN (SELECT Z_PK FROM ZSERVICEINSTANCE)
        """

    /// Deletes dangling join rows from the store at `url` if any exist. Safe to
    /// call on a healthy store (no writes), a missing store (first launch), or a
    /// store with an unrecognized schema (skips without guessing). Must run
    /// while no `ModelContainer`/SQLite connection is open on the same file.
    static func repairDanglingLinks(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else {
            AppLogger.dataStore.error("StoreRepair: could not open store at \(url.path)")
            if let db { sqlite3_close(db) }
            return
        }
        // Wait instead of failing immediately if the file is transiently locked
        // (e.g. a lingering WAL from the previous run). This runs before the
        // ModelContainer opens, so contention should be brief.
        sqlite3_busy_timeout(db, 3000)
        defer {
            // All prepared statements are finalized (scalarInt/exec do so), so a
            // non-OK close is unexpected — log rather than swallow it.
            if sqlite3_close(db) != SQLITE_OK {
                AppLogger.dataStore.error("StoreRepair: sqlite3_close did not return OK")
            }
        }

        // Schema guard — only proceed against the exact tables/columns we know.
        // An unexpected schema (a future rename) is skipped, never guessed at.
        guard schemaMatches(db) else {
            AppLogger.dataStore.info("StoreRepair: schema not recognized; skipping")
            return
        }

        // Gate: leave a healthy store completely untouched.
        let countSQL = "SELECT COUNT(*) FROM \(linkTable) WHERE \(danglingPredicate);"
        guard let before = scalarInt(db, countSQL) else {
            AppLogger.dataStore.error("StoreRepair: dangling-count query failed; skipping")
            return
        }
        guard before > 0 else { return }

        AppLogger.dataStore.info("StoreRepair: found \(before) dangling link(s); repairing")

        // Back up the store (+ WAL/SHM) before mutating — the policy is never to
        // destroy the user's data without a way back.
        backupStore(at: url)

        let deleteSQL = "DELETE FROM \(linkTable) WHERE \(danglingPredicate);"
        guard exec(db, "BEGIN;"),
              exec(db, deleteSQL),
              exec(db, "COMMIT;") else {
            AppLogger.dataStore.error("StoreRepair: delete failed; rolling back")
            _ = exec(db, "ROLLBACK;")
            return
        }

        let after = scalarInt(db, countSQL) ?? -1
        AppLogger.dataStore.info("StoreRepair: dangling links before=\(before) after=\(after)")
    }

    /// Counts `Space` rows in the store at `url` by reading the raw SQLite file,
    /// **before** any `ModelContainer` opens or migrates it. Returns the row
    /// count, or `nil` when the count can't be established — no file yet (first
    /// launch), the file can't be opened, or the `ZSPACE` table isn't present
    /// (unrecognized schema). `nil` therefore means "unknown", never "zero": the
    /// caller must not treat it as an empty store.
    ///
    /// `AppState.loadContainer` uses this to tell a genuine fresh install (no
    /// file → `nil`) apart from a store that *had* spaces on disk but came up
    /// empty after opening — the signature of a silent migration failure. The
    /// caller then auto-restores the newest usable snapshot rather than letting
    /// the seed overwrite recoverable data. Reads only; never writes.
    static func spaceCount(at url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        defer { sqlite3_close(db) }

        // Only count when the table is actually there; a missing table means an
        // unrecognized schema, which is "unknown" (nil), not an empty store.
        let hasTable = scalarInt(db, """
            SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(spaceTable)';
            """) ?? 0
        guard hasTable == 1 else { return nil }
        return scalarInt(db, "SELECT COUNT(*) FROM \(spaceTable);")
    }

    // MARK: - Restore from snapshot

    /// A pre-migration snapshot judged safe to restore from, plus what the
    /// filename records about when it was taken and which version it preceded.
    struct RestoreCandidate: Equatable {
        /// The snapshot's primary `.bak` file (its `-wal`/`-shm` are siblings).
        let primaryURL: URL
        /// The app version stamped into the filename (e.g. `1.5.12+21`), or nil
        /// if the name didn't parse.
        let version: String?
        /// When the snapshot was taken, from the filename's Unix-second stamp.
        let takenAt: Date?
    }

    /// True when the snapshot at `url` is safe to restore from: it opens, passes
    /// `PRAGMA integrity_check`, and holds at least one `Space`. Reads only.
    static func snapshotHasUsableData(at url: URL) -> Bool {
        guard (spaceCount(at: url) ?? 0) > 0 else { return false }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return false
        }
        sqlite3_busy_timeout(db, 3000)
        defer { sqlite3_close(db) }
        // `(1)` stops at the first error — we only need ok/not-ok, and this
        // bounds the check's cost at launch on a large store.
        return scalarText(db, "PRAGMA integrity_check(1);") == "ok"
    }

    /// The newest pre-migration snapshot of the store at `storeURL` that is safe
    /// to restore from, or nil if none qualifies. Walks the `.snapshot-*.bak`
    /// siblings newest-first (by the filename's Unix-second stamp) and returns
    /// the first that `snapshotHasUsableData` — so an empty or corrupt snapshot
    /// is skipped in favor of an older good one.
    static func newestRestorableSnapshot(for storeURL: URL) -> RestoreCandidate? {
        let fm = FileManager.default
        let dir = storeURL.deletingLastPathComponent()
        let prefix = storeURL.lastPathComponent + snapshotInfix
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }

        // Primary snapshot files only (skip the -wal/-shm siblings), newest-first
        // by the numeric stamp parsed from the name.
        let primaries = names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }
            // Newest-first by the numeric stamp; an unparseable name sorts oldest.
            .sorted { (stampAndVersion($0, prefix: prefix).stamp ?? .min) > (stampAndVersion($1, prefix: prefix).stamp ?? .min) }

        for name in primaries {
            let url = dir.appending(path: name)
            guard snapshotHasUsableData(at: url) else { continue }
            let parsed = stampAndVersion(name, prefix: prefix)
            return RestoreCandidate(
                primaryURL: url,
                version: parsed.version,
                takenAt: parsed.stamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
        return nil
    }

    /// Restores the snapshot triple at `candidate` over the store at `storeURL`.
    /// The current (bad) triple is first moved aside to a single
    /// `<name>.prerestore-<stamp>.bak` — never destroyed — so even a failed
    /// migration's output is recoverable; a second attempt skips re-backing-up so
    /// a deterministic-failure loop can't bloat the directory. Returns whether the
    /// primary file was put in place. Must run while no `ModelContainer` holds the
    /// store open.
    static func restoreFromSnapshot(_ candidate: RestoreCandidate, to storeURL: URL) -> Bool {
        let fm = FileManager.default
        let dir = storeURL.deletingLastPathComponent()
        let baseName = storeURL.lastPathComponent

        // Back up the current triple once (skip if a prior prerestore exists).
        let alreadyBackedUp = (try? fm.contentsOfDirectory(atPath: dir.path))?
            .contains { $0.hasPrefix(baseName + ".prerestore-") } ?? false
        if !alreadyBackedUp {
            let stamp = String(Int(Date().timeIntervalSince1970))
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: storeURL.path + suffix)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = URL(fileURLWithPath: storeURL.path + ".prerestore-\(stamp).bak" + suffix)
                do { try fm.copyItem(at: src, to: dst) } catch {
                    AppLogger.dataStore.error("StoreRepair: prerestore backup of \(src.lastPathComponent) failed: \(error.localizedDescription)")
                }
            }
        }

        // Replace the live triple with the snapshot's. The snapshot's primary is
        // `<...>.bak`; its WAL/SHM are `<...>.bak-wal`/`-shm`.
        let snapshotPath = candidate.primaryURL.path
        for suffix in ["", "-wal", "-shm"] {
            let live = URL(fileURLWithPath: storeURL.path + suffix)
            try? fm.removeItem(at: live)
            let snap = URL(fileURLWithPath: snapshotPath + suffix)
            guard fm.fileExists(atPath: snap.path) else { continue }
            do {
                try fm.copyItem(at: snap, to: live)
            } catch {
                AppLogger.dataStore.error("StoreRepair: restore copy of \(snap.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
        // Report success only if the store now in place is actually usable — a
        // partial copy (e.g. a failed `-wal`) can leave a stale or empty store,
        // and the caller must not treat that as a real recovery.
        let usable = snapshotHasUsableData(at: storeURL)
        if !usable {
            AppLogger.dataStore.error("StoreRepair: restore left an unusable store at \(storeURL.lastPathComponent)")
        }
        return usable
    }

    /// Parses `<prefix><stamp>-<version>.bak` into its Unix-second stamp and
    /// version. Either may be nil if the name doesn't match. The stamp drives
    /// newest-first ordering; the version is shown in the recovery banner.
    private static func stampAndVersion(_ name: String, prefix: String) -> (stamp: Int?, version: String?) {
        guard name.hasPrefix(prefix), name.hasSuffix(".bak") else { return (nil, nil) }
        let core = String(name.dropFirst(prefix.count).dropLast(".bak".count))
        // `core` is `<stamp>-<version>`; split on the FIRST hyphen only, since the
        // version itself contains no leading hyphen but the whole thing might.
        guard let dash = core.firstIndex(of: "-") else { return (Int(core), nil) }
        let stamp = Int(core[..<dash])
        let version = String(core[core.index(after: dash)...])
        return (stamp, version.isEmpty ? nil : version)
    }

    // MARK: - Pre-migration snapshots

    /// Filename infix marking a pre-migration snapshot of the store.
    static let snapshotInfix = ".snapshot-"

    /// The running app version, as `short+build` (e.g. `1.5.7+16`). Used to
    /// decide whether a migration might be about to run.
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)+\(build)"
    }

    /// Copies the store aside before a build with a *new* version opens it, so a
    /// migration that loses or reshapes data can always be recovered. A no-op
    /// when the running version matches the last launch (no migration expected)
    /// or when no store exists yet. Keeps the most recent `keep` snapshots.
    ///
    /// `version`/`defaults` are injectable for tests; production passes the
    /// defaults. The version tag lives in the build's own `UserDefaults`, so the
    /// debug and release apps track their versions independently.
    static func backupBeforeMigrationIfNeeded(
        at url: URL,
        version: String = StoreRepair.currentVersion,
        defaults: UserDefaults = .standard,
        keeping keep: Int = 3
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let key = "chorus.storeSnapshotVersion"
        guard defaults.string(forKey: key) != version else { return }

        // Stamp with the fixed-width Unix second (so names sort by age) followed
        // by the version, which both documents what each snapshot preceded and
        // keeps two versions taken in the same second from colliding.
        let safeVersion = version.replacingOccurrences(of: "/", with: "_")
        snapshot(at: url, stamp: "\(Int(Date().timeIntervalSince1970))-\(safeVersion)")
        pruneSnapshots(at: url, keeping: keep)
        defaults.set(version, forKey: key)
    }

    /// Copies `store`(+`-wal`/`-shm`) to `store.snapshot-<stamp>.bak` siblings.
    static func snapshot(at url: URL, stamp: String) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: url.path + "\(snapshotInfix)\(stamp).bak" + suffix)
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                AppLogger.dataStore.error("StoreRepair: snapshot of \(src.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Deletes all but the `keep` most recent snapshot triples for this store.
    /// Snapshot names sort newest-last by their fixed-width Unix-second stamp, so
    /// a lexical sort orders them by age.
    static func pruneSnapshots(at url: URL, keeping keep: Int) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + snapshotInfix
        guard let all = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        // Newest-first by numeric stamp — consistent with newestRestorableSnapshot
        // (a plain lexical sort would misorder a differently-formatted stamp).
        let primaries = all
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }
            .sorted { (stampAndVersion($0, prefix: prefix).stamp ?? .min) > (stampAndVersion($1, prefix: prefix).stamp ?? .min) }
        guard primaries.count > keep else { return }

        // Retain the newest `keep`, PLUS the newest snapshot that still holds
        // usable data. Without the second clause a run of post-loss empty
        // snapshots (each version bump snapshots the emptied store) would push
        // the last good backup past `keep` and delete the only copy of real data.
        var retain = Set(primaries.prefix(keep))
        if let newestGood = primaries.first(where: { snapshotHasUsableData(at: dir.appending(path: $0)) }) {
            retain.insert(newestGood)
        }

        for name in primaries where !retain.contains(name) {
            for suffix in ["", "-wal", "-shm"] {
                let victim = dir.appending(path: name + suffix)
                if fm.fileExists(atPath: victim.path) {
                    try? fm.removeItem(at: victim)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func schemaMatches(_ db: OpaquePointer) -> Bool {
        let tables = scalarInt(db, """
            SELECT COUNT(*) FROM sqlite_master WHERE type='table'
             AND name IN ('\(linkTable)','\(spaceTable)','\(serviceTable)');
            """) ?? 0
        guard tables == 3 else { return false }
        let cols = scalarInt(db, """
            SELECT COUNT(*) FROM pragma_table_info('\(linkTable)')
             WHERE name IN ('ZSPACE','ZSERVICE');
            """) ?? 0
        return cols == 2
    }

    private static func backupStore(at url: URL) {
        let fm = FileManager.default
        // If DELETE keeps failing, repair re-runs on every launch; writing a
        // fresh timestamped triple each time would bloat the store's directory.
        // Back up only once — skip if any prior `.corrupt-*.bak` already exists.
        let dir = url.deletingLastPathComponent()
        let baseName = url.lastPathComponent
        if let siblings = try? fm.contentsOfDirectory(atPath: dir.path),
           siblings.contains(where: { $0.hasPrefix(baseName + ".corrupt-") }) {
            AppLogger.dataStore.info("StoreRepair: a backup already exists; skipping")
            return
        }
        let stamp = String(Int(Date().timeIntervalSince1970))
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: url.path + ".corrupt-\(stamp).bak" + suffix)
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                AppLogger.dataStore.error("StoreRepair: backup of \(src.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Runs a statement with no result rows. Returns whether it succeeded.
    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Runs a query whose first column of its first row is an integer.
    private static func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Runs a query whose first column of its first row is text (e.g.
    /// `PRAGMA integrity_check`). Returns nil if there's no row or the value is
    /// null.
    private static func scalarText(_ db: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }
}
