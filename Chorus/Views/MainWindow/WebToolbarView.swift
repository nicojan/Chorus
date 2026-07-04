import SwiftUI

struct WebToolbarView: View {
    let webViewState: WebViewState
    var homeURL: URL?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Button {
                webViewState.webView?.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
            }
            .disabled(!webViewState.canGoBack)
            .buttonStyle(.plain)
            .help("Back")
            .accessibilityLabel("Back")

            Button {
                webViewState.webView?.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .disabled(!webViewState.canGoForward)
            .buttonStyle(.plain)
            .help("Forward")
            .accessibilityLabel("Forward")

            Button {
                if webViewState.isLoading {
                    webViewState.webView?.stopLoading()
                } else {
                    webViewState.webView?.reload()
                }
            } label: {
                Image(systemName: webViewState.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(webViewState.isLoading ? "Stop" : "Reload")
            .accessibilityLabel(webViewState.isLoading ? "Stop loading" : "Reload page")

            if let homeURL {
                Button {
                    webViewState.webView?.load(URLRequest(url: homeURL))
                } label: {
                    Image(systemName: "house")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Home")
                .accessibilityLabel("Go to home page")
            }

            loadingProgressSlot

            Text(webViewState.currentURL?.host ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(webViewState.currentURL.map { "Current page: \($0.host ?? "")" } ?? "")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Same surface as the selected folder tab above it, so the tab and this
        // toolbar read as one connected element set off the unselected tabs.
        .background(ServiceIconPalette.pageSurface(dark: colorScheme == .dark))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation toolbar")
    }

    private var loadingProgressSlot: some View {
        ZStack {
            ProgressView(value: webViewState.estimatedProgress)
                .progressViewStyle(.linear)
                .opacity(webViewState.isLoading ? 1 : 0)
                .accessibilityHidden(!webViewState.isLoading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 6)
    }
}
