import Foundation
import WebKit
import Combine

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
                self?.canGoBack = change.newValue ?? false
            }
        )
        observations.append(
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                self?.canGoForward = change.newValue ?? false
            }
        )
        observations.append(
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                self?.isLoading = change.newValue ?? false
            }
        )
        observations.append(
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                self?.estimatedProgress = change.newValue ?? 0
            }
        )
        observations.append(
            webView.observe(\.url, options: [.new]) { [weak self] _, change in
                self?.currentURL = change.newValue ?? nil
            }
        )
        observations.append(
            webView.observe(\.title, options: [.new]) { [weak self] _, change in
                self?.title = change.newValue ?? nil
            }
        )
    }

    func detach() {
        observations.removeAll()
        webView = nil
    }
}
