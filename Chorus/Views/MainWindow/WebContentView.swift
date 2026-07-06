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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shared nav state so the top tab bar can host the nav buttons.
    private var webViewState: WebViewState { appState.webViewState }

    private var selectedService: ServiceInstance? {
        guard let id = selectedServiceID else { return nil }
        return services.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let service = selectedService, let webView = currentWebView {
                // Horizontal layouts host the nav buttons in the top tab bar; the
                // sidebar layout shows them in a slim row above the content.
                if appState.railLayout == .sidebar {
                    WebNavButtons(webViewState: webViewState, homeURL: URL(string: service.url))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .windowBackgroundColor))
                    Divider()
                }

                ZStack(alignment: .topTrailing) {
                    WebViewContainer(webView: webView)

                    // Show cached snapshot as instant visual feedback while page loads.
                    // Fades out once the web view finishes loading. It fills the
                    // web view's frame (rather than aspect-fill, which cropped or
                    // stretched it); since the snapshot was taken at this frame it
                    // lines up without distortion.
                    if let snapshot = transitionSnapshot, webViewState.isLoading {
                        Image(nsImage: snapshot)
                            .resizable()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }

                    if appState.findInPageVisible {
                        FindInPageBar(
                            isVisible: Binding(
                                get: { appState.findInPageVisible },
                                set: { appState.findInPageVisible = $0 }
                            ),
                            webView: webView
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: webViewState.isLoading)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: appState.findInPageVisible)
            } else if selectedService != nil {
                ProgressView("Loading service…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .onAppear {
            loadWebViewForSelectedService()
        }
        .onChange(of: selectedServiceID) {
            loadWebViewForSelectedService()
        }
        .onChange(of: appState.webViewRebuildToken) {
            // A service's web view was rebuilt (e.g. custom CSS edit). Re-fetch
            // so the active service picks up the freshly created view.
            loadWebViewForSelectedService()
        }
        .onChange(of: webViewState.isLoading) { _, loading in
            // Drop the snapshot once the page finishes so it can't linger over a
            // loaded page and to free the bitmap. Delayed past the fade, and
            // re-checked in case another load started in the meantime.
            guard !loading else { return }
            let delay = reduceMotion ? 0 : 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !webViewState.isLoading { transitionSnapshot = nil }
            }
        }
    }

    private func loadWebViewForSelectedService() {
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
            webViewState.detach()
            currentWebView = nil
            transitionSnapshot = nil
            previousServiceID = nil
            return
        }

        // Grab the snapshot before loading — if the service was soft-hibernated,
        // this gives us an instant preview to show while the web view wakes up.
        transitionSnapshot = appState.webViewPool.snapshot(for: service.id)

        let webView = appState.webViewPool.webView(for: service)
        // Apply the effective zoom (per-service if set, else the Chorus-wide
        // default) so it survives hibernation and relaunch. Setting pageZoom is
        // a no-op when the value matches.
        webView.pageZoom = CGFloat(appState.effectiveZoom(for: service))
        currentWebView = webView
        webViewState.attach(to: webView)
        previousServiceID = service.id

        // Once the view is shown its frame settles a render tick later. Some SPAs
        // (Gmail) cache a viewport-height layout and, if it was measured against a
        // stale/transitional frame, leave their fixed header stranded above the
        // visible area with no way to scroll to it. Fire a synthetic resize so the
        // page re-measures against the real frame; it's a no-op for other sites.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            _ = try? await webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'))")
        }

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
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
