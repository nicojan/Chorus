import SwiftUI
import SwiftData

extension Notification.Name {
    static let menuBarServiceActivated = Notification.Name("menuBarServiceActivated")
}

struct MenuBarView: View {
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Query(filter: #Predicate<ServiceInstance> { $0.isGlobal == true })
    private var globalServices: [ServiceInstance]
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    /// Brings the main window back, or opens it again once it was closed. In
    /// menu-bar-only mode there is no Dock icon, so a closed window had no way
    /// back while this looked it up among the open windows.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !sortedGlobals.isEmpty {
                Section {
                    ForEach(sortedGlobals) { service in
                        serviceButton(service, placeName: "Global", spaceID: nil)
                    }
                } header: {
                    Text("🌐 Global")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(spaces) { space in
                Section {
                    ForEach(servicesForSpace(space)) { service in
                        serviceButton(service, placeName: space.name, spaceID: space.id)
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
                openWindow(id: "main")
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
                SheetQuit.quit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var sortedGlobals: [ServiceInstance] {
        RailItems.liveGlobals(globalServices)
    }

    private func serviceButton(_ service: ServiceInstance, placeName: String, spaceID: UUID?) -> some View {
        Button {
            activateService(service.id, inSpace: spaceID)
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
        .accessibilityLabel("\(service.label) in \(placeName)")
        .help("Open \(service.label) in \(placeName)")
    }

    private func servicesForSpace(_ space: Space) -> [ServiceInstance] {
        // Route through AppState's fetch — the same reliable, dangling-link-
        // guarded path every other view uses — rather than reading
        // `space.serviceLinks` directly, which can lag a just-added/removed
        // service until SwiftData reconciles the relationship.
        appState.servicesForSpace(space.id)
    }

    /// A nil `spaceID` is a global service: the post carries no space, and
    /// the handler leaves the current space alone.
    private func activateService(_ serviceID: UUID, inSpace spaceID: UUID?) {
        NSApp.activate(ignoringOtherApps: true)
        // Post notification for AppState to handle navigation
        var userInfo: [String: Any] = ["serviceID": serviceID]
        if let spaceID { userInfo["spaceID"] = spaceID }
        NotificationCenter.default.post(
            name: .menuBarServiceActivated,
            object: nil,
            userInfo: userInfo
        )
        openWindow(id: "main")
    }
}
