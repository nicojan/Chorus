import Foundation
import WebKit

@MainActor
@Observable
final class WebViewState {
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var estimatedProgress: Double = 0
    private(set) var currentURL: URL?
    private(set) var title: String?

    private var observations: [NSKeyValueObservation] = []
    private(set) weak var webView: WKWebView?

    init() {}

    func attach(to webView: WKWebView) {
        self.webView = webView
        observations.removeAll()

        observations.append(
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.canGoBack = value }
            }
        )
        observations.append(
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.canGoForward = value }
            }
        )
        observations.append(
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.isLoading = value }
            }
        )
        observations.append(
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? 0
                Task { @MainActor in self?.estimatedProgress = value }
            }
        )
        observations.append(
            webView.observe(\.url, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                Task { @MainActor in self?.currentURL = value }
            }
        )
        observations.append(
            webView.observe(\.title, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                Task { @MainActor in self?.title = value }
            }
        )
    }

    func detach() {
        observations.removeAll()
        webView = nil
    }
}
