import SwiftUI
import SwiftData

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
            }
        }
        .sheet(isPresented: $state.showQuickSwitcher) {
            QuickSwitcherView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
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
        switch appState.railLayout {
        case .sidebar:
            HStack(spacing: 0) {
                spacesRail(axis: .vertical, selection: spaceSelection)
                Divider()
                if let spaceID = appState.selectedSpaceID {
                    servicesRail(axis: .vertical, spaceID: spaceID, selection: serviceSelection)
                    Divider()
                }
                webContent
            }
        case .topBars:
            VStack(spacing: 0) {
                spacesRail(axis: .horizontal, selection: spaceSelection)
                Divider()
                if let spaceID = appState.selectedSpaceID {
                    servicesRail(axis: .horizontal, spaceID: spaceID, selection: serviceSelection)
                    Divider()
                }
                webContent
            }
        case .hybrid:
            HStack(spacing: 0) {
                spacesRail(axis: .vertical, selection: spaceSelection)
                Divider()
                VStack(spacing: 0) {
                    if let spaceID = appState.selectedSpaceID {
                        servicesRail(axis: .horizontal, spaceID: spaceID, selection: serviceSelection)
                        Divider()
                    }
                    webContent
                }
            }
        }
    }

    private func spacesRail(axis: Axis, selection: Binding<UUID?>) -> some View {
        SpaceStripView(selectedSpaceID: selection, axis: axis)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Spaces")
    }

    private func servicesRail(axis: Axis, spaceID: UUID, selection: Binding<UUID?>) -> some View {
        ServiceSidebarView(spaceID: spaceID, selectedServiceID: selection, axis: axis)
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
