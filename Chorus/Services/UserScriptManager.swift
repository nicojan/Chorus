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

    func configureScripts(for instance: ServiceInstance, on controller: WKUserContentController) {
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
