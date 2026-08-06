import Foundation

/// Moves the store out of SwiftData's default, unscoped location and into a
/// folder named for this app.
///
/// `ModelConfiguration(isStoredInMemoryOnly: false)` resolves, for an app that
/// is not sandboxed, to `Application Support/default.store` — a path with no
/// bundle identifier in it. Every non-sandboxed SwiftData app that takes the
/// default lands on that same file. When two of them do, whichever opens it
/// second migrates it to *its* model, and Core Data drops the entities that
/// model doesn't declare. Both apps then lose everything, repeatedly, since
/// both re-open the file at every launch.
///
/// That is not hypothetical. Chorus shared the file with Bartender 6, whose
/// `WidgetSettings` model replaced the spaces and services table for table; the
/// store on disk ended up holding `ZWIDGETSETTINGS` and nothing of Chorus's,
/// three times in one week, and a crash report caught the collision mid-flight
/// (a save faulting a row whose table had been redefined under the open
/// connection).
///
/// So the store moves to `Application Support/Chorus/default.store`. Debug
/// builds already sit in `Chorus-debug` for the same class of reason and are
/// untouched by this.
///
/// The move has to survive finding someone else's file at the old path, which
/// is exactly the state the bug leaves behind. Nothing is moved unless it can
/// be proved to be Chorus's, and nothing is deleted until its copy has been
/// read back.
enum StoreRelocation {
    /// The folder the store moves into, under Application Support.
    static let folderName = "Chorus"

    /// SwiftData's default store filename. Kept as the store's name after the
    /// move so every `.bak` sibling, the pending-restore validation, and the
    /// recovery picker's filename parsing all keep working unchanged.
    static let storeName = "default.store"

    /// The store URL to open, having moved a legacy store and its backups into
    /// the app's own folder when that is safe. Production entry point.
    static func resolveStoreURL() -> URL {
        let support = URL.applicationSupportDirectory
        return resolveStoreURL(
            legacy: support.appending(path: storeName),
            scoped: support.appending(path: folderName).appending(path: storeName)
        )
    }

    /// Decides which store to open, performing the one-time move.
    ///
    /// Returns `scoped` whenever the app can safely run there, and `legacy`
    /// only when the move was attempted and failed — running on the old path
    /// for one more launch is better than opening an empty store while the
    /// user's data sits somewhere else.
    ///
    /// The order matters. The live store moves first and the backups follow,
    /// so a failure part-way leaves the store and its backups together in the
    /// old folder rather than split across two.
    static func resolveStoreURL(legacy: URL, scoped: URL) -> URL {
        let fm = FileManager.default
        let scopedDir = scoped.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: scopedDir, withIntermediateDirectories: true)
        } catch {
            AppLogger.dataStore.error("Could not create the store folder (\(error.localizedDescription)); staying on the old path")
            return legacy
        }

        // Already moved. Never look at the old path again: an older build of
        // Chorus run in the meantime could have left a store there, and
        // importing it now would overwrite newer data.
        guard !fm.fileExists(atPath: scoped.path) else { return scoped }

        if fm.fileExists(atPath: legacy.path) {
            if StoreInventory.readContent(at: legacy) != nil {
                guard moveTriple(from: legacy, to: scoped) else {
                    AppLogger.dataStore.error("Could not move the store into \(folderName); staying on the old path")
                    return legacy
                }
                AppLogger.dataStore.info("Moved the store into \(folderName)")
            } else {
                // Someone else's file, or one Chorus cannot read. Either way it
                // is not provably ours, so it stays exactly where it is — the
                // backups swept below are what brings the user's data back.
                AppLogger.dataStore.error("The store at the old path is not Chorus's; leaving it and starting from backups")
            }
        }

        moveBackups(from: legacy, to: scoped)
        return scoped
    }

    // MARK: - Moving files

    /// Copies a store triple to `destination` and removes the source only once
    /// the copy reads back as a store. A partial copy is cleaned up, so a
    /// failure leaves the old path as the only copy rather than two half ones.
    private static func moveTriple(from source: URL, to destination: URL) -> Bool {
        guard StoreRepair.copyTriple(from: source.path, to: destination.path, label: "moving the store into \(folderName)"),
              StoreInventory.readContent(at: destination) != nil else {
            AppLogger.dataStore.error("The copied store could not be read back; discarding it")
            removeTriple(at: destination)
            return false
        }
        removeTriple(at: source)
        return true
    }

    /// Moves every backup Chorus kept beside the legacy store. These are the
    /// `.snapshot-`/`.prerestore-`/`.corrupt-`/`.prepick-` families, matched
    /// here by the broader shape they all share — `<store>.<anything>.bak`,
    /// plus `-wal`/`-shm` siblings — so a family from an older build whose
    /// infix no longer matches today's spelling is swept along too rather than
    /// stranded. The live triple can never match: it has no `.bak`.
    ///
    /// Best-effort per file. A backup that fails to move stays readable where
    /// it is, which is worse than moving it but never worse than deleting it.
    private static func moveBackups(from legacy: URL, to scoped: URL) {
        let fm = FileManager.default
        let sourceDir = legacy.deletingLastPathComponent()
        let destinationDir = scoped.deletingLastPathComponent()
        guard sourceDir != destinationDir,
              let names = try? fm.contentsOfDirectory(atPath: sourceDir.path) else { return }

        let prefix = legacy.lastPathComponent + "."
        var moved = 0
        for name in names where name.hasPrefix(prefix) && isBackupSuffix(name) {
            let destination = destinationDir.appending(path: name)
            try? fm.removeItem(at: destination)
            do {
                try fm.moveItem(at: sourceDir.appending(path: name), to: destination)
                moved += 1
            } catch {
                AppLogger.dataStore.error("Could not move backup \(name): \(error.localizedDescription)")
            }
        }
        if moved > 0 {
            AppLogger.dataStore.info("Moved \(moved) backup file(s) into \(folderName)")
        }
    }

    /// Whether a filename is a backup primary or one of its WAL siblings.
    private static func isBackupSuffix(_ name: String) -> Bool {
        name.hasSuffix(".bak") || name.hasSuffix(".bak-wal") || name.hasSuffix(".bak-shm")
    }

    private static func removeTriple(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
