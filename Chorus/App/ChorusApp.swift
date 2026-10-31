import ChorusEngine
import SwiftUI
import SwiftData
#if canImport(Sparkle)
import Sparkle
#endif

@main
struct ChorusApp: App {
    @State private var appState: AppState
    @NSApplicationDelegateAdaptor(ChorusAppDelegate.self) private var appDelegate

    #if canImport(Sparkle)
    /// Owns the Sparkle updater for the app's lifetime: drives the
    /// "Check for Updates…" command and runs scheduled background checks.
    private let updaterController: SPUStandardUpdaterController
    /// Closes open sheets before Sparkle relaunches. Sparkle keeps its
    /// delegate weakly, so the app holds it.
    private let updaterDelegate: UpdaterQuitDelegate
    #endif

    init() {
        _appState = State(initialValue: AppState())
        #if canImport(Sparkle)
        let delegate = UpdaterQuitDelegate()
        updaterDelegate = delegate
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        #endif
    }

    var body: some Scene {
        Window("Chorus", id: "main") {
            ContentView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
                .preferredColorScheme(appState.appearanceColorScheme)
                .onAppear {
                    appDelegate.appState = appState
                }
                .onDisappear {
                    appState.saveSelection()
                }
        }
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // AppKit drops a quit while a sheet is open; see `SheetQuit`.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Chorus") { SheetQuit.quit(reason: .menu) }
                    .keyboardShortcut("q")
            }

            // The stock About panel, with the donation link added to its credits
            // field. Replacing the item rather than adding a second one keeps the
            // menu at one About; Sparkle's group below still lands after it.
            CommandGroup(replacing: .appInfo) {
                Button("About Chorus") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [.credits: Self.aboutCredits]
                    )
                }
            }

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
                // With no space selected the sheet has nowhere to add the
                // service and renders empty and un-dismissable, so disable ⌘N
                // until a space exists (the seeded app always has one; this
                // covers the transient no-space state).
                // A sheet is its own window, which the lock screen doesn't cover.
                .disabled(appState.selectedSpaceID == nil || appState.isLocked)

                Button("Quick Switcher") {
                    appState.showQuickSwitcher.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(appState.isLocked)

                Divider()

                Button(appState.doNotDisturb ? "Turn Off Do Not Disturb" : "Do Not Disturb") {
                    appState.doNotDisturb.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Lock Now") {
                    appState.lock()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!appState.appLockEnabled)

                Button("Mute All Microphones") {
                    appState.muteAllMicrophones()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            // ⌘W closes the tab on screen, the way it does in a browser, and the
            // window when there is none. Replacing the group takes out the stock
            // Close item, which would otherwise claim ⌘W first.
            CommandGroup(replacing: .saveItem) {
                Button(appState.activeServiceShowsTab ? "Close Tab" : "Close") {
                    appState.closeTabOrWindow()
                }
                .keyboardShortcut("w", modifiers: .command)
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
                railLayout: appState.railLayout,
                getServicesForSpace: { spaceID in
                    servicesForSpace(spaceID)
                },
                getAllServiceDestinations: {
                    allServiceDestinations()
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

                Divider()

                Button("Show Previous Tab") {
                    appState.selectActiveServiceTab(offset: -1)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!appState.activeServiceHasTabs)

                Button("Show Next Tab") {
                    appState.selectActiveServiceTab(offset: 1)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!appState.activeServiceHasTabs)
            }
        }

        MenuBarExtra("Chorus", systemImage: "square.grid.2x2") {
            MenuBarView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
        }

        Settings {
            #if canImport(Sparkle)
            SettingsView(updater: updaterController.updater)
                .environment(appState)
                .modelContainer(appState.modelContainer)
                .preferredColorScheme(appState.appearanceColorScheme)
            #else
            SettingsView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
                .preferredColorScheme(appState.appearanceColorScheme)
            #endif
        }
    }

    @MainActor
    private func servicesForSpace(_ spaceID: UUID) -> [ServiceInstance] {
        // Route through AppState's implementation, which guards against
        // dangling links (reading `link.space`/`.service` on a deleted model
        // traps). This is called from keyboard shortcuts, so an unguarded copy
        // could crash on a keystroke. Globals sit where the placement puts them.
        appState.railServices(forSpace: spaceID)
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
    private func allServiceDestinations() -> [ServiceShortcutDestination] {
        // Globals sit where the placement setting puts them, as the all-services
        // rail lists them. They carry no space, so ⌘1 on one does not switch spaces.
        let globals = RailEdits.globalServices(in: appState.modelContainer.mainContext).map(\.id)
        let spaces = allSpaces().map { space in
            (spaceID: space.id, services: appState.servicesForSpace(space.id).map(\.id))
        }
        return ServiceShortcutNavigation.shortcutDestinations(
            globals: globals, spaces: spaces, placement: GlobalPlacement.current()
        )
    }


    /// The credits block in the About panel: one line on what the app is, then a
    /// live link to the donation page. The panel centres its own text, so the
    /// paragraph style has to match or the link sits off to one side.
    private static var aboutCredits: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center

        let credits = NSMutableAttributedString(
            string: "One window for the services you keep open all day.\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centred
            ]
        )
        credits.append(
            NSAttributedString(
                string: "Buy me a coffee",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.linkColor,
                    .link: SupportLink.url,
                    .paragraphStyle: centred
                ]
            )
        )
        return credits
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

/// Holds Sparkle's install-and-relaunch until open sheets are closed, since
/// AppKit drops a quit while one is open (see `SheetQuit`).
@MainActor
final class UpdaterQuitDelegate: NSObject, SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard SheetQuit.hasSheet else { return false }
        // Sparkle asks on the main thread, and the handler is called back on
        // it too, so it never crosses threads.
        nonisolated(unsafe) let handler = installHandler
        SheetQuit.closeSheets { _ in handler() }
        return true
    }
}
#endif
