import WebKit
import UserNotifications
import os

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

    func configureScripts(for instance: ServiceInstance, on controller: WKUserContentController) {
        let mutedCheck = isServiceMuted
        let handler = NotificationMessageHandler(
            serviceID: instance.id,
            isMutedCheck: { id in
                mutedCheck?(id) ?? false
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
    }

    func removeHandler(for instanceID: UUID) {
        messageHandlers.removeValue(forKey: instanceID)
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

    private static let logger = Logger(subsystem: "com.nicojan.Chorus", category: "NotificationHandler")

    init(serviceID: UUID, isMutedCheck: @escaping @Sendable (UUID) -> Bool) {
        self.serviceID = serviceID
        self.isMutedCheck = isMutedCheck
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "chorusNotification",
              let jsonString = message.body as? String,
              let data = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(NotificationPayload.self, from: data)
        else { return }

        guard !isMutedCheck(serviceID) else { return }

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
                Self.logger.error("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }
}
