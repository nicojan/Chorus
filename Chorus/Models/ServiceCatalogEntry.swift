import Foundation

struct ServiceCatalogEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    let icon: String
    let category: String
    let badgeJS: String?
    let userAgent: String?
    let description: String
}
