import SwiftUI
import WebKit

/// Overlay search bar shown above the active WKWebView for Cmd-F find-in-page.
/// Uses WKWebView.find(_:configuration:) (macOS 11+) — no JS injection needed.
/// Highlights persist between calls; pressing Esc dismisses and clears them.
struct FindInPageBar: View {
    @Binding var isVisible: Bool
    let webView: WKWebView?

    @State private var query: String = ""
    @State private var lastMatchFound: Bool? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Find in page", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { search(forward: true) }
                .onChange(of: query) { _, newValue in
                    if newValue.isEmpty {
                        lastMatchFound = nil
                        clearHighlights()
                    } else {
                        search(forward: true)
                    }
                }

            if let matchFound = lastMatchFound, !query.isEmpty {
                Image(systemName: matchFound ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(matchFound ? Color.secondary : Color.orange)
                    .accessibilityLabel(matchFound ? "match found" : "no match")
            }

            Button {
                search(forward: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("Previous (Shift+Return)")
            .accessibilityLabel("Previous match")
            .keyboardShortcut(.return, modifiers: .shift)

            Button {
                search(forward: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Next (Return)")
            .accessibilityLabel("Next match")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
            .accessibilityLabel("Close find bar")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(8)
        .frame(maxWidth: 360, alignment: .trailing)
        .onAppear { isFocused = true }
        .onChange(of: isVisible) { _, visible in
            if visible {
                isFocused = true
            } else {
                clearHighlights()
                query = ""
                lastMatchFound = nil
            }
        }
    }

    private func search(forward: Bool) {
        guard let webView, !query.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = false
        config.wraps = true
        webView.find(query, configuration: config) { result in
            Task { @MainActor in
                lastMatchFound = result.matchFound
            }
        }
    }

    private func clearHighlights() {
        // WKWebView's find leaves yellow highlights even after the bar is
        // dismissed; running a no-op find with an unmatchable string clears
        // them. There's no public "clearSelection"/"endFind" API.
        guard let webView else { return }
        let config = WKFindConfiguration()
        webView.find("\u{FFFD}\u{FFFD}\u{FFFD}", configuration: config) { _ in }
    }

    private func dismiss() {
        // Clear highlights here rather than in an `onChange(of: isVisible)`:
        // flipping `isVisible` makes the parent drop this view in the same
        // update, so an onChange side effect may never run. The find call is
        // dispatched to the pooled web view, which outlives this view.
        clearHighlights()
        isVisible = false
    }
}
