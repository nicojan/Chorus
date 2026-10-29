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
    var isServiceMuted: (@Sendable (UUID) -> Bool)?
    /// Per-service "forward notifications to macOS" flag. Defaults to true when
    /// unset, preserving behavior for services that predate the toggle.
    var isServiceNotifyingOS: (@Sendable (UUID) -> Bool)?
    var isDoNotDisturbActive: (@Sendable () -> Bool)?
    /// The service's label, shown on each notification it posts.
    var serviceLabel: (@Sendable (UUID) -> String?)?
    var autoDismissCookieBanners: Bool = true

    /// Full setup for a freshly built web view: the message handlers (added once)
    /// plus all user scripts.
    func configureScripts(
        for serviceID: UUID,
        customCSS: String?,
        darkInjection: DarkReaderSupport.DarkInjection,
        stayActiveInBackground: Bool,
        on controller: WKUserContentController
    ) {
        installHandlers(for: serviceID, on: controller)
        installUserScripts(
            for: serviceID,
            customCSS: customCSS,
            darkInjection: darkInjection,
            stayActiveInBackground: stayActiveInBackground,
            on: controller
        )
    }

    /// Registers the message handlers. Called once when the web view is built —
    /// NOT on reinstall, since `removeAllUserScripts()` leaves message handlers in
    /// place and re-adding would throw.
    func installHandlers(for serviceID: UUID, on controller: WKUserContentController) {
        let mutedCheck = isServiceMuted
        let notifyOSCheck = isServiceNotifyingOS
        let dndCheck = isDoNotDisturbActive
        let labelLookup = serviceLabel
        let handler = NotificationMessageHandler(
            serviceID: serviceID,
            labelLookup: { id in
                labelLookup?(id) ?? nil
            },
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
    }

    /// Adds all user scripts. Safe to call again after `removeAllUserScripts()`
    /// to re-bake state (e.g. the Dark Reader theme scripts) so the next full
    /// navigation is correct. `darkInjection` selects what dark-theming scripts
    /// to bake.
    func installUserScripts(
        for serviceID: UUID,
        customCSS: String?,
        darkInjection: DarkReaderSupport.DarkInjection,
        stayActiveInBackground: Bool,
        on controller: WKUserContentController
    ) {
        let notificationScript = makeNotificationInterceptionScript(serviceID: serviceID.uuidString)
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

        // IndexedDB write count, which quit waits on. Main frame only, since
        // quit reads it with `evaluateJavaScript`, which only reaches that frame.
        controller.addUserScript(WKUserScript(
            source: Self.makeWriteTrackerScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        // Focus override (opt-in per service) — reports the page as focused even
        // while Chorus is in the background, so a service that flips presence to
        // "away" on window blur (Microsoft Teams) keeps showing the user active.
        // Off unless the service opted in, because faking focus can make a site
        // hold back the notifications Chorus forwards.
        if stayActiveInBackground {
            let focusScript = WKUserScript(
                source: Self.makeFocusOverrideScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            controller.addUserScript(focusScript)
        }

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
        // background and enable baked in. `.none` adds nothing.
        switch darkInjection {
        case .none:
            break
        case .themed:
            controller.addUserScript(WKUserScript(
                source: DarkReaderSupport.antiFlashScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: DarkReaderSupport.world
            ))
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
    ///
    /// The override has one way out, for quitting. Pages save their state when
    /// they go hidden — WhatsApp Web writes its session then — and an app that
    /// quits kills its pages without a `visibilitychange` or a `pagehide`. With
    /// the page pinned to visible it never got a save point at all, and WhatsApp
    /// could come back signed out. `quitReleaseJS` calls the function below,
    /// which lets the page go hidden and sends it both events.
    static func makeVisibilityOverrideScript() -> String {
        return """
        (function() {
            try {
                var released = false;
                Object.defineProperty(document, 'visibilityState', {
                    configurable: true,
                    get: function() { return released ? 'hidden' : 'visible'; }
                });
                Object.defineProperty(document, 'hidden', {
                    configurable: true,
                    get: function() { return released; }
                });
                // Swallow real visibilitychange events so a page can't react to
                // the view actually going off-screen and revert to "hidden"
                // behavior; the overridden getters keep reporting visible.
                document.addEventListener('visibilitychange', function(e) {
                    if (!released) { e.stopImmediatePropagation(); }
                }, true);
                Object.defineProperty(window, '__chorusReleaseForQuit', {
                    configurable: false,
                    enumerable: false,
                    value: function() {
                        if (released) { return; }
                        released = true;
                        document.dispatchEvent(new Event('visibilitychange', { bubbles: true }));
                        window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: false }));
                    }
                });
            } catch (e) {}
        })();
        """
    }

    /// Evaluated in each live page just before quit. See
    /// `makeVisibilityOverrideScript`.
    nonisolated static let quitReleaseJS = "window.__chorusReleaseForQuit && window.__chorusReleaseForQuit(); true"

    /// Counts the page's IndexedDB writes that have not finished: write and
    /// upgrade transactions until they complete or abort, and database opens
    /// and deletes until they succeed, fail or block. Quit waits for the count
    /// to reach zero, since quitting kills any write still under way. See
    /// `WriteSettle`.
    static func makeWriteTrackerScript() -> String {
        return """
        (function() {
            try {
                if (!window.IDBDatabase || !window.IDBFactory || window.__chorusPendingWrites) { return; }
                var pending = 0;
                function track(target, events) {
                    pending++;
                    var done = false;
                    function finish() {
                        if (done) { return; }
                        done = true;
                        pending--;
                    }
                    for (var i = 0; i < events.length; i++) {
                        target.addEventListener(events[i], finish);
                    }
                }
                var transaction = IDBDatabase.prototype.transaction;
                IDBDatabase.prototype.transaction = function(names, mode) {
                    var tx = transaction.apply(this, arguments);
                    if (mode === 'readwrite') { track(tx, ['complete', 'abort']); }
                    return tx;
                };
                ['open', 'deleteDatabase'].forEach(function(name) {
                    var original = IDBFactory.prototype[name];
                    IDBFactory.prototype[name] = function() {
                        var request = original.apply(this, arguments);
                        track(request, ['success', 'error', 'blocked']);
                        return request;
                    };
                });
                Object.defineProperty(window, '__chorusPendingWrites', {
                    configurable: false,
                    enumerable: false,
                    value: function() { return pending; }
                });
            } catch (e) {}
        })();
        """
    }

    /// Evaluated in each live page while quit waits. See
    /// `makeWriteTrackerScript`.
    nonisolated static let pendingWritesJS = "window.__chorusPendingWrites ? window.__chorusPendingWrites() : 0"

    /// Reports the page as focused even when its web view is in the background,
    /// so a service that flips your status to "away"/"idle" on window blur
    /// (Microsoft Teams) keeps showing you active. Opt-in per service — see
    /// `WebSurface.staysActiveInBackground`.
    ///
    /// Overrides `document.hasFocus()` to true and swallows real `blur` events on
    /// both window and document (capture phase, before the page's own handlers)
    /// so a page can't start its idle timer when Chorus loses focus. Pairs with
    /// the always-visible override so both halves of the "is the user here?"
    /// check read active.
    static func makeFocusOverrideScript() -> String {
        return """
        (function() {
            try {
                Object.defineProperty(document, 'hasFocus', {
                    configurable: true,
                    value: function() { return true; }
                });
                // Swallow ONLY the top-level blur that fires when the whole
                // window/document loses focus (the app going to the background).
                // A form field losing focus fires its own blur that captures
                // down through this same window listener; killing those too would
                // break dropdowns, draft saving, and validation across the page,
                // so guard on the event target being the window or document.
                var swallow = function(e) {
                    if (e.target === window || e.target === document) {
                        e.stopImmediatePropagation();
                    }
                };
                window.addEventListener('blur', swallow, true);
                document.addEventListener('blur', swallow, true);
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

    /// Intercepts the two ways a page raises a notification and forwards each to
    /// the native handler.
    ///
    /// The replacement has to keep the `Notification` contract intact, which the
    /// first version of this script did not. It assigned a bare function over
    /// `window.Notification` without carrying `prototype` or the statics across,
    /// so `n instanceof Notification` was false and everything on the
    /// constructor except the two properties re-declared here disappeared — a
    /// site that feature-detects either way saw a broken API. The
    /// `RTCPeerConnection` shim in this same file already does both; this now
    /// matches it.
    ///
    /// `ServiceWorkerRegistration.prototype.showNotification` is the other path,
    /// and it was not covered at all. Modern web apps raise notifications
    /// through it rather than through `new Notification`, so those never reached
    /// Chorus. **This covers the page-side call only.** A notification raised
    /// from inside the service worker — the push path — runs in a worker context
    /// no page script can enter, and is still not intercepted.
    ///
    /// The original constructor is still called so the page gets a real
    /// `Notification` back to hold `onclick`/`close()` on. That cannot double up
    /// today: WebKit only delivers web notifications to an app that adopts the
    /// `WKUIDelegate` notification methods, and Chorus adopts none of them, so
    /// the original object is inert for display.
    private func makeNotificationInterceptionScript(serviceID: String) -> String {
        return """
        (function() {
            var SERVICE_ID = \(Self.jsStringLiteral(serviceID));

            function forward(title, options) {
                try {
                    window.webkit.messageHandlers.chorusNotification.postMessage(
                        JSON.stringify({
                            title: title == null ? '' : String(title),
                            body: (options && options.body) || '',
                            icon: (options && options.icon) || '',
                            tag: (options && options.tag) || '',
                            serviceID: SERVICE_ID
                        })
                    );
                } catch (e) {
                    // A page that has torn down the bridge must not take the
                    // site's own notification call down with it.
                }
            }

            var OrigNotification = window.Notification;
            if (OrigNotification) {
                var ChorusNotification = function(title, options) {
                    forward(title, options);
                    return new OrigNotification(title, options);
                };

                // Same prototype object, so `instanceof Notification` holds for
                // instances the original constructor returns.
                ChorusNotification.prototype = OrigNotification.prototype;

                // Carry every static across, descriptors and all, before the two
                // overrides below replace the ones Chorus answers itself.
                Object.getOwnPropertyNames(OrigNotification).forEach(function(key) {
                    if (key === 'prototype' || key === 'name' || key === 'length') return;
                    try {
                        var descriptor = Object.getOwnPropertyDescriptor(OrigNotification, key);
                        if (descriptor) Object.defineProperty(ChorusNotification, key, descriptor);
                    } catch (e) {}
                });

                Object.defineProperty(ChorusNotification, 'permission', {
                    get: function() { return 'granted'; },
                    configurable: true
                });
                ChorusNotification.requestPermission = function(cb) {
                    if (cb) cb('granted');
                    return Promise.resolve('granted');
                };

                window.Notification = ChorusNotification;
            }

            if (window.ServiceWorkerRegistration &&
                window.ServiceWorkerRegistration.prototype &&
                window.ServiceWorkerRegistration.prototype.showNotification) {
                var origShow = window.ServiceWorkerRegistration.prototype.showNotification;
                window.ServiceWorkerRegistration.prototype.showNotification = function(title, options) {
                    forward(title, options);
                    return origShow.apply(this, arguments);
                };
            }
        })();
        """
    }
}

final class NotificationMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    /// Whether an intercepted web notification goes on to macOS. It fires only
    /// when the service is not muted, has OS notifications on, and Do Not
    /// Disturb is off. Pure, so the policy is unit-testable.
    nonisolated static func shouldPostOSNotification(
        isMuted: Bool,
        notifyOS: Bool,
        doNotDisturb: Bool
    ) -> Bool {
        !isMuted && notifyOS && !doNotDisturb
    }

    let serviceID: UUID
    let labelLookup: @Sendable (UUID) -> String?
    let isMutedCheck: @Sendable (UUID) -> Bool
    let notifyOSCheck: @Sendable (UUID) -> Bool
    let isDoNotDisturbCheck: @Sendable () -> Bool

    /// The last notification posted and when. A service's tab runs the same
    /// interception script as its page, so a chat open in both fires each
    /// notification twice. Only touched from `didReceive`, on the main thread.
    private var lastPosted: (key: String, at: Date)?

    /// How close together two identical notifications must be to count as one.
    static let duplicateWindow: TimeInterval = 3

    /// Whether a notification repeats the last one posted, within the window.
    static func isDuplicate(key: String, last: (key: String, at: Date)?, now: Date) -> Bool {
        guard let last else { return false }
        return last.key == key && now.timeIntervalSince(last.at) < duplicateWindow
    }

    /// When this page's last notifications were posted, newest last, for the
    /// rate limit. Only touched from `didReceive`, on the main thread.
    private var recentPosts: [Date] = []

    /// At most this many notifications from one page within `rateWindow`. A
    /// page can call `new Notification` in a loop; a chat that bursts a few
    /// messages at once stays under it.
    static let rateLimit = 5
    static let rateWindow: TimeInterval = 10

    /// Whether one more notification would pass the rate limit, given when the
    /// recent ones were posted.
    static func isRateLimited(recent: [Date], now: Date) -> Bool {
        recent.filter { now.timeIntervalSince($0) < rateWindow }.count >= rateLimit
    }

    /// The longest title and body a notification keeps. A page sets both, and
    /// nothing on screen needs more.
    static let maxTitleLength = 200
    static let maxBodyLength = 1000

    init(
        serviceID: UUID,
        labelLookup: @escaping @Sendable (UUID) -> String?,
        isMutedCheck: @escaping @Sendable (UUID) -> Bool,
        notifyOSCheck: @escaping @Sendable (UUID) -> Bool,
        isDoNotDisturbCheck: @escaping @Sendable () -> Bool
    ) {
        self.serviceID = serviceID
        self.labelLookup = labelLookup
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

        guard Self.shouldPostOSNotification(
            isMuted: isMutedCheck(serviceID),
            notifyOS: notifyOSCheck(serviceID),
            doNotDisturb: isDoNotDisturbCheck()
        ) else { return }

        let key = payload.title + "\u{0}" + payload.body
        let now = Date()
        guard !Self.isDuplicate(key: key, last: lastPosted, now: now) else { return }
        guard !Self.isRateLimited(recent: recentPosts, now: now) else {
            AppLogger.notifications.info("Dropped a notification: the page is posting faster than \(Self.rateLimit) in \(Int(Self.rateWindow)) s")
            return
        }
        lastPosted = (key, now)
        recentPosts = recentPosts.filter { now.timeIntervalSince($0) < Self.rateWindow } + [now]

        let content = UNMutableNotificationContent()
        content.title = String(payload.title.prefix(Self.maxTitleLength))
        content.body = String(payload.body.prefix(Self.maxBodyLength))
        // The page writes the title and body, so it could claim to be any
        // service. The subtitle is Chorus's own: the service it came from.
        content.subtitle = labelLookup(serviceID) ?? ""
        content.threadIdentifier = serviceID.uuidString
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
