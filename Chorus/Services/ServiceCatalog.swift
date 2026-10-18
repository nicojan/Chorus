import Foundation

// Immutable after init — `entries` is a `let` of Sendable elements and every
// member is read-only — so the shared singleton is safe to touch from any
// actor. Conforming to Sendable (rather than pinning it to @MainActor) keeps
// the off-main callers, e.g. AppState's nonisolated `catalogEntry(for:)`.
final class ServiceCatalog: Sendable {
    static let shared = ServiceCatalog()

    let entries: [ServiceCatalogEntry]

    private init() {
        guard let url = Bundle.main.url(forResource: "ServiceCatalog", withExtension: "json") else {
            AppLogger.general.warning("ServiceCatalog.json not found in bundle")
            self.entries = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            // Lossy decode: one malformed entry must not empty the whole catalog
            // (which would leave the Browse tab blank and drop baked-in defaults).
            let decoded = try JSONDecoder().decode([FailableDecodable<ServiceCatalogEntry>].self, from: data)
            self.entries = decoded.compactMap(\.value)
            let dropped = decoded.count - self.entries.count
            if dropped > 0 {
                AppLogger.general.warning("Skipped \(dropped) malformed catalog entr\(dropped == 1 ? "y" : "ies")")
            }
        } catch {
            AppLogger.general.error("Failed to load ServiceCatalog.json: \(error.localizedDescription)")
            self.entries = []
        }
    }

    func entry(for id: String) -> ServiceCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// The entry whose home is at `host`, ignoring case and a leading `www.`,
    /// for a service added by its address, which carries no catalog id. The
    /// first entry wins where two share a host.
    func entry(forHost host: String) -> ServiceCatalogEntry? {
        let wanted = Self.bareHost(host)
        return entries.first { URL(string: $0.url)?.host.map(Self.bareHost) == wanted }
    }

    private static func bareHost(_ host: String) -> String {
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }
}

/// Decodes to nil instead of throwing, so one malformed element in an array
/// doesn't fail the whole decode. Each element gets its own decoder, so a
/// caught failure leaves the array decode positioned for the next element.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
