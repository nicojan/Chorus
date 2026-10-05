import SwiftUI
import SwiftData
import WebKit

struct WebContentView: View {
    let selectedServiceID: UUID?

    @Environment(AppState.self) private var appState
    @Query private var services: [ServiceInstance]
    @State private var currentWebView: WKWebView?
    @State private var transitionSnapshot: NSImage?
    @State private var previousServiceID: UUID?
    @State private var showPasskeyNotice = false
    @AppStorage(ServiceNameVisibility.defaultsKey) private var showServiceNames = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shared nav state so the top tab bar can host the nav buttons.
    private var webViewState: WebViewState { appState.webViewState }

    /// How far the traffic lights reach past a left rail into this view's top
    /// row. With names off the rail is 52 points, narrower than the lights, and
    /// the back button sat under the green one. The bar layouts put their own
    /// bar on top, so nothing here reaches the lights.
    private var trafficLightsOverhang: CGFloat {
        guard !appState.railLayout.hasTopBar else { return 0 }
        return SpaceStripMetrics.barLeadingInset(
            stripWidth: showServiceNames ? ServiceRowView.railWidth : ServiceRowView.compactRailWidth,
            lightsWidth: SpaceStripMetrics.trafficLightsWidth
        )
    }

    private var selectedService: ServiceInstance? {
        guard let id = selectedServiceID else { return nil }
        return services.first { $0.id == id }
    }

    /// The tabs the selected service has open. See `ServiceTabs`.
    private var selectedTabs: ServiceTabs? {
        guard let id = selectedServiceID else { return nil }
        return appState.webViewPool.tabs(for: id)
    }

    /// The page on screen: the selected tab, or the service's own page.
    private var displayedWebView: WKWebView? {
        selectedTabs?.selectedTab?.webView ?? currentWebView
    }

    var body: some View {
        VStack(spacing: 0) {
            if let service = selectedService, currentWebView != nil {
                // Both bar layouts host the nav buttons in the top bar itself.
                // The two left-rail layouts have no top bar, so they get a slim
                // navigation row above the card, on the canvas.
                if !appState.railLayout.hasTopBar {
                    // The gutter puts the first circle on the web card's edge.
                    WebNavButtons(webViewState: webViewState, homeURL: URL(string: service.url))
                        .padding(.horizontal, ChorusCard.gutter)
                        .padding(.leading, trafficLightsOverhang)
                        .frame(maxWidth: .infinity, minHeight: ChorusCard.topBand, alignment: .leading)
                }
            } else if !appState.railLayout.hasTopBar {
                // No page, no buttons, but the band stays, so the card keeps its
                // top edge level with the rail card's.
                Color.clear.frame(height: ChorusCard.topBand)
            }

            // The notices sit between the nav row and the card, pushing the
            // page down rather than covering it. See `WindowNotices`.
            WindowNotices()
            if showPasskeyNotice, selectedService != nil, currentWebView != nil {
                passkeyNoticeCard
                    .padding(.bottom, ChorusCard.gutter)
                    // A new service starts its own 12 seconds.
                    .id(selectedServiceID)
            }

            // Everything below the nav row is one card: the page, the loading
            // placeholder and the empty state alike, so the window keeps its
            // shape while a service loads or when there is none.
            cardContent
                .contentCard()

        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showPasskeyNotice)
        .onAppear {
            loadWebViewForSelectedService()
        }
        .onChange(of: selectedServiceID) {
            // Only a change of selection opens a Mac app, never the launch
            // restore or a web view rebuild.
            loadWebViewForSelectedService(opensNativeApp: true)
        }
        .onChange(of: appState.webViewRebuildToken) {
            // A service's web view was rebuilt (e.g. custom CSS edit). Re-fetch
            // so the active service picks up the freshly created view.
            loadWebViewForSelectedService()
        }
        .onChange(of: selectedTabs?.selectedID) {
            showDisplayedWebView()
        }
        .onChange(of: webViewState.isLoading) { _, loading in
            // Drop the snapshot once the page finishes so it can't linger over a
            // loaded page and to free the bitmap. Delayed past the fade, and
            // re-checked in case another load started in the meantime.
            guard !loading else { return }
            if let displayedWebView { Self.nudgeLayout(of: displayedWebView) }
            let delay = reduceMotion ? 0 : 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !webViewState.isLoading { transitionSnapshot = nil }
            }
        }
    }

    private var cardContent: some View {
        WebContentCard(
            service: selectedService,
            webView: displayedWebView,
            tabs: selectedTabs,
            transitionSnapshot: transitionSnapshot,
            isLoading: webViewState.isLoading,
            findInPageVisible: Binding(
                get: { appState.findInPageVisible },
                set: { appState.findInPageVisible = $0 }
            ),
            onCloseTab: { id in
                guard let serviceID = selectedServiceID else { return }
                appState.webViewPool.closeTab(id, for: serviceID)
            }
        ) { emptyState }
    }

    /// Points the nav buttons at whichever page is now on screen, after a tab
    /// opens, closes or is picked. The snapshot belongs to the service's page,
    /// so it never covers a tab.
    private func showDisplayedWebView() {
        guard let displayedWebView else { return }
        webViewState.attach(to: displayedWebView)
        if displayedWebView !== currentWebView { transitionSnapshot = nil }
        Self.nudgeLayout(of: displayedWebView)
    }

    /// The snapshot to keep after binding to a service's web view: one only
    /// while the load it stands in for is actually running. A snapshot held past
    /// that is stale, and the next navigation would paint it over a live page.
    static func retainedSnapshot(_ captured: NSImage?, isLoading: Bool) -> NSImage? {
        isLoading ? captured : nil
    }

    /// Once the view is shown its frame settles a render tick later. Some SPAs
    /// (Gmail) cache a viewport-height layout and, if it was measured against a
    /// stale/transitional frame, leave their fixed header stranded above the
    /// visible area with no way to scroll to it. Fire a synthetic resize so the
    /// page re-measures against the real frame; it's a no-op for other sites.
    /// It runs on selection and again when a load finishes: at launch the
    /// selection one lands on a page that has not started loading, so it alone
    /// never reached Gmail.
    private static func nudgeLayout(of webView: WKWebView) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            _ = try? await webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'))")
        }
    }

    private func loadWebViewForSelectedService(opensNativeApp: Bool = false) {
        // Stop the outgoing service's active poll — but only if the pool still
        // regards it as the active service. On a deep-link switch AppState has
        // already made the incoming service active and moved the outgoing one
        // onto a background poll; stopping here would wrongly kill it. On a
        // normal switch the pool hasn't transitioned yet, so this is the right
        // point to stop. (See NotificationManager.shouldStopOutgoingPoll.)
        if let previousID = previousServiceID,
           NotificationManager.shouldStopOutgoingPoll(
               previousID: previousID,
               poolActiveID: appState.webViewPool.activeServiceID
           ) {
            appState.notificationManager.stopPolling(for: previousID)
        }

        guard let service = selectedService else {
            NativeAppDocker.shared.undock()
            webViewState.detach()
            currentWebView = nil
            transitionSnapshot = nil
            previousServiceID = nil
            return
        }

        // A Mac app has no web view. The outgoing page stays loaded in the
        // background, like any service you switch away from.
        if let bundleID = service.nativeAppBundleID {
            appState.webViewPool.deactivateActiveService()
            webViewState.detach()
            currentWebView = nil
            transitionSnapshot = nil
            previousServiceID = service.id
            showPasskeyNotice = false
            if opensNativeApp { NativeAppDocker.shared.dock(bundleID: bundleID) }
            return
        }
        NativeAppDocker.shared.undock()

        // Grab the snapshot before loading — if the service was soft-hibernated,
        // this gives us an instant preview to show while the web view wakes up.
        let captured = appState.webViewPool.snapshot(for: service.id)

        let webView = appState.webViewPool.webView(for: service)
        // Apply the effective zoom (per-service if set, else the Chorus-wide
        // default) so it survives hibernation and relaunch. Setting pageZoom is
        // a no-op when the value matches.
        webView.pageZoom = CGFloat(appState.effectiveZoom(for: service))
        currentWebView = webView
        // Coming back to a service shows the tab that was on screen when it was
        // left, if any.
        let shown = appState.webViewPool.displayedWebView(for: service.id) ?? webView
        webViewState.attach(to: shown)
        // Only hold the snapshot if there is a load for it to cover. Switching
        // to a service that is already loaded starts no navigation, so the
        // `isLoading` observer never fires and the old clear-on-finish path
        // never runs — the image would sit in state until the page's next
        // navigation put it back on screen.
        transitionSnapshot = shown === webView
            ? Self.retainedSnapshot(captured, isLoading: webView.isLoading)
            : nil
        previousServiceID = service.id

        // Passive one-time notice: WKWebView can't use passkeys for sign-in, so
        // warn the user the first time each service is opened. Gated by the same
        // capability switch as the Add Service notice, and marked seen as soon
        // as it's shown so switching away and back doesn't re-trigger it.
        if !AppCapabilities.passkeysSupported, appState.shouldShowPasskeyNotice(for: service) {
            showPasskeyNotice = true
            appState.markPasskeyNoticeSeen(for: service.id)
        } else {
            showPasskeyNotice = false
        }

        Self.nudgeLayout(of: webView)

        // Start active-mode badge/title polling for the displayed service.
        // Pass closures (rather than the captured bool) so the next poll tick
        // sees fresh values after the user toggles mute or per-service badge.
        let catalogEntry = service.catalogEntryID.flatMap { ServiceCatalog.shared.entry(for: $0) }
        let serviceID = service.id
        let appStateRef = appState
        appState.notificationManager.startPolling(
            for: service.id,
            webView: webView,
            isMuted: { appStateRef.isServiceEffectivelyMuted(serviceID) },
            showBadge: { appStateRef.isServiceShowingBadge(serviceID) },
            catalogEntry: catalogEntry,
            mode: .active
        )
    }

    /// A dismissible card warning that passkey sign-in isn't available in
    /// Chorus's web views, above the page with the window's other notices.
    /// Auto-hides after
    /// a short delay; the "seen" state is already persisted when it appears,
    /// so it never returns for this service.
    private var passkeyNoticeCard: some View {
        NoticeCard(severity: .info, systemImage: "person.badge.key.fill") {
            Text(AppCapabilities.passkeyUnavailableBanner)
                .font(ChorusType.caption)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button {
                showPasskeyNotice = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .task {
            // A cancelled wait means the card already went, so it must not
            // hide the next one.
            do {
                try await Task.sleep(for: .seconds(12))
            } catch {
                return
            }
            showPasskeyNotice = false
        }
    }

    /// Whether the currently selected space contains any services. Only
    /// evaluated when nothing is selected (the empty-state branch), so the
    /// per-render fetch is off the hot path.
    private var selectedSpaceHasServices: Bool {
        guard let spaceID = appState.selectedSpaceID else { return false }
        return !appState.servicesForSpace(spaceID).isEmpty
    }

    @ViewBuilder
    private var emptyState: some View {
        if appState.selectedSpaceID == nil {
            emptyStateContent(
                icon: "square.stack.3d.up",
                message: "Create a space to get started",
                actionTitle: nil
            )
        } else if selectedSpaceHasServices {
            emptyStateContent(
                icon: "rectangle.stack",
                message: "Pick a service from the sidebar to get started",
                actionTitle: nil
            )
        } else {
            emptyStateContent(
                icon: "plus.rectangle.on.rectangle",
                message: "No services in this space yet",
                actionTitle: "Add Service"
            ) {
                appState.showAddService = true
            }
        }
    }

    private func emptyStateContent(
        icon: String,
        message: String,
        actionTitle: String?,
        action: @escaping () -> Void = {}
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)

            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Renders the selected service without owning selection, polling, or storage.
/// Keeping this separate lets the real SwiftUI service transition run in tests.
struct WebContentCard<EmptyContent: View>: View {
    let service: ServiceInstance?
    /// The page on screen for this service: the selected tab, or its own page.
    let webView: WKWebView?
    /// The service's open tabs, shown above the page when it has any.
    let tabs: ServiceTabs?
    let transitionSnapshot: NSImage?
    let isLoading: Bool
    @Binding var findInPageVisible: Bool
    let onCloseTab: (UUID) -> Void
    @ViewBuilder var emptyContent: () -> EmptyContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The page the host should hold. A Mac-app service and an empty selection
    /// both have none, and the host stays mounted either way so the outgoing
    /// page can still receive its native exit.
    private var pageWebView: WKWebView? {
        guard let service, service.nativeAppBundleID == nil else { return nil }
        return webView
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Keep the host in the hierarchy for every selection. Hiding or
            // removing it would prevent the outgoing page's native exit.
            WebViewContainer(webView: pageWebView)

            if let service, let bundleID = service.nativeAppBundleID {
                NativeAppPanel(label: service.label, bundleID: bundleID)
                    .background(ChorusColor.card)
            } else if let service, let webView = pageWebView {
                VStack(spacing: 0) {
                    if let tabs, !tabs.isEmpty {
                        ServiceTabStrip(
                            serviceLabel: service.label,
                            tabs: tabs,
                            onClose: onCloseTab
                        )
                    }
                    pageChrome(webView)
                }
            } else if service != nil {
                ProgressView("Loading service…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ChorusColor.card)
            } else {
                emptyContent()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ChorusColor.card)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isLoading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: findInPageVisible)
    }

    /// The load snapshot and the find bar over the live page. The page itself is
    /// the card's base layer, so it stays mounted while this comes and goes.
    private func pageChrome(_ webView: WKWebView) -> some View {
        ZStack(alignment: .topTrailing) {
            // Show cached snapshot as instant visual feedback while page loads.
            // Fades out once the web view finishes loading. It fills the
            // web view's frame (rather than aspect-fill, which cropped or
            // stretched it); since the snapshot was taken at this frame it
            // lines up without distortion.
            if let snapshot = transitionSnapshot, isLoading {
                Image(nsImage: snapshot)
                    .resizable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .transition(.opacity)
                    // The snapshot is a picture, never a shield. Without
                    // this it sits over the live web view and eats every
                    // click for as long as a navigation runs — a page
                    // that looks exactly like the one underneath but
                    // answers nothing (reported on TD EasyWeb: click
                    // Login and the app appears to freeze).
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if findInPageVisible {
                FindInPageBar(isVisible: $findInPageVisible, webView: webView)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

/// What the card shows for a Mac-app service: the app runs in its own window,
/// so this offers to bring it forward.
private struct NativeAppPanel: View {
    let label: String
    let bundleID: String

    @State private var isTrusted = NativeAppBadgeReader.isTrusted

    var body: some View {
        VStack(spacing: 16) {
            if let appURL = NativeApp.appURL(bundleID: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("\(label) opens in its own window.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Open \(label)") { NativeAppDocker.shared.dock(bundleID: bundleID) }
                    .buttonStyle(.borderedProminent)
                if !isTrusted {
                    Text("To show \(label)'s unread count and hold its window in place, turn on Chorus in System Settings, under Privacy & Security, then Accessibility.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Button("Open Accessibility Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Chorus can't find \(label) on this Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ScreenFrameReporter { NativeAppDocker.shared.updateTarget($0) })
        // The app went behind Chorus; a click on its place brings it back.
        .contentShape(Rectangle())
        .onTapGesture { NativeAppDocker.shared.dock(bundleID: bundleID) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = NativeAppBadgeReader.isTrusted
        }
    }
}

/// Reports its own frame in screen coordinates whenever the view is laid out
/// again or its window moves, so a docked Mac app can follow the service area
/// through window drags, resizes and rail layout changes.
private struct ScreenFrameReporter: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onChange = onChange
        nsView.report()
    }

    final class ReportingView: NSView {
        var onChange: (CGRect) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            // A docked app goes out of sight with the window and comes back with it.
            for name in [NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { NativeAppDocker.shared.suspend() }
                })
            }
            observers.append(center.addObserver(
                forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { NativeAppDocker.shared.resume() }
            })
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard let window else { return }
            onChange(window.convertToScreen(convert(bounds, to: nil)))
        }
    }
}
