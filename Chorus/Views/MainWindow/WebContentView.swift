import SwiftUI
import SwiftData
import WebKit

struct WebContentView: View {
    let selectedServiceID: UUID?

    @Environment(AppState.self) private var appState
    @Query private var services: [ServiceInstance]
    @State private var webViewState = WebViewState()
    @State private var currentWebView: WKWebView?

    private var selectedService: ServiceInstance? {
        guard let id = selectedServiceID else { return nil }
        return services.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectedService != nil, let webView = currentWebView {
                WebToolbarView(webViewState: webViewState)

                WebViewContainer(webView: webView)
                    .id(selectedServiceID)
            } else if selectedService != nil {
                ProgressView()
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
        guard let service = selectedService else {
            webViewState.detach()
            currentWebView = nil
            return
        }
        let webView = appState.webViewPool.webView(for: service)
        currentWebView = webView
        webViewState.attach(to: webView)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)

            Text("Pick a service from the sidebar to get started")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
