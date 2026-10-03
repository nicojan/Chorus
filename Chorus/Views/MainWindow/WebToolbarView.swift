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
    @Environment(AppState.self) private var appState

    var body: some View {
        buttons
            .featureTip(.openQuickSwitcher, arrowEdge: .bottom, appState: appState)
    }

    private var buttons: some View {
        HStack(spacing: ChorusNav.spacing) {
            navButton("chevron.left", label: "Back", enabled: webViewState.canGoBack) {
                webViewState.webView?.goBack()
            }
            navButton("chevron.right", label: "Forward", enabled: webViewState.canGoForward) {
                webViewState.webView?.goForward()
            }

            Button {
                if webViewState.isLoading {
                    webViewState.webView?.stopLoading()
                } else if let webView = webViewState.webView {
                    Task { await WebViewCoordinator.reload(webView, fallbackURL: homeURL) }
                }
            } label: {
                Image(systemName: webViewState.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, height: 14)
                    .navCircle()
            }
            .buttonStyle(.chromeCircle)
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
                    .navCircle()
            }
            // The button style draws the label as SwiftUI, circle and all, so
            // the whole 28 points open the menu. The borderless style drew only
            // the glyph and took clicks on it alone.
            .menuStyle(.button)
            .buttonStyle(.chromeCircle)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(currentPageURL == nil)
            .help(didCopy ? "Copied" : "Share this page")
            .accessibilityLabel(didCopy ? "Link copied" : "Share this page")

            DownloadsButton()
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
                .navCircle()
        }
        .buttonStyle(.chromeCircle)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
