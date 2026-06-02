import Foundation

/// Polls badge counts for fully hibernated services by fetching their page title
/// via a lightweight URLSession request (no WKWebView needed).
///
/// Most web apps include unread counts in their `<title>` tag, e.g. "(3) Slack".
/// This lets us show badge counts even when a service is fully hibernated.
@MainActor
@Observable
final class HibernatedBadgePoller {
    private var pollTask: Task<Void, Never>?
    private var trackedServices: [UUID: TrackedService] = [:]

    /// How often to poll each hibernated service (60 seconds)
    private let pollInterval: TimeInterval = 60

    private let badgeManager: BadgeManager
    private let session: URLSession


    struct TrackedService {
        let url: String
        let isMuted: Bool
        let showBadge: Bool
        let dataStoreIdentifier: UUID
    }

    init(badgeManager: BadgeManager) {
        self.badgeManager = badgeManager
        // Use a simple ephemeral session — we only need the HTML title, not cookies/auth
        // (the title is usually set before auth gates, but we try anyway)
        self.session = URLSession(configuration: .ephemeral)
    }

    /// Start tracking a hibernated service for badge polling.
    func track(
        serviceID: UUID,
        url: String,
        isMuted: Bool,
        showBadge: Bool,
        dataStoreIdentifier: UUID
    ) {
        trackedServices[serviceID] = TrackedService(
            url: url,
            isMuted: isMuted,
            showBadge: showBadge,
            dataStoreIdentifier: dataStoreIdentifier
        )
        ensurePolling()
        AppLogger.badges.debug("Tracking hibernated service \(serviceID) for badge polling")
    }

    /// Stop tracking a service (e.g., when it wakes from hibernation).
    func untrack(serviceID: UUID) {
        trackedServices.removeValue(forKey: serviceID)
        if trackedServices.isEmpty {
            stopPolling()
        }
    }

    /// Stop all polling.
    func stopAll() {
        trackedServices.removeAll()
        stopPolling()
    }

    // MARK: - Private

    private func ensurePolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 60))
                guard let self, !Task.isCancelled else { break }
                await self.pollAllTrackedServices()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollAllTrackedServices() async {
        let snapshot = trackedServices

        await withTaskGroup(of: Void.self) { group in
            for (serviceID, tracked) in snapshot {
                group.addTask { [weak self] in
                    await self?.pollService(id: serviceID, tracked: tracked)
                }
            }
        }
    }

    private func pollService(id: UUID, tracked: TrackedService) async {
        guard let url = URL(string: tracked.url) else { return }

        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            // Some sites return lighter content for bots / non-browser UA,
            // but we need the real title — use a standard user agent
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else { return }

            // Only parse the first 16KB — title is always near the top
            let headChunk = data.prefix(16_384)
            guard let html = String(data: headChunk, encoding: .utf8)
                    ?? String(data: headChunk, encoding: .ascii)
            else { return }

            let count = Self.extractBadgeFromTitle(html: html)

            // Only update when we detect a positive count.
            // We can't reliably distinguish "0 unread" from "auth wall / redirect page"
            // so we never reset to 0 from the poller — the live web view handles that.
            if count > 0 {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if tracked.showBadge {
                        self.badgeManager.updateBadge(for: id, count: count, isMuted: tracked.isMuted)
                    }
                }
            }
        } catch {
            AppLogger.badges.debug("Failed to poll \(tracked.url): \(error.localizedDescription)")
        }
    }

    /// Extracts badge count from HTML by finding the <title> tag and parsing "(N)".
    nonisolated static func extractBadgeFromTitle(html: String) -> Int {
        // Find <title>...</title>
        let titlePattern = /<title[^>]*>(.*?)<\/title>/
        guard let match = html.firstMatch(of: titlePattern) else { return 0 }
        let title = String(match.1)

        // Reuse the same pattern as NotificationManager
        let badgePattern = /\((\d+)\)/
        if let badgeMatch = title.firstMatch(of: badgePattern),
           let count = Int(badgeMatch.1) {
            return count
        }
        return 0
    }
}
