import Foundation
import WebKit

final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

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
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let description = error.localizedDescription
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let html = """
        <html><body style="display:flex;justify-content:center;align-items:center;
            height:100vh;font-family:-apple-system;color:#64748b;text-align:center;
            background:#f8fafc;">
            <div>
                <h2 style="color:#1e293b;font-weight:600;">Unable to connect</h2>
                <p>\(description)</p>
                <button onclick="location.reload()"
                    style="padding:8px 16px;font-size:14px;cursor:pointer;
                    background:#2563eb;color:white;border:none;border-radius:6px;
                    margin-top:12px;">
                    Try Again
                </button>
            </div>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private static func areSameDomain(_ a: String, _ b: String) -> Bool {
        let normalize: (String) -> String = { host in
            host.replacingOccurrences(of: "www.", with: "")
                .split(separator: ".").suffix(2).joined(separator: ".")
        }
        return normalize(a) == normalize(b)
    }
}
