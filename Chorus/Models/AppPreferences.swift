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
        appearanceModeRaw: String? = nil
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
}
