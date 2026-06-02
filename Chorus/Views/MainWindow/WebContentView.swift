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

                ZStack {
                    WebViewContainer(webView: webView)

                    // Show cached snapshot as instant visual feedback while page loads.
                    // Fades out once the web view finishes loading.
                    if let snapshot = transitionSnapshot, webViewState.isLoading {
                        Image(nsImage: snapshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: webViewState.isLoading)
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
        currentWebView = webView
        webViewState.attach(to: webView)
        previousServiceID = service.id

        // Start badge/title polling for the active service
        let catalogEntry = service.catalogEntryID.flatMap { ServiceCatalog.shared.entry(for: $0) }
        appState.notificationManager.startPolling(
            for: service.id,
            webView: webView,
            isMuted: service.isMuted,
            showBadge: service.showBadge,
            catalogEntry: catalogEntry
        )
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text("Pick a service from the sidebar to get started")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
