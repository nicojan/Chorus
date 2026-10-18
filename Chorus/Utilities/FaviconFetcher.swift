import Foundation

actor FaviconFetcher {
    static let shared = FaviconFetcher()

    /// Whether the Google favicon fallback may run. Off unless the user opts in,
    /// because that request tells Google which services the user runs — and the
    /// host can be a private one (a self-hosted Mattermost, an internal mail
    /// server) typed into "Add service". Every other source in this file is
    /// fetched from the service's own host, so this is the one third party in
    /// the path. `AppState` pushes the preference in on load and on change.
    private var googleFallbackEnabled = false

    func setGoogleFallbackEnabled(_ enabled: Bool) {
        googleFallbackEnabled = enabled
    }

    func fetchFavicon(for urlString: String) async -> Data? {
        guard let baseURL = URL(string: urlString),
              let host = baseURL.host,
              let scheme = baseURL.scheme,
              ["http", "https"].contains(scheme.lowercased())
        else { return nil }

        // Keep the port: a self-hosted service on :8443 serves its icons there,
        // and port 443 on the same host may be another server entirely.
        let origin = baseURL.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"

        // Try high-res sources first, then fall back to lower-res
        let candidates = [
            "\(origin)/apple-touch-icon.png",
            "\(origin)/apple-touch-icon-precomposed.png",
            "\(origin)/favicon-192x192.png",
            "\(origin)/favicon-96x96.png",
            "\(origin)/favicon-32x32.png",
            "\(origin)/favicon.ico",
        ]

        for candidate in candidates {
            if let data = await fetchURL(candidate)?.data, let icon = storable(data) {
                AppLogger.favicon.debug("Favicon found at \(candidate, privacy: .private)")
                return icon
            }
        }

        // Try parsing HTML for <link rel="icon"> tags
        if let data = await fetchFromHTMLLinks(url: baseURL) {
            return data
        }

        // Google favicon API fallback — opt-in only; see googleFallbackEnabled.
        // Never send a likely-private host (self-hosted, intranet, literal
        // private IP) to Google even when the toggle is on: those hostnames are
        // the ones a user would least expect to leak off-device.
        if googleFallbackEnabled, !Self.isLikelyPrivateHost(host) {
            let googleAPI = "https://www.google.com/s2/favicons?domain=\(host)&sz=128"
            if let data = await fetchURL(googleAPI)?.data, let icon = storable(data) {
                AppLogger.favicon.debug("Favicon from Google API for \(host, privacy: .private)")
                return icon
            }
        }

        AppLogger.favicon.debug("No favicon found for \(host, privacy: .private)")
        return nil
    }

    private func fetchFromHTMLLinks(url: URL) async -> Data? {
        let fetched = await fetchURL(url.absoluteString)
        guard let htmlData = fetched?.data,
              let html = String(data: htmlData, encoding: .utf8)
        else { return nil }

        let iconURLs = Self.resolvedIconLinks(
            from: html,
            requestedURL: url,
            finalURL: fetched?.finalURL
        )

        // Sort by size descending — prefer largest icon
        let sorted = iconURLs.sorted { $0.size > $1.size }

        for iconInfo in sorted {
            // The href came from (possibly hostile / compromised) page HTML, so
            // gate it: http/https only, no loopback/link-local/private hosts.
            // Without this a `<link rel=icon href="file:///…">` or an internal-IP
            // href would make this non-sandboxed app read local files / hit
            // internal hosts (SSRF).
            guard let iconURL = URL(string: iconInfo.url), Self.isFetchableIconURL(iconURL) else {
                continue
            }
            if let data = await fetchURL(iconInfo.url)?.data, let icon = storable(data) {
                AppLogger.favicon.debug("Favicon from HTML link: \(iconInfo.url, privacy: .private)")
                return icon
            }
        }

        return nil
    }

    /// Whether an icon URL parsed from page HTML is safe to fetch: http/https
    /// only and not aimed at a loopback/link-local/private host.
    nonisolated static func isFetchableIconURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return !isLikelyPrivateHost(host)
    }

    /// Hosts we never fetch a parsed href from and never send to a third party:
    /// literal private/reserved IPs, `localhost`, single-label intranet names
    /// (no dot), and private-use TLDs. A DNS-resolving check is deliberately out
    /// of scope — this cheap name test catches the common self-hosted/intranet
    /// shapes without a lookup, and the redirect guard covers the rest at fetch
    /// time.
    nonisolated static func isLikelyPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if isPrivateOrReservedHost(h) { return true }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if !h.contains(".") { return true }  // single-label intranet name
        let privateTLDs: Set<String> = [
            "local", "internal", "lan", "corp", "home", "test", "intranet", "localdomain",
        ]
        if let tld = h.split(separator: ".").last, privateTLDs.contains(String(tld)) {
            return true
        }
        return false
    }

    /// Recognizes literal loopback / link-local / private / reserved IPs so they
    /// can't be reached via a parsed favicon href. A normal hostname (not a
    /// literal IP) returns false — DNS-level rebinding is out of scope.
    nonisolated static func isPrivateOrReservedHost(_ host: String) -> Bool {
        if host.contains(":") {  // IPv6 literal
            let h = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
            let lower = h.lowercased()
            if lower == "::1" || lower == "::" { return true }
            // An IPv4 address written as IPv6 reaches the same IPv4 host.
            if lower.hasPrefix("::ffff:") { return isPrivateOrReservedHost(String(lower.dropFirst(7))) }
            return lower.hasPrefix("fe80") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
        }
        // `inet_aton` reads every form of IPv4 literal a URL loader accepts, not
        // just the dotted quad: `127.1`, `0x7f.1`, `2130706433`. A name it
        // can't read is a normal hostname.
        var address = in_addr()
        guard inet_aton(host, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        let a = value >> 24, b = (value >> 16) & 0xff
        switch a {
        case 0, 10, 127: return true                      // this-network, private, loopback
        case 100 where (64...127).contains(b): return true // carrier-grade NAT, Tailscale
        case 169 where b == 254: return true              // link-local
        case 172 where (16...31).contains(b): return true // private
        case 192 where b == 168: return true              // private
        default: return false
        }
    }

    struct IconLink: Equatable {
        let url: String
        let size: Int
    }

    /// Icon links from a page's HTML, resolved against the URL the response
    /// actually came from rather than the one that was asked for.
    ///
    /// A relative `href` is relative to the document, and after a redirect the
    /// document is not where the request went. `easyweb.td.com` 302s to
    /// `authentication.td.com/uap-ui/`, whose only icon link is
    /// `href="favicon.ico"`; resolved against the requested host that becomes
    /// `easyweb.td.com/favicon.ico`, which TD answers with another redirect to a
    /// 404 page — so Chorus found no icon at all and drew a letter tile for a
    /// site that has a perfectly good favicon.
    nonisolated static func resolvedIconLinks(
        from html: String,
        requestedURL: URL,
        finalURL: URL?
    ) -> [IconLink] {
        parseIconLinks(from: html, baseURL: finalURL ?? requestedURL)
    }

    nonisolated static func parseIconLinks(from html: String, baseURL: URL) -> [IconLink] {
        var results: [IconLink] = []

        let linkPattern = /<link\b[^>]*>/.ignoresCase()

        for match in html.matches(of: linkPattern) {
            let tag = String(match.output)
            guard let rel = attributeValue(in: tag, named: "rel")?.lowercased() else { continue }
            let relTokens = Set(rel.split(whereSeparator: \.isWhitespace).map(String.init))
            guard relTokens.contains("icon") || relTokens.contains("apple-touch-icon") else { continue }

            guard let href = attributeValue(in: tag, named: "href"),
                  let resolvedURL = URL(string: href, relativeTo: baseURL)?.absoluteURL
            else { continue }

            // Extract size hint
            let size = attributeValue(in: tag, named: "sizes").map(Self.largestIconSize) ?? 0

            results.append(IconLink(url: resolvedURL.absoluteString, size: size))
        }

        return results
    }

    nonisolated private static func attributeValue(in tag: String, named name: String) -> String? {
        let pattern = #"(?i)\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: range),
              let valueRange = Range(match.range(at: 1), in: tag) else {
            return nil
        }
        return String(tag[valueRange])
    }

    nonisolated private static func largestIconSize(from sizes: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)x\d+"#) else { return 0 }
        let range = NSRange(sizes.startIndex..<sizes.endIndex, in: sizes)
        return regex.matches(in: sizes, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: sizes) else { return nil }
            return Int(sizes[valueRange])
        }.max() ?? 0
    }

    /// Hard ceiling on any single fetch (favicon or the HTML we parse for links).
    /// Favicons are KBs; this only exists to stop a hostile/broken endpoint from
    /// streaming a huge body into memory.
    private static let maxFetchBytes = 5 * 1024 * 1024  // 5 MB

    /// Re-validates every redirect hop with the same rule as the initial href
    /// check. Without it a public-host icon href could 302 to a loopback /
    /// link-local / private / non-http target and this non-sandboxed app would
    /// follow it (SSRF via redirect), since the initial `isFetchableIconURL`
    /// guard only ever sees the first URL. Stateless, so one shared instance.
    private static let redirectGuard = FaviconRedirectGuard()

    /// A fetched body together with the URL it was finally served from, which
    /// differs from the requested one whenever a redirect was followed. The
    /// caller needs the final URL to resolve a document's relative icon hrefs.
    struct FetchedBody {
        let data: Data
        let finalURL: URL?
    }

    private func fetchURL(_ urlString: String) async -> FetchedBody? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            // Stream so we can stop at the cap instead of buffering an unbounded
            // response all at once (memory DoS via an oversized favicon/HTML body).
            // The per-task delegate re-checks each redirect target (SSRF guard).
            let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: Self.redirectGuard)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            if http.expectedContentLength > Int64(Self.maxFetchBytes) { return nil }

            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(http.expectedContentLength), Self.maxFetchBytes))
            }
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxFetchBytes { return nil }
            }
            guard !data.isEmpty else { return nil }
            return FetchedBody(data: data, finalURL: http.url)
        } catch {
            AppLogger.favicon.debug("Fetch failed for \(urlString, privacy: .private): \(error.localizedDescription)")
        }
        return nil
    }

    /// The icon as it is stored: an SVG as it came, since it is drawn as
    /// vectors, and any other image shrunk to a PNG by `IconThumbnail`. Nil
    /// when the data isn't an image or is too large to decode safely; the
    /// rail, the menu bar and the switcher decode it on every redraw.
    private func storable(_ data: Data) -> Data? {
        guard isValidImage(data) else { return nil }
        return Self.looksLikeSVG(data) ? data : IconThumbnail.png(from: data, maxPixelSize: 256)
    }

    private func isValidImage(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let header = [UInt8](data.prefix(4))
        // PNG
        if header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47 { return true }
        // JPEG
        if header[0] == 0xFF && header[1] == 0xD8 { return true }
        // ICO
        if header[0] == 0x00 && header[1] == 0x00 && header[2] == 0x01 && header[3] == 0x00 { return true }
        // GIF
        if header[0] == 0x47 && header[1] == 0x49 && header[2] == 0x46 { return true }
        // WebP: the container is "RIFF"<size>"WEBP". Verify the WEBP tag at
        // bytes 8–11, not just the RIFF magic — WAV/AVI are also RIFF and would
        // be cached as junk that never renders.
        if data.count >= 12,
           header[0] == 0x52, header[1] == 0x49, header[2] == 0x46, header[3] == 0x46 {
            let tag = [UInt8](data.prefix(12).suffix(4))
            if tag == [0x57, 0x45, 0x42, 0x50] { return true }  // "WEBP"
        }
        // SVG is text, not a binary magic number; sniff the head for an <svg
        // root. NSImage renders SVG on modern macOS, so accept it rather than
        // rejecting it and falling through to the lower-res Google API.
        if Self.looksLikeSVG(data) { return true }
        return false
    }

    /// Whether `data` is an SVG document — its *root* element is `<svg`, past an
    /// optional BOM, XML declaration, and leading comments. Anchored at the root
    /// (not "contains <svg anywhere") so an HTML page with an inline `<svg>` icon
    /// — e.g. an SPA index returned with 200 for an unknown /favicon path — isn't
    /// false-accepted and cached as a non-rendering image. UTF-8 only (SVG is
    /// text); the isoLatin1 fallback that never fails is deliberately dropped.
    nonisolated private static func looksLikeSVG(_ data: Data) -> Bool {
        let head = data.prefix(1024)
        guard var text = String(data: head, encoding: .utf8) else { return false }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("<?xml"), let close = text.range(of: "?>") {
            text = String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while text.hasPrefix("<!--"), let close = text.range(of: "-->") {
            text = String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lower = text.lowercased()
        return lower.hasPrefix("<svg") || lower.hasPrefix("<!doctype svg")
    }
}

/// Task delegate that cancels a redirect aimed at a host the favicon fetcher's
/// initial `isFetchableIconURL` check would have rejected. Returning `nil` stops
/// URLSession from following the 3xx, so the fetch sees the redirect response
/// (not the internal target) and its `statusCode == 200` guard discards it.
/// Stateless, so safe to share across tasks.
private final class FaviconRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, FaviconFetcher.isFetchableIconURL(url) else { return nil }
        return request
    }
}
