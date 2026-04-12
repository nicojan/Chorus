import Foundation
import WebKit
import UserNotifications
import os

@MainActor
@Observable
final class NotificationManager {
    private var pollTasks: [UUID: Task<Void, Never>] = [:]
    private let badgeManager: BadgeManager
    private var pendingServiceID: UUID?

    private static let logger = Logger(subsystem: "com.nicojan.Chorus", category: "NotificationManager")

    var onServiceRequested: (@MainActor (UUID) -> Void)?

    init(badgeManager: BadgeManager) {
        self.badgeManager = badgeManager
        requestNotificationPermission()
        configureNotificationDelegate()
    }

    func startPolling(for instanceID: UUID, webView: WKWebView, isMuted: Bool, catalogEntry: ServiceCatalogEntry?) {
        stopPolling(for: instanceID)

        let task = Task { @MainActor [weak self, weak webView] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let webView, !Task.isCancelled else { break }

                tick += 1

                // Title polling every 5 seconds
                if tick % 5 == 0 {
                    await pollTitle(webView: webView, instanceID: instanceID, isMuted: isMuted)
                }

                // DOM badge polling every 10 seconds for curated services
                if tick % 10 == 0, let entry = catalogEntry, entry.badgeJS != nil {
                    await pollBadge(webView: webView, instanceID: instanceID, isMuted: isMuted, catalogEntry: entry)
                }
            }
        }
        pollTasks[instanceID] = task
    }

    func stopPolling(for instanceID: UUID) {
        pollTasks[instanceID]?.cancel()
        pollTasks.removeValue(forKey: instanceID)
    }

    func stopAllPolling() {
        for task in pollTasks.values {
            task.cancel()
        }
        pollTasks.removeAll()
    }

    func handlePendingNotification() -> UUID? {
        let id = pendingServiceID
        pendingServiceID = nil
        return id
    }

    // MARK: - Polling

    private func pollTitle(webView: WKWebView, instanceID: UUID, isMuted: Bool) async {
        do {
            let result = try await webView.evaluateJavaScript("document.title")
            if let title = result as? String {
                let count = Self.extractBadgeCount(from: title)
                badgeManager.updateBadge(for: instanceID, count: count, isMuted: isMuted)
            }
        } catch {
            // Page may not be ready yet
        }
    }

    private func pollBadge(webView: WKWebView, instanceID: UUID, isMuted: Bool, catalogEntry: ServiceCatalogEntry) async {
        guard let badgeJS = catalogEntry.badgeJS else { return }
        do {
            let result = try await webView.evaluateJavaScript(badgeJS)
            let count: Int
            if let intResult = result as? Int {
                count = intResult
            } else if let stringResult = result as? String, let parsed = Int(stringResult) {
                count = parsed
            } else {
                return
            }
            badgeManager.updateBadge(for: instanceID, count: count, isMuted: isMuted)
        } catch {
            // Badge extraction failed — page may have changed
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

    private nonisolated func requestNotificationPermission() {
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
        NotificationCenterDelegate.retained = delegate
    }
}

// MARK: - Notification Center Delegate

private final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    let onServiceRequested: @Sendable (UUID) -> Void
    static var retained: NotificationCenterDelegate?

    init(onServiceRequested: @escaping @Sendable (UUID) -> Void) {
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
