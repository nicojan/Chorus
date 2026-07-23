import Foundation
import SwiftData

enum AppPresenceMode: String, Codable {
    case dock
    case menuBar
    case both
}

/// Where the spaces and services rails sit relative to the web content.
enum RailLayout: String, Codable, CaseIterable {
    /// Both rails vertical on the left (the default).
    case sidebar
    /// Spaces row on top, services as folder tabs below.
    case topBars
    /// Spaces rail on the left, services as folder tabs across the top.
    case hybrid

    var displayName: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .topBars: return "Top bars"
        case .hybrid: return "Spaces left, tabs on top"
        }
    }
}

/// App-level light/dark appearance override.
enum AppearanceMode: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Always Light"
        case .dark: return "Always Dark"
        }
    }
}

@Model
final class AppPreferences {
    @Attribute(.unique) var id: UUID
    var appPresenceMode: AppPresenceMode
    var launchAtLogin: Bool
    var globalKeyboardShortcutsEnabled: Bool
    var showBadgeCountInDock: Bool
    var autoDismissCookieBanners: Bool
    var selectedSpaceID: UUID?
    var selectedServiceID: UUID?

    /// Chorus-wide default page zoom applied to services that have no explicit
    /// per-service zoom. Optional so SwiftData lightweight migration succeeds on
    /// existing rows; nil is treated as 1.0. Read via `defaultZoomEffective`.
    var defaultZoom: Double?

    /// Scheduled "quiet hours" Do Not Disturb. All optional for SwiftData
    /// lightweight migration. Start/end are minutes since midnight; nil defaults
    /// to 22:00–07:00 when the schedule is first enabled.
    var scheduledDNDEnabled: Bool?
    var dndStartMinutes: Int?
    var dndEndMinutes: Int?

    /// App lock (Touch ID / password). Optional for SwiftData lightweight
    /// migration. `lockOnLaunch`/`lockOnSleep` default true once the lock is
    /// enabled; the user chooses which triggers apply in Settings.
    var appLockEnabled: Bool?
    var lockOnLaunch: Bool?
    var lockOnSleep: Bool?

    /// Rail layout. Optional so SwiftData lightweight migration succeeds on
    /// existing rows; nil or an unknown value resolves to `.sidebar`. Read via
    /// `railLayout`.
    var railLayoutRaw: String?

    /// App-level appearance override. Optional for lightweight migration; nil or
    /// unknown resolves to `.system`. Read via `appearanceMode`.
    var appearanceModeRaw: String?

    /// Global on/off for the network content blocker. Optional for SwiftData
    /// lightweight migration; nil is treated as enabled (`contentBlockingEnabledEffective`),
    /// so both fresh installs and existing installs upgrading into the feature
    /// get blocking on by default.
    var contentBlockingEnabled: Bool?

    /// Global "give services without a dark theme a dark one" switch. Optional for
    /// SwiftData lightweight migration; nil is treated as off
    /// (`autoDarkModeEnabledEffective`), so it's opt-in and upgrades unchanged.
    var autoDarkModeEnabled: Bool?

    /// "Hide annoyances" (cookie notices, newsletter pop-ups, floating bars) on
    /// top of ad/tracker blocking. Optional for SwiftData lightweight migration;
    /// nil is treated as off — it's opt-in because cosmetic hiding is more
    /// aggressive than domain blocking.
    var annoyanceBlockingEnabled: Bool?

    /// Default camera / microphone permission for services that haven't pinned
    /// their own. Stored raw for SwiftData lightweight migration; nil resolves to
    /// `.ask` (see `MediaPermissionResolver.effectivePolicy`).
    var defaultCameraPolicyRaw: String?
    var defaultMicrophonePolicyRaw: String?

    /// Allow the Google favicon service as a last-resort icon source. Optional
    /// for SwiftData lightweight migration; nil is treated as off — it's opt-in
    /// because the request discloses the service's hostname to a third party,
    /// and a custom service's host can be private. Off just means a service
    /// whose own host serves no usable icon falls back to its monogram.
    var googleFaviconFallbackEnabled: Bool?
    /// Fully hibernate a background service after it has been idle for
    /// `autoHibernateIdleMinutes`, freeing its WebContent process. Optional for
    /// SwiftData lightweight migration; nil is treated as off — opt-in because it
    /// changes runtime behaviour. Notification-critical services (the Messaging
    /// catalog category) and any service marked "Keep Loaded" are never touched,
    /// so real-time alerts for chat apps are preserved; a hibernated service still
    /// refreshes its unread badge on a periodic background sweep (every few
    /// minutes), and that count only climbs until the service is reopened.
    var autoHibernateIdleEnabled: Bool?

    /// Idle minutes before auto-hibernation kicks in. Optional; nil resolves to 10.
    var autoHibernateIdleMinutes: Int?

    init(
        id: UUID = UUID(),
        appPresenceMode: AppPresenceMode = .dock,
        launchAtLogin: Bool = false,
        globalKeyboardShortcutsEnabled: Bool = true,
        showBadgeCountInDock: Bool = true,
        autoDismissCookieBanners: Bool = true,
        selectedSpaceID: UUID? = nil,
        selectedServiceID: UUID? = nil,
        defaultZoom: Double? = nil,
        scheduledDNDEnabled: Bool? = nil,
        dndStartMinutes: Int? = nil,
        dndEndMinutes: Int? = nil,
        appLockEnabled: Bool? = nil,
        lockOnLaunch: Bool? = nil,
        lockOnSleep: Bool? = nil,
        railLayoutRaw: String? = nil,
        appearanceModeRaw: String? = nil,
        contentBlockingEnabled: Bool? = nil,
        autoDarkModeEnabled: Bool? = nil,
        annoyanceBlockingEnabled: Bool? = nil,
        defaultCameraPolicyRaw: String? = nil,
        defaultMicrophonePolicyRaw: String? = nil,
        googleFaviconFallbackEnabled: Bool? = nil,
        autoHibernateIdleEnabled: Bool? = nil,
        autoHibernateIdleMinutes: Int? = nil
    ) {
        self.id = id
        self.appPresenceMode = appPresenceMode
        self.launchAtLogin = launchAtLogin
        self.globalKeyboardShortcutsEnabled = globalKeyboardShortcutsEnabled
        self.showBadgeCountInDock = showBadgeCountInDock
        self.autoDismissCookieBanners = autoDismissCookieBanners
        self.selectedSpaceID = selectedSpaceID
        self.selectedServiceID = selectedServiceID
        self.defaultZoom = defaultZoom
        self.scheduledDNDEnabled = scheduledDNDEnabled
        self.dndStartMinutes = dndStartMinutes
        self.dndEndMinutes = dndEndMinutes
        self.appLockEnabled = appLockEnabled
        self.lockOnLaunch = lockOnLaunch
        self.lockOnSleep = lockOnSleep
        self.railLayoutRaw = railLayoutRaw
        self.appearanceModeRaw = appearanceModeRaw
        self.contentBlockingEnabled = contentBlockingEnabled
        self.autoDarkModeEnabled = autoDarkModeEnabled
        self.annoyanceBlockingEnabled = annoyanceBlockingEnabled
        self.defaultCameraPolicyRaw = defaultCameraPolicyRaw
        self.defaultMicrophonePolicyRaw = defaultMicrophonePolicyRaw
        self.googleFaviconFallbackEnabled = googleFaviconFallbackEnabled
        self.autoHibernateIdleEnabled = autoHibernateIdleEnabled
        self.autoHibernateIdleMinutes = autoHibernateIdleMinutes
    }

    /// Materialises the storage-optional default zoom (nil → 1.0).
    var defaultZoomEffective: Double { defaultZoom ?? 1.0 }

    /// Resolves the stored rail layout, defaulting unknown/legacy values to
    /// `.sidebar`.
    var railLayout: RailLayout {
        railLayoutRaw.flatMap(RailLayout.init(rawValue:)) ?? .sidebar
    }

    /// Resolves the stored appearance override, defaulting to `.system`.
    var appearanceMode: AppearanceMode {
        appearanceModeRaw.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    /// Materialises the storage-optional content-blocking flag (nil → true).
    var contentBlockingEnabledEffective: Bool { contentBlockingEnabled ?? true }

    /// Materialises the storage-optional auto-dark flag (nil → false).
    var autoDarkModeEnabledEffective: Bool { autoDarkModeEnabled ?? false }

    /// Materialises the storage-optional annoyance-blocking flag (nil → false).
    var annoyanceBlockingEnabledEffective: Bool { annoyanceBlockingEnabled ?? false }

    /// Materialises the storage-optional Google favicon fallback flag (nil → false).
    var googleFaviconFallbackEnabledEffective: Bool { googleFaviconFallbackEnabled ?? false }
    /// Materialises the storage-optional auto-hibernate flag (nil → false).
    var autoHibernateIdleEnabledEffective: Bool { autoHibernateIdleEnabled ?? false }

    /// Idle minutes before auto-hibernation, clamped to a sane 1...120 (nil → 10).
    var autoHibernateIdleMinutesEffective: Int {
        min(120, max(1, autoHibernateIdleMinutes ?? 10))
    }
}
