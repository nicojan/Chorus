import SwiftUI
import SwiftData
import WebKit

struct WebContentView: View {
    let selectedServiceID: UUID?

    @Environment(AppState.self) private var appState
    @Query private var services: [ServiceInstance]
    @State private var webViewState = WebViewState()
    @State private var currentWebView: WKWebView?
    @State private var transitionSnapshot: NSImage?
    @State private var previousServiceID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedService: ServiceInstance? {
        guard let id = selectedServiceID else { return nil }
        return services.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let service = selectedService, let webView = currentWebView {
                WebToolbarView(
                    webViewState: webViewState,
                    homeURL: URL(string: service.url)
                )

                ZStack(alignment: .topTrailing) {
                    WebViewContainer(webView: webView)

                    // Show cached snapshot as instant visual feedback while page loads.
                    // Fades out once the web view finishes loading.
                    if let snapshot = transitionSnapshot, webViewState.isLoading {
                        Image(nsImage: snapshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
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
    }

    private func loadWebViewForSelectedService() {
        // Stop polling for the previously selected service
        if let previousID = previousServiceID {
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
        // Apply the persisted per-service zoom so it survives hibernation
        // and relaunch. Setting pageZoom is a no-op when the value matches.
        webView.pageZoom = CGFloat(service.zoomLevelEffective)
        currentWebView = webView
        webViewState.attach(to: webView)
        previousServiceID = service.id

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
