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
    /// True for services that already render dark on their own when the app is
    /// dark — always-dark web apps, dark-by-default ones, or ones that follow
    /// `prefers-color-scheme` by default. Dark Reader is kept off for these in
    /// `.auto` mode so it doesn't double-darken and break them. Optional so
    /// entries without the key still decode (nil → not native-dark).
    let nativeDark: Bool?
}
