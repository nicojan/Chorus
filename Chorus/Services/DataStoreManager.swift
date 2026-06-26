import WebKit

/// Vends per-service `WKWebsiteDataStore` instances, caching them by
/// identifier. WebKit backs every store for a given identifier with the same
/// on-disk data, but repeatedly *constructing* `WKWebsiteDataStore(forIdentifier:)`
/// is wasteful and — on macOS 26 — sits in the same fragile WebKit territory
/// that already forced avoiding `allDataStoreIdentifiers`. Reusing one instance
/// per identifier avoids that churn.
@MainActor
final class DataStoreManager {
    private var cache: [UUID: WKWebsiteDataStore] = [:]

    func dataStore(for instance: ServiceInstance) -> WKWebsiteDataStore {
        dataStore(forIdentifier: instance.dataStoreIdentifier)
    }

    func dataStore(forIdentifier identifier: UUID) -> WKWebsiteDataStore {
        if let cached = cache[identifier] {
            return cached
        }
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        cache[identifier] = store
        return store
    }

    /// Drops the cached instance for an identifier. Call before removing the
    /// store from disk so a stale handle can't keep it alive.
    func evict(identifier: UUID) {
        cache.removeValue(forKey: identifier)
    }

    func deleteDataStore(for instance: ServiceInstance) async throws {
        evict(identifier: instance.dataStoreIdentifier)
        try await WKWebsiteDataStore.remove(forIdentifier: instance.dataStoreIdentifier)
    }

    func deleteDataStore(identifier: UUID) async throws {
        evict(identifier: identifier)
        try await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }
}
