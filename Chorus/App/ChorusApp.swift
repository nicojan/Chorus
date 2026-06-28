import SwiftUI
import SwiftData
#if canImport(Sparkle)
import Sparkle
#endif

@main
struct ChorusApp: App {
    @State private var appState: AppState

    #if canImport(Sparkle)
    /// Owns the Sparkle updater for the app's lifetime: drives the
    /// "Check for Updates…" command and runs scheduled background checks.
    private let updaterController: SPUStandardUpdaterController
    #endif

    init() {
        _appState = State(initialValue: AppState())
        #if canImport(Sparkle)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
    }

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
            #if canImport(Sparkle)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            #endif

            CommandGroup(replacing: .newItem) {
                Button("Add Service...") {
                    appState.showAddService = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Quick Switcher") {
                    appState.showQuickSwitcher.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button(appState.doNotDisturb ? "Turn Off Do Not Disturb" : "Do Not Disturb") {
                    appState.doNotDisturb.toggle()
                    appState.badgeManager.doNotDisturb = appState.doNotDisturb
                    appState.badgeManager.updateDockBadge()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
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

            CommandGroup(after: .toolbar) {
                Button("Reload") {
                    appState.reloadActiveService()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Zoom In") {
                    appState.adjustActiveServiceZoom(by: 1.1)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Zoom Out") {
                    appState.adjustActiveServiceZoom(by: 1.0 / 1.1)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    appState.resetActiveServiceZoom()
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("Find...") {
                    appState.findInPageVisible = true
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        MenuBarExtra("Chorus", systemImage: "square.grid.2x2") {
            MenuBarView()
                .modelContainer(appState.modelContainer)
        }

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
        }
    }

    @MainActor
    private func servicesForSpace(_ spaceID: UUID) -> [ServiceInstance] {
        let context = appState.modelContainer.mainContext
        let descriptor = FetchDescriptor<SpaceServiceLink>()
        do {
            let links = try context.fetch(descriptor)
            return links
                .filter { $0.space.id == spaceID }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.service)
        } catch {
            AppLogger.dataStore.error("Failed to fetch services for space: \(error.localizedDescription)")
            return []
        }
    }

    @MainActor
    private func allSpaces() -> [Space] {
        let context = appState.modelContainer.mainContext
        let descriptor = FetchDescriptor<Space>(sortBy: [SortDescriptor(\.sortOrder)])
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLogger.dataStore.error("Failed to fetch spaces: \(error.localizedDescription)")
            return []
        }
    }

    @MainActor
    private func saveWindowState() {
        let context = appState.modelContainer.mainContext
        let descriptor = FetchDescriptor<AppPreferences>()

        let prefs: AppPreferences
        do {
            prefs = try context.fetch(descriptor).first ?? AppPreferences()
        } catch {
            AppLogger.dataStore.error("Failed to fetch preferences for window state: \(error.localizedDescription)")
            return
        }

        if prefs.modelContext == nil {
            context.insert(prefs)
        }

        prefs.selectedSpaceID = appState.selectedSpaceID
        prefs.selectedServiceID = appState.selectedServiceID

        do {
            try context.save()
        } catch {
            AppLogger.dataStore.error("Failed to save window state: \(error.localizedDescription)")
        }
    }
}

// MARK: - Sparkle auto-update ("Check for Updates…" menu command)
//
// Defined here (a file that is part of the Chorus target) rather than a
// standalone file, so it compiles when Sparkle is resolved. Gated on
// canImport(Sparkle) so the project still builds before the package is present.

#if canImport(Sparkle)
import Sparkle

/// Publishes whether the updater can currently check for updates, so the menu
/// item can enable/disable itself reactively.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu command. The intermediate view exists so the
/// disabled state binds correctly (a known SwiftUI menu quirk).
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
#endif
