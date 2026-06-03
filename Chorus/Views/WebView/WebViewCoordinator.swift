import Foundation
import WebKit
import AppKit

final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, @unchecked Sendable {

    private var popupWebView: WKWebView?
    private var popupWindow: NSWindow?
    private var popupTitleObservation: NSKeyValueObservation?

    /// Fallback URL to load if the WebContent process crashes before any
    /// navigation has committed (so `webView.reload()` has nothing to retry).
    var fallbackURL: URL?

    /// Routes external/cross-domain navigations through AppState so it can
    /// match the URL against an existing Chorus service before falling back
    /// to the system browser. When nil the coordinator falls back to
    /// `NSWorkspace.open` directly.
    var externalLinkHandler: ((URL) -> Void)?

    /// URL schemes the OS handles natively. We forward to NSWorkspace rather
    /// than letting WebKit fail with an unsupported-scheme error.
    private static let nonWebSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio", "imessage", "maps"
    ]

    deinit {
        popupTitleObservation?.invalidate()
        cleanupPopup()
    }

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

        // 1. Non-web schemes (mailto:, tel:, sms:, facetime:, maps:, etc.)
        //    Hand off to the system handler so Mail/Phone/Messages opens,
        //    instead of letting WebKit fail with an unsupported-URL error.
        if let scheme = url.scheme?.lowercased(),
           Self.nonWebSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        // 2. Cmd-clicks unconditionally go to the system browser — matches
        //    Safari's "open in new tab/window" convention. Detected via the
        //    modifierFlags on the navigation action.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        // 3. Cross-domain target=_blank links route through the external-link
        //    handler so AppState can match the URL against another existing
        //    Chorus service before falling back to NSWorkspace. Same-domain
        //    target=_blank still goes through createWebViewWith (OAuth popups).
        if navigationAction.targetFrame == nil,
           let currentHost = webView.url?.host,
           let targetHost = url.host,
           !Self.areSameDomain(currentHost, targetHost) {
            if let handler = externalLinkHandler {
                handler(url)
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }

        // 4. Everything else (same-domain navigation, cross-domain in-frame
        //    OAuth round-trips, target=_blank same-domain popups handled by
        //    createWebViewWith) loads in place.
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

    // WebKit kills WebContent on memory pressure, JIT bugs, or page crashes.
    // The webview is left blank with no recovery affordance — auto-reload
    // so the user just sees a brief flicker instead of a broken view.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppLogger.webView.warning("WebContent process terminated — reloading")
        if webView.url != nil {
            webView.reload()
        } else if let fallback = fallbackURL {
            webView.load(URLRequest(url: fallback))
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
        <head>
            <meta name="viewport" content="width=device-width">
            <style>
                body { display:flex;justify-content:center;align-items:center;
                    height:100vh;font-family:-apple-system,system-ui;color:#64748b;
                    text-align:center;background:#f8fafc;margin:0; }
                h2 { color:#1e293b;font-weight:600;margin:0 0 8px; }
                p { margin:0 0 20px;line-height:1.5; }
                button { padding:10px 24px;font-size:14px;cursor:pointer;
                    background:#2563eb;color:white;border:none;border-radius:8px;
                    font-weight:500; }
                .icon { font-size:48px;margin-bottom:16px; }
                .container { max-width:400px;padding:20px; }
                @media (prefers-color-scheme: dark) {
                    body { background:#0f172a;color:#94a3b8; }
                    h2 { color:#e2e8f0; }
                    button { background:#3b82f6; }
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="icon">⚠️</div>
                <h2>Unable to connect</h2>
                <p>\(description)</p>
                <button onclick="location.reload()">Try Again</button>
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
        // Clean up any existing popup before opening a new one
        cleanupPopup()

        // CRITICAL: Use the configuration passed in — it inherits the parent's data store
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self

        // Honor the page's requested popup size when reasonable; otherwise
        // default to a comfortable 1100×800 (the previous 800×600 was too
        // cramped for modern OAuth screens and standalone editors).
        let requestedWidth = (windowFeatures.width?.doubleValue ?? 0)
        let requestedHeight = (windowFeatures.height?.doubleValue ?? 0)
        let width = max(640, min(1400, requestedWidth > 0 ? requestedWidth : 1100))
        let height = max(480, min(1000, requestedHeight > 0 ? requestedHeight : 800))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = popup
        window.title = navigationAction.request.url?.host ?? "Chorus"
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.popupWebView = popup
        self.popupWindow = window

        // Mirror the page's <title> into the NSWindow title bar so the user
        // sees what's actually loaded (e.g. "Google Drive — Sign in") rather
        // than the stale initial host name.
        popupTitleObservation?.invalidate()
        popupTitleObservation = popup.observe(\.title, options: [.new]) { [weak window] webView, _ in
            let newTitle = (webView.title?.isEmpty == false) ? webView.title! : (webView.url?.host ?? "Chorus")
            Task { @MainActor in
                window?.title = newTitle
            }
        }

        // Observe window close to clean up even when closed via OS button
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popupWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        return popup
    }

    @objc private func popupWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === popupWindow else { return }
        cleanupPopup()
    }

    private func cleanupPopup() {
        if let window = popupWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
        popupTitleObservation?.invalidate()
        popupTitleObservation = nil
        popupWebView?.navigationDelegate = nil
        popupWebView?.uiDelegate = nil
        popupWindow?.close()
        popupWebView = nil
        popupWindow = nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popupWebView {
            cleanupPopup()
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

    /// Exposed so AppState can use the same eTLD+1 matching when deciding
    /// whether an external URL belongs to a service already in Chorus.
    static func areSameDomain(_ a: String, _ b: String) -> Bool {
        let normalizedA = effectiveDomain(a)
        let normalizedB = effectiveDomain(b)
        return normalizedA == normalizedB
    }

    static func effectiveDomain(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("www.") {
            h = String(h.dropFirst(4))
        }

        let parts = h.split(separator: ".")
        guard parts.count >= 2 else { return h }

        // Known two-part TLDs (country-code second-level domains)
        let twoPartTLDs: Set<String> = [
            "co.uk", "org.uk", "ac.uk", "gov.uk",
            "com.au", "net.au", "org.au", "edu.au",
            "co.nz", "net.nz", "org.nz",
            "co.jp", "or.jp", "ne.jp",
            "com.br", "org.br", "net.br",
            "co.kr", "or.kr",
            "co.in", "net.in", "org.in",
            "com.cn", "net.cn", "org.cn",
            "co.za", "org.za",
            "com.mx", "org.mx",
            "co.il", "org.il",
            "com.sg", "org.sg",
            "com.hk", "org.hk",
            "co.th", "or.th",
        ]

        let lastTwo = parts.suffix(2).joined(separator: ".")
        if twoPartTLDs.contains(lastTwo) && parts.count >= 3 {
            // eTLD+1 is last 3 parts
            return parts.suffix(3).joined(separator: ".")
        }

        // Standard: eTLD+1 is last 2 parts
        return lastTwo
    }
}
