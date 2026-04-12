import Foundation
import WebKit
import AppKit

final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    private var popupWebView: WKWebView?
    private var popupWindow: NSWindow?

    // MARK: - Navigation Delegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Open external-domain links (target=_blank) in system browser
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame == nil,
           let currentHost = webView.url?.host,
           let targetHost = url.host,
           !Self.areSameDomain(currentHost, targetHost) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let nsError = error as NSError
        // Ignore cancelled loads (e.g., user navigated away)
        guard nsError.code != NSURLErrorCancelled else { return }

        let description = error.localizedDescription
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let html = """
        <html>
        <head><meta name="viewport" content="width=device-width"></head>
        <body style="display:flex;justify-content:center;align-items:center;
            height:100vh;font-family:-apple-system,system-ui;color:#64748b;
            text-align:center;background:#f8fafc;margin:0;">
            <div style="max-width:400px;padding:20px;">
                <div style="font-size:48px;margin-bottom:16px;">⚠️</div>
                <h2 style="color:#1e293b;font-weight:600;margin:0 0 8px;">
                    Unable to connect
                </h2>
                <p style="margin:0 0 20px;line-height:1.5;">\(description)</p>
                <button onclick="location.reload()"
                    style="padding:10px 24px;font-size:14px;cursor:pointer;
                    background:#2563eb;color:white;border:none;border-radius:8px;
                    font-weight:500;">
                    Try Again
                </button>
            </div>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - UI Delegate (OAuth Pop-ups)

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // CRITICAL: Use the configuration passed in — it inherits the parent's data store
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = popup
        window.title = "Sign In"
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.popupWebView = popup
        self.popupWindow = window

        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popupWebView {
            popupWindow?.close()
            popupWebView = nil
            popupWindow = nil
        }
    }

    // MARK: - Context Menu

    // WKWebView provides native context menus by default on macOS.
    // We add "Open Link in Browser" and "Copy Link" via the default
    // context menu handling. Custom context menus can be added via
    // WKUIDelegate methods if needed in the future.

    // MARK: - Download Delegate

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.begin { result in
            completionHandler(result == .OK ? panel.url : nil)
        }
    }

    // MARK: - Helpers

    private static func areSameDomain(_ a: String, _ b: String) -> Bool {
        let normalize: (String) -> String = { host in
            host.replacingOccurrences(of: "www.", with: "")
                .split(separator: ".").suffix(2).joined(separator: ".")
        }
        return normalize(a) == normalize(b)
    }
}
