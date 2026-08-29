import Foundation
import AppKit

/// Fetches and disk-caches favicons for every entry in the service catalog.
/// Icons are stored in `~/Library/Caches/<bundle>/CatalogIcons/` keyed by
/// catalog entry ID. Stale icons (>7 days) are refreshed in the background.
actor CatalogIconCache {
    static let shared = CatalogIconCache()

    private let cacheDirectory: URL
    private let staleInterval: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    /// In-memory cache of loaded icon bytes, keyed by catalog entry ID.
    ///
    /// Bytes rather than `NSImage` on purpose. `NSImage` is not Sendable in the
    /// Xcode 16 SDK, so handing one out of this actor does not compile there,
    /// and callers build the image themselves. Caching the decoded image here
    /// would keep something no caller can be given.
    private var dataCache: [String: Data] = [:]

    private init() {
        // Fall back to the temp directory rather than trapping if the caches
        // directory can't be located — a missing icon cache is a cosmetic
        // degradation, not a reason to crash the app at launch.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDirectory = caches.appendingPathComponent("CatalogIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Returns the raw icon data for a catalog entry, or nil if not yet fetched.
    /// Served from memory after the first read, so a grid that reappears does
    /// not go back to disk for every tile.
    func iconData(for entryID: String) -> Data? {
        if let cached = dataCache[entryID] {
            return cached
        }
        let fileURL = cacheDirectory.appendingPathComponent(entryID)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        dataCache[entryID] = data
        return data
    }

    /// Fetches icons for catalog entries that are missing or stale. Called once at
    /// launch, in the background. `force` (set after an app update) re-fetches
    /// every entry, so a release that changes an icon isn't stuck showing the
    /// cached one until the weekly staleness timer lapses.
    func fetchAllIfNeeded(entries: [ServiceCatalogEntry], force: Bool = false) async {
        let fileManager = FileManager.default

        let needsFetch = force ? entries : entries.filter { entry in
            let fileURL = cacheDirectory.appendingPathComponent(entry.id)
            guard fileManager.fileExists(atPath: fileURL.path) else { return true }
            guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let modified = attrs[.modificationDate] as? Date else { return true }
            return modified.addingTimeInterval(staleInterval) < Date()
        }

        guard !needsFetch.isEmpty else { return }
        AppLogger.favicon.info("Fetching catalog icons for \(needsFetch.count) entries")

        await withTaskGroup(of: Void.self) { group in
            for entry in needsFetch {
                group.addTask {
                    await self.fetchAndCache(entry: entry)
                }
            }
        }

        AppLogger.favicon.info("Catalog icon fetch complete")
    }

    private func fetchAndCache(entry: ServiceCatalogEntry) async {
        guard let data = await FaviconFetcher.shared.fetchFavicon(for: entry.url) else { return }
        let fileURL = cacheDirectory.appendingPathComponent(entry.id)
        do {
            try data.write(to: fileURL, options: .atomic)
            dataCache[entry.id] = data
        } catch {
            AppLogger.favicon.error("Failed to cache icon for \(entry.id): \(error.localizedDescription)")
        }
    }
}
