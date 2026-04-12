import Foundation
import SwiftData

enum AppPresenceMode: String, Codable {
    case dock
    case menuBar
    case both
}

@Model
final class AppPreferences {
    var id: UUID
    var appPresenceMode: AppPresenceMode
    var launchAtLogin: Bool
    var globalKeyboardShortcutsEnabled: Bool
    var showBadgeCountInDock: Bool
    var selectedSpaceID: UUID?
    var selectedServiceID: UUID?

    init(
        id: UUID = UUID(),
        appPresenceMode: AppPresenceMode = .dock,
        launchAtLogin: Bool = false,
        globalKeyboardShortcutsEnabled: Bool = true,
        showBadgeCountInDock: Bool = true,
        selectedSpaceID: UUID? = nil,
        selectedServiceID: UUID? = nil
    ) {
        self.id = id
        self.appPresenceMode = appPresenceMode
        self.launchAtLogin = launchAtLogin
        self.globalKeyboardShortcutsEnabled = globalKeyboardShortcutsEnabled
        self.showBadgeCountInDock = showBadgeCountInDock
        self.selectedSpaceID = selectedSpaceID
        self.selectedServiceID = selectedServiceID
    }
}
