import SwiftUI
import SwiftData

@main
struct ChorusApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        Window("Chorus", id: "main") {
            ContentView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
                .onDisappear {
                    saveWindowState()
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Service...") {
                    appState.showAddService = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            KeyboardShortcutCommands(
                selectedServiceID: Binding(
                    get: { appState.selectedServiceID },
                    set: { appState.selectedServiceID = $0 }
                ),
                selectedSpaceID: Binding(
                    get: { appState.selectedSpaceID },
                    set: { appState.selectedSpaceID = $0 }
                ),
                getServicesForSpace: { spaceID in
                    servicesForSpace(spaceID)
                },
                getSpaces: {
                    allSpaces()
                }
            )
        }

        MenuBarExtra("Chorus", systemImage: "square.grid.2x2") {
            MenuBarView()
                .modelContainer(appState.modelContainer)
        }

        Settings {
            SettingsView()
                .modelContainer(appState.modelContainer)
        }
    }

    @MainActor
    private func servicesForSpace(_ spaceID: UUID) -> [ServiceInstance] {
        let context = appState.modelContainer.mainContext
        let descriptor = FetchDescriptor<SpaceServiceLink>()
        let links = (try? context.fetch(descriptor)) ?? []
        return links
            .filter { $0.space.id == spaceID }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.service)
    }

    @MainActor
    private func allSpaces() -> [Space] {
        let context = appState.modelContainer.mainContext
        let descriptor = FetchDescriptor<Space>(sortBy: [SortDescriptor(\.sortOrder)])
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    private func saveWindowState() {
        let context = appState.modelContainer.mainContext
        let descriptor = FetchDescriptor<AppPreferences>()
        let prefs = (try? context.fetch(descriptor))?.first ?? AppPreferences()

        if prefs.modelContext == nil {
            context.insert(prefs)
        }

        prefs.selectedSpaceID = appState.selectedSpaceID
        prefs.selectedServiceID = appState.selectedServiceID
        try? context.save()
    }
}
