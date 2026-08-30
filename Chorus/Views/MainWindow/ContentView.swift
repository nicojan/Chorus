import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState

    /// Whether the hybrid layout's space strip carries names, read here because
    /// it sets the strip's width, and the service bar beside it has to start
    /// clear of whatever the traffic lights overhang.
    @AppStorage(SpaceStripMetrics.defaultsKey) private var showSpaceNames = true

    /// Gates the fresh-start confirmation. Local to the view rather than on
    /// `AppState`: nothing outside this banner presents it.
    @State private var isConfirmingFreshStart = false

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            // Three notices, one shape. They used to be two raw SwiftUI yellows
            // and a solid red bar, which read as three unrelated designs stacked
            // on each other. `NoticeStrip` carries the severity in the icon and
            // the rule under the strip, and carries the window-drag handle every
            // one of them needs.
            if let error = appState.storeError {
                NoticeStrip(severity: .error) {
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
                    if appState.isStoreInMemoryFallback {
                        Button("Start fresh…") {
                            isConfirmingFreshStart = true
                        }
                        .font(.caption)
                        .help("Set your current data file aside and start with a new, empty one")
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
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Warning: \(error)")
                .confirmationDialog(
                    "Start with a new, empty Chorus?",
                    isPresented: $isConfirmingFreshStart,
                    titleVisibility: .visible
                ) {
                    Button("Start Fresh and Restart") {
                        appState.chooseFreshStart()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your current data file is kept as a backup and stays listed under Review backups, so you can put it back later. Chorus restarts to do this.")
                }
                // The quit waits for the dialog to close: AppKit will not
                // terminate while one is attached and drops the request rather
                // than deferring it. Same split as the recovery picker's.
                .onChange(of: isConfirmingFreshStart) { _, shown in
                    if !shown { appState.quitForScheduledFreshStart() }
                }
            }

            if appState.storeError == nil, appState.storeRecoveryOffer != nil {
                NoticeStrip(severity: .info) {
                    Text("Chorus has a backup with more of your spaces and services than it can see now.")
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("Review backups…") { appState.isShowingStoreRecovery = true }
                        .font(.caption)
                    Button("Not now") { appState.declineStoreRecovery() }
                        .font(.caption)
                }
                // No .accessibilityLabel override here, unlike the storeError
                // banner above: an explicit label replaces what `.combine`
                // would otherwise speak, and on this banner the buttons ARE
                // the point — overriding would drop "Review backups…" and
                // "Not now" from VoiceOver's reading, leaving them reachable
                // only as custom actions.
                .accessibilityElement(children: .combine)
            }

            if !appState.networkMonitor.isOnline {
                NoticeStrip(severity: .warning) {
                    Text("You're offline. Services won't load new content until your connection returns.")
                        .font(.caption)
                    Spacer()
                }
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
                SupportButton()
                    .padding(.trailing, 10 - SupportButtonMetrics.targetOverhang)
                    .padding(.top, supportButtonTopInset)
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

    /// Arranges the rails and the web content per the chosen layout: one rail
    /// down the left, one along the top as a bar of tabs, or the spaces down the
    /// left with that space's services along the top.
    ///
    /// The first two draw one rail, with the current space as its header. The
    /// third is the only one that still puts two rails on screen, and there the
    /// header comes off — the strip beside it is already saying where you are.
    @ViewBuilder
    private func mainLayout(
        spaceSelection: Binding<UUID?>,
        serviceSelection: Binding<UUID?>
    ) -> some View {
        // The title bar is hidden, so content runs to the top edge. Reserve the
        // top-left for the traffic lights: push the leftmost top elements clear.
        let lightsHeight: CGFloat = 28
        let lightsWidth: CGFloat = 72

        switch appState.railLayout {
        case .sidebar:
            HStack(spacing: 0) {
                rail(axis: .vertical, spaceSelection: spaceSelection, serviceSelection: serviceSelection, contentInset: lightsHeight)
                Divider()
                webContent
            }
        case .topBars:
            VStack(spacing: 0) {
                rail(axis: .horizontal, spaceSelection: spaceSelection, serviceSelection: serviceSelection, contentInset: lightsWidth)
                Divider()
                webContent
            }
        case .hybrid:
            HStack(spacing: 0) {
                SpaceStripView(selectedSpaceID: spaceSelection, contentInset: lightsHeight)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Spaces")
                Divider()
                VStack(spacing: 0) {
                    // The traffic lights sit over the strip. Only what they
                    // overhang lands on this bar, so only that much is spent
                    // clearing them — a wide strip swallows them whole and the
                    // tabs start flush.
                    rail(
                        axis: .horizontal,
                        spaceSelection: spaceSelection,
                        serviceSelection: serviceSelection,
                        contentInset: SpaceStripMetrics.barLeadingInset(
                            stripWidth: SpaceStripMetrics.width(showingNames: showSpaceNames),
                            lightsWidth: lightsWidth
                        ),
                        showsSpaceHeader: false
                    )
                    Divider()
                    webContent
                }
            }
        }
    }

    private func rail(
        axis: Axis,
        spaceSelection: Binding<UUID?>,
        serviceSelection: Binding<UUID?>,
        contentInset: CGFloat = 0,
        showsSpaceHeader: Bool = true
    ) -> some View {
        UnifiedRailView(
            selectedSpaceID: spaceSelection,
            selectedServiceID: serviceSelection,
            axis: axis,
            contentInset: contentInset,
            showsSpaceHeader: showsSpaceHeader
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space and services")
    }

    private var webContent: some View {
        WebContentView(selectedServiceID: appState.selectedServiceID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Web content")
    }

    /// Centres the donation button's 20 point chip in whatever the layout puts
    /// along the top: the sidebar's nav row, 32 points tall, and the unified
    /// rail's bar, 42. Re-measured when one rail replaced two — the old 36 and
    /// 40 point bars are gone. The overhang comes off because the chip is
    /// centred inside a larger click target.
    private var supportButtonTopInset: CGFloat {
        let overhang = SupportButtonMetrics.targetOverhang
        switch appState.railLayout {
        case .sidebar: return 6 - overhang
        // The hybrid layout puts the same 42 point bar along the top, so the
        // button is centred in it the same way.
        case .topBars, .hybrid: return (UnifiedRailView.barHeight - SupportButtonMetrics.chipSize) / 2 - overhang
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

/// The donation button's geometry, in one place because two views need it:
/// `ContentView` draws the button and `UnifiedRailView` keeps its corner clear.
///
/// There is no visibility half any more. The button used to be switchable from
/// Settings; it is one 20 point chip that only takes colour under the pointer,
/// and the switch cost every layout a second code path for a hole where it
/// would have been.
enum SupportButtonMetrics {
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
/// under the pointer. The pointer gets 28 points to hit — see
/// `SupportButtonMetrics`.
private struct SupportButton: View {
    @State private var isHovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(SupportLink.url)
        } label: {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
                .frame(width: SupportButtonMetrics.chipSize, height: SupportButtonMetrics.chipSize)
                // The rails scroll under this button when a space holds enough
                // services to overflow, so it needs its own fill to stay legible.
                .background(Color(nsColor: .windowBackgroundColor))
                // The paint stops at the chip; the pointer gets a wider target
                // around it. Growing the fill instead would make the button
                // louder, which is the thing the 20 points are buying.
                .frame(width: SupportButtonMetrics.targetSize, height: SupportButtonMetrics.targetSize)
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
