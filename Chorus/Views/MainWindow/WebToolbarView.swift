import SwiftUI

struct WebToolbarView: View {
    let webViewState: WebViewState
    @State private var showingSearch = false
    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
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

                Button {
                    showingSearch.toggle()
                    if !showingSearch {
                        clearSearch()
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Find in page")
                .keyboardShortcut("f", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            if showingSearch {
                searchBar
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation toolbar")
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Find in page...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    performSearch()
                }
                .onChange(of: searchQuery) {
                    if searchQuery.isEmpty {
                        clearSearch()
                    }
                }

            Button {
                showingSearch = false
                searchQuery = ""
                clearSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func performSearch() {
        guard !searchQuery.isEmpty else { return }
        let escaped = searchQuery
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webViewState.webView?.evaluateJavaScript(
            "window.find('\(escaped)', false, false, true)"
        )
    }

    private func clearSearch() {
        webViewState.webView?.evaluateJavaScript(
            "window.getSelection().removeAllRanges()"
        )
    }
}
