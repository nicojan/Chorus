import Foundation
import WebKit
import UserNotifications
import os

@MainActor
@Observable
final class NotificationManager {
    private var pollTimers: [UUID: Timer] = [:]
    private let badgeManager: BadgeManager
    private var pendingServiceID: UUID?

    private static let logger = Logger(subsystem: "com.nicojan.Chorus", category: "NotificationManager")

    var onServiceRequested: ((UUID) -> Void)?

    init(badgeManager: BadgeManager) {
        self.badgeManager = badgeManager
        requestNotificationPermission()
        configureNotificationDelegate()
    }

    func startPolling(for instanceID: UUID, webView: WKWebView, isMuted: Bool, catalogEntry: ServiceCatalogEntry?) {
        stopPolling(for: instanceID)

        // Title polling every 5 seconds
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self, weak webView] _ in
            guard let self, let webView else { return }
            Task { @MainActor in
                self.pollTitle(webView: webView, instanceID: instanceID, isMuted: isMuted)
            }
        }
        pollTimers[instanceID] = timer

        // DOM badge polling every 10 seconds for curated services
        if let entry = catalogEntry, entry.badgeJS != nil {
            let domTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self, weak webView] _ in
                guard let self, let webView else { return }
                Task { @MainActor in
                    self.pollBadge(webView: webView, instanceID: instanceID, isMuted: isMuted, catalogEntry: entry)
                }
            }
            // Store DOM timer with a modified key
            let domKey = UUID(uuid: (
                instanceID.uuid.0 ^ 0xFF, instanceID.uuid.1, instanceID.uuid.2,
                instanceID.uuid.3, instanceID.uuid.4, instanceID.uuid.5,
                instanceID.uuid.6, instanceID.uuid.7, instanceID.uuid.8,
                instanceID.uuid.9, instanceID.uuid.10, instanceID.uuid.11,
                instanceID.uuid.12, instanceID.uuid.13, instanceID.uuid.14,
                instanceID.uuid.15
            ))
            pollTimers[domKey] = domTimer
        }
    }

    func stopPolling(for instanceID: UUID) {
        pollTimers[instanceID]?.invalidate()
        pollTimers.removeValue(forKey: instanceID)

        let domKey = UUID(uuid: (
            instanceID.uuid.0 ^ 0xFF, instanceID.uuid.1, instanceID.uuid.2,
            instanceID.uuid.3, instanceID.uuid.4, instanceID.uuid.5,
            instanceID.uuid.6, instanceID.uuid.7, instanceID.uuid.8,
            instanceID.uuid.9, instanceID.uuid.10, instanceID.uuid.11,
            instanceID.uuid.12, instanceID.uuid.13, instanceID.uuid.14,
            instanceID.uuid.15
        ))
        pollTimers[domKey]?.invalidate()
        pollTimers.removeValue(forKey: domKey)
    }

    func stopAllPolling() {
        for timer in pollTimers.values {
            timer.invalidate()
        }
        pollTimers.removeAll()
    }

    func handlePendingNotification() -> UUID? {
        let id = pendingServiceID
        pendingServiceID = nil
        return id
    }

    // MARK: - Polling

    private func pollTitle(webView: WKWebView, instanceID: UUID, isMuted: Bool) {
        webView.evaluateJavaScript("document.title") { [weak self] result, _ in
            guard let self, let title = result as? String else { return }
            let count = Self.extractBadgeCount(from: title)
            Task { @MainActor in
                self.badgeManager.updateBadge(for: instanceID, count: count, isMuted: isMuted)
            }
        }
    }

    private func pollBadge(webView: WKWebView, instanceID: UUID, isMuted: Bool, catalogEntry: ServiceCatalogEntry) {
        guard let badgeJS = catalogEntry.badgeJS else { return }
        webView.evaluateJavaScript(badgeJS) { [weak self] result, _ in
            guard let self else { return }
            let count: Int
            if let intResult = result as? Int {
                count = intResult
            } else if let stringResult = result as? String, let parsed = Int(stringResult) {
                count = parsed
            } else {
                return
            }
            Task { @MainActor in
                self.badgeManager.updateBadge(for: instanceID, count: count, isMuted: isMuted)
            }
        }
    }

    static func extractBadgeCount(from title: String) -> Int {
        let pattern = /\((\d+)\)/
        if let match = title.firstMatch(of: pattern),
           let count = Int(match.1) {
            return count
        }
        return 0
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                Self.logger.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    private func configureNotificationDelegate() {
        let delegate = NotificationCenterDelegate { [weak self] serviceID in
            Task { @MainActor in
                self?.onServiceRequested?(serviceID)
            }
        }
        UNUserNotificationCenter.current().delegate = delegate
        // Retain the delegate
        Self._notificationDelegate = delegate
    }

    private static var _notificationDelegate: NotificationCenterDelegate?
}

// MARK: - Notification Center Delegate

private final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    let onServiceRequested: (UUID) -> Void

    init(onServiceRequested: @escaping (UUID) -> Void) {
        self.onServiceRequested = onServiceRequested
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let serviceIDString = response.notification.request.content.userInfo["serviceID"] as? String,
           let serviceID = UUID(uuidString: serviceIDString) {
            onServiceRequested(serviceID)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
