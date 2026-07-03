import Foundation
import SwiftData

/// Per-service dark-mode choice: never, always, or follow the system appearance.
enum DarkModePreference: String, CaseIterable {
    case off, on, auto
}

@Model
final class ServiceInstance {
    @Attribute(.unique) var id: UUID
    var label: String
    var url: String
    var customIconData: Data?
    var fetchedIconData: Data?
    var faviconFetchedAt: Date?
    var catalogEntryID: String?
    var isMuted: Bool
    var showBadge: Bool
    var neverHibernate: Bool
    var userAgent: String?
    var dataStoreIdentifier: UUID
    /// Per-service page zoom (e.g. 1.0 = 100%, 1.25 = 125%). Stored optional
    /// so SwiftData lightweight migration succeeds on existing rows — read
    /// sites should use `zoomLevelEffective` which substitutes 1.0 for nil.
    var pageZoom: Double?

    /// Whether this service forwards its web notifications to macOS Notification
    /// Center. Stored optional so SwiftData lightweight migration succeeds on
    /// existing rows — nil is treated as enabled (the prior default). Read sites
    /// should use `notifiesOSEffective`. Independent of `showBadge` (badge) and
    /// of `isMuted` (mute is the master override over both).
    var osNotificationsEnabled: Bool?

    /// Per-service custom CSS injected into the page. Stored optional so
    /// SwiftData lightweight migration succeeds on existing rows — nil means
    /// "use the built-in default for this service" (see `ServiceCSSDefaults`),
    /// so a service like LinkedIn still gets its messaging-only view untouched.
    /// A non-nil value overrides the default; a blank value disables both.
    var customCSS: String?

    /// Per-service dark mode: "off", "on", or "auto" (follow the system).
    /// Optional for SwiftData lightweight migration; nil is treated as "off".
    /// Read via `darkModePreference`.
    var darkMode: String?

    @Relationship(deleteRule: .cascade, inverse: \SpaceServiceLink.service)
    var spaceLinks: [SpaceServiceLink]

    var createdAt: Date
    var lastAccessedAt: Date

    /// Materialises the storage-optional zoom into a Double (nil → 1.0).
    var zoomLevelEffective: Double { pageZoom ?? 1.0 }

    /// Materialises the storage-optional dark-mode string (nil → .off).
    var darkModePreference: DarkModePreference {
        DarkModePreference(rawValue: darkMode ?? "off") ?? .off
    }

    /// Materialises the storage-optional OS-notification flag (nil → true), so
    /// services created before this flag existed keep forwarding notifications.
    var notifiesOSEffective: Bool { osNotificationsEnabled ?? true }

    /// True if this service is muted directly, or via any space it belongs to
    /// (muting a space cascades to its members). Use this when the model object
    /// is already in hand — it avoids AppState's fetch-all-then-scan lookup.
    var isEffectivelyMuted: Bool {
        if isMuted { return true }
        return spaceLinks.contains { $0.space.isMutedEffective }
    }

    init(
        id: UUID = UUID(),
        label: String,
        url: String,
        customIconData: Data? = nil,
        fetchedIconData: Data? = nil,
        faviconFetchedAt: Date? = nil,
        catalogEntryID: String? = nil,
        isMuted: Bool = false,
        showBadge: Bool = true,
        neverHibernate: Bool = false,
        userAgent: String? = nil,
        dataStoreIdentifier: UUID = UUID(),
        pageZoom: Double? = nil,
        osNotificationsEnabled: Bool? = nil,
        customCSS: String? = nil,
        darkMode: String? = nil
    ) {
        self.id = id
        self.label = label
        self.url = url
        self.customIconData = customIconData
        self.fetchedIconData = fetchedIconData
        self.faviconFetchedAt = faviconFetchedAt
        self.catalogEntryID = catalogEntryID
        self.isMuted = isMuted
        self.showBadge = showBadge
        self.neverHibernate = neverHibernate
        self.userAgent = userAgent
        self.dataStoreIdentifier = dataStoreIdentifier
        self.pageZoom = pageZoom
        self.osNotificationsEnabled = osNotificationsEnabled
        self.customCSS = customCSS
        self.darkMode = darkMode
        self.spaceLinks = []
        self.createdAt = Date()
        self.lastAccessedAt = Date()
    }
}
