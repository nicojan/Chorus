import Foundation
import WebKit

/// Polls badge counts for fully hibernated services by fetching their page title
/// via a lightweight URLSession request (no WKWebView needed).
///
/// Most web apps include unread counts in their `<title>` tag, e.g. "(3) Slack".
/// We seed each request with the service's own `WKWebsiteDataStore` cookies
/// so the poll sees the authenticated page, not the unauth landing page.
@MainActor
@Observable
final class HibernatedBadgePoller {
    private var pollTask: Task<Void, Never>?
    private var trackedServices: [UUID: TrackedService] = [:]

    /// When true, no poll timer runs even if services are tracked. Set while
    /// the network is unreachable or the Mac is asleep so we don't fire doomed
    /// URLSession requests; tracking is retained so we can resume cleanly.
    private var isPaused = false

    /// How often to poll each hibernated service (60 seconds)
    private let pollInterval: TimeInterval = 60

    private let badgeManager: BadgeManager
    private let dataStoreManager: DataStoreManager
    private let session: URLSession


    struct TrackedService {
        let url: String
        var isMuted: Bool
        var showBadge: Bool
        let dataStoreIdentifier: UUID
    }

    init(badgeManager: BadgeManager, dataStoreManager: DataStoreManager) {
        self.badgeManager = badgeManager
        self.dataStoreManager = dataStoreManager
        // Stateless session — we attach each service's cookies manually per
        // request. An ephemeral config still keeps an in-memory cookie jar
        // shared across every request, so without disabling it, one service's
        // Set-Cookie response would be replayed onto another service on the
        // same host (e.g. two Gmail accounts), reading the wrong account's
        // unread count. Turning the jar off leaves only our per-service header.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: configuration)
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
        // Fire one poll immediately rather than waiting a full interval, so a
        // just-hibernated service's badge stays current. Guarded by !isPaused
        // so we don't fire while offline or asleep.
        if !isPaused, let tracked = trackedServices[serviceID] {
            Task { [weak self] in await self?.pollService(id: serviceID, tracked: tracked) }
        }
        AppLogger.badges.debug("Tracking hibernated service \(serviceID) for badge polling")
    }

    /// Performs a single badge fetch for a service WITHOUT adding it to the
    /// recurring poll set. Used for the one-shot launch sweep so services that
    /// won't have a live web view (e.g. outside the active space) still show a
    /// startup badge, without entangling with the web-view lifecycle. Respects
    /// the same "never reset to 0" rule as the recurring poll.
    func pollOnce(
        serviceID: UUID,
        url: String,
        isMuted: Bool,
        showBadge: Bool,
        dataStoreIdentifier: UUID
    ) async {
        // Skip muted services: their badge is masked anyway, so a fetch would
        // just waste a cookie-bearing request to a server the user silenced.
        guard !isPaused, showBadge, !isMuted else { return }
        await pollService(id: serviceID, tracked: TrackedService(
            url: url,
            isMuted: isMuted,
            showBadge: showBadge,
            dataStoreIdentifier: dataStoreIdentifier
        ), requireTracked: false)
    }

    /// Refresh mutable notification/badge flags for an already-tracked service.
    /// Muting and per-service badge toggles can change while a service is fully
    /// hibernated, so the lightweight poller must not keep using stale values.
    func updateState(serviceID: UUID, isMuted: Bool, showBadge: Bool) {
        guard var tracked = trackedServices[serviceID] else { return }
        tracked.isMuted = isMuted
        tracked.showBadge = showBadge
        trackedServices[serviceID] = tracked
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

    /// Suspend the poll timer without forgetting tracked services. Use when
    /// the network goes offline or the Mac sleeps.
    func pause() {
        isPaused = true
        stopPolling()
    }

    /// Resume polling after `pause()`, restarting the timer if any services
    /// are still tracked.
    func resume() {
        isPaused = false
        if !trackedServices.isEmpty {
            ensurePolling()
        }
    }

    // MARK: - Private

    private func ensurePolling() {
        guard !isPaused, pollTask == nil else { return }
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

    private func pollService(id: UUID, tracked: TrackedService, requireTracked: Bool = true) async {
        guard let url = URL(string: tracked.url) else { return }

        let dataStore = dataStoreManager.dataStore(forIdentifier: tracked.dataStoreIdentifier)
        let allCookies = await Self.allCookies(from: dataStore.httpCookieStore)
        let matchingCookies = Self.cookies(allCookies, matching: url)
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: matchingCookies)

        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            // Some sites return lighter content for bots / non-browser UA,
            // but we need the real title — use a standard user agent
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            for (name, value) in cookieHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }

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
            //
            // For the recurring poll, the service may have woken (and been
            // untracked) during the seconds-long URLSession await; dropping the
            // result then avoids overwriting the live web view's fresh badge
            // with a stale background count. The one-shot `pollOnce` caller
            // passes `requireTracked: false` and uses its own snapshot.
            let current: TrackedService
            if requireTracked {
                guard let live = trackedServices[id] else { return }
                current = live
            } else {
                current = tracked
            }
            if count > 0, current.showBadge {
                badgeManager.updateBadge(for: id, count: count, isMuted: current.isMuted)
            }
        } catch {
            AppLogger.badges.debug("Failed to poll \(tracked.url): \(error.localizedDescription)")
        }
    }

    /// Bridges WKHTTPCookieStore's completion-handler API to async. Main-actor
    /// isolated because getAllCookies (and its completion) is @MainActor; the
    /// await suspends rather than blocking, so this doesn't stall the main actor.
    @MainActor private static func allCookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { cookies in
                cont.resume(returning: cookies)
            }
        }
    }

    /// Subset of `cookies` that URLSession would attach for a request to `url`.
    /// Mirrors the standard cookie-attribute rules (domain match, path prefix,
    /// secure flag, expiry).
    nonisolated static func cookies(_ cookies: [HTTPCookie], matching url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        let isSecure = (url.scheme?.lowercased() == "https")
        let now = Date()

        return cookies.filter { cookie in
            let raw = cookie.domain.lowercased()
            let domain = raw.hasPrefix(".") ? String(raw.dropFirst()) : raw
            let domainMatches = host == domain || host.hasSuffix("." + domain)
            let pathMatches = Self.pathMatches(requestPath: path, cookiePath: cookie.path)
            let secureOK = !cookie.isSecure || isSecure
            let notExpired = (cookie.expiresDate ?? .distantFuture) > now
            return domainMatches && pathMatches && secureOK && notExpired
        }
    }

    /// RFC 6265 §5.1.4 path-match: the request path equals the cookie path, or
    /// the cookie path is a prefix that ends at a path boundary. A plain
    /// `hasPrefix` is wrong — it would match request `/foobar` against cookie
    /// `/foo`.
    nonisolated static func pathMatches(requestPath: String, cookiePath: String) -> Bool {
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        // Prefix matches; require the boundary to be a "/" (either the cookie
        // path already ends in "/", or the next char of the request path is "/").
        return cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).first == "/"
    }

    /// Extracts badge count from HTML by finding the <title> tag and parsing "(N)".
    nonisolated static func extractBadgeFromTitle(html: String) -> Int {
        // Find <title>...</title> — most pages emit lowercase but be lenient.
        let titlePattern = /<title[^>]*>([\s\S]*?)<\/title>/.ignoresCase()
        guard let match = html.firstMatch(of: titlePattern) else { return 0 }
        let title = String(match.1)
        return NotificationManager.extractBadgeCount(from: title)
    }
}
