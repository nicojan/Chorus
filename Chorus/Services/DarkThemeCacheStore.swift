import Foundation

/// Persistent per-service cache of Dark Reader's generated theme CSS.
///
/// Dark Reader themes a page by running a full dynamic analysis on every load:
/// it walks every stylesheet, fetches cross-origin CSS, computes per-element
/// color inversions, and injects override styles. On heavy single-page apps
/// (Gmail, LinkedIn) that first pass takes seconds, during which the page
/// renders washed and low-contrast — the delay the load cover exists to hide.
///
/// `DarkReader.exportGeneratedCSS()` returns that computed theme as a plain CSS
/// string. This store persists it after the first themed load so later loads
/// can inject it at document-start and paint dark at once, while dynamic Dark
/// Reader still runs to refine the result and refresh the cache. The static
/// snapshot alone would go stale as the SPA renders views it didn't cover, so
/// it is only ever the fast first paint, never a replacement for the live pass.
///
/// Keyed by service instance id — one site per service. One file per service
/// under `~/Library/Caches/<bundle>/DarkThemeCache/`, with an in-memory memo so
/// a web-view build blocks on disk at most once per service per launch. The
/// cache is regeneratable, so it lives in Caches (the OS may purge it) rather
/// than Application Support.
@MainActor
final class DarkThemeCacheStore {

    /// Format version of the cache record itself. Bump only when the *shape* of
    /// what we store changes. The generator (`darkreader.js`) is tracked
    /// separately and automatically — see `cacheVersion`.
    nonisolated static let formatVersion = 1

    /// The effective version stamped into every record: the format version
    /// folded with a stable hash of the bundled Dark Reader library. This makes
    /// a `darkreader.js` update invalidate every old snapshot on read
    /// automatically — a stale-generator theme is never applied over a page —
    /// without anyone remembering to bump a constant.
    nonisolated static let cacheVersion: Int =
        formatVersion &* 31 &+ stableHash(DarkReaderSupport.libraryJS)

    /// Deterministic djb2 hash. `String.hashValue` is seeded per-process and so
    /// would change the version every launch, invalidating the cache constantly;
    /// this is stable across launches.
    nonisolated static func stableHash(_ s: String) -> Int {
        var h = 5381
        for byte in s.utf8 { h = (h &* 33) &+ Int(byte) }
        return h
    }

    /// Skip caching pathologically large output — a runaway export shouldn't
    /// bloat the caches dir or stall a build reading it back. Heavy real themes
    /// (Gmail's runs ~1–3 MB once Dark Reader inlines everything), so this is set
    /// well above them; only genuinely runaway output is rejected.
    nonisolated static let maxCSSBytes = 6_000_000

    /// On-disk record: the generator version plus the CSS it produced.
    private struct Entry: Codable {
        let v: Int
        let css: String
    }

    private let cacheDirectory: URL

    /// Memo of resolved lookups. A present value is cached CSS; a stored `nil`
    /// records a known miss so a build never re-reads disk for the same service.
    private var memo: [UUID: String?] = [:]

    /// Serial queue for file writes so a large write never blocks the main
    /// thread (the store is otherwise main-actor for the pool's convenience).
    private let ioQueue = DispatchQueue(label: "com.nicojan.Chorus.DarkThemeCache")

    init() {
        // Fall back to the temp directory rather than trapping — a missing theme
        // cache is a cosmetic slow-first-paint, not a reason to crash at launch.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDirectory = caches.appendingPathComponent("DarkThemeCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Pure helpers (unit-tested without disk)

    /// Marker Dark Reader's `exportGeneratedCSS()` emits only when it actually
    /// rewrote the page's own stylesheets (its `collectCSS` pushes this comment
    /// only when `modifiedCSS.length` is non-zero). Its presence is what
    /// separates a real, useful theme from the fallback-only output an
    /// under-rendered or login page produces.
    nonisolated static let modifiedMarker = "Modified CSS"

    /// Whether a CSS string is worth caching: within the size cap AND a real
    /// theme (contains per-element modifications), not just Dark Reader's
    /// fallback scaffolding. Caching a fallback-only snapshot would give a false
    /// cache hit that paints nothing useful and short-circuits the cover, so it
    /// is rejected in favor of letting the live pass run.
    nonisolated static func isCacheable(_ css: String) -> Bool {
        guard css.utf8.count <= maxCSSBytes else { return false }
        return css.contains(modifiedMarker)
    }

    /// Encodes CSS into a versioned record, or nil when it isn't cacheable.
    nonisolated static func encode(css: String, version: Int = cacheVersion) -> Data? {
        guard isCacheable(css) else { return nil }
        return try? JSONEncoder().encode(Entry(v: version, css: css))
    }

    /// Decodes a record, returning its CSS only when the generator version
    /// matches. A version mismatch (or malformed data) reads as a miss so a
    /// snapshot from an older Dark Reader is never applied.
    nonisolated static func decode(_ data: Data, expectedVersion: Int = cacheVersion) -> String? {
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.v == expectedVersion else { return nil }
        return entry.css
    }

    // MARK: - Disk-backed store

    private func fileURL(for id: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// The cached theme CSS for a service, or nil on a miss / version mismatch /
    /// stale low-quality entry. Memoized so repeated builds for the same service
    /// don't re-read disk. A decoded entry that no longer passes the quality gate
    /// (e.g. a fallback-only snapshot written before the gate existed) is treated
    /// as a miss and dropped, so it self-heals instead of serving a false hit.
    func cachedCSS(for id: UUID) -> String? {
        if let memoed = memo[id] { return memoed }
        let decoded = (try? Data(contentsOf: fileURL(for: id))).flatMap { Self.decode($0) }
        let resolved = decoded.flatMap { Self.isCacheable($0) ? $0 : nil }
        if decoded != nil && resolved == nil {
            let url = fileURL(for: id)
            ioQueue.async { try? FileManager.default.removeItem(at: url) }
        }
        memo[id] = resolved
        return resolved
    }

    /// Persists a service's generated theme CSS. No-ops for output that isn't
    /// cacheable or that matches what's already cached (every themed load
    /// re-exports, so skipping identical writes avoids churning the disk). The
    /// memo updates at once; the file is written off the main thread.
    func store(css: String, for id: UUID) {
        guard let data = Self.encode(css: css) else { return }
        if case let .some(existing) = memo[id], existing == css { return }
        memo[id] = css
        let url = fileURL(for: id)
        AppLogger.webView.debug("Dark theme cache write for \(id.uuidString, privacy: .public) (\(data.count, privacy: .public) bytes)")
        ioQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Drops a service's cache entry (called on service deletion). The memo
    /// records a miss so a stale value can't be served for a recycled id.
    func remove(for id: UUID) {
        memo[id] = String?.none
        let url = fileURL(for: id)
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
