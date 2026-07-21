import WebKit
import UserNotifications

struct NotificationPayload: Codable {
    let title: String
    let body: String
    let icon: String
    let tag: String
    let serviceID: String
}

@MainActor
final class UserScriptManager {
    private var messageHandlers: [UUID: NotificationMessageHandler] = [:]
    private var darkProbeHandlers: [UUID: DarkProbeMessageHandler] = [:]
    private var darkCSSCacheHandlers: [UUID: DarkCSSCacheMessageHandler] = [:]

    var isServiceMuted: (@Sendable (UUID) -> Bool)?
    /// Per-service "forward notifications to macOS" flag. Defaults to true when
    /// unset, preserving behavior for services that predate the toggle.
    var isServiceNotifyingOS: (@Sendable (UUID) -> Bool)?
    var isDoNotDisturbActive: (@Sendable () -> Bool)?
    var autoDismissCookieBanners: Bool = true

    /// Called when a service's dark-detection probe reports a verdict
    /// (serviceID, whether the site lacks its own dark theme).
    var onDarkProbeVerdict: (@Sendable (UUID, Bool) -> Void)?

    /// Called when a themed service exports its generated Dark Reader CSS
    /// (serviceID, the CSS) so it can be cached for a fast first paint next load.
    var onDarkCSSExport: (@Sendable (UUID, String) -> Void)?

    /// Full setup for a freshly built web view: the message handlers (added once)
    /// plus all user scripts.
    func configureScripts(
        for instance: ServiceInstance,
        customCSS: String?,
        darkInjection: DarkReaderSupport.DarkInjection,
        cachedDarkCSS: String? = nil,
        on controller: WKUserContentController
    ) {
        installHandlers(for: instance, on: controller)
        installUserScripts(
            for: instance,
            customCSS: customCSS,
            darkInjection: darkInjection,
            cachedDarkCSS: cachedDarkCSS,
            on: controller
        )
    }

    /// Registers the message handlers. Called once when the web view is built —
    /// NOT on reinstall, since `removeAllUserScripts()` leaves message handlers in
    /// place and re-adding would throw.
    func installHandlers(for instance: ServiceInstance, on controller: WKUserContentController) {
        let mutedCheck = isServiceMuted
        let notifyOSCheck = isServiceNotifyingOS
        let dndCheck = isDoNotDisturbActive
        let handler = NotificationMessageHandler(
            serviceID: instance.id,
            isMutedCheck: { id in
                mutedCheck?(id) ?? false
            },
            notifyOSCheck: { id in
                notifyOSCheck?(id) ?? true
            },
            isDoNotDisturbCheck: {
                dndCheck?() ?? false
            }
        )
        controller.add(handler, name: "chorusNotification")
        messageHandlers[instance.id] = handler

        let verdict = onDarkProbeVerdict
        let probeHandler = DarkProbeMessageHandler(serviceID: instance.id) { id, lacksDark in
            verdict?(id, lacksDark)
        }
        controller.add(probeHandler, name: "chorusDarkProbe")
        darkProbeHandlers[instance.id] = probeHandler

        // Registered in Dark Reader's ISOLATED world, not the page world:
        // the export script that posts here runs in that world (it needs
        // `window.DarkReader`), and `window.webkit.messageHandlers` is scoped
        // per content world — a page-world registration would be invisible to
        // it, so the message would silently throw and the cache would never
        // populate. This also keeps the handler out of the page's own reach.
        let export = onDarkCSSExport
        let cacheHandler = DarkCSSCacheMessageHandler(serviceID: instance.id) { id, css in
            export?(id, css)
        }
        controller.add(cacheHandler, contentWorld: DarkReaderSupport.world, name: "chorusDarkCSSCache")
        darkCSSCacheHandlers[instance.id] = cacheHandler
    }

    /// Adds all user scripts. Safe to call again after `removeAllUserScripts()`
    /// to re-bake state (e.g. the Dark Reader theme scripts or the detection
    /// probe) so the next full navigation is correct. `darkInjection` selects
    /// what dark-theming scripts to bake.
    func installUserScripts(
        for instance: ServiceInstance,
        customCSS: String?,
        darkInjection: DarkReaderSupport.DarkInjection,
        cachedDarkCSS: String? = nil,
        on controller: WKUserContentController
    ) {
        let notificationScript = makeNotificationInterceptionScript(serviceID: instance.id.uuidString)
        let userScript = WKUserScript(
            source: notificationScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(userScript)

        // Page Visibility override — makes preloaded/off-screen views report as
        // "visible" so services that only write their unread count into the
        // title while visible (WhatsApp, Messenger, Discord, …) still surface it
        // for the badge. Focus is intentionally left untouched.
        let visibilityScript = WKUserScript(
            source: Self.makeVisibilityOverrideScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(visibilityScript)

        // WebRTC call detection — hooks RTCPeerConnection to track active calls
        let callDetectionScript = WKUserScript(
            source: Self.makeCallDetectionScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(callDetectionScript)

        if autoDismissCookieBanners {
            let cookieScript = WKUserScript(
                source: CookieConsentManager.makeConsentDismissalScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            controller.addUserScript(cookieScript)
        }

        // Per-service custom CSS (e.g. LinkedIn's messaging-only view). Injected
        // at document start so the page never flashes its unstyled layout, and
        // only when there's actually CSS to apply.
        if let customCSS, !customCSS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cssScript = WKUserScript(
                source: Self.makeCSSInjectionScript(css: customCSS),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            controller.addUserScript(cssScript)
        }

        // Dark theming. `.themed` injects Dark Reader into an ISOLATED world so
        // its window.chrome stub and DarkReader global never reach the site (the
        // shared DOM means the theme it injects still applies), with an anti-flash
        // background and enable baked in. `.probe` injects a tiny background
        // sampler to decide whether an auto service needs theming. `.none` adds
        // nothing.
        switch darkInjection {
        case .none:
            break
        case .themed:
            // On a cache hit the cached theme paints the page dark at
            // document-start, so the cover only needs to bridge Dark Reader
            // taking over — a short settle, not the multi-second hold a cold,
            // washed first pass needs.
            let hasCache = cachedDarkCSS != nil
            controller.addUserScript(WKUserScript(
                source: DarkReaderSupport.antiFlashScript(settleCapMs: hasCache ? 900 : 6000),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: DarkReaderSupport.world
            ))
            // Cached generated CSS first: it paints dark immediately so the user
            // never sees Dark Reader's washed first pass. Dynamic Dark Reader
            // then runs on top to catch anything the snapshot missed, and the
            // export script drops this static style once it has taken over.
            if let cachedDarkCSS {
                controller.addUserScript(WKUserScript(
                    source: Self.makeCachedDarkStyleScript(css: cachedDarkCSS),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: DarkReaderSupport.world
                ))
            }
            controller.addUserScript(WKUserScript(
                source: DarkReaderSupport.libraryJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: DarkReaderSupport.world
            ))
            controller.addUserScript(WKUserScript(
                source: DarkReaderSupport.bootstrapScript(enable: true),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: DarkReaderSupport.world
            ))
            // After the live pass settles, export the generated CSS to refresh
            // the cache (and populate it on the first-ever, cache-miss load).
            controller.addUserScript(WKUserScript(
                source: Self.makeDarkCSSExportScript(serviceID: instance.id.uuidString),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: DarkReaderSupport.world
            ))
        case .probe:
            // The app is dark (probe is only chosen when appDark), and this load
            // will end up either themed by Dark Reader or showing the site's own
            // dark theme — either way cover it so the user doesn't watch the light
            // page while the probe samples and the verdict comes back.
            controller.addUserScript(WKUserScript(
                source: DarkReaderSupport.antiFlashScript(deferReveal: true),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: DarkReaderSupport.world
            ))
            controller.addUserScript(WKUserScript(
                source: Self.makeDarkProbeScript(serviceID: instance.id.uuidString),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
    }

    /// Builds a script that injects `css` into the page as a `<style>` element.
    /// The CSS is JSON-encoded into a JS string literal so quotes, newlines, and
    /// backslashes can't break out of the script. The style node carries a stable
    /// id and is reused if already present, so re-injection can never stack.
    nonisolated static func makeCSSInjectionScript(css: String) -> String {
        let literal: String
        if let data = try? JSONEncoder().encode(css),
           let json = String(data: data, encoding: .utf8) {
            literal = json
        } else {
            // Encoding a String basically never fails, but if it did we'd inject
            // an empty style and silently lose the user's CSS — log so it isn't
            // a mystery.
            AppLogger.general.warning("Custom CSS could not be JSON-encoded; injecting no CSS for this service")
            literal = "\"\""
        }
        return """
        (function() {
            var CSS = \(literal);
            var existing = document.getElementById('chorus-custom-css');
            if (existing) { existing.textContent = CSS; return; }
            var style = document.createElement('style');
            style.id = 'chorus-custom-css';
            style.textContent = CSS;
            (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    func removeHandler(for instanceID: UUID) {
        messageHandlers.removeValue(forKey: instanceID)
        darkProbeHandlers.removeValue(forKey: instanceID)
        darkCSSCacheHandlers.removeValue(forKey: instanceID)
    }

    /// Encodes a Swift string as a JS string literal (quotes included) so it can
    /// be interpolated into a script without breaking out of the surrounding
    /// literal. Falls back to `""`. Used for the service id baked into the probe
    /// and notification scripts — a UUID today, but encode it so it stays safe
    /// regardless of what feeds it.
    nonisolated static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }

    /// Samples the page background after load and reports its color to the
    /// `chorusDarkProbe` handler, which decides whether the site lacks a dark
    /// theme. The service id is baked in. Reads `<body>` first, falling back to
    /// `<html>` when the body background is transparent.
    ///
    /// A single fixed timeout misreads slow single-page apps: they paint a
    /// transparent/light frame first and only settle into their own dark theme a
    /// second or two later, so a one-shot early sample reports "light" and Dark
    /// Reader wrongly themes an already-dark app. So this polls on a widening
    /// schedule and reports once the reading has settled: as soon as an opaque
    /// *dark* background appears it reports immediately (the app themed itself),
    /// otherwise it keeps the latest opaque sample and reports that at the end
    /// (falling back to white if the page never painted an opaque background).
    /// The verdict is cached after the first report, so this cost is paid once.
    nonisolated static func makeDarkProbeScript(serviceID: String) -> String {
        """
        (function() {
            var attempts = [300, 700, 1500, 3000, 5000];
            var i = 0;
            var lastOpaque = null;
            var done = false;
            function rgba(el) {
                if (!el) return null;
                var c = getComputedStyle(el).backgroundColor || "";
                var m = c.match(/rgba?\\(([^)]+)\\)/);
                if (!m) return null;
                var p = m[1].split(',').map(function(x){ return parseFloat(x.trim()); });
                return { r: p[0]||0, g: p[1]||0, b: p[2]||0, a: (p.length > 3 ? p[3] : 1) };
            }
            function relativeLuminance(c) {
                return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255.0;
            }
            function report(bg) {
                if (done) return;
                done = true;
                try {
                    window.webkit.messageHandlers.chorusDarkProbe.postMessage(JSON.stringify({
                        serviceID: \(jsStringLiteral(serviceID)), r: bg.r, g: bg.g, b: bg.b, a: bg.a
                    }));
                } catch (e) {}
            }
            function tick() {
                try {
                    var bg = rgba(document.body);
                    if (!bg || bg.a < 0.5) { var h = rgba(document.documentElement); if (h) bg = h; }
                    if (bg && bg.a >= 0.5) {
                        lastOpaque = bg;
                        // An opaque dark background means the app themed itself — settle now.
                        if (relativeLuminance(bg) <= 0.5) { report(bg); return; }
                    }
                } catch (e) {}
                i++;
                if (i < attempts.length) {
                    setTimeout(tick, attempts[i] - attempts[i - 1]);
                } else {
                    report(lastOpaque || { r: 255, g: 255, b: 255, a: 1 });
                }
            }
            setTimeout(tick, attempts[0]);
        })();
        """
    }

    /// Injects a service's cached Dark Reader theme as a `<style>` at
    /// document-start, so a themed page paints dark immediately instead of
    /// flashing light while the live Dark Reader pass computes the theme. The
    /// CSS is JSON-encoded into a JS string literal so it can't break out of the
    /// script. The node carries a stable id and is reused if already present, so
    /// re-injection can't stack; `DarkReaderSupport.disableJS` and the export
    /// script remove it by that id once live theming owns the page.
    nonisolated static func makeCachedDarkStyleScript(css: String) -> String {
        """
        (function() {
            var CSS = \(jsStringLiteral(css));
            var ID = \(jsStringLiteral(DarkReaderSupport.cacheStyleID));
            var existing = document.getElementById(ID);
            if (existing) { existing.textContent = CSS; return; }
            var style = document.createElement('style');
            style.id = ID;
            style.textContent = CSS;
            (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    /// Runs at document-end in Dark Reader's isolated world. Once the live pass
    /// has enabled and settled, it exports the generated theme CSS and posts it
    /// to the `chorusDarkCSSCache` handler so it can be cached for the next load,
    /// then removes the static cached-theme style (dynamic Dark Reader now owns
    /// theming, so a stale snapshot must not linger over the live rules). Retries
    /// a few times because `enable()` finishes its first pass a beat after the
    /// document is ready.
    nonisolated static func makeDarkCSSExportScript(serviceID: String) -> String {
        """
        (function() {
            var SID = \(jsStringLiteral(serviceID));
            function attempt(triesLeft) {
                var DR = window.DarkReader;
                if (!DR || typeof DR.exportGeneratedCSS !== 'function' ||
                    (typeof DR.isEnabled === 'function' && !DR.isEnabled())) {
                    if (triesLeft > 0) setTimeout(function() { attempt(triesLeft - 1); }, 1000);
                    return;
                }
                Promise.resolve(DR.exportGeneratedCSS()).then(function(css) {
                    if (!css) return;
                    try {
                        window.webkit.messageHandlers.chorusDarkCSSCache.postMessage(
                            JSON.stringify({ serviceID: SID, css: css }));
                    } catch (e) {}
                    // Drop the static snapshot only once Dark Reader's own style
                    // nodes are in the DOM, so the live pass has actually taken
                    // over the page — removing it earlier (on `isEnabled()` alone,
                    // which only means enable() was called) could flash lighter
                    // areas the live pass hasn't reached yet. If they aren't there
                    // yet, leave the snapshot in place; `disableJS` and the next
                    // load clean it up.
                    if (document.querySelector('.darkreader--sync, .darkreader--fallback, .darkreader--override')) {
                        var cached = document.getElementById(\(jsStringLiteral(DarkReaderSupport.cacheStyleID)));
                        if (cached) cached.remove();
                    }
                }).catch(function() {});
            }
            // The first pass is usually done a couple of seconds after the DOM is
            // ready; give it time, then retry a few times if not yet enabled.
            setTimeout(function() { attempt(5); }, 2500);
        })();
        """
    }

    /// JavaScript that can be evaluated to check if a WebRTC call is active.
    /// Returns `true` if any RTCPeerConnection is in a connected/active state.
    nonisolated static let callDetectionQueryJS = "window.__chorusActiveCall === true"

    /// Reports the page as visible even when its web view is preloaded/off-screen,
    /// so services that gate their unread-count title updates on Page Visibility
    /// (WhatsApp, Messenger, Discord, …) still surface the count for the badge.
    ///
    /// Deliberately does NOT fake `document.hasFocus()` — it stays false for a
    /// background view — so apps that gate desktop notifications on *focus* keep
    /// firing them, preserving Chorus's `window.Notification` forwarding.
    static func makeVisibilityOverrideScript() -> String {
        return """
        (function() {
            try {
                Object.defineProperty(document, 'visibilityState', {
                    configurable: true,
                    get: function() { return 'visible'; }
                });
                Object.defineProperty(document, 'hidden', {
                    configurable: true,
                    get: function() { return false; }
                });
                // Swallow real visibilitychange events so a page can't react to
                // the view actually going off-screen and revert to "hidden"
                // behavior; the overridden getters keep reporting visible.
                document.addEventListener('visibilitychange', function(e) {
                    e.stopImmediatePropagation();
                }, true);
            } catch (e) {}
        })();
        """
    }

    /// Hooks RTCPeerConnection to detect active voice/video calls.
    /// Sets `window.__chorusActiveCall = true` when a connection is active,
    /// and `false` when all connections close.
    private static func makeCallDetectionScript() -> String {
        return """
        (function() {
            if (!window.RTCPeerConnection) return;

            var OrigRTC = window.RTCPeerConnection;
            var activePeers = new Set();
            var frameId = Math.random().toString(36).substr(2, 9);

            window.__chorusActiveCall = false;

            // Aggregate call state onto the top frame, keyed by frame, so a call
            // running inside a same-origin iframe is still seen by the pool's
            // main-frame check (evaluateJavaScript runs in the main frame only).
            // Cross-origin frames can't reach window.top (property access
            // throws), so they fall back to their own flag — an inherent limit.
            function updateCallState() {
                var active = activePeers.size > 0;
                try {
                    var top = window.top || window;
                    if (!top.__chorusCallFrames) top.__chorusCallFrames = {};
                    if (active) {
                        top.__chorusCallFrames[frameId] = true;
                    } else {
                        delete top.__chorusCallFrames[frameId];
                    }
                    top.__chorusActiveCall = Object.keys(top.__chorusCallFrames).length > 0;
                } catch (e) {
                    window.__chorusActiveCall = active;
                }
            }

            window.RTCPeerConnection = function() {
                var pc = new (Function.prototype.bind.apply(OrigRTC, [null].concat(Array.from(arguments))))();
                var id = Math.random().toString(36).substr(2, 9);

                pc.addEventListener('connectionstatechange', function() {
                    if (pc.connectionState === 'connected') {
                        activePeers.add(id);
                    } else if (pc.connectionState === 'closed' ||
                               pc.connectionState === 'failed' ||
                               pc.connectionState === 'disconnected') {
                        activePeers.delete(id);
                    }
                    updateCallState();
                });

                pc.addEventListener('iceconnectionstatechange', function() {
                    if (pc.iceConnectionState === 'connected' ||
                        pc.iceConnectionState === 'completed') {
                        activePeers.add(id);
                    } else if (pc.iceConnectionState === 'closed' ||
                               pc.iceConnectionState === 'failed' ||
                               pc.iceConnectionState === 'disconnected') {
                        activePeers.delete(id);
                    }
                    updateCallState();
                });

                return pc;
            };

            window.RTCPeerConnection.prototype = OrigRTC.prototype;
            Object.keys(OrigRTC).forEach(function(key) {
                window.RTCPeerConnection[key] = OrigRTC[key];
            });
        })();
        """
    }

    private func makeNotificationInterceptionScript(serviceID: String) -> String {
        return """
        (function() {
            var OrigNotification = window.Notification;
            window.Notification = function(title, options) {
                window.webkit.messageHandlers.chorusNotification.postMessage(
                    JSON.stringify({
                        title: title,
                        body: (options && options.body) || '',
                        icon: (options && options.icon) || '',
                        tag: (options && options.tag) || '',
                        serviceID: \(Self.jsStringLiteral(serviceID))
                    })
                );
                return new OrigNotification(title, options);
            };
            Object.defineProperty(window.Notification, 'permission', {
                get: function() { return 'granted'; }
            });
            window.Notification.requestPermission = function(cb) {
                if (cb) cb('granted');
                return Promise.resolve('granted');
            };
        })();
        """
    }
}

final class NotificationMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    let serviceID: UUID
    let isMutedCheck: @Sendable (UUID) -> Bool
    let notifyOSCheck: @Sendable (UUID) -> Bool
    let isDoNotDisturbCheck: @Sendable () -> Bool

    init(
        serviceID: UUID,
        isMutedCheck: @escaping @Sendable (UUID) -> Bool,
        notifyOSCheck: @escaping @Sendable (UUID) -> Bool,
        isDoNotDisturbCheck: @escaping @Sendable () -> Bool
    ) {
        self.serviceID = serviceID
        self.isMutedCheck = isMutedCheck
        self.notifyOSCheck = notifyOSCheck
        self.isDoNotDisturbCheck = isDoNotDisturbCheck
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "chorusNotification" else { return }

        // Only accept notifications from the service's own origin — the main
        // frame, or a same-origin subframe. The interception script runs in all
        // frames (some services fire notifications from a subframe), so without
        // this gate a cross-origin ad/tracker iframe could post a native
        // notification with attacker-controlled title/body attributed to the
        // trusted service (spoofing / phishing).
        let frame = message.frameInfo
        if !frame.isMainFrame {
            // Compare the full origin (scheme + host + port), not just the host:
            // a same-host subframe on a different scheme/port is a different
            // origin and must not post a notification attributed to the service.
            let origin = frame.securityOrigin
            guard let mainURL = message.webView?.url,
                  let mainScheme = mainURL.scheme?.lowercased(),
                  let mainHost = mainURL.host,
                  !origin.host.isEmpty,
                  origin.protocol.lowercased() == mainScheme,
                  origin.host == mainHost
            else { return }
            // WKSecurityOrigin reports 0 for the scheme's default port; URL
            // reports nil. Normalize both before comparing.
            let defaultPort = mainScheme == "https" ? 443 : 80
            let originPort = origin.port == 0 ? defaultPort : origin.port
            let mainPort = mainURL.port ?? defaultPort
            guard originPort == mainPort else { return }
        }

        guard let jsonString = message.body as? String,
              let data = jsonString.data(using: .utf8)
        else { return }

        let payload: NotificationPayload
        do {
            payload = try JSONDecoder().decode(NotificationPayload.self, from: data)
        } catch {
            AppLogger.notifications.error("Failed to decode notification payload: \(error.localizedDescription)")
            return
        }

        guard NotificationManager.shouldPostOSNotification(
            isMuted: isMutedCheck(serviceID),
            notifyOS: notifyOSCheck(serviceID),
            doNotDisturb: isDoNotDisturbCheck()
        ) else { return }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.userInfo = ["serviceID": serviceID.uuidString]
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLogger.notifications.error("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Custom CSS presets and per-service defaults

/// Baked-in default CSS for known catalog services, plus the rule that decides
/// what actually gets injected for a service. Kept as pure functions so the
/// resolution logic is unit-testable without a running web view.
enum ServiceCSSDefaults {
    /// The default CSS shipped for a catalog service, or nil when it has none.
    static func css(forCatalogID id: String?) -> String? {
        switch id {
        case "linkedin": return linkedInMessaging
        default: return nil
        }
    }

    /// The CSS to inject for a service: the instance's own CSS when set,
    /// otherwise the baked-in default. A blank result injects nothing — an
    /// explicit "no CSS" override.
    static func effectiveCSS(instanceCSS: String?, catalogID: String?) -> String? {
        let raw = instanceCSS ?? css(forCatalogID: catalogID)
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return raw
    }

    /// Trims LinkedIn down to just its messaging pane, filling the window like a
    /// dedicated chat app: hides the global nav and right rail, and expands the
    /// conversation list + thread to full width and height. Selectors are
    /// LinkedIn's stable semantic names, verified against the live page.
    static let linkedInMessaging = """
    #global-nav, .global-nav { display: none !important; }
    .authentication-outlet { padding-top: 0 !important; }
    /* Fill the window by chaining height:100% from html all the way down to the
       message panes — not 100vh, which binds to the WKWebView's initial zero
       frame and never recomputes, and not flex/grid stretch, which doesn't hold
       at every LinkedIn breakpoint (its content row is block, not grid, when
       narrow). Scoped with :has(#messaging)/#messaging so only the messaging
       page is height-constrained, never the feed. Responsive at any size. */
    html:has(#messaging), body:has(#messaging) { height: 100% !important; }
    .application-outlet:has(#messaging), .authentication-outlet:has(#messaging) { height: 100% !important; }
    #messaging.scaffold-layout,
    #messaging .scaffold-layout__inner,
    #messaging .scaffold-layout__content,
    #messaging .scaffold-layout__list-detail,
    #messaging .scaffold-layout__list-detail-container,
    #messaging .scaffold-layout__list-detail-inner,
    #messaging .scaffold-layout__detail { height: 100% !important; }
    .scaffold-layout__inner { margin-left: 0 !important; margin-right: 0 !important; max-width: none !important; width: 100% !important; }
    /* Single column, and kill the grid column-gap: when the right rail is hidden
       its grid track collapses to 0 but the gap stays, leaving a gray strip on
       the right (most visible when zoomed out into the wide breakpoint). */
    .scaffold-layout__content { grid-template-columns: minmax(0, 1fr) !important; column-gap: 0 !important; grid-column-gap: 0 !important; margin-top: 0 !important; }
    .scaffold-layout__aside { display: none !important; }
    .scaffold-layout__content, .scaffold-layout__list-detail, .scaffold-layout__list-detail-container, .scaffold-layout__list-detail-inner { max-width: none !important; width: 100% !important; }
    .msg-overlay-list-bubble, .msg-overlay { display: none !important; }
    """
}

private struct DarkProbePayload: Codable {
    let serviceID: String
    let r: Double
    let g: Double
    let b: Double
    let a: Double
}

private struct DarkCSSCachePayload: Codable {
    let serviceID: String
    let css: String
}

/// Receives a themed service's exported Dark Reader CSS and forwards it for
/// caching, keyed by the service it came from.
final class DarkCSSCacheMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    let serviceID: UUID
    let onExport: @Sendable (UUID, String) -> Void

    init(serviceID: UUID, onExport: @escaping @Sendable (UUID, String) -> Void) {
        self.serviceID = serviceID
        self.onExport = onExport
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Main frame only — a subframe must not poison a service's theme cache.
        guard message.name == "chorusDarkCSSCache", message.frameInfo.isMainFrame else { return }
        guard let jsonString = message.body as? String,
              let data = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DarkCSSCachePayload.self, from: data),
              payload.serviceID == serviceID.uuidString
        else { return }
        onExport(serviceID, payload.css)
    }
}

/// Receives a service's background-color sample from its detection probe and
/// classifies whether the site lacks its own dark theme, forwarding the verdict.
final class DarkProbeMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    let serviceID: UUID
    let onVerdict: @Sendable (UUID, Bool) -> Void

    init(serviceID: UUID, onVerdict: @escaping @Sendable (UUID, Bool) -> Void) {
        self.serviceID = serviceID
        self.onVerdict = onVerdict
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Main frame only — a subframe must not spoof a verdict for the service.
        guard message.name == "chorusDarkProbe", message.frameInfo.isMainFrame else { return }
        guard let jsonString = message.body as? String,
              let data = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DarkProbePayload.self, from: data),
              payload.serviceID == serviceID.uuidString
        else { return }
        let lacksDark = DarkReaderSupport.classifyLacksDark(
            r: payload.r, g: payload.g, b: payload.b, a: payload.a
        )
        onVerdict(serviceID, lacksDark)
    }
}
