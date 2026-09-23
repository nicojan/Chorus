import SwiftUI

/// Compact web navigation controls for the active service — back, forward,
/// reload/stop, home, and a share menu that copies the address, opens it in the
/// user's browser, or hands it to the system share sheet. No URL and no
/// background of its own: it's hosted at the right
/// of the top tab bar (horizontal layouts) and above the content (sidebar).
struct WebNavButtons: View {
    let webViewState: WebViewState
    var homeURL: URL?

    @State private var didCopy = false

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
                    .frame(width: 16, height: 14)
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

            Menu {
                Button("Copy Link") { copyCurrentURL() }
                Button("Open in Browser") { openInDefaultBrowser() }
                if let url = currentPageURL {
                    ShareLink("Share\u{2026}", item: url)
                }
            } label: {
                // Every glyph in this row sits in the same box. Two of them swap
                // (reload for stop, share for the copied checkmark), and without
                // a fixed size the swap re-lays the whole cluster out and shifts
                // the buttons beside it.
                Image(systemName: didCopy ? "checkmark" : "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, height: 14)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(currentPageURL == nil)
            .help(didCopy ? "Copied" : "Share this page")
            .accessibilityLabel(didCopy ? "Link copied" : "Share this page")

        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
    }

    /// The address to copy: the state's tracked URL, or the web view's own if the
    /// observer has not caught up yet.
    private var currentPageURL: URL? {
        webViewState.currentURL ?? webViewState.webView?.url
    }

    /// Hands the page to whatever the user has set as their browser. Chorus is
    /// not one, so this is the way out to a real one.
    private func openInDefaultBrowser() {
        guard let url = currentPageURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyCurrentURL() {
        guard let url = currentPageURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)

        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
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
                .frame(width: 16, height: 14)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
