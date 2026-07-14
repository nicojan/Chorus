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
}
