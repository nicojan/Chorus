import AppKit
import ServiceManagement
import os

final class AppPresenceManager {
    private static let logger = Logger(subsystem: "com.nicojan.Chorus", category: "AppPresence")

    func apply(mode: AppPresenceMode) {
        switch mode {
        case .dock:
            NSApp.setActivationPolicy(.regular)
        case .menuBar:
            NSApp.setActivationPolicy(.accessory)
        case .both:
            NSApp.setActivationPolicy(.regular)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Self.logger.error("Launch at login error: \(error.localizedDescription)")
        }
    }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
