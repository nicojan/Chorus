import SwiftUI
import SwiftData

extension Notification.Name {
    static let menuBarServiceActivated = Notification.Name("menuBarServiceActivated")
}

struct MenuBarView: View {
    @Query private var services: [ServiceInstance]
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(spaces) { space in
                Section {
                    ForEach(servicesForSpace(space)) { service in
                        Button {
                            activateService(service.id, inSpace: space.id)
                        } label: {
                            if let iconData = service.customIconData ?? service.fetchedIconData,
                               let nsImage = NSImage(data: iconData) {
                                Label {
                                    Text(service.label)
                                } icon: {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 16, height: 16)
                                }
                            } else {
                                Label(service.label, systemImage: "globe")
                            }
                        }
                        .accessibilityLabel("\(service.label) in \(space.name)")
                        .help("Open \(service.label) in \(space.name)")
                    }
                } header: {
                    Text("\(space.emoji) \(space.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button("Show Chorus") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            // Settings must be reachable here: in "Menu bar only" mode the app
            // runs as an accessory with no menu bar, so this is the only way
            // back to Settings (e.g. to leave menu-bar-only mode).
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Quit Chorus") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func servicesForSpace(_ space: Space) -> [ServiceInstance] {
        space.serviceLinks
            .filter { $0.modelContext != nil && $0.service.modelContext != nil }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.service)
    }

    private func activateService(_ serviceID: UUID, inSpace spaceID: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        // Post notification for AppState to handle navigation
        NotificationCenter.default.post(
            name: .menuBarServiceActivated,
            object: nil,
            userInfo: ["serviceID": serviceID, "spaceID": spaceID]
        )
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
