import Foundation
import WebKit
import AppKit

@MainActor
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    /// The popups this service has open, first-opened first. Usually none or
    /// one; a sign-in popup that opens its own adds a second. See `PopupChain`.
    private var popups: [ServicePopup] = []

    /// The service's main web view that opened the current popup. Kept so we can
    /// reload it once the sign-in popup closes (see reloadOpenerAfterPopup).
    private weak var openerWebView: WKWebView?

    /// The reload that waits after a sign-in popup closes. See
    /// `reloadOpenerAfterPopup` for why it waits.
    private var pendingOpenerReload: Task<Void, Never>?

    /// How long the service gets to finish a sign-in by itself before it is
    /// reloaded.
    nonisolated static let openerReloadDelay: Duration = .seconds(3)

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
    /// to the system browser. The second argument is the source service's id
    /// (`instanceID`), so AppState can honour that service's "open links in
    /// Chorus" choice. When nil the coordinator falls back to `NSWorkspace.open`
    /// directly.
    var externalLinkHandler: ((URL, UUID?) -> Void)?
    var mailLinkHandler: ((URL) -> Void)?

    /// Whether some Chorus service owns a URL, so a page's `window.open` to it
    /// can switch to that service instead of opening a window. Set by
    /// `WebViewPool`. Nil ⇒ nothing is handed off.
    /// The second argument is this service's id, which never counts as the owner.
    var serviceOwnsURL: ((URL, UUID?) -> Bool)?

    /// The service this coordinator drives, set by `WebViewPool` so navigation
    /// callbacks can be attributed to a specific service.
    var instanceID: UUID?

    /// Called when a top-level navigation finishes (fresh load or login
    /// redirect) so the app can fire an immediate badge poll instead of waiting
    /// for the next poll tick. Never called for OAuth popup web views.
    var onNavigationFinished: ((UUID) -> Void)?

    /// Reports a navigation event for this service so the pool can keep a health
    /// state the rail can draw. Set by `WebViewPool`. Never called for OAuth
    /// popup web views: a popup's failure is the popup's business, and the
    /// service behind it is still fine.
    var onHealthEvent: ((UUID, ServiceHealth.Event) -> Void)?

    /// Set just before Chorus loads one of its own error pages into the web
    /// view, and cleared by the `didFinish` that page produces.
    ///
    /// Without it the failed dot would light and go out immediately: a failure
    /// paints an error page, painting it is a navigation, and that navigation
    /// finishes — which would report the service healthy while it is sitting on
    /// "Unable to connect".
    private var errorPageLoadInFlight = false

    /// Resolves a camera/microphone capture request to a WebKit decision. Set by
    /// `WebViewPool` (supplied by `AppState`), which owns the per-service policy
    /// and the "ask" prompt. Nil ⇒ deny (fail closed).
    var mediaCapturePolicyProvider: ((UUID, WKMediaCaptureType, WKFrameInfo) async -> WKPermissionDecision)?

    /// URL schemes the OS handles natively. We forward to NSWorkspace rather
    /// than letting WebKit fail with an unsupported-scheme error.
    nonisolated private static let nonWebSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio", "imessage", "maps"
    ]

    enum NonWebNavigationAction: Equatable { case cancel, routeMail, openSystem }

    /// Decides a non-web navigation without performing the side effect. Mail is
    /// deliberately distinct from the system path so Chorus can never hand a
    /// click back to itself when it is the default mail reader.
    nonisolated static func nonWebNavigationAction(
        for url: URL,
        navigationType: WKNavigationType
    ) -> NonWebNavigationAction? {
        guard let scheme = url.scheme?.lowercased(), nonWebSchemes.contains(scheme) else { return nil }
        guard navigationType == .linkActivated else { return .cancel }
        return scheme == "mailto" ? .routeMail : .openSystem
    }

    /// Whether a URL may be handed to `NSWorkspace.open`. Only http/https and the
    /// curated `nonWebSchemes` qualify.
    ///
    /// Without this gate a page could offer a link on any scheme the system has a
    /// handler for and a single click would fire it: `smb://`/`afp://` mounts a
    /// remote share (leaking the user's NTLM credentials to the attacker's
    /// server), `file://` opens local content, and an arbitrary custom scheme
    /// reaches whatever app claims it. The click requirement (`.linkActivated`)
    /// bounds this to social engineering rather than a drive-by, but the handoff
    /// itself should never have been unrestricted.
    nonisolated static func isSafeForExternalOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || nonWebSchemes.contains(scheme)
    }

    /// Whether a link that leaves a service (and that no other Chorus service
    /// owns) should open in an in-app Chorus window rather than the system
    /// browser. True only when the source service opted in AND the target is
    /// http/https. Other schemes stay on the `openExternally` path so the vetted-
    /// scheme gate above still decides them (a `mailto:` reaches Mail, an
    /// `smb://` is dropped) — an in-app web view can't load them anyway.
    nonisolated static func shouldOpenInAppBrowser(sourceOptedIn: Bool, url: URL) -> Bool {
        guard sourceOptedIn, let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Hands `url` to the system handler, but only on a vetted scheme. Anything
    /// else is dropped with a log line rather than silently ignored.
    nonisolated static func openExternally(_ url: URL) {
        guard isSafeForExternalOpen(url) else {
            AppLogger.webView.info("Blocked external open on disallowed scheme: \(url.scheme ?? "none")")
            return
        }
        NSWorkspace.shared.open(url)
    }

    deinit {
        // A backstop for the popup lifecycle, which is normally torn down by
        // popupWindowWillClose / webViewDidClose. deinit is nonisolated, so it
        // can't call the main-actor-isolated closePopups(); hand the popups to
        // a main-actor task that invalidates their title observations and
        // closes their windows. The list is captured as a local so the hop
        // never touches `self`, which is being deallocated.
        let openPopups = popups
        if !openPopups.isEmpty {
            Task { @MainActor in
                for popup in openPopups {
                    popup.titleObservation?.invalidate()
                    popup.window.close()
                }
            }
        }
        // Mirror closePopups' removeObserver so the willClose observer is gone
        // even if the coordinator is deallocated with a popup still open. Must
        // come LAST: passing `self` copies it, after which isolated stored
        // properties can't be touched in a deinit. removeObserver(self) is
        // thread-safe; the modern runtime would auto-clear it anyway, but drop it
        // explicitly for symmetry.
        NotificationCenter.default.removeObserver(self)
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
        //    Only on a real click: a page that runs
        //    `location.href = "facetime-audio://attacker"` (navigationType
        //    `.other`) could otherwise spawn Mail/Messages/call prompts with no
        //    user gesture, on repeat. Cancel either way so WebKit doesn't then
        //    try to load the unsupported scheme; only a `.linkActivated`
        //    navigation actually reaches the system handler.
        if let action = Self.nonWebNavigationAction(
            for: url,
            navigationType: navigationAction.navigationType
        ) {
            switch action {
            case .cancel:
                break
            case .routeMail:
                mailLinkHandler?(url)
            case .openSystem:
                Self.openExternally(url)
            }
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
            Self.openExternally(url)
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
        //      the login can finish instead of being kicked to the browser;
        //    - so is a sign-in page anywhere that says it will come back here
        //      (Trello → id.atlassian.com?continue=trello.com). See
        //      `routesClickedLinkOut`.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame ?? true,
           let currentHost = webView.url?.host,
           Self.routesClickedLinkOut(url, currentHost: currentHost) {
            if let handler = externalLinkHandler {
                handler(url, instanceID)
            } else {
                Self.openExternally(url)
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
        guard !isPopup(webView), let instanceID else { return }
        if errorPageLoadInFlight {
            errorPageLoadInFlight = false
        } else {
            onHealthEvent?(instanceID, .finishedLoading)
        }
        onNavigationFinished?(instanceID)
    }

    // WebKit kills WebContent on memory pressure, JIT bugs, or page crashes.
    // The webview is left blank with no recovery affordance — auto-reload so
    // the user just sees a brief flicker. But a page that crashes
    // deterministically would reload-crash forever, so back off after a few
    // crashes in a short window and show a recovery page instead.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The OAuth/sign-in popup shares this coordinator as its delegate.
        // Don't apply the service's crash recovery (fallbackURL + home page) to
        // it — that would reload the popup on the service's home URL, not the
        // popup's own page. Reload its own page, but with the same crash-window
        // backoff the main view has: a popup that crashes deterministically
        // would otherwise reload-crash forever. Give up by closing the popup.
        if let index = popupIndex(of: webView) {
            let popup = popups[index]
            let now = Date()
            popup.crashTimestamps.append(now)
            popup.crashTimestamps = popup.crashTimestamps.filter { now.timeIntervalSince($0) <= Self.crashWindow }
            guard Self.shouldAutoReload(
                crashTimestamps: popup.crashTimestamps,
                now: now,
                maxCrashes: Self.maxCrashesInWindow,
                window: Self.crashWindow
            ) else {
                AppLogger.webView.error("OAuth popup WebContent terminated repeatedly — closing popup")
                closePopups(PopupChain.closedWhenClosing(at: index, count: popups.count))
                return
            }
            if webView.url != nil { webView.reload() }
            return
        }

        // The service's own content process died — reconcile downloads it started
        // so a stuck transfer can't leak this coordinator (see cancelActiveDownloads).
        cancelActiveDownloads()

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
            // A page that keeps crashing is a failure the rail should show, and
            // the recovery page's own load must not report it healthy.
            if let instanceID { onHealthEvent?(instanceID, .failed) }
            errorPageLoadInFlight = true
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
        if isPopup(webView) { return }

        let nsError = error as NSError
        guard !Self.keepsCurrentPage(afterProvisionalFailure: nsError, hasCommittedPage: webView.url != nil) else {
            // No error page, but the rail's loading ring has to come down, or it
            // spins forever.
            reportStoppedLoading(webView)
            return
        }

        // Same page the generic error page below is about, reported to the rail
        // so a service that failed while you were looking at another one still
        // says so.
        if let instanceID { onHealthEvent?(instanceID, .failed) }

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
        errorPageLoadInFlight = true
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// A load that failed after it committed. The page it committed is on
    /// screen, part-loaded, so it stays — but without this the rail's ring kept
    /// spinning. Stop is a stop; anything else, a connection lost mid-load, is a
    /// failure the rail should show.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isPopup(webView) { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            reportStoppedLoading(webView)
        } else if let instanceID {
            onHealthEvent?(instanceID, .failed)
        }
    }

    /// Tells the rail a load ended with neither a finish nor a failure worth an
    /// error page. A replacing navigation also cancels the old one, so this
    /// waits a turn and leaves the ring alone while a load is still running.
    private func reportStoppedLoading(_ webView: WKWebView) {
        Task { @MainActor [weak self, weak webView] in
            await Task.yield()
            guard let self, let webView, !webView.isLoading,
                  let instanceID = self.instanceID else { return }
            self.onHealthEvent?(instanceID, .stoppedLoading)
        }
    }

    /// Whether a provisional failure leaves the current page up instead of the
    /// error page. None of these is a connection problem: a cancelled load
    /// (Stop, or another navigation replaced it), a URL WebKit has no way to
    /// show, and a response WebKit handed to a download instead of rendering.
    /// Showing "Unable to connect" for a download that worked would be wrong.
    ///
    /// A cancel always keeps the page, even an empty one: the user pressed
    /// Stop, or something replaced the load. The other two keep it only when a
    /// page has committed. On a first load there is nothing to keep, and a
    /// blank view with a healthy rail would hide a service that never came up.
    nonisolated static func keepsCurrentPage(afterProvisionalFailure error: NSError, hasCommittedPage: Bool) -> Bool {
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return true }
        guard hasCommittedPage else { return false }
        // WebKitErrorCannotShowURL (101) and
        // WebKitErrorFrameLoadInterruptedByPolicyChange (102), still reported
        // under the legacy domain.
        if error.domain == "WebKitErrorDomain" { return error.code == 101 || error.code == 102 }
        return false
    }

    /// Reloads a web view, or loads `fallbackURL` when there is nothing to
    /// reload. A first load stopped before it committed leaves no page, and
    /// `reload()` on that does nothing, so Reload looked broken.
    static func reload(_ webView: WKWebView, fallbackURL: URL?) {
        if webView.reload() == nil, let fallbackURL {
            webView.load(URLRequest(url: fallbackURL))
        }
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
        // Only wire the retry button for http/https targets — the URL derives from
        // the failing navigation, but refuse `javascript:`/`data:` so a crafted
        // failing URL can't run script when the user clicks Try Again.
        if let retryURLString,
           let retryScheme = URL(string: retryURLString)?.scheme?.lowercased(),
           retryScheme == "http" || retryScheme == "https" {
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
        // a workspace via a target=_blank link — or is a clicked sign-in link
        // (Gmail's "Sign in" to accounts.google.com), load it in the existing
        // web view instead of spawning a separate NSWindow. Only genuinely
        // cross-service popups (real OAuth sign-in windows to another domain)
        // fall through and get their own window below.
        //
        // Restricted to real link clicks. A programmatic `window.open()` hands
        // the caller a window handle, and sign-in flows test it:
        //
        //     const w = window.open(url); if (!w) return;
        //
        // Returning nil there reads as "popup blocked", so the page abandons
        // whatever it was starting with no window and no error to show for it.
        // Same-service `window.open` therefore falls through to a real window,
        // which shares the opener's data store so a session started in it lands
        // in the right place.
        if Self.shouldLoadNewWindowInPlace(
            navigationType: navigationAction.navigationType,
            targetHost: navigationAction.request.url?.host,
            openerHost: webView.url?.host
        ) {
            webView.load(navigationAction.request)
            return nil
        }

        let openerIndex = popupIndex(of: webView)

        // A page opening another Chorus service's link with `window.open` — a
        // Linear link in Slack — switches to that service, the way a clicked
        // link already does.
        if let url = navigationAction.request.url,
           Self.shouldHandOffScriptedWindow(
               navigationType: navigationAction.navigationType,
               openerIsPopup: openerIndex != nil,
               requestedSize: windowFeatures.width != nil || windowFeatures.height != nil,
               targetURL: url,
               openerHost: webView.url?.host,
               ownedByAnotherService: serviceOwnsURL?(url, instanceID) ?? false
           ) {
            if let handler = externalLinkHandler {
                handler(url, instanceID)
            } else {
                Self.openExternally(url)
            }
            return nil
        }

        closePopups(PopupChain.closedWhenOpening(fromPopupAt: openerIndex, count: popups.count))

        // Remember the service's main web view so we can reload it after the
        // popup closes. The popup shares this data store, so once sign-in
        // finishes the session cookies are already here — the main view just
        // needs to reload to leave its signed-out page.
        if openerIndex == nil {
            openerWebView = webView
            // A reload still waiting from the last popup would land in the
            // middle of this one.
            pendingOpenerReload?.cancel()
            pendingOpenerReload = nil
        }

        // CRITICAL: Use the configuration passed in — it inherits the parent's data store
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        // The user agent is a web view property, not part of the configuration,
        // so the popup does not inherit it. Left at WebKit's default, Gmail in a
        // popup shows "This browser version is no longer supported".
        popup.customUserAgent = webView.customUserAgent
        #if DEBUG
        popup.isInspectable = true
        #endif

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
        // We hold this window in a strong property (`popups`) and release
        // it ourselves in closePopups. Left at its `true` default, AppKit would
        // also release the window when it closes — an over-release that crashes
        // the app when an OAuth/sign-in popup (e.g. Gmail) window is closed.
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.title = navigationAction.request.url?.host ?? "Chorus"
        window.center()
        window.makeKeyAndOrderFront(nil)

        // The sign-in signal, taken from the URL that opened the popup and not
        // touched again: a service asking the user to sign in again opens
        // straight at its provider. See `shouldReloadOpener`.
        let entry = ServicePopup(
            webView: popup,
            window: window,
            openedAtAuthHost: navigationAction.request.url?.host.map(Self.isAuthHost) ?? false
        )
        popups.append(entry)

        // Mirror the page's <title> into the NSWindow title bar so the user
        // sees what's actually loaded (e.g. "Google Drive — Sign in") rather
        // than the stale initial host name.
        // Read the new title from the (Sendable String?) KVO change value rather
        // than reaching back into the web view — the observe closure is
        // nonisolated/@Sendable, and touching the main-actor-isolated WKWebView
        // from it is a data race under Swift 6. An empty title leaves the bar on
        // its current text (the host it was seeded with) instead of clearing it.
        entry.titleObservation = popup.observe(\.title, options: [.new]) { [weak window] _, change in
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
              let index = popups.firstIndex(where: { $0.window === window }) else { return }
        // Closed by the user (red button / ⌘W), not by the page.
        closePopup(at: index, selfClosed: false)
    }

    /// Whether closing a popup should reload the service that opened it.
    ///
    /// Reloading exists for sign-in: the popup shares the service's data store,
    /// so once sign-in finishes the session cookies are already here and the
    /// main view only needs a reload to leave its signed-out page.
    ///
    /// Reloading *unconditionally* is wrong, because a popup is also how an
    /// ordinary link opens. Glance at a link from a chat service, close the
    /// window, and the service reloads underneath you — losing scroll position,
    /// a half-typed message, and whatever else the page held but never sent.
    /// That is a steady, visible cost paid for a case that comes up rarely.
    ///
    /// Two signals separate them, and either one is enough:
    ///
    /// - **The page closed itself.** OAuth popups finish by calling
    ///   `window.close()`; a link window is closed by the user. This is the
    ///   signal that carries flows through identity providers we don't list,
    ///   such as a company's own Okta or Keycloak.
    /// - **The popup was opened at a known sign-in gateway.** A service asking
    ///   the user to sign in again opens straight at its provider, so the very
    ///   first URL is the gateway. This covers a flow the user closes by hand
    ///   once it is done, which some providers leave to them.
    ///
    /// The second signal reads the *opening* URL only, never the rest of the
    /// navigation chain, and that distinction is the whole point. Plenty of
    /// ordinary links pass through a sign-in gateway on their way somewhere
    /// else: opening an Azure portal link from Teams starts at
    /// `portal.azure.com` and redirects through `login.microsoftonline.com` for
    /// SSO. Watching the chain counts that as a sign-in and reloads the service
    /// — the exact bug this function exists to fix, measured happening.
    ///
    /// When neither signal holds, the popup was a link, and the service is left
    /// alone. The failure mode this trades into is mild and recoverable: a
    /// sign-in that neither starts at a listed gateway nor closes itself leaves
    /// the service on its signed-out page until the user hits reload, once.
    nonisolated static func shouldReloadOpener(selfClosed: Bool, openedAtAuthHost: Bool) -> Bool {
        selfClosed || openedAtAuthHost
    }

    /// Whether the reload that waited after a popup closed should still run.
    ///
    /// Many services finish a sign-in themselves once the popup closes. Figma's
    /// sign-in page opens `/start_google_sso`, checks every 250 ms for a cookie
    /// the popup writes, posts the token it holds, and then moves on to the
    /// files page. Reloading the moment the popup closes killed that script
    /// before it read the cookie, and the page stayed on the sign-in form. So
    /// the reload waits, and it is dropped if the page has moved or is still
    /// loading by then: the service has handled the sign-in on its own.
    nonisolated static func shouldRunDeferredOpenerReload(
        urlAtClose: URL?,
        urlNow: URL?,
        isLoading: Bool
    ) -> Bool {
        !isLoading && urlNow == urlAtClose
    }

    /// Reloads the service that opened the popup, when the rules above say to.
    private func reloadOpenerAfterPopup(selfClosed: Bool, openedAtAuthHost: Bool) {
        guard Self.shouldReloadOpener(
            selfClosed: selfClosed,
            openedAtAuthHost: openedAtAuthHost
        ) else { return }
        guard let opener = openerWebView else { return }
        let urlAtClose = opener.url
        pendingOpenerReload?.cancel()
        pendingOpenerReload = Task { @MainActor [weak self, weak opener] in
            try? await Task.sleep(for: Self.openerReloadDelay)
            guard !Task.isCancelled, let self, let opener else { return }
            self.pendingOpenerReload = nil
            guard Self.shouldRunDeferredOpenerReload(
                urlAtClose: urlAtClose,
                urlNow: opener.url,
                isLoading: opener.isLoading
            ) else { return }
            if opener.url != nil {
                opener.reload()
            } else if let fallback = self.fallbackURL {
                opener.load(URLRequest(url: fallback))
            }
        }
    }

    private func popupIndex(of webView: WKWebView) -> Int? {
        popups.firstIndex { $0.webView === webView }
    }

    private func isPopup(_ webView: WKWebView) -> Bool {
        popupIndex(of: webView) != nil
    }

    /// Closes the popup at `index` and every popup it opened. Only the first
    /// popup's close can reload the service: a child closing hands control
    /// back to its parent popup, and the flow is not over yet.
    private func closePopup(at index: Int, selfClosed: Bool) {
        if index == 0 {
            reloadOpenerAfterPopup(selfClosed: selfClosed, openedAtAuthHost: popups[0].openedAtAuthHost)
        }
        closePopups(PopupChain.closedWhenClosing(at: index, count: popups.count))
    }

    /// Tears down the popups in `range`, last-opened first. The close observer
    /// comes off before `close()`, so a teardown never re-enters
    /// `popupWindowWillClose`.
    private func closePopups(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        for popup in popups[range].reversed() {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: popup.window
            )
            popup.titleObservation?.invalidate()
            popup.titleObservation = nil
            popup.webView.navigationDelegate = nil
            popup.webView.uiDelegate = nil
            popup.window.close()
        }
        popups.removeSubrange(range)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let index = popupIndex(of: webView) {
            // The page called window.close() on itself — the shape an OAuth
            // popup takes when it finishes.
            closePopup(at: index, selfClosed: true)
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

        // WebKit hangs the page's `<input type=file>` until `completionHandler`
        // fires exactly once. Route it through a one-shot latch so it can't fire
        // twice and — crucially — so the page is released even if the host window
        // closes while the sheet is open, in which case the sheet's own handler
        // may never run and the input would hang forever.
        let session = FilePickerSession(completionHandler)
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            session.finish(response == .OK ? panel.urls : nil)
        }

        // Attach as a sheet to the web view's window when we have one; fall back
        // to a standalone modal panel otherwise (e.g. an OAuth popup web view).
        if let window = webView.window {
            session.observeClose(of: window)
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            panel.begin(completionHandler: handleResponse)
        }
    }

    // MARK: - Media Capture (camera / microphone) permission

    /// Gates every `getUserMedia()` call. Without this method WKWebView denies
    /// all capture, so video/voice services never get the camera or mic.
    ///
    /// CRITICAL: `decisionHandler` MUST be `@escaping @MainActor (…)`. The WebKit
    /// header annotates the block `WK_SWIFT_UI_ACTOR` (= `@MainActor`); drop it and
    /// Swift silently declines to treat this as the protocol witness — the method
    /// never reaches the Obj-C runtime, WebKit never calls it, and capture fails
    /// with no error. Same trap as `runOpenPanelWith` above. The `origin`
    /// parameter is `WKSecurityOrigin` (not URL); getting it wrong also breaks the
    /// witness. The `Task` captures only locals — never `self` — so a coordinator
    /// torn down mid-decision leaves the handler a safe no-op.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        // A breadcrumb so QA can confirm the witness actually fires (the trap is
        // silent, so "did the method get called at all?" is the first question).
        AppLogger.webView.info("Media capture request (type \(type.rawValue), mainFrame \(frame.isMainFrame))")
        guard let id = instanceID, let provider = mediaCapturePolicyProvider else {
            decisionHandler(.deny)
            return
        }
        Task { @MainActor in
            decisionHandler(await provider(id, type, frame))
        }
    }

    // MARK: - JavaScript Dialogs (alert / confirm / prompt)

    /// Presents a native panel for `window.alert()`. Without this method WebKit
    /// shows nothing and returns at once — harmless for alert, but the same
    /// missing-delegate default silently answers `confirm()` with "Cancel" and
    /// `prompt()` with nil (see below), which strands any page flow gated on a
    /// dialog. Gmail's Send runs through `confirm()` (the attachment reminder and
    /// the no-subject prompt), so a signed-in user clicking Send just saw nothing
    /// happen. Implementing all three restores the expected behaviour.
    ///
    /// CRITICAL: `completionHandler` MUST be `@escaping @MainActor`. The WebKit
    /// header annotates the block `WK_SWIFT_UI_ACTOR` (= `@MainActor`); drop it
    /// and Swift silently declines to treat this as the protocol witness — the
    /// method never reaches the Obj-C runtime, WebKit never calls it, and the
    /// page hangs. Same trap as `runOpenPanelWith` above.
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        WebViewDialogs.alert(message, over: webView, completion: completionHandler)
    }

    /// Presents a native OK / Cancel panel for `window.confirm()`. Returns `true`
    /// only when the user chooses OK; window-close-first resolves to `false`, the
    /// same as clicking Cancel. See the alert method above for the `@MainActor`
    /// witness requirement — it applies identically here.
    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        WebViewDialogs.confirm(message, over: webView, completion: completionHandler)
    }

    /// Presents a native text-input panel for `window.prompt()`. Returns the
    /// entered text on OK, or nil on Cancel / window-close-first (which the page
    /// reads as a dismissed prompt). See the alert method above for the
    /// `@MainActor` witness requirement.
    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        WebViewDialogs.prompt(prompt, defaultText: defaultText, over: webView, completion: completionHandler)
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
        trackDownload(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
        trackDownload(download)
    }

    /// Maps each in-flight download to the destination we chose for it, so the
    /// finish handler can reveal the right file (WKDownload doesn't hand the
    /// destination back). Keyed by object identity; cleared on finish/failure.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    /// Identities of downloads still running, and a strong self-reference held
    /// while any are. The coordinator is otherwise retained only by
    /// `WebViewPool.coordinators`, and `WKDownload.delegate` is weak — so
    /// evicting/rebuilding/hibernating the web view mid-download would dealloc
    /// the coordinator, drop the delegate, lose `downloadDestinations`, and
    /// silently abort the transfer. Keeping `self` alive until the last
    /// download finishes lets it complete regardless of the web view's fate.
    // Hold the WKDownloads themselves (not just their ids) so a WebContent crash
    // can cancel any that are still in flight — otherwise a download that never
    // delivers a terminal callback would keep `selfRetainWhileDownloading`
    // (and this coordinator's data-store refs) alive for the app's lifetime.
    private var activeDownloads: Set<WKDownload> = []
    private var selfRetainWhileDownloading: WebViewCoordinator?

    /// The app-wide download list, and each running download's row in it. Set
    /// by `WebViewPool`.
    var downloadCenter: DownloadCenter?
    private var downloadItemIDs: [ObjectIdentifier: UUID] = [:]

    private func trackDownload(_ download: WKDownload) {
        activeDownloads.insert(download)
        selfRetainWhileDownloading = self
        let guessedName = download.originalRequest?.url?.lastPathComponent
        downloadItemIDs[ObjectIdentifier(download)] = downloadCenter?.begin(
            serviceID: instanceID,
            filename: Self.sanitizedDownloadFilename(guessedName ?? ""),
            progress: download.progress,
            cancel: { [weak self, weak download] in
                guard let self, let download else { return }
                self.cancelDownload(download)
            }
        )
    }

    /// Cancel from the download list. WebKit sends no failure callback for a
    /// download it was told to cancel (`DownloadProxy::didFail` returns early
    /// once cancelled), so the bookkeeping the failure handler would do has to
    /// happen here — otherwise the self-retain above keeps this coordinator
    /// alive for the rest of the run.
    private func cancelDownload(_ download: WKDownload) {
        download.cancel(nil)
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        untrackDownload(download)
    }

    /// Takes the download off the books and returns its row in the list.
    @discardableResult
    private func untrackDownload(_ download: WKDownload) -> UUID? {
        activeDownloads.remove(download)
        if activeDownloads.isEmpty { selfRetainWhileDownloading = nil }
        return downloadItemIDs.removeValue(forKey: ObjectIdentifier(download))
    }

    /// Cancels every in-flight download and clears the self-retain. Called when
    /// the main web view's content process dies: such downloads can't be relied
    /// on to deliver a terminal callback, so releasing here prevents a permanent
    /// coordinator leak. The page has already crashed, so an aborted transfer is
    /// an acceptable tradeoff (the user can retry).
    private func cancelActiveDownloads() {
        guard !activeDownloads.isEmpty else { return }
        for download in activeDownloads {
            download.cancel(nil)
            if let itemID = downloadItemIDs[ObjectIdentifier(download)] {
                downloadCenter?.fail(itemID, message: "The page stopped responding")
            }
        }
        activeDownloads.removeAll()
        downloadItemIDs.removeAll()
        downloadDestinations.removeAll()
        selfRetainWhileDownloading = nil
    }

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
        if let itemID = downloadItemIDs[ObjectIdentifier(download)] {
            downloadCenter?.setDestination(destination, for: itemID)
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        let destination = downloadDestinations.removeValue(forKey: key)
        if let itemID = untrackDownload(download) {
            downloadCenter?.finish(itemID)
        }
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
        if let itemID = untrackDownload(download) {
            downloadCenter?.fail(itemID, message: Self.downloadFailureMessage(error))
        }
        AppLogger.webView.error("Download failed: \(error.localizedDescription)")
    }

    // MARK: - Helpers

    /// What the download list says went wrong. URL-loading errors already read
    /// as plain words ("The Internet connection appears to be offline."); what
    /// WebKit reports in its own domain reads as "WebKitErrorDomain error 102",
    /// which means nothing to anyone, so that gets one plain line instead.
    nonisolated static func downloadFailureMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return nsError.localizedDescription }
        return "The download stopped before it finished."
    }

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

    /// Whether a new-window request should collapse into the opener's web view
    /// instead of getting its own window.
    ///
    /// Only real link clicks collapse. A programmatic `window.open()` must come
    /// back with a window handle: sign-in flows null-check the return value to
    /// detect a popup blocker, and a nil answer makes them abandon the flow
    /// silently — no window, no error, no request. Factored out so the rule is
    /// unit-testable without a live `WKWebView`.
    ///
    /// A clicked link to a sign-in gateway collapses too. Signed-out Gmail shows
    /// a marketing page whose "Sign in" is `<a target="_blank">` to
    /// accounts.google.com. Given its own window, the sign-in finished there and
    /// Gmail loaded in that window, while the service stayed on the marketing
    /// page behind it. Loaded in place, the gateway's `continue` URL brings the
    /// service itself back. Such a link has no opener to report to (Google marks
    /// it `noopener`), so nothing waits on the window; the OAuth popups that do
    /// wait come from `window.open`, which never reaches this branch.
    nonisolated static func shouldLoadNewWindowInPlace(
        navigationType: WKNavigationType,
        targetHost: String?,
        openerHost: String?
    ) -> Bool {
        guard navigationType == .linkActivated,
              let targetHost,
              let openerHost
        else { return false }
        return belongsToService(targetHost, serviceHost: openerHost)
            || isAuthHost(targetHost)
    }

    /// Whether a page's `window.open` should switch to another Chorus service
    /// instead of opening a window. Clicked links never get here — they were
    /// routed in `decidePolicyFor`. So this is script, and only the narrow case
    /// is handed off: the service's own page (not a popup) opening an unsized
    /// window to a web URL that another Chorus service owns.
    ///
    /// Anything else keeps its window. A size asked for is how sign-in popups
    /// ask, a popup's own children are sign-in steps, and a host no service owns
    /// might be a company's own identity provider that Chorus doesn't list.
    /// Sending that to the browser would strand the sign-in there, which is a
    /// worse failure than a link in a window. A URL shaped like a sign-in stays
    /// too, even on a host a service owns: Linear's "Connect Slack" opens
    /// Slack's OAuth page, and handing that to the Slack service would run the
    /// consent in the wrong data store and lose the callback.
    nonisolated static func shouldHandOffScriptedWindow(
        navigationType: WKNavigationType,
        openerIsPopup: Bool,
        requestedSize: Bool,
        targetURL: URL,
        openerHost: String?,
        ownedByAnotherService: Bool
    ) -> Bool {
        guard navigationType != .linkActivated,
              !openerIsPopup,
              !requestedSize,
              ownedByAnotherService,
              let scheme = targetURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let targetHost = targetURL.host,
              let openerHost
        else { return false }
        return !belongsToService(targetHost, serviceHost: openerHost)
            && !isAuthHost(targetHost)
            && !looksLikeSignIn(targetURL)
    }

    /// Whether a link the user clicked on a page at `currentHost` leaves the
    /// service, and so goes to the link router (another Chorus service, or the
    /// browser). It stays when it is the same service, a known sign-in gateway,
    /// or a sign-in round trip back to this service. Factored out of
    /// `decidePolicyFor` so the rule can be tested without a `WKWebView`.
    nonisolated static func routesClickedLinkOut(_ url: URL, currentHost: String) -> Bool {
        guard let targetHost = url.host else { return false }
        return !belongsToService(targetHost, serviceHost: currentHost)
            && !isAuthHost(targetHost)
            && !isSignInRoundTrip(url, serviceHost: currentHost)
    }

    /// Whether `url` is a sign-in step that says it will come back to the
    /// service at `serviceHost`: shaped like a sign-in (see `looksLikeSignIn`),
    /// with a query value that is an address on the service, such as Trello's
    /// `continue=https://trello.com/…` or an OAuth `redirect_uri`. Lists of
    /// gateways never cover every company's own sign-in page; this does, and
    /// the return address keeps it from catching a sign-in page for somewhere
    /// else.
    nonisolated static func isSignInRoundTrip(_ url: URL, serviceHost: String) -> Bool {
        guard looksLikeSignIn(url),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return false }
        return items.contains { item in
            guard let value = item.value,
                  let returnURL = URL(string: value),
                  let scheme = returnURL.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let returnHost = returnURL.host
            else { return false }
            return belongsToService(returnHost, serviceHost: serviceHost)
        }
    }

    /// Whether a URL reads as a step in a sign-in or an authorization, whatever
    /// its host: OAuth and SAML parameters in the query, or a path segment such
    /// as `oauth`, `authorize` or `login`. Errs toward yes; a false yes costs a
    /// link its switch to another service, and a false no costs a sign-in.
    nonisolated static func looksLikeSignIn(_ url: URL) -> Bool {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryKeys = Set((components?.queryItems ?? []).map { $0.name.lowercased() })
        if !queryKeys.isDisjoint(with: signInQueryKeys) { return true }
        let segments = url.pathComponents.map { $0.lowercased() }
        return segments.contains { segment in
            signInPathSegments.contains(segment)
                || signInPathSegments.contains { segment.hasPrefix($0 + ".") }
        }
    }

    nonisolated private static let signInQueryKeys: Set<String> = [
        "client_id", "redirect_uri", "response_type", "samlrequest", "samlresponse", "code_challenge",
    ]
    nonisolated private static let signInPathSegments: Set<String> = [
        "oauth", "oauth2", "authorize", "auth", "login", "signin", "sign-in", "sso", "saml", "openid",
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

        // Reduce with the public-suffix-aware registrable-domain function, the
        // same one the capture trust check uses. The naive `effectiveDomain`
        // collapsed a shared multi-tenant hosting suffix to its bare form, so
        // `evil.vercel.app` and `team.vercel.app` both became `vercel.app` and
        // an attacker sibling on that suffix was treated as owning a user's
        // service — its page then loaded in place inside the service's
        // authenticated web view. `captureRegistrableDomain` keeps the tenant
        // label (`team.vercel.app`), so distinct owners no longer collide.
        let targetDomain = captureRegistrableDomain(target)
        guard targetDomain == captureRegistrableDomain(service) else { return false }

        if sharedUmbrellaDomains.contains(targetDomain) {
            return target == service
        }
        return true
    }

    /// Multi-tenant hosting suffixes where each label directly under the suffix is
    /// a DIFFERENT owner — a curated subset of the Public Suffix List's private
    /// section. For the camera/mic trust decision these are treated as public
    /// suffixes, so `alice.web.app` and `attacker.web.app` are different sites and
    /// a capture grant can never leak across them. Not exhaustive (a full PSL is
    /// the ideal), but it covers the common free-hosting providers a service might
    /// live on. Used ONLY by the capture check, not by link routing.
    nonisolated static let captureSharedHostingSuffixes: Set<String> = [
        "github.io", "gitlab.io", "web.app", "firebaseapp.com", "appspot.com",
        "run.app", "pages.dev", "workers.dev", "vercel.app", "netlify.app",
        "herokuapp.com", "onrender.com", "fly.dev", "glitch.me", "repl.co",
        "replit.dev", "surge.sh", "azurewebsites.net",
    ]

    /// The registrable domain for the capture trust decision. Like
    /// `effectiveDomain`, but also treats the multi-tenant hosting suffixes above
    /// as public suffixes, so a tenant on shared hosting reduces to
    /// `<tenant>.<suffix>` instead of the bare suffix.
    nonisolated static func captureRegistrableDomain(_ host: String) -> String {
        let h = normalizedHost(host)
        let parts = h.split(separator: ".")
        guard parts.count >= 2 else { return h }
        for suffix in captureSharedHostingSuffixes {
            if h == suffix { return h }
            if h.hasSuffix("." + suffix) {
                let labels = suffix.split(separator: ".").count + 1  // tenant + suffix
                return parts.suffix(labels).joined(separator: ".")
            }
        }
        return effectiveDomain(h)
    }

    /// Whether a capture request from `frameHost` should be trusted as the service
    /// at `serviceHost`. Stricter than `belongsToService` (which drives link
    /// routing): hosts that merely share a multi-tenant hosting suffix are
    /// different owners and never match, closing a grant leak across e.g.
    /// `*.web.app`. Same registrable domain still matches (so `*.slack.com`
    /// workspaces work), and shared-umbrella domains keep their exact-host rule.
    nonisolated static func captureOriginBelongsToService(_ frameHost: String, serviceHost: String) -> Bool {
        let frame = normalizedHost(frameHost)
        let service = normalizedHost(serviceHost)
        guard !frame.isEmpty, !service.isEmpty else { return false }
        let frameDomain = captureRegistrableDomain(frame)
        guard frameDomain == captureRegistrableDomain(service) else { return false }
        if sharedUmbrellaDomains.contains(frameDomain) {
            return frame == service
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
        "login.microsoftonline.us",
        "account.live.com",
        // Atlassian's one sign-in page, for Trello, Jira, Confluence and Bitbucket.
        "id.atlassian.com",
        // Coda signs in here since Superhuman bought it.
        "id.superhuman.com",
        // ChatGPT's sign-in, on openai.com rather than chatgpt.com.
        "auth.openai.com",
        "auth0.openai.com",
        // Zoho signs in on a domain per data centre, so outside the US the
        // sign-in is on another domain from zoho.com.
        "accounts.zoho.com",
        "accounts.zoho.eu",
        "accounts.zoho.in",
        "accounts.zoho.com.au",
        "accounts.zoho.com.cn",
        "accounts.zoho.jp",
        "accounts.zoho.sa",
        "accounts.zohocloud.ca",
        // Company sign-in providers with one shared host.
        "sso.jumpcloud.com",
        "auth.pingone.com",
        "auth.pingone.eu",
        "auth.pingone.ca",
        "auth.pingone.asia",
        "auth.pingone.com.au",
    ]

    /// Company sign-in providers that give every customer a subdomain
    /// (`acme.okta.com`, `contoso.b2clogin.com`). Any subdomain counts except the
    /// provider's own site, so a link to Okta's marketing or docs pages still
    /// leaves the service. Domains from each provider's documentation.
    nonisolated static let authTenantDomains: Set<String> = [
        "okta.com", "okta-emea.com", "oktapreview.com", "okta-gov.com", "okta.mil",
        "auth0.com",
        "onelogin.com",
        "duosecurity.com",
        "b2clogin.com", "ciamlogin.com",
        "cloudflareaccess.com",
        "awsapps.com",
    ]

    /// The first labels a provider uses for its own site rather than a
    /// customer's sign-in.
    nonisolated private static let providerSiteLabels: Set<String> = [
        "developer", "help", "support", "docs", "status", "community", "trust",
    ]

    /// Whether `host` is a known authentication gateway (an exact match or a
    /// subdomain of one, or a customer's subdomain of a company sign-in
    /// provider). Callers keep such hosts in-app so sign-in completes.
    nonisolated static func isAuthHost(_ host: String) -> Bool {
        let h = normalizedHost(host)
        if authHosts.contains(h) || authHosts.contains(where: { h.hasSuffix("." + $0) }) {
            return true
        }
        return authTenantDomains.contains { domain in
            guard h.hasSuffix("." + domain) else { return false }
            let first = h.split(separator: ".").first.map(String.init) ?? ""
            return !providerSiteLabels.contains(first)
        }
    }

    /// Lowercases a host and drops a leading `www.` so host comparisons ignore
    /// casing and the optional www prefix.
    nonisolated private static func normalizedHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }
}

/// Drives a file-open panel to a single completion. WebKit hangs the page's
/// `<input type=file>` until the handler fires exactly once, so this guarantees
/// it fires — on selection, cancel, or the host window closing first — and never
/// twice. `@MainActor` (hence Sendable) so the close observer can hold it.
@MainActor
private final class FilePickerSession {
    private var completion: (@MainActor ([URL]?) -> Void)?
    private var closeObserver: NSObjectProtocol?

    init(_ completion: @escaping @MainActor ([URL]?) -> Void) {
        self.completion = completion
    }

    /// Fires the completion with nil if `window` closes before the panel does,
    /// releasing the page's file input instead of leaving it hung.
    func observeClose(of window: NSWindow) {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            // The .main queue delivers this on the main thread, so assuming main
            // isolation to reach the @MainActor method is safe here.
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    /// Idempotent: the first call fires the handler and detaches the observer;
    /// later calls are no-ops.
    func finish(_ urls: [URL]?) {
        guard let completion else { return }
        self.completion = nil
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        completion(urls)
    }
}
