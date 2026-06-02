import Foundation

final class ServiceCatalog {
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
            self.entries = try JSONDecoder().decode([ServiceCatalogEntry].self, from: data)
        } catch {
            AppLogger.general.error("Failed to load ServiceCatalog.json: \(error.localizedDescription)")
            self.entries = []
        }
    }

    func entry(for id: String) -> ServiceCatalogEntry? {
        entries.first { $0.id == id }
    }

    func entries(in category: String) -> [ServiceCatalogEntry] {
        entries.filter { $0.category.lowercased() == category.lowercased() }
    }

    var categories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }
}
