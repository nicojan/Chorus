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
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Service...") {
                    appState.showAddService = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .modelContainer(appState.modelContainer)
        }
    }
}
