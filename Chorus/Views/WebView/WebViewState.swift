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

    /// Bumped on every attach/detach. Each observer captures the generation it
    /// was created under; a KVO callback that hops to the main queue after a
    /// rebind finds the generation has moved on and drops its stale write, so a
    /// queued update from the previous web view can't clobber the new one's state
    /// after a fast service switch.
    private var generation = 0

    init() {}

    func attach(to webView: WKWebView) {
        self.webView = webView
        generation &+= 1
        let gen = generation
        observations.removeAll()
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        estimatedProgress = webView.estimatedProgress
        currentURL = webView.url
        title = webView.title

        // WKWebView fires KVO on the main thread in practice, but this is not
        // contractually guaranteed. Use DispatchQueue.main.async for safety —
        // it's a no-op if already on main, and handles the off-main edge case
        // without the crash risk of MainActor.assumeIsolated.
        observations.append(
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                DispatchQueue.main.async { guard let self, self.generation == gen else { return }; self.canGoBack = value }
            }
        )
        observations.append(
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                DispatchQueue.main.async { guard let self, self.generation == gen else { return }; self.canGoForward = value }
            }
        )
        observations.append(
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                DispatchQueue.main.async { guard let self, self.generation == gen else { return }; self.isLoading = value }
            }
        )
        observations.append(
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? 0
                DispatchQueue.main.async { guard let self, self.generation == gen else { return }; self.estimatedProgress = value }
            }
        )
        observations.append(
            webView.observe(\.url, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                DispatchQueue.main.async { guard let self, self.generation == gen else { return }; self.currentURL = value }
            }
        )
        observations.append(
            webView.observe(\.title, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                DispatchQueue.main.async { guard let self, self.generation == gen else { return }; self.title = value }
            }
        )
    }

    func detach() {
        generation &+= 1
        observations.removeAll()
        webView = nil
        canGoBack = false
        canGoForward = false
        isLoading = false
        estimatedProgress = 0
        currentURL = nil
        title = nil
    }
}
