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

    // NOTE: there is deliberately no direct `deleteDataStore(...)` here. Removing
    // a `WKWebsiteDataStore` while its `WKWebView` is still retained hard-crashes
    // inside WebKit, so every on-disk removal must go through AppState's
    // `markDataStoreOrphaned` → deferred `cleanUpOrphanedDataStores` path, which
    // evicts the cached handle and only removes once the web view has torn down.
}
