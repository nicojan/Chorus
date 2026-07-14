import Foundation
import AppKit

/// Fetches and disk-caches favicons for every entry in the service catalog.
/// Icons are stored in `~/Library/Caches/<bundle>/CatalogIcons/` keyed by
/// catalog entry ID. Stale icons (>7 days) are refreshed in the background.
actor CatalogIconCache {
    static let shared = CatalogIconCache()

    private let cacheDirectory: URL
    private let staleInterval: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    /// In-memory cache of loaded images, keyed by catalog entry ID.
    private var imageCache: [String: NSImage] = [:]

    private init() {
        // Fall back to the temp directory rather than trapping if the caches
        // directory can't be located — a missing icon cache is a cosmetic
        // degradation, not a reason to crash the app at launch.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDirectory = caches.appendingPathComponent("CatalogIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Returns the cached icon for a catalog entry, or nil if not yet fetched.
    func icon(for entryID: String) -> NSImage? {
        if let cached = imageCache[entryID] {
            return cached
        }
        let fileURL = cacheDirectory.appendingPathComponent(entryID)
        guard let data = try? Data(contentsOf: fileURL),
              let image = NSImage(data: data) else {
            return nil
        }
        imageCache[entryID] = image
        return image
    }

    /// Returns the raw icon data for a catalog entry, or nil if not yet fetched.
    func iconData(for entryID: String) -> Data? {
        let fileURL = cacheDirectory.appendingPathComponent(entryID)
        return try? Data(contentsOf: fileURL)
    }

    /// Fetches icons for all catalog entries that are missing or stale.
    /// Call this once on app launch — it runs entirely in the background.
    func fetchAllIfNeeded(entries: [ServiceCatalogEntry]) async {
        let fileManager = FileManager.default

        let needsFetch = entries.filter { entry in
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
            imageCache[entry.id] = NSImage(data: data)
        } catch {
            AppLogger.favicon.error("Failed to cache icon for \(entry.id): \(error.localizedDescription)")
        }
    }
}
