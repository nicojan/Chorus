import WebKit

final class UserScriptManager {
    private var messageHandlers: [UUID: NotificationMessageHandler] = [:]

    func configureScripts(for instance: ServiceInstance, on controller: WKUserContentController) {
        let handler = NotificationMessageHandler(serviceID: instance.id)
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

final class NotificationMessageHandler: NSObject, WKScriptMessageHandler {
    let serviceID: UUID

    init(serviceID: UUID) {
        self.serviceID = serviceID
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Notification handling will be fully implemented in Phase 3
        guard message.name == "chorusNotification" else { return }
    }
}
