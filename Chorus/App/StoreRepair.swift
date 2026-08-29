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

    /// Whether the store at `url` currently holds dangling join rows, read
    /// without writing anything. `repairDanglingLinks` answers the same question
    /// on its way to fixing them, but it runs inside the open path and reports
    /// nothing back; callers that need to know the store arrived *damaged* — so
    /// they can hold off on anything irreversible this launch — ask here first.
    ///
    /// False for a healthy store, a missing one, and a schema this build does
    /// not recognize. Unknown is deliberately reported as "not damaged": this
    /// gates caution, and the other guards (`hadHistory`, the restore path)
    /// already cover a store that cannot be read at all.
    static func hasDanglingLinks(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let db = StoreInventory.openReadOnly(url) else { return false }
        defer { sqlite3_close(db) }
        guard schemaMatches(db) else { return false }
        return (scalarInt(db, "SELECT COUNT(*) FROM \(linkTable) WHERE \(danglingPredicate);") ?? 0) > 0
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
    ///
    /// Opens via `StoreInventory.openReadOnly` rather than its own connection,
    /// so the two share one fallback for a WAL-mode file whose `-wal` sibling
    /// is gone (see that function's doc) instead of carrying two copies of it.
    static func spaceCount(at url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let db = StoreInventory.openReadOnly(url) else { return nil }
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
    ///
    /// Opens via `StoreInventory.openReadOnly` rather than its own connection,
    /// so this integrity check gets the same WAL-header/no-`-wal` fallback as
    /// `spaceCount` above — an `integrity_check` run over an `immutable=1`
    /// connection is exactly as meaningful as one over a plain read-only
    /// connection, so nothing about what this check proves changes.
    static func snapshotHasUsableData(at url: URL) -> Bool {
        guard (spaceCount(at: url) ?? 0) > 0 else { return false }

        guard let db = StoreInventory.openReadOnly(url) else { return false }
        defer { sqlite3_close(db) }
        // `(1)` stops at the first error — we only need ok/not-ok, and this
        // bounds the check's cost at launch on a large store.
        return scalarText(db, "PRAGMA integrity_check(1);") == "ok"
    }

    /// Whether the snapshot at `url` holds data that is actually the user's, as
    /// opposed to the default seed a post-loss snapshot captures.
    ///
    /// `snapshotHasUsableData` answers "can this be opened and does it have a
    /// space", which is the right question for an automatic restore. It is the
    /// wrong question for pruning: the seed has two spaces, so a snapshot taken
    /// after the loss passes it, and protecting that one let the user's real
    /// backup age past `keep` and be deleted.
    ///
    /// `readContent` requires three tables and can fail to read a store that
    /// `snapshotHasUsableData` (which only needs `ZSPACE`) still judges usable.
    /// Unknown content is not evidence of a seed, so that case falls back to the
    /// shipped rule rather than being denied protection — pruning must never
    /// delete a backup it merely failed to read.
    static func snapshotHoldsUsersData(at url: URL) -> Bool {
        guard let content = StoreInventory.readContent(at: url) else { return snapshotHasUsableData(at: url) }
        guard !content.looksLikeUntouchedSeed else { return false }
        return snapshotHasUsableData(at: url)
    }

    /// The newest pre-migration snapshot of the store at `storeURL` that is safe
    /// to restore from, or nil if none qualifies. Walks the `.snapshot-*.bak`
    /// siblings newest-first (by the filename's Unix-second stamp) and returns
    /// the first that `snapshotHasUsableData` — so an empty or corrupt snapshot
    /// is skipped in favor of an older good one.
    static func newestRestorableSnapshot(for storeURL: URL) -> RestoreCandidate? {
        let dir = storeURL.deletingLastPathComponent()
        let prefix = storeURL.lastPathComponent + snapshotInfix
        // Shares `primariesNewestFirst` with `pruneSnapshots`/`prunePickAsides`
        // rather than repeating the same filter+sort a third time; the only
        // difference (an empty directory returning `[]` here vs. `nil` before)
        // is unobservable, since the loop below falls through to `return nil`
        // either way.
        let primaries = primariesNewestFirst(in: dir, prefix: prefix)

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
    /// Internal (not `private`) so `StoreInventory.candidates` can reuse it for
    /// the `.prerestore-`/`.corrupt-` families rather than reimplementing the
    /// same parse; a name with no version segment already returns `(stamp, nil)`,
    /// which is exactly what those two families need.
    static func stampAndVersion(_ name: String, prefix: String) -> (stamp: Int?, version: String?) {
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

    /// Backup primaries for one family, newest first by numeric stamp. A plain
    /// lexical sort would misorder a differently-formatted stamp.
    private static func primariesNewestFirst(in dir: URL, prefix: String) -> [String] {
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return all
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }
            .sorted { (stampAndVersion($0, prefix: prefix).stamp ?? .min) > (stampAndVersion($1, prefix: prefix).stamp ?? .min) }
    }

    /// Deletes all but the `keep` most recent snapshot triples for this store —
    /// except that whichever older one still holds the user's own data is
    /// always spared, even past the `keep` window (see `primariesNewestFirst`
    /// for how the newest-first order is derived).
    static func pruneSnapshots(at url: URL, keeping keep: Int) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + snapshotInfix
        let primaries = primariesNewestFirst(in: dir, prefix: prefix)
        guard primaries.count > keep else { return }

        var retain = Set(primaries.prefix(keep))
        // Protect the newest snapshot holding the USER's data, not merely the
        // newest with rows: a snapshot taken after a loss holds the default
        // seed, and protecting that one would let the real backup age out.
        if let newestUsers = primaries.first(where: { snapshotHoldsUsersData(at: dir.appending(path: $0)) }) {
            retain.insert(newestUsers)
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

    // MARK: - User-chosen restore's way-back copies

    /// Filename infix marking the store as it stood immediately before a
    /// deliberate, user-chosen restore. Its own family, separate from
    /// `snapshotInfix`/`.prerestore-`/`.corrupt-` — see `applyPendingRestore`'s
    /// doc for why it can't share `.prerestore-`.
    static let pickAsideInfix = ".prepick-"

    /// The user-chosen restore's way-back copies. Each deliberate restore writes one
    /// full triple, and no other reaper matches the family, so keep the newest few
    /// PLUS the single oldest, and delete the rest. Bounds the family at `keep + 1`.
    ///
    /// Unlike `pruneSnapshots`, no content check picks out the one worth keeping
    /// beyond the newest few — every aside is by definition the store as it stood
    /// immediately before a restore the user asked for, so there is no seed-shaped
    /// impostor to screen out. But the direction of value is the OPPOSITE of
    /// `pruneSnapshots`: the oldest aside is the store as it stood before the user
    /// began trying candidates at all, which is exactly what a run of several
    /// restores across several launches (the expected path for a picker the user
    /// needed because they couldn't tell which backup was right) would otherwise
    /// prune away first. It is also live recovery material, not internal
    /// bookkeeping — `StoreInventory.candidates`/`best` can select from this
    /// family — so a purely-recency rule would reap a candidate the picker is
    /// actively offering.
    static func prunePickAsides(at url: URL, keeping keep: Int) {
        let dir = url.deletingLastPathComponent()
        let primaries = primariesNewestFirst(in: dir, prefix: url.lastPathComponent + pickAsideInfix)
        guard let oldest = primaries.last else { return }

        var retain = Set(primaries.prefix(keep))
        retain.insert(oldest)

        for name in primaries where !retain.contains(name) {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: dir.appending(path: name + suffix))
            }
        }
    }

    // MARK: - User-chosen restore

    /// Where the user's pick waits for the next launch. The restore itself runs
    /// before the container opens, because swapping SQLite files under a live
    /// container faults deleted models and traps.
    static let resetAsideInfix = ".reset-"

    /// UserDefaults key holding a request to start fresh, written by the banner
    /// and consumed by `applyPendingReset` at the next launch.
    ///
    /// Deferred to launch for the same reason a restore is: the store must be
    /// moved while no `ModelContainer` holds it open, and the only moment that
    /// is reliably true is before the container is built.
    static let pendingResetKey = "chorus.pendingReset"

    /// Whether the store at `url` provably holds nothing.
    ///
    /// "Provably" is the point. `readContent` returns nil for a file it cannot
    /// read *and* for one whose schema it does not recognise, and neither is
    /// evidence of emptiness — an unreadable store is exactly the kind that
    /// might still hold everything. Only three zero counts read back from this
    /// app's own three tables count as proof.
    static func storeIsProvablyEmpty(at url: URL) -> Bool {
        guard let content = StoreInventory.readContent(at: url) else { return false }
        return content.spaces == 0 && content.services == 0 && content.links == 0
    }

    /// Whether any backup sibling worth protecting exists for `storeURL`,
    /// readable or not.
    ///
    /// Deliberately weaker than `newestRestorableSnapshot`, which answers "is
    /// there one we can restore from". Before deciding nothing is worth keeping,
    /// the question is the broader "is there anything here at all". A file too
    /// damaged to restore automatically is still one the user may be able to
    /// salvage by hand, and its existence should stop a fresh start.
    ///
    /// Reads `StoreInventory.preservationInfixes`, which is every backup family
    /// except `.reset-`. It used to read `snapshotInfix` alone, so a `.prepick-`,
    /// `.prerestore-` or `.corrupt-` aside holding real data did not stop a
    /// fresh start. `.reset-` stays excluded on purpose; see that property.
    static func hasAnyPreservedCopy(for storeURL: URL) -> Bool {
        let dir = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return names.contains { name in
            guard name.hasSuffix(".bak") else { return false }
            return StoreInventory.preservationInfixes.contains { name.hasPrefix(base + $0) }
        }
    }

    /// Moves the store triple aside to `<name>.reset-<stamp>.bak`, leaving no
    /// store at `url`. Returns whether the primary file is gone from `url`
    /// afterwards, which is what the caller needs before opening a fresh one.
    ///
    /// Moves rather than deletes, always. Every other path in this file treats
    /// the user's bytes as undeletable, and a fresh start is no different: the
    /// whole reason this is safe to offer is that the old store survives under a
    /// name the recovery picker already lists.
    ///
    /// A missing store is success, not failure — there is nothing to move and
    /// the postcondition ("no store at `url`") already holds.
    @discardableResult
    static func moveStoreAside(at url: URL, stamp: String = String(Int(Date().timeIntervalSince1970))) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }

        let destination = url.deletingLastPathComponent()
            .appending(path: url.lastPathComponent + resetAsideInfix + stamp + ".bak")

        // Copy first, then remove, rather than moving: a copy that fails leaves
        // the live store untouched, whereas a partial move can leave neither
        // file whole. `copyTriple` reports whether every suffix it attempted
        // actually landed.
        guard copyTriple(from: url.path, to: destination.path, label: "reset aside") else {
            AppLogger.dataStore.error("Could not set the store aside; leaving it in place rather than starting fresh over it")
            return false
        }
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        let cleared = !fm.fileExists(atPath: url.path)
        if cleared {
            AppLogger.dataStore.info("Store set aside as \(destination.lastPathComponent); starting fresh")
        } else {
            AppLogger.dataStore.error("Store copy succeeded but the original could not be removed; not starting fresh")
        }
        return cleared
    }

    /// Honours a start-fresh request written by the banner, if one is waiting.
    /// Returns whether the store was actually set aside.
    ///
    /// The key is cleared before any file work, so a crash part-way through
    /// cannot make every later launch retry the same move.
    @discardableResult
    static func applyPendingReset(
        at storeURL: URL,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.bool(forKey: pendingResetKey) else { return false }
        defaults.removeObject(forKey: pendingResetKey)
        return moveStoreAside(at: storeURL)
    }

    static let pendingRestoreKey = "chorus.pendingRestore"

    /// Validates a pending restore filename. The value comes from UserDefaults,
    /// which is outside the app's control, so it is treated as untrusted: it must
    /// be a plain filename (no separators, no traversal) belonging to this store
    /// and naming one of the four backup families.
    static func validatedRestoreName(_ name: String, storeName: String) -> String? {
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains(".."),
              name.hasSuffix(".bak") else { return nil }
        // Derived from `StoreInventory.BackupFamily` rather than a hand-written
        // literal — everything else in the family chain (`BackupFamily` → the
        // `Kind` switch → the `displayTitle` switch) is compiler-enforced
        // exhaustive; this used to be the one exception, so a fifth family
        // could be enumerated and offered by the picker yet silently rejected
        // here at the next launch.
        guard StoreInventory.backupInfixes.contains(where: { name.hasPrefix(storeName + $0) }) else { return nil }
        return name
    }

    /// Puts the user's chosen backup in place, if one is waiting. Returns whether
    /// a restore actually happened.
    ///
    /// The key is cleared before any file work, so a crash part-way through
    /// cannot make the next launch retry forever. The current store is always
    /// copied aside first, with a fresh stamp every time: unlike
    /// `restoreFromSnapshot`, which keeps one copy for an automatic retry loop,
    /// each deliberate restore is a separate decision and deserves its own way
    /// back. If the result cannot be read, the copy is put back.
    ///
    /// The aside copy uses its own `.prepick-` family rather than
    /// `.prerestore-`. `restoreFromSnapshot`'s "already backed up" sentinel
    /// treats the presence of ANY `.prerestore-`-prefixed file as proof it has
    /// already set the live store aside once; if a deliberate restore wrote
    /// into that same family, every later *automatic* restore would see that
    /// file, believe it had already backed up, and skip its own aside copy —
    /// permanently, since nothing ever prunes it. `.prepick-` keeps this
    /// restore's aside out of that sentinel's sight entirely.
    ///
    /// Both the aside copy and the apply are gated on their own success rather
    /// than trusting a single read at the end: `copyTriple` reports whether
    /// every suffix it attempted actually copied, and the aside step keeps that
    /// result — a disk full enough to fail the aside copy still lets
    /// `try? removeItem` succeed, so without it the next step would remove the
    /// live triple, fail to replace it, and leave nothing behind (review
    /// Finding 1). What the aside has to be is a faithful copy, which is not
    /// the same as a readable one: an unreadable store is one of the reasons
    /// someone opens this picker, and a byte-for-byte copy of it is exactly the
    /// way back they had, so the aside is only required to *read* when what it
    /// copied read. Bailing on either check is safe: the pending key is already
    /// cleared, the live store has not been touched, and the chosen `.bak` is
    /// untouched.
    ///
    /// If the restored store then fails to migrate on a later launch,
    /// `loadContainer`'s own auto-restore may kick in and replace it again —
    /// that is intended, not a bug: both this pick's `.bak` source and its
    /// `.prepick-` aside survive untouched, so nothing the user chose is ever
    /// actually lost.
    @discardableResult
    static func applyPendingRestore(
        at storeURL: URL,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let raw = defaults.string(forKey: pendingRestoreKey) else { return false }
        defaults.removeObject(forKey: pendingRestoreKey)

        guard let name = validatedRestoreName(raw, storeName: storeURL.lastPathComponent) else {
            AppLogger.dataStore.error("Pending restore name rejected; ignoring it")
            return false
        }
        let dir = storeURL.deletingLastPathComponent()
        let source = dir.appending(path: name)
        guard FileManager.default.fileExists(atPath: source.path) else {
            AppLogger.dataStore.error("Pending restore source is gone; ignoring it")
            return false
        }

        // Whether the store about to be replaced can be read at all, taken
        // *before* the copy. A store that will not open is one of the reasons
        // someone reaches for this picker, so an unreadable aside is only
        // evidence of a problem when what it copied was readable.
        let liveWasReadable = StoreInventory.readContent(at: storeURL) != nil

        let stamp = String(Int(Date().timeIntervalSince1970))
        let asidePrefix = storeURL.path + "\(pickAsideInfix)\(stamp).bak"
        let asideCopied = copyTriple(from: storeURL.path, to: asidePrefix, label: "setting the current store aside")
        // From here on an aside triple may be on disk — including a partial one,
        // when the copy failed half-way — and no other reaper matches this
        // family, so every exit below has to bound it or a repeated failure
        // writes a fresh full-store copy per launch that nothing ever reaps.
        // A `defer` makes that structural instead of something each new branch
        // has to remember.
        defer { prunePickAsides(at: storeURL, keeping: 3) }

        // Bailing on either check below is safe: the pending key is already
        // cleared, the live store has not been touched, and the chosen `.bak` is
        // untouched.
        guard asideCopied else {
            AppLogger.dataStore.error("Could not set the current store aside; refusing to restore")
            return false
        }
        if liveWasReadable, StoreInventory.readContent(at: URL(fileURLWithPath: asidePrefix)) == nil {
            AppLogger.dataStore.error("The copy of the current store cannot be read; refusing to restore")
            return false
        }

        let applied = copyTriple(from: source.path, to: storeURL.path, label: "applying the chosen restore")
        guard applied, StoreInventory.readContent(at: storeURL) != nil else {
            AppLogger.dataStore.error("Chosen restore left an unreadable store; putting the previous one back")
            _ = copyTriple(from: asidePrefix, to: storeURL.path, label: "reverting a failed restore")
            // Do NOT delete the aside here even though the revert makes it look
            // redundant: if the revert copy itself only partly succeeded (e.g. a
            // failed `-wal`), this aside is the only intact copy of the store as
            // it stood before the attempt. Bound the family by count instead —
            // the `defer` above — never by deleting it on this path.
            return false
        }
        AppLogger.dataStore.info("Restored the store the user chose: \(name)")
        return true
    }

    /// Copies a store triple, overwriting the destination. Every destination
    /// suffix is cleared *unconditionally*, even when the source lacks that
    /// suffix: a destination left with its own stale `-wal`/`-shm` beside a
    /// freshly copied main file is a foreign WAL, and SQLite does not bind a
    /// WAL to a specific database file — the next open can replay those
    /// frames onto a database they were never written for. Used for setting
    /// the current store aside, applying the chosen backup, and reverting to
    /// the aside copy if the result can't be read.
    ///
    /// Returns whether every suffix it attempted to copy actually succeeded —
    /// a suffix whose source doesn't exist is skipped, not counted as a
    /// failure. `applyPendingRestore` gates each step on this rather than
    /// trusting a later read alone to notice a partial or missing copy (review
    /// Finding 1): a failed `removeItem` on the destination (permissions, or a
    /// `uchg` flag) makes the following `copyItem` throw "file exists", which
    /// this now reports as failure instead of silently doing nothing while
    /// still reading as success. `label` is logged alongside any failure so a
    /// failed aside, apply, and revert are distinguishable in the log (review
    /// Finding 10) — previously all three shared one generic message.
    @discardableResult
    static func copyTriple(from sourcePath: String, to destinationPath: String, label: String) -> Bool {
        let fm = FileManager.default
        var allSucceeded = true
        for suffix in ["", "-wal", "-shm"] {
            let dst = URL(fileURLWithPath: destinationPath + suffix)
            try? fm.removeItem(at: dst)
            let src = URL(fileURLWithPath: sourcePath + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                AppLogger.dataStore.error("Copy of \(src.lastPathComponent) failed (\(label)): \(error.localizedDescription)")
                allSucceeded = false
            }
        }
        return allSucceeded
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
