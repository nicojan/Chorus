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
    /// True for curated, reputable call vendors (Messenger, Teams, Meet, …) whose
    /// calling runs across their own family of domains — Messenger jumps
    /// `facebook.com`→`messenger.com`, Teams spans the Microsoft domains. For these
    /// we trust the service's own MAIN-frame origin wherever it navigates itself,
    /// so a cross-domain call honors the service's camera/mic policy without a
    /// per-origin prompt, the way the vendor's native app behaves. Scoped to the
    /// main frame only — third-party subframes stay untrusted. Optional so entries
    /// without the key still decode (nil → not first-party).
    let firstParty: Bool?
    /// True for services that broadcast a presence/availability status and flip it
    /// to "away" when their window loses focus (Microsoft Teams). Adding one of
    /// these offers to turn on "always appear active" so backgrounding Chorus
    /// doesn't make the user look away. Optional so entries without the key still
    /// decode (nil → not presence-sensitive).
    let presenceSensitive: Bool?
}
