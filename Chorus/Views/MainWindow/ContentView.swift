import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState

    /// Settings switches the donation button off here. See
    /// `SupportButtonVisibility` for why this is a default rather than a
    /// stored preference.
    @AppStorage(SupportButtonVisibility.defaultsKey) private var showSupportButton = true

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
                    if appState.storeRecoveryOffer != nil {
                        Button("Review backups…") {
                            appState.isShowingStoreRecovery = true
                        }
                        .font(.caption)
                    }
                    if appState.storeErrorDismissible {
                        Button {
                            appState.dismissStoreBanner()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss")
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A banner sits at the very top of the window, inside the
                // title-bar drag band, and the top-bar layouts turn the OS
                // window drag off (see `WindowMovableConfigurator`). Without a
                // handle of its own the banner is dead to dragging, and since
                // it also pushes the tab strip's handle down out of the band,
                // the window can't be moved by its top edge at all while one is
                // up. Same idiom as `SpaceStripView`: the handle goes behind the
                // content and in front of the fill, so the buttons still take
                // their own clicks.
                .background(WindowDragHandle())
                .background(Color.yellow.opacity(0.15))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Warning: \(error)")
            }

            if appState.storeError == nil, appState.storeRecoveryOffer != nil {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    Text("Chorus has a backup with more of your spaces and services than it can see now.")
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("Review backups…") { appState.isShowingStoreRecovery = true }
                        .font(.caption)
                    Button("Not now") { appState.declineStoreRecovery() }
                        .font(.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                // See the store banner above for why this needs its own handle.
                .background(WindowDragHandle())
                .background(Color.yellow.opacity(0.15))
                // No .accessibilityLabel override here, unlike the storeError
                // banner above: an explicit label replaces what `.combine`
                // would otherwise speak, and on this banner the buttons ARE
                // the point — overriding would drop "Review backups…" and
                // "Not now" from VoiceOver's reading, leaving them reachable
                // only as custom actions.
                .accessibilityElement(children: .combine)
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
                // See the store banner above for why this needs its own handle.
                .background(WindowDragHandle())
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
            // The traffic lights hold the top-left, so the donation button takes
            // the top-right of whichever bar the layout puts up there.
            .overlay(alignment: .topTrailing) {
                if showSupportButton {
                    SupportButton()
                        .padding(.trailing, 10 - SupportButtonVisibility.targetOverhang)
                        .padding(.top, supportButtonTopInset)
                }
            }
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
        .sheet(isPresented: $state.isShowingStoreRecovery, onDismiss: {
            // Only quits when the user actually picked a backup. It has to
            // happen here rather than in the button: a quit requested while
            // this sheet is still attached is refused and dropped.
            appState.quitForScheduledRestore()
        }) {
            StoreRecoveryView()
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
        .alert(
            "Always appear active in \(appState.presencePrompt?.serviceLabel ?? "")?",
            isPresented: Binding(
                get: { appState.presencePrompt != nil },
                set: { _ in }   // dismissal always routes through a button below
            ),
            presenting: appState.presencePrompt
        ) { prompt in
            Button("Always Appear Active") { appState.answerPresencePrompt(prompt.id, enable: true) }
            Button("Not Now", role: .cancel) { appState.answerPresencePrompt(prompt.id, enable: false) }
        } message: { prompt in
            Text("\(prompt.serviceLabel) shows you as away when its window isn't focused. Turn this on to stay active even while you work in other apps. You can change it later in the service's settings. It may hold back some of its notifications while Chorus is in the background.")
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
        let lightsHeight: CGFloat = 28
        let lightsWidth: CGFloat = 72
        let railWidth: CGFloat = 52

        switch appState.railLayout {
        case .sidebar:
            HStack(spacing: 0) {
                spacesRail(axis: .vertical, selection: spaceSelection, contentInset: lightsHeight)
                Divider()
                if let spaceID = appState.selectedSpaceID {
                    servicesRail(axis: .vertical, spaceID: spaceID, selection: serviceSelection, contentInset: lightsHeight)
                    Divider()
                }
                webContent
            }
        case .topBars:
            VStack(spacing: 0) {
                spacesRail(axis: .horizontal, selection: spaceSelection, contentInset: lightsWidth)
                Divider()
                if let spaceID = appState.selectedSpaceID {
                    servicesRail(axis: .horizontal, spaceID: spaceID, selection: serviceSelection)
                }
                webContent
            }
        case .hybrid:
            HStack(spacing: 0) {
                spacesRail(axis: .vertical, selection: spaceSelection, contentInset: lightsHeight)
                Divider()
                VStack(spacing: 0) {
                    if let spaceID = appState.selectedSpaceID {
                        servicesRail(axis: .horizontal, spaceID: spaceID, selection: serviceSelection, contentInset: lightsWidth - railWidth)
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

    /// Centres the donation button's chip in the bar the current layout puts
    /// along the top: the sidebar's nav row is 32 points tall, the top-bar spaces
    /// rail 36, and the hybrid service rail 40. The overhang comes off because
    /// the chip is centred inside a larger click target.
    private var supportButtonTopInset: CGFloat {
        let overhang = SupportButtonVisibility.targetOverhang
        switch appState.railLayout {
        case .sidebar: return 6 - overhang
        case .topBars: return 8 - overhang
        case .hybrid: return 10 - overhang
        }
    }

    private func selectFirstService(in spaceID: UUID) {
        appState.selectedServiceID = appState.servicesForSpace(spaceID).first?.id
    }
}

/// Where the donation button and the About panel both point.
enum SupportLink {
    static let url = URL(string: "https://buymeacoffee.com/0xff.r4bbit")!
}

/// The donation button's visibility and geometry, in one place because three
/// views need them: `ContentView` draws the button, `ServiceSidebarView` keeps
/// its corner clear, and Settings switches it off.
enum SupportButtonVisibility {
    /// Whether the window draws the button at all. This is chrome visibility
    /// rather than user data, so it lives in defaults instead of
    /// `AppPreferences`: a stored property there is a new schema version and a
    /// migration (see CLAUDE.md), which a cosmetic toggle does not earn.
    static let defaultsKey = "showSupportButton"

    /// The painted chip. Below the 44 point target the UX audit asks for
    /// everywhere else, and deliberately so: this is a permanent request for
    /// money in a mouse-only app, and at 44 it reads as a control rather than a
    /// quiet link. The target below carries the accessibility argument instead.
    static let chipSize: CGFloat = 20

    /// The clickable area, which is larger than the paint.
    static let targetSize: CGFloat = 28

    /// How far the target overhangs the chip on each side. Both paddings that
    /// place the button subtract this, so the chip stays where it was drawn.
    static var targetOverhang: CGFloat { (targetSize - chipSize) / 2 }

    /// What the tab bar's nav buttons keep clear of the window's top-right
    /// corner: the button's trailing gap, its target, and 6 points between them.
    static var reservedWidth: CGFloat { 10 + targetSize + 6 }
}

/// A small link to the donation page, in the top-right of the window. Chorus
/// asks for money nowhere else, so this stands all the time, which is the reason
/// it is drawn quietly: it paints 20 points of chrome and only takes colour
/// under the pointer. The pointer gets 28 points to hit, and Settings can hide
/// it outright — see `SupportButtonVisibility`.
private struct SupportButton: View {
    @State private var isHovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(SupportLink.url)
        } label: {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
                .frame(width: SupportButtonVisibility.chipSize, height: SupportButtonVisibility.chipSize)
                // The rails scroll under this button when a space holds enough
                // services to overflow, so it needs its own fill to stay legible.
                .background(Color(nsColor: .windowBackgroundColor))
                // The paint stops at the chip; the pointer gets a wider target
                // around it. Growing the fill instead would make the button
                // louder, which is the thing the 20 points are buying.
                .frame(width: SupportButtonVisibility.targetSize, height: SupportButtonVisibility.targetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Buy me a coffee")
        .accessibilityLabel("Buy me a coffee")
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
