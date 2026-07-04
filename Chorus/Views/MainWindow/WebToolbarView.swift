import SwiftUI

/// Compact web navigation controls — back, forward, reload/stop, home — for the
/// active service. No URL and no background of its own: it's hosted at the right
/// of the top tab bar (horizontal layouts) and above the content (sidebar).
struct WebNavButtons: View {
    let webViewState: WebViewState
    var homeURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            navButton("chevron.left", label: "Back", enabled: webViewState.canGoBack) {
                webViewState.webView?.goBack()
            }
            navButton("chevron.right", label: "Forward", enabled: webViewState.canGoForward) {
                webViewState.webView?.goForward()
            }

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
            .disabled(webViewState.webView == nil)
            .help(webViewState.isLoading ? "Stop" : "Reload")
            .accessibilityLabel(webViewState.isLoading ? "Stop loading" : "Reload page")

            if let homeURL {
                navButton("house", label: "Home", enabled: webViewState.webView != nil) {
                    webViewState.webView?.load(URLRequest(url: homeURL))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
    }

    private func navButton(
        _ icon: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
