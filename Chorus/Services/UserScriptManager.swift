import WebKit
import UserNotifications

struct NotificationPayload: Codable {
    let title: String
    let body: String
    let icon: String
    let tag: String
    let serviceID: String
}

final class UserScriptManager {
    private var messageHandlers: [UUID: NotificationMessageHandler] = [:]

    var isServiceMuted: (@Sendable (UUID) -> Bool)?
    /// Per-service "forward notifications to macOS" flag. Defaults to true when
    /// unset, preserving behavior for services that predate the toggle.
    var isServiceNotifyingOS: (@Sendable (UUID) -> Bool)?
    var isDoNotDisturbActive: (@Sendable () -> Bool)?
    var autoDismissCookieBanners: Bool = true

    func configureScripts(
        for instance: ServiceInstance,
        customCSS: String?,
        on controller: WKUserContentController
    ) {
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
    }

    /// Builds a script that injects `css` into the page as a `<style>` element.
    /// The CSS is JSON-encoded into a JS string literal so quotes, newlines, and
    /// backslashes can't break out of the script. The style node carries a stable
    /// id and is reused if already present, so re-injection can never stack.
    static func makeCSSInjectionScript(css: String) -> String {
        let literal: String
        if let data = try? JSONEncoder().encode(css),
           let json = String(data: data, encoding: .utf8) {
            literal = json
        } else {
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
    }

    /// JavaScript that can be evaluated to check if a WebRTC call is active.
    /// Returns `true` if any RTCPeerConnection is in a connected/active state.
    static let callDetectionQueryJS = "window.__chorusActiveCall === true"

    /// Reports the page as visible even when its web view is preloaded/off-screen,
    /// so services that gate their unread-count title updates on Page Visibility
    /// (WhatsApp, Messenger, Discord, …) still surface the count for the badge.
    ///
    /// Deliberately does NOT fake `document.hasFocus()` — it stays false for a
    /// background view — so apps that gate desktop notifications on *focus* keep
    /// firing them, preserving Chorus's `window.Notification` forwarding.
    private static func makeVisibilityOverrideScript() -> String {
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

            window.__chorusActiveCall = false;

            function updateCallState() {
                window.__chorusActiveCall = activePeers.size > 0;
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
        let escapedID = serviceID.replacingOccurrences(of: "'", with: "\\'")
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
                        serviceID: '\(escapedID)'
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
        guard message.name == "chorusNotification",
              let jsonString = message.body as? String,
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

/// A named block of CSS a user can apply to a service from the Edit Service
/// sheet.
struct CSSPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let css: String
}

/// The library of ready-made CSS snippets offered in the Edit Service sheet.
enum CSSPresets {
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
    #messaging .scaffold-layout__list-detail-inner { height: 100% !important; }
    .scaffold-layout__inner { margin-left: 0 !important; margin-right: 0 !important; max-width: none !important; width: 100% !important; }
    /* Single column, and kill the grid column-gap: when the right rail is hidden
       its grid track collapses to 0 but the gap stays, leaving a gray strip on
       the right (most visible when zoomed out into the wide breakpoint). */
    .scaffold-layout__content { grid-template-columns: minmax(0, 1fr) !important; column-gap: 0 !important; grid-column-gap: 0 !important; margin-top: 0 !important; }
    .scaffold-layout__aside { display: none !important; }
    .scaffold-layout__content, .scaffold-layout__list-detail, .scaffold-layout__list-detail-container, .scaffold-layout__list-detail-inner { max-width: none !important; width: 100% !important; }
    .msg-overlay-list-bubble, .msg-overlay { display: none !important; }
    """

    /// Hides WebKit scrollbars — generic and safe on any site.
    static let hideScrollbars = """
    ::-webkit-scrollbar { width: 0 !important; height: 0 !important; }
    """

    static let all: [CSSPreset] = [
        CSSPreset(id: "linkedin-messaging", name: "LinkedIn: messaging only", css: linkedInMessaging),
        CSSPreset(id: "hide-scrollbars", name: "Hide scrollbars", css: hideScrollbars),
    ]
}

/// Baked-in default CSS for known catalog services, plus the rule that decides
/// what actually gets injected for a service. Kept as pure functions so the
/// resolution logic is unit-testable without a running web view.
enum ServiceCSSDefaults {
    /// The default CSS shipped for a catalog service, or nil when it has none.
    static func css(forCatalogID id: String?) -> String? {
        switch id {
        case "linkedin": return CSSPresets.linkedInMessaging
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
}

/// Forces dark mode on services that lack their own. Uses a whole-page inversion
/// filter — the only universal way to darken a site with no dark theme — and
/// re-inverts images/video so photos keep their real colors. Imperfect by
/// nature; a service that needs a polished theme can use its own custom CSS.
enum DarkMode {
    static let css = """
    html { filter: invert(1) hue-rotate(180deg) !important; background: #1a1a1a !important; }
    img, video, picture, canvas, svg, iframe,
    [style*="background-image"], [style*="background:url"], [style*="background: url"] {
        filter: invert(1) hue-rotate(180deg) !important;
    }
    """

    /// Whether dark mode should be applied for a preference given the current
    /// system appearance. Pure, for unit testing.
    static func shouldApply(preference: DarkModePreference, systemIsDark: Bool) -> Bool {
        switch preference {
        case .off: return false
        case .on: return true
        case .auto: return systemIsDark
        }
    }
}
