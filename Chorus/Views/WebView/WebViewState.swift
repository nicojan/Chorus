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

        // WKWebView fires KVO on the main thread in practice, but this is not
        // contractually guaranteed. Use DispatchQueue.main.async for safety —
        // it's a no-op if already on main, and handles the off-main edge case
        // without the crash risk of MainActor.assumeIsolated.
        observations.append(
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                DispatchQueue.main.async { self?.canGoBack = value }
            }
        )
        observations.append(
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                DispatchQueue.main.async { self?.canGoForward = value }
            }
        )
        observations.append(
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                DispatchQueue.main.async { self?.isLoading = value }
            }
        )
        observations.append(
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? 0
                DispatchQueue.main.async { self?.estimatedProgress = value }
            }
        )
        observations.append(
            webView.observe(\.url, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                DispatchQueue.main.async { self?.currentURL = value }
            }
        )
        observations.append(
            webView.observe(\.title, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                DispatchQueue.main.async { self?.title = value }
            }
        )
    }

    func detach() {
        observations.removeAll()
        webView = nil
    }
}
