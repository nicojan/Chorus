import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    /// Whether the hybrid layout's space strip carries names, read here because
    /// it sets the strip's width, and the service bar beside it has to start
    /// clear of whatever the traffic lights overhang.
    @AppStorage(SpaceStripMetrics.defaultsKey) private var showSpaceNames = true
    /// Whether the rail carries service names, which dragging its edge sets.
    @AppStorage(ServiceNameVisibility.defaultsKey) private var showServiceNames = true
    @AppStorage(RailWidth.defaultsKey) private var railNamedWidth = Double(RailWidth.defaultNamed)

    /// How much desktop the window lets through. See `WindowGlassStyle`.
    @AppStorage(WindowGlassStyle.defaultsKey) private var glassStyleRaw = WindowGlassStyle.defaultStyle.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency


    var body: some View {
        @Bindable var state = appState

        mainLayout(
            spaceSelection: $state.selectedSpaceID,
            serviceSelection: $state.selectedServiceID
        )
        .frame(minWidth: 800, minHeight: 500)
        // The canvas behind everything, frosted when a glass style is on.
        // It also keeps the traffic-light insets from showing the
        // title-bar vibrancy (the top-left tint).
        .background(
            WindowBackdrop(
                style: WindowGlassStyle.resolve(glassStyleRaw)
                    .effective(reduceTransparency: reduceTransparency)
            )
        )
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
        .overlay { quickSwitcherLayer }
        // The top-bar and hybrid layouts put draggable tabs in the title-bar
        // drag band, so turn the OS window drag off there (a click-drag on a tab
        // would otherwise move the window instead of reordering) and let the
        // WindowDragHandles move the window instead. The sidebar keeps the
        // normal title-bar drag.
        .background(WindowMovableConfigurator(isMovable: !appState.railLayout.hasTopBar))
        .background(TrafficLightsPositioner(bandHeight: ChorusCard.topBand))
        .onAppear {
            appState.openMainWindow = { [openWindow] in openWindow(id: "main") }
        }
        // Ask for macOS notification permission here, not in AppState.init:
        // requesting during App.init (before the scene exists) can fail with
        // "Notifications are not allowed for this application" and leave the app
        // unregistered. The root view's .task runs after launch, when the
        // request lands correctly. Idempotent, so re-running is harmless.
        .task {
            appState.notificationManager.requestAuthorization()
            #if DEBUG
            appState.applyDebugMockBadges()
            appState.startDemoControl()
            #endif
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
        .sheet(isPresented: Binding(
            // Never over the store recovery sheet, which has to come first.
            get: { appState.whatsNewVersion != nil && !appState.isShowingStoreRecovery },
            set: { if !$0 { appState.dismissWhatsNew() } }
        )) {
            if let version = appState.whatsNewVersion {
                WhatsNewSheet(version: version)
                    .environment(appState)
            }
        }
        .alert(
            "Let Chorus use Accessibility for \(appState.accessibilityExplanationAppName ?? "")?",
            isPresented: Binding(
                get: { appState.accessibilityExplanationAppName != nil },
                set: { if !$0 { appState.accessibilityExplanationAppName = nil } }
            ),
            presenting: appState.accessibilityExplanationAppName
        ) { _ in
            Button("Continue") { NativeAppBadgeReader.requestTrust() }
            Button("Not Now", role: .cancel) {}
        } message: { name in
            Text("Chorus needs it for two things: to read \(name)'s unread count from the Dock, and to move \(name)'s window over the space its tab would take. It never reads what's inside \(name) or any other app. macOS asks next. You can turn it off any time in System Settings, under Privacy & Security, then Accessibility.")
        }
        .modifier(MailLinkPresentation(appState: appState))
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

    /// Arranges the rails and web content for the chosen layout, including the
    /// compact left rail that groups every service by space.
    ///
    /// The ordinary left and top rails show the current space as their header.
    /// The hybrid and all-services layouts already show spaces in the rail, so
    /// they omit that header.
    @ViewBuilder
    private func mainLayout(
        spaceSelection: Binding<UUID?>,
        serviceSelection: Binding<UUID?>
    ) -> some View {
        // The title bar is hidden, so content runs to the top edge. Reserve the
        // top-left for the traffic lights: push the leftmost top elements clear.
        let lightsWidth = SpaceStripMetrics.trafficLightsWidth

        switch appState.railLayout {
        // The two left rails sit under the top band, where the traffic lights
        // are, so both cards start at the same height.
        case .sidebar:
            HStack(spacing: 0) {
                rail(axis: .vertical, spaceSelection: spaceSelection, serviceSelection: serviceSelection, contentInset: ChorusCard.topBand)
                webContent
                    .overlay(alignment: .leading) { RailResizeHandle(showsNames: $showServiceNames, namedWidth: $railNamedWidth, topInset: ChorusCard.topBand) }
            }
        case .allServices:
            HStack(spacing: 0) {
                rail(
                    axis: .vertical,
                    spaceSelection: spaceSelection,
                    serviceSelection: serviceSelection,
                    contentInset: ChorusCard.topBand,
                    showsSpaceHeader: false,
                    showsAllSpaces: true
                )
                webContent
                    .overlay(alignment: .leading) { RailResizeHandle(showsNames: $showServiceNames, namedWidth: $railNamedWidth, topInset: ChorusCard.topBand) }
            }
        case .topBars:
            VStack(spacing: 0) {
                rail(axis: .horizontal, spaceSelection: spaceSelection, serviceSelection: serviceSelection, contentInset: lightsWidth)
                webContent
            }
        case .hybrid:
            HStack(spacing: 0) {
                // The strip's card starts under the bar's height, level with
                // the web card beside it.
                SpaceStripView(selectedSpaceID: spaceSelection, contentInset: UnifiedRailView.barHeight)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Spaces")
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
                    // The strip's edge sets its names, as the rail's does.
                    webContent
                        .overlay(alignment: .leading) { RailWidthHandle(showsNames: $showSpaceNames) }
                }
            }
        }
    }

    /// The ⌘K switcher over the whole window: a faint scrim that closes it on
    /// a click, and the panel pinned near the top. See `QuickSwitcherView`.
    @ViewBuilder
    private var quickSwitcherLayer: some View {
        if appState.showQuickSwitcher {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                        .onTapGesture { appState.showQuickSwitcher = false }
                        .accessibilityHidden(true)
                    QuickSwitcherView(maxRows: QuickSwitcherView.maxRows(windowHeight: proxy.size.height))
                        .padding(.top, QuickSwitcherView.topInset(windowHeight: proxy.size.height))
                }
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    private func rail(
        axis: Axis,
        spaceSelection: Binding<UUID?>,
        serviceSelection: Binding<UUID?>,
        contentInset: CGFloat = 0,
        showsSpaceHeader: Bool = true,
        showsAllSpaces: Bool = false
    ) -> some View {
        UnifiedRailView(
            selectedSpaceID: spaceSelection,
            selectedServiceID: serviceSelection,
            axis: axis,
            contentInset: contentInset,
            showsSpaceHeader: showsSpaceHeader,
            showsAllSpaces: showsAllSpaces
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space and services")
        // The rail itself is what the other layouts rearrange.
        .featureTip(.showLayouts, arrowEdge: axis == .vertical ? .trailing : .bottom, appState: appState)
    }

    /// The web view on its inset card. The gutter runs round three sides; the
    /// top is left to whatever sits above the card, the nav row or the bar,
    /// which already spaces itself off the window edge.
    private var webContent: some View {
        WebContentView(selectedServiceID: appState.selectedServiceID)
            .padding([.horizontal, .bottom], ChorusCard.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Web content")
    }

    /// Centres the donation button's 20 point chip in the 52 point band, which
    /// every layout has along its top. The overhang comes off because the chip
    /// is centred inside a larger click target.
    private var supportButtonTopInset: CGFloat {
        (ChorusCard.topBand - SupportButtonMetrics.chipSize) / 2 - SupportButtonMetrics.targetOverhang
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
                // No fill of its own: nothing scrolls under this corner, since
                // the bar's nav buttons keep it clear, and an opaque square
                // shows as a patch once the canvas is frosted.
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

/// The window's three notices, one shape. They used to be two raw SwiftUI
/// yellows and a solid red bar across the top of the window, which read as
/// three unrelated designs stacked on each other and sat in the band the
/// traffic lights share. Now they are cards in a stack above the web card,
/// with the passkey notice, so they push the page down rather than cover it:
/// two of them cannot be dismissed, and a card over the page would hide the
/// top of every site for as long as it stood.
struct WindowNotices: View {
    @Environment(AppState.self) private var appState

    /// Gates the fresh-start confirmation. Local to the view rather than on
    /// `AppState`: nothing outside this notice presents it.
    @State private var isConfirmingFreshStart = false

    var body: some View {
        VStack(spacing: 6) {
            if let error = appState.storeError {
                NoticeCard(severity: .error) {
                    // Wraps in full: when Chorus is running on a temporary
                    // store, the end of this message says changes won't be
                    // saved, and that is the part that must not be cut off.
                    Text(error)
                        .font(ChorusType.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let url = appState.storeFileURL {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .font(ChorusType.caption)
                    }
                    if appState.storeRecoveryOffer != nil {
                        Button("Review backups…") {
                            appState.isShowingStoreRecovery = true
                        }
                        .font(ChorusType.caption)
                    }
                    if appState.isStoreInMemoryFallback {
                        Button("Start fresh…") {
                            isConfirmingFreshStart = true
                        }
                        .font(ChorusType.caption)
                        .help("Set your current data file aside and start with a new, empty one")
                    }
                    if appState.storeErrorDismissible {
                        Button {
                            appState.dismissStoreBanner()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .font(ChorusType.caption)
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
                NoticeCard(severity: .info) {
                    Text("Chorus has a backup with more of your spaces and services than it can see now.")
                        .font(ChorusType.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("Review backups…") { appState.isShowingStoreRecovery = true }
                        .font(ChorusType.caption)
                    Button("Not now") { appState.declineStoreRecovery() }
                        .font(ChorusType.caption)
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
                NoticeCard(severity: .warning) {
                    Text("You're offline. Services won't load new content until your connection returns.")
                        .font(ChorusType.caption)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Offline")
            }
        }
        // A gap under the stack only when something is in it.
        .padding(.bottom, isShowingAny ? ChorusCard.gutter : 0)
    }

    private var isShowingAny: Bool {
        appState.storeError != nil
            || appState.storeRecoveryOffer != nil
            || !appState.networkMonitor.isOnline
    }
}
