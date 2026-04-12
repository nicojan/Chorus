import Foundation
import WebKit

// WKProcessPool was deprecated in macOS 12, but per-instance pools still provide
// process-level isolation as a defense-in-depth measure alongside
// WKWebsiteDataStore(forIdentifier:). We suppress the deprecation warnings
// deliberately here.
final class ProcessPoolManager {
    private var pools: [UUID: Any] = [:]

    func processPool(for instanceID: UUID) -> WKProcessPool {
        if let existing = pools[instanceID] as? WKProcessPool { return existing }
        let pool = WKProcessPool()
        pools[instanceID] = pool
        return pool
    }

    func removePool(for instanceID: UUID) {
        pools.removeValue(forKey: instanceID)
    }
}
