import Foundation
import WebKit
import AppKit

@MainActor
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    private var popupWebView: WKWebView?
    private var popupWindow: NSWindow?
    private var popupTitleObservation: NSKeyValueObservation?

    /// The service's main web view that opened the current popup. Kept so we can
    /// reload it once the sign-in popup closes (see reloadOpenerAfterPopup).
    private weak var openerWebView: WKWebView?

    /// Fallback URL to load if the WebContent process crashes before any
    /// navigation has committed (so `webView.reload()` has nothing to retry).
    var fallbackURL: URL?

    /// Timestamps of recent WebContent terminations, used to break a crash →
    /// reload → crash loop. Accessed only from main-thread delegate callbacks.
    private var crashTimestamps: [Date] = []
    // nonisolated so the nonisolated `shouldAutoReload` can use them as default
    // argument values — they're immutable Sendable constants.
    private nonisolated static let maxCrashesInWindow = 3
    private nonisolated static let crashWindow: TimeInterval = 30

    /// Routes external/cross-domain navigations through AppState so it can
    /// match the URL against an existing Chorus service before falling back
    /// to the system browser. When nil the coordinator falls back to
    /// `NSWorkspace.open` directly.
    var externalLinkHandler: ((URL) -> Void)?

    /// The service this coordinator drives, set by `WebViewPool` so navigation
    /// callbacks can be attributed to a specific service.
    var instanceID: UUID?

    /// Called when a top-level navigation finishes (fresh load or login
    /// redirect) so the app can fire an immediate badge poll instead of waiting
    /// for the next poll tick. Never called for OAuth popup web views.
    var onNavigationFinished: ((UUID) -> Void)?

    /// URL schemes the OS handles natively. We forward to NSWorkspace rather
    /// than letting WebKit fail with an unsupported-scheme error.
    private static let nonWebSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio", "imessage", "maps"
    ]

    deinit {
        // A backstop for the popup lifecycle, which is normally torn down by
        // popupWindowWillClose / webViewDidClose. deinit is nonisolated, so it
        // can't call the main-actor-isolated cleanupPopup(); invalidate the
        // (thread-safe) KVO observation here and close any still-open popup
        // window on the main actor. The window is captured as a local so the
        // hop never touches `self`, which is being deallocated.
        popupTitleObservation?.invalidate()
        if let window = popupWindow {
            Task { @MainActor in window.close() }
        }
    }

    // MARK: - Navigation Delegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else {
            return .cancel
        }

        // 1. Non-web schemes (mailto:, tel:, sms:, facetime:, maps:, etc.)
        //    Hand off to the system handler so Mail/Phone/Messages opens,
        //    instead of letting WebKit fail with an unsupported-URL error.
        if let scheme = url.scheme?.lowercased(),
           Self.nonWebSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return .cancel
        }

        // 2. A navigation WebKit has flagged as a download — an `<a download>`
        //    click, or a link whose response will be streamed to disk. Convert
        //    it to a download in-app. This must come before the external-link
        //    routing below: a Teams/SharePoint "Download" link points at a
        //    different host, so routing would kick it to the browser (or, for a
        //    same-host PDF, WebKit would show it inline) and no file would save.
        if navigationAction.shouldPerformDownload {
            return .download
        }

        // 3. Cmd-clicks unconditionally go to the system browser — matches
        //    Safari's "open in new tab/window" convention. Detected via the
        //    modifierFlags on the navigation action.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            NSWorkspace.shared.open(url)
            return .cancel
        }

        // 4. A link the user clicked that leaves the current service is routed
        //    through the external-link handler, which opens another matching
        //    Chorus service if one owns that domain, otherwise the default
        //    browser. This covers both new-window links (targetFrame == nil) and
        //    plain in-frame link clicks.
        //
        //    Gated deliberately:
        //    - only `.linkActivated` (a real user click), so OAuth/SSO redirects
        //      and other programmatic navigations (navigationType `.other`) stay
        //      in-app and can complete;
        //    - only the main frame (or a new-window request), so an embedded
        //      iframe navigating cross-origin isn't kicked out;
        //    - "leaves the service" is `!belongsToService`, which keeps
        //      *.slack.com workspaces in-app but treats Google products
        //      (docs. vs mail.google.com) as separate;
        //    - identity gateways (accounts.google.com, login.microsoftonline.com,
        //      …) are exempt via `isAuthHost`, so clicking "Sign in" on a
        //      signed-out page (Gmail → accounts.google.com) loads in place and
        //      the login can finish instead of being kicked to the browser.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame ?? true,
           let currentHost = webView.url?.host,
           let targetHost = url.host,
           !Self.belongsToService(targetHost, serviceHost: currentHost),
           !Self.isAuthHost(targetHost) {
            if let handler = externalLinkHandler {
                handler(url)
            } else {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }

        // 5. Everything else (same-service navigation, cross-domain in-frame
        //    OAuth round-trips, and programmatic new-window requests handled by
        //    createWebViewWith) loads in place.
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        // An explicit `Content-Disposition: attachment` means "download this",
        // even for a type WebKit could render inline (e.g. a PDF served as a
        // download — the reported Teams case). Otherwise download anything we
        // can't display.
        if Self.isAttachment(navigationResponse.response) {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only the service's main web view carries a badge — ignore OAuth
        // popups (the coordinator is their navigation delegate too).
        guard webView !== popupWebView, let instanceID else { return }
        onNavigationFinished?(instanceID)
    }

    // WebKit kills WebContent on memory pressure, JIT bugs, or page crashes.
    // The webview is left blank with no recovery affordance — auto-reload so
    // the user just sees a brief flicker. But a page that crashes
    // deterministically would reload-crash forever, so back off after a few
    // crashes in a short window and show a recovery page instead.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The OAuth/sign-in popup shares this coordinator as its delegate.
        // Don't apply the service's crash recovery (fallbackURL + backoff) to
        // it — that would reload the popup on the service's home URL, not the
        // popup's own page. Reload its own page if it has one.
        if webView === popupWebView {
            if webView.url != nil { webView.reload() }
            return
        }

        let now = Date()
        crashTimestamps.append(now)
        crashTimestamps = crashTimestamps.filter { now.timeIntervalSince($0) <= Self.crashWindow }

        let retryURL = webView.url ?? fallbackURL

        guard Self.shouldAutoReload(
            crashTimestamps: crashTimestamps,
            now: now,
            maxCrashes: Self.maxCrashesInWindow,
            window: Self.crashWindow
        ) else {
            AppLogger.webView.error("WebContent terminated repeatedly — showing recovery page")
            let html = Self.errorPageHTML(
                title: "This page keeps crashing",
                message: "Chorus stopped reloading it automatically to avoid a loop. You can try again, or switch to another service.",
                retryURLString: retryURL?.absoluteString
            )
            webView.loadHTMLString(html, baseURL: nil)
            return
        }

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
        // Don't overwrite the popup with our generic error page: a transient
        // provisional failure mid sign-in (an intermediate redirect WebKit
        // can't render, a captive-portal blip) would break the OAuth flow.
        // Let the popup's own site handle it. (didFinish already skips the
        // popup; this keeps the failure path symmetric.)
        if webView === popupWebView { return }

        let nsError = error as NSError
        // Ignore cancelled loads (e.g., user navigated away)
        guard nsError.code != NSURLErrorCancelled else { return }

        // The URL that failed isn't `webView.url` (which still points at the
        // last committed page); pull it from the error so "Try Again" retries
        // the right page.
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
            ?? (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? webView.url?.absoluteString
            ?? fallbackURL?.absoluteString

        let html = Self.errorPageHTML(
            title: "Unable to connect",
            message: error.localizedDescription,
            retryURLString: failingURL
        )
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Crash backoff / error page (pure, testable)

    /// Whether to keep auto-reloading after a WebContent crash. Returns false
    /// once `maxCrashes` terminations occur within `window` seconds, so a
    /// deterministically-crashing page stops looping.
    nonisolated static func shouldAutoReload(
        crashTimestamps: [Date],
        now: Date,
        maxCrashes: Int = maxCrashesInWindow,
        window: TimeInterval = crashWindow
    ) -> Bool {
        let recent = crashTimestamps.filter { now.timeIntervalSince($0) <= window }
        return recent.count < maxCrashes
    }

    /// Builds the in-webview error/recovery page. When `retryURLString` is
    /// non-nil a "Try Again" button navigates to that exact URL (JSON-encoded
    /// so it can't break out of the JS string) — never `location.reload()`,
    /// which would just reload this about:blank error document.
    nonisolated static func errorPageHTML(
        title: String,
        message: String,
        retryURLString: String?
    ) -> String {
        func escapeHTML(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }

        let retryBlock: String
        if let retryURLString {
            // Escape for embedding inside a double-quoted JS string literal so
            // a URL with quotes/newlines can't break out (or close the script).
            let escaped = retryURLString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "<", with: "\\x3C")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            retryBlock = """
                <button id="chorus-retry">Try Again</button>
                <script>
                    var target = "\(escaped)";
                    document.getElementById('chorus-retry')
                        .addEventListener('click', function() { location.href = target; });
                </script>
            """
        } else {
            retryBlock = ""
        }

        return """
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
                <h2>\(escapeHTML(title))</h2>
                <p>\(escapeHTML(message))</p>
                \(retryBlock)
            </div>
        </body></html>
        """
    }

    // MARK: - UI Delegate (OAuth Pop-ups)

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // If the new-window request is for the same service — e.g. Slack opening
        // a workspace via window.open / target=_blank — load it in the existing
        // web view instead of spawning a separate NSWindow. Only genuinely
        // cross-service popups (real OAuth sign-in windows to another domain)
        // fall through and get their own window below.
        if let targetHost = navigationAction.request.url?.host,
           let openerHost = webView.url?.host,
           Self.belongsToService(targetHost, serviceHost: openerHost) {
            webView.load(navigationAction.request)
            return nil
        }

        // Clean up any existing popup before opening a new one
        cleanupPopup()

        // Remember the service's main web view so we can reload it after the
        // popup closes. The popup shares this data store, so once sign-in
        // finishes the session cookies are already here — the main view just
        // needs to reload to leave its signed-out page.
        openerWebView = webView

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
        // We hold this window in a strong property (`popupWindow`) and release
        // it ourselves in cleanupPopup. Left at its `true` default, AppKit would
        // also release the window when it closes — an over-release that crashes
        // the app when an OAuth/sign-in popup (e.g. Gmail) window is closed.
        window.isReleasedWhenClosed = false
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
        // Read the new title from the (Sendable String?) KVO change value rather
        // than reaching back into the web view — the observe closure is
        // nonisolated/@Sendable, and touching the main-actor-isolated WKWebView
        // from it is a data race under Swift 6. An empty title leaves the bar on
        // its current text (the host it was seeded with) instead of clearing it.
        popupTitleObservation = popup.observe(\.title, options: [.new]) { [weak window] _, change in
            guard let newTitle = change.newValue ?? nil, !newTitle.isEmpty else { return }
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
        reloadOpenerAfterPopup()
        cleanupPopup()
    }

    /// After a sign-in / OAuth popup closes, the shared data store already holds
    /// the new session cookies, but the service's main web view is still on its
    /// signed-out page. Reload it so the user lands on the authenticated app.
    private func reloadOpenerAfterPopup() {
        guard let opener = openerWebView else { return }
        if opener.url != nil {
            opener.reload()
        } else if let fallback = fallbackURL {
            opener.load(URLRequest(url: fallback))
        }
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
            reloadOpenerAfterPopup()
            cleanupPopup()
        }
    }

    // MARK: - File Upload Picker

    /// Presents the native file picker when a page triggers an
    /// `<input type="file">` (e.g. Slack's "Upload File" for a profile photo).
    /// WKWebView shows no picker at all unless this delegate method is
    /// implemented, so without it every file-upload button silently does
    /// nothing. Honors the input's `multiple` and `webkitdirectory` attributes.
    ///
    /// CRITICAL: `completionHandler` MUST be `@MainActor`. The WebKit header
    /// annotates the block `WK_SWIFT_UI_ACTOR` (= `@MainActor`), so the imported
    /// optional-protocol requirement carries that isolation. Drop it and Swift
    /// silently declines to treat this as the witness — the method never reaches
    /// the Objective-C runtime (`responds(to:)` is false), WebKit never calls it,
    /// and the picker never opens, with no error or warning.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.resolvesAliases = true

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }

        // Attach as a sheet to the web view's window when we have one; fall back
        // to a standalone modal panel otherwise (e.g. an OAuth popup web view).
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            panel.begin(completionHandler: handleResponse)
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

    /// Maps each in-flight download to the destination we chose for it, so the
    /// finish handler can reveal the right file (WKDownload doesn't hand the
    /// destination back). Keyed by object identity; cleared on finish/failure.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    // Save straight to the user's Downloads folder — the browser-like default —
    // rather than prompting with a save panel for every file. WKDownload fails
    // if the destination already exists, so we pick a non-colliding name.
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let fileManager = FileManager.default
        let downloads: URL
        do {
            downloads = try fileManager.url(
                for: .downloadsDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            AppLogger.webView.error("Couldn't locate the Downloads folder: \(error.localizedDescription)")
            return nil
        }

        let filename = Self.sanitizedDownloadFilename(suggestedFilename)
        let destination = Self.nonCollidingURL(
            in: downloads,
            filename: filename,
            fileExists: { fileManager.fileExists(atPath: $0.path) }
        )
        downloadDestinations[ObjectIdentifier(download)] = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        let destination = downloadDestinations.removeValue(forKey: key)
        guard let destination else { return }
        AppLogger.webView.info("Download finished: \(destination.lastPathComponent)")
        // Bounce the Downloads stack in the Dock — the standard macOS
        // "download finished" feedback, so the user can see where it landed.
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name("com.apple.DownloadFileFinished"),
            object: destination.path
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        AppLogger.webView.error("Download failed: \(error.localizedDescription)")
    }

    // MARK: - Helpers

    /// Reduces a server-suggested filename to a safe single path component:
    /// strips any directory parts and path separators so a crafted name can't
    /// escape the Downloads folder, and falls back to "download" if empty.
    nonisolated static func sanitizedDownloadFilename(_ suggested: String) -> String {
        // Take the last path component off the raw name first (so "../../x"
        // reduces to "x"), then scrub any separators the OS still treats as
        // path-significant.
        let cleaned = (suggested as NSString).lastPathComponent
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." || cleaned == "-" {
            return "download"
        }
        return cleaned
    }

    /// Whether the response asks to be saved rather than displayed, i.e. it
    /// carries a `Content-Disposition: attachment` header. Used so a downloadable
    /// file WebKit could otherwise render inline (a PDF, an image) still saves.
    nonisolated static func isAttachment(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else {
            return false
        }
        return disposition.lowercased().contains("attachment")
    }

    /// Returns a URL in `directory` for `filename` that no file occupies,
    /// inserting " (1)", " (2)", … before the extension on collisions — matching
    /// how browsers de-duplicate downloads. `fileExists` is injected so the
    /// logic is testable without touching the disk.
    nonisolated static func nonCollidingURL(
        in directory: URL,
        filename: String,
        fileExists: (URL) -> Bool
    ) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard fileExists(candidate) else { return candidate }

        let ns = filename as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var index = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !fileExists(url) { return url }
            index += 1
        }
    }

    /// Reduces a host to its registrable domain (eTLD+1), e.g.
    /// `app.slack.com` → `slack.com`, `foo.co.uk` → `foo.co.uk`. Exposed so
    /// `belongsToService` and its callers share one definition of "same site".
    nonisolated static func effectiveDomain(_ host: String) -> String {
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

    /// Registrable domains that host many distinct products on different
    /// subdomains — Gmail, Google Docs, and Drive all live under google.com.
    /// For these, only the exact host counts as "the same service", so a Docs
    /// link clicked in Gmail is routed out instead of hijacking the inbox.
    /// Services that use per-tenant/workspace subdomains (e.g. *.slack.com,
    /// *.atlassian.net) are deliberately NOT listed — there a subdomain change
    /// is still the same app and should stay in-app.
    nonisolated static let sharedUmbrellaDomains: Set<String> = [
        "google.com",
        "microsoft.com",
        "live.com",
        "yahoo.com",
        "apple.com",
        "amazon.com",
    ]

    /// Whether `targetHost` belongs to the service whose current (or home) host
    /// is `serviceHost`. Same registrable domain counts as the same service — so
    /// Slack can switch workspaces across *.slack.com in-app — except for
    /// shared-umbrella domains (see `sharedUmbrellaDomains`) where only the exact
    /// host matches. Used to decide in-app vs. browser for links and new windows.
    nonisolated static func belongsToService(_ targetHost: String, serviceHost: String) -> Bool {
        let target = normalizedHost(targetHost)
        let service = normalizedHost(serviceHost)
        guard !target.isEmpty, !service.isEmpty else { return false }

        let targetDomain = effectiveDomain(target)
        guard targetDomain == effectiveDomain(service) else { return false }

        if sharedUmbrellaDomains.contains(targetDomain) {
            return target == service
        }
        return true
    }

    /// Sign-in / identity gateways. These host the authentication step for a
    /// service (and for third-party "Sign in with…" flows), so they are never a
    /// separate product to route out — a click to one during sign-in must stay
    /// in-app to complete. They sit on shared-umbrella domains (accounts vs.
    /// mail.google.com), so `belongsToService`'s exact-host rule would otherwise
    /// treat them as leaving the service and open the browser mid-login.
    nonisolated static let authHosts: Set<String> = [
        "accounts.google.com",
        "accounts.youtube.com",
        "login.microsoftonline.com",
        "login.microsoft.com",
        "login.windows.net",
        "login.live.com",
        "login.yahoo.com",
        "appleid.apple.com",
        "idmsa.apple.com",
    ]

    /// Whether `host` is a known authentication gateway (an exact match or a
    /// subdomain of one). Callers keep such hosts in-app so sign-in completes.
    nonisolated static func isAuthHost(_ host: String) -> Bool {
        let h = normalizedHost(host)
        return authHosts.contains(h) || authHosts.contains { h.hasSuffix("." + $0) }
    }

    /// Lowercases a host and drops a leading `www.` so host comparisons ignore
    /// casing and the optional www prefix.
    nonisolated private static func normalizedHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }
}
