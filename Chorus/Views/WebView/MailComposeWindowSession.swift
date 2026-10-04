import AppKit
import WebKit

/// Owns one standalone compose window. Its web view shares only the selected
/// service's website data store, without replacing or reloading its inbox.
@MainActor
final class MailComposeWindowSession: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    let window: NSWindow
    private let webView: WKWebView
    private let messageHandler: MailComposeMessageHandler
    private let onClose: () -> Void
    private var onMailRequest: ((URL) -> Void)?
    private let allowedOrigin: Origin
    private var isFinished = false
    private var focusTask: Task<Void, Never>?

    init(
        dataStore: WKWebsiteDataStore,
        userAgent: String,
        title: String,
        url: URL,
        loadPage: (WKWebView, URL) -> Void = { view, url in view.load(URLRequest(url: url)) },
        onMailRequest: ((URL) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = configuration.userContentController
        // All scripts and handlers belong to the final configuration, before
        // WKWebView construction. The proxy forwards weakly after initialization.
        let messageHandler = MailComposeMessageHandler()
        controller.add(messageHandler, name: "chorusMailHandler")
        controller.addUserScript(WKUserScript(
            source: UserScriptManager.makeWindowCloseInterceptionScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: UserScriptManager.makeMailComposerLifecycleScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = userAgent
        self.webView = webView
        self.messageHandler = messageHandler
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.onClose = onClose
        self.onMailRequest = onMailRequest
        self.allowedOrigin = Origin(
            scheme: url.scheme ?? "https", host: url.host ?? "",
            port: url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        )
        super.init()

        messageHandler.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }
        webView.uiDelegate = self
        webView.navigationDelegate = self
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentView = webView
        window.center()
        loadPage(webView, url)
    }

    func show() {
        guard !isFinished else { return }
        cancelPendingFocus()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        // External event delivery can finish ordering scenes after this call.
        // A newer route or main-window interaction cancels the delayed repair.
        focusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, !self.isFinished, NSApp.isActive else { return }
            self.window.makeKeyAndOrderFront(nil)
        }
    }

    func cancelPendingFocus() {
        focusTask?.cancel()
        focusTask = nil
    }

    private func handleMessage(_ message: WKScriptMessage) {
        guard message.name == "chorusMailHandler",
              let body = message.body as? [String: Any]
        else { return }
        let origin = message.frameInfo.securityOrigin
        let frameOrigin = Origin(
            scheme: origin.protocol, host: origin.host,
            port: origin.port == 0 ? nil : origin.port
        )
        let trustedFrame = message.frameInfo.isMainFrame || frameOrigin == allowedOrigin
        guard trustedFrame,
              body["windowClose"] as? Bool == true || body["composerClosed"] as? Bool == true
        else { return }
        finish(closeWindow: true)
    }

    // The completion blocks must retain @MainActor to match WebKit's Obj-C
    // protocol witnesses. Omitting it can silently prevent delegate delivery.
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        guard !isFinished else { completionHandler(); return }
        WebViewDialogs.alert(message, over: webView, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        guard !isFinished else { completionHandler(false); return }
        WebViewDialogs.confirm(message, over: webView, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        guard !isFinished else { completionHandler(nil); return }
        WebViewDialogs.prompt(prompt, defaultText: defaultText, over: webView, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              url.scheme?.lowercased() == "mailto"
        else { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        guard !isFinished else { return }
        onMailRequest?(url)
    }

    func webViewDidClose(_ webView: WKWebView) {
        finish(closeWindow: true)
    }

    func windowWillClose(_ notification: Notification) {
        finish(closeWindow: false)
    }

    private func finish(closeWindow: Bool) {
        guard !isFinished else { return }
        isFinished = true
        cancelPendingFocus()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "chorusMailHandler")
        webView.configuration.userContentController.removeAllUserScripts()
        messageHandler.onMessage = nil
        webView.stopLoading()
        webView.uiDelegate = nil
        webView.navigationDelegate = nil
        onMailRequest = nil
        window.delegate = nil
        if closeWindow { window.close() }
        window.contentView = nil
        onClose()
    }
}

private final class MailComposeMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    var onMessage: (@MainActor (WKScriptMessage) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated { onMessage?(message) }
    }
}
