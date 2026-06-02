import WebKit

final class DataStoreManager {

    func dataStore(for instance: ServiceInstance) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: instance.dataStoreIdentifier)
    }

    func deleteDataStore(for instance: ServiceInstance) async throws {
        try await WKWebsiteDataStore.remove(forIdentifier: instance.dataStoreIdentifier)
    }

    func deleteDataStore(identifier: UUID) async throws {
        try await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }
}
