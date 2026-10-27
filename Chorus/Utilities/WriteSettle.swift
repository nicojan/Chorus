import Foundation

/// Decides when a quitting app's pages have stopped writing to IndexedDB.
///
/// Quitting kills WebKit's networking process, which holds every page's
/// IndexedDB, and launchd sends it SIGKILL the moment the app exits. A write
/// still under way is lost. WhatsApp Web keeps its data in several databases
/// and checks them against each other on load, so losing one write leaves them
/// out of step, and it shows "A database error occurred" and asks to relink.
/// The quit release makes it write, so the quit waits for the writes to finish.
///
/// Two signals, since neither sees everything: the pages' count of open write
/// transactions (`UserScriptManager.pendingWritesJS`), which misses writes made
/// from a worker, and the IndexedDB files on disk, which only change when a
/// write commits. Settled means no open transaction and no file change for
/// `quietWindow`.
struct WriteSettle<Stamp: Equatable> {
    let quietWindow: Duration
    private var lastStamp: Stamp?
    private var quietSince: ContinuousClock.Instant?

    init(quietWindow: Duration) {
        self.quietWindow = quietWindow
    }

    /// Records one reading and says whether the writes have settled.
    mutating func observe(pending: Int, stamp: Stamp, at now: ContinuousClock.Instant) -> Bool {
        defer { lastStamp = stamp }
        guard pending == 0, stamp == lastStamp, let since = quietSince else {
            quietSince = pending == 0 ? now : nil
            return false
        }
        return now - since >= quietWindow
    }
}

/// Reads the IndexedDB files of WebKit's on-disk data stores.
enum IndexedDBFiles {
    /// What changes when a write commits: the newest modification date, and
    /// the byte and file counts. The `-shm` index is left out, since reading
    /// a database touches it too.
    struct Stamp: Equatable, Sendable {
        var latest: Date = .distantPast
        var bytes: Int64 = 0
        var files = 0
    }

    /// The folder WebKit keeps `WKWebsiteDataStore(forIdentifier:)` in. WebKit
    /// does not publish this layout, so a reader treats a missing folder as
    /// having nothing in it.
    static func storeDirectory(for identifier: UUID, bundleID: String) -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WebKit")
            .appendingPathComponent(bundleID)
            .appendingPathComponent("WebsiteDataStore")
            .appendingPathComponent(identifier.uuidString.lowercased())
    }

    /// Stamps every file under `Origins/<top>/<frame>/IndexedDB` in each store.
    /// The other folders in an origin are left alone: a service worker's
    /// cached scripts alone can run to hundreds of megabytes.
    static func stamp(under storeDirectories: [URL]) -> Stamp {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var stamp = Stamp()
        for store in storeDirectories {
            let origins = store.appendingPathComponent("Origins")
            for top in children(of: origins) {
                for frame in children(of: top) {
                    let databases = frame.appendingPathComponent("IndexedDB")
                    guard let files = fileManager.enumerator(at: databases, includingPropertiesForKeys: keys) else { continue }
                    for case let file as URL in files where !file.lastPathComponent.hasSuffix("-shm") {
                        guard let values = try? file.resourceValues(forKeys: Set(keys)),
                              values.isRegularFile == true else { continue }
                        stamp.files += 1
                        stamp.bytes += Int64(values.fileSize ?? 0)
                        if let modified = values.contentModificationDate, modified > stamp.latest {
                            stamp.latest = modified
                        }
                    }
                }
            }
        }
        return stamp
    }

    private static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
