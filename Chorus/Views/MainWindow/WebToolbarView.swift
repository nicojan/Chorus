import SwiftUI

struct WebToolbarView: View {
    let webViewState: WebViewState

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

            Button {
                webViewState.webView?.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
            }
            .disabled(!webViewState.canGoForward)
            .buttonStyle(.plain)
            .help("Forward")

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

            if webViewState.isLoading {
                ProgressView(value: webViewState.estimatedProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }

            Text(webViewState.currentURL?.host ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation toolbar")
    }
}
