import SwiftUI
import SwiftData

/// Fixed metrics of the window's chrome. The title bar is hidden, so these
/// insets are what keep content clear of the traffic lights — shared rather than
/// repeated, because a rail and the view beside it drifting apart by a few
/// points is exactly the kind of misalignment nobody notices until it ships.
enum WindowChrome {
    /// Height of the traffic-light strip.
    static let lightsHeight: CGFloat = 28
    /// Width the traffic lights occupy, for insetting content that starts at the
    /// window's leading edge.
    static let lightsWidth: CGFloat = 72
}

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            if let error = appState.storeError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                    if let url = appState.storeFileURL {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .font(.caption)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.15))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Warning: \(error)")
            }

            if !appState.networkMonitor.isOnline {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                    Text("You're offline. Services won't load new content until your connection returns.")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(ServiceIconPalette.badgeRed)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Offline")
            }

            mainLayout(
                spaceSelection: $state.selectedSpaceID,
                serviceSelection: $state.selectedServiceID
            )
            .frame(minWidth: 800, minHeight: 500)
            // Fill behind everything with the window shade so the traffic-light
            // insets don't reveal the title-bar vibrancy (the top-left tint).
            .background(Color(nsColor: .windowBackgroundColor))
            // Extend up into the (hidden) title-bar area so the tab bar sits at
            // the very top of the window; the traffic-light insets keep the
            // top-left clear.
            .ignoresSafeArea(.container, edges: .top)
        }
        // The top-bar and hybrid layouts put draggable tabs in the title-bar
        // drag band, so turn the OS window drag off there (a click-drag on a tab
        // would otherwise move the window instead of reordering) and let the
        // WindowDragHandles move the window instead. The sidebar keeps the
        // normal title-bar drag.
        .background(WindowMovableConfigurator(isMovable: appState.railLayout == .sidebar))
        // Ask for macOS notification permission here, not in AppState.init:
        // requesting during App.init (before the scene exists) can fail with
        // "Notifications are not allowed for this application" and leave the app
        // unregistered. The root view's .task runs after launch, when the
        // request lands correctly. Idempotent, so re-running is harmless.
        .task {
            appState.notificationManager.requestAuthorization()
        }
        .onChange(of: appState.selectedSpaceID) { _, newSpaceID in
            if let spaceID = newSpaceID {
                appState.preloadServicesForSpace(spaceID)
                // Don't overwrite a serviceID that was set in the same
                // render tick by QuickSwitcher or the menu-bar handler
                // (they write spaceID + serviceID together). Only fall
                // back to selectFirstService when the current selection
                // isn't valid for the new space — e.g., the user clicked
                // a space chip in SpaceStripView.
                let validIDs = Set(appState.servicesForSpace(spaceID).map(\.id))
                if let currentID = appState.selectedServiceID, validIDs.contains(currentID) {
                    return
                }
                selectFirstService(in: spaceID)
            }
        }
        .sheet(isPresented: $state.showAddService) {
            if let spaceID = appState.selectedSpaceID {
                AddServiceSheet(spaceID: spaceID)
            } else {
                // Defensive: ⌘N is disabled without a selected space, but if the
                // sheet is ever presented in that state, give it a way out rather
                // than a blank, un-dismissable panel.
                VStack(spacing: 16) {
                    Text("Select or create a space before adding a service.")
                        .multilineTextAlignment(.center)
                    Button("OK") { state.showAddService = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(40)
                .frame(minWidth: 320)
            }
        }
        .sheet(isPresented: $state.showQuickSwitcher) {
            QuickSwitcherView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
        }
        .alert(
            appState.pendingMediaRequest?.title ?? "",
            isPresented: Binding(
                get: { appState.pendingMediaRequest != nil },
                set: { _ in }   // dismissal always routes through a button below
            ),
            presenting: appState.pendingMediaRequest
        ) { request in
            Button("Allow") { appState.answerMediaRequest(request.id, allow: true) }
            Button("Don't Allow", role: .cancel) { appState.answerMediaRequest(request.id, allow: false) }
        } message: { request in
            Text(request.message)
        }
        .overlay {
            if appState.isLocked {
                LockView()
                    .environment(appState)
                    .transition(.opacity)
            }
        }
    }

    /// Arranges the two rails and the web content per the chosen layout. Sidebar
    /// keeps both rails vertical on the left; top bars stacks them horizontally
    /// above the content; hybrid keeps spaces on the left with service tabs on
    /// top of the content.
    @ViewBuilder
    private func mainLayout(
        spaceSelection: Binding<UUID?>,
        serviceSelection: Binding<UUID?>
    ) -> some View {
        // The title bar is hidden, so content runs to the top edge. Reserve the
        // top-left for the traffic lights: push the leftmost top elements clear.
        let lightsHeight = WindowChrome.lightsHeight
        let lightsWidth = WindowChrome.lightsWidth
        let railWidth: CGFloat = 52

        // With the spaces rail hidden, whatever sits at the top-left inherits the
        // job of clearing the traffic lights. In `.sidebar` the services rail
        // already reserves `lightsHeight`, but the horizontal service tabs in
        // `.topBars`/`.hybrid` were only inset on the assumption that the spaces
        // rail was there to their left (or above), so they need the full
        // `lightsWidth` once it goes away.
        let spacesHidden = appState.hideSpacesUI
        let hybridTabInset = spacesHidden ? lightsWidth : lightsWidth - railWidth

        switch appState.railLayout {
        case .sidebar:
            HStack(spacing: 0) {
                // The vertical rules start below the traffic-light band rather
                // than running the full height. Otherwise they cut across the
                // title strip and chop the top of the window into segments; the
                // rails already leave that band clear, so the rules should too.
                if !spacesHidden {
                    spacesRail(axis: .vertical, selection: spaceSelection, contentInset: lightsHeight)
                    Divider().padding(.top, lightsHeight)
                }
                if let spaceID = appState.selectedSpaceID {
                    servicesRail(axis: .vertical, spaceID: spaceID, selection: serviceSelection, contentInset: lightsHeight)
                    Divider().padding(.top, lightsHeight)
                }
                webContent
            }
        case .topBars:
            VStack(spacing: 0) {
                if !spacesHidden {
                    spacesRail(axis: .horizontal, selection: spaceSelection, contentInset: lightsWidth)
                    Divider()
                }
                if let spaceID = appState.selectedSpaceID {
                    servicesRail(
                        axis: .horizontal, spaceID: spaceID, selection: serviceSelection,
                        contentInset: spacesHidden ? lightsWidth : 0)
                }
                webContent
            }
        case .hybrid:
            HStack(spacing: 0) {
                if !spacesHidden {
                    spacesRail(axis: .vertical, selection: spaceSelection, contentInset: lightsHeight)
                    Divider()
                }
                VStack(spacing: 0) {
                    if let spaceID = appState.selectedSpaceID {
                        servicesRail(axis: .horizontal, spaceID: spaceID, selection: serviceSelection, contentInset: hybridTabInset)
                    }
                    webContent
                }
            }
        }
    }

    private func spacesRail(axis: Axis, selection: Binding<UUID?>, contentInset: CGFloat = 0) -> some View {
        SpaceStripView(selectedSpaceID: selection, axis: axis, contentInset: contentInset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Spaces")
    }

    private func servicesRail(axis: Axis, spaceID: UUID, selection: Binding<UUID?>, contentInset: CGFloat = 0) -> some View {
        ServiceSidebarView(spaceID: spaceID, selectedServiceID: selection, axis: axis, contentInset: contentInset)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Services")
    }

    private var webContent: some View {
        WebContentView(selectedServiceID: appState.selectedServiceID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Web content")
    }

    private func selectFirstService(in spaceID: UUID) {
        appState.selectedServiceID = appState.servicesForSpace(spaceID).first?.id
    }
}

/// Opaque cover shown while the app is locked, hiding all content until the user
/// authenticates. Prompts for Touch ID on appear; the button retries.
struct LockView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Chorus is locked")
                .font(.title2)
                .bold()
            Button("Unlock") {
                appState.authenticate()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            appState.authenticate()
        }
    }
}
