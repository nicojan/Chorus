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
              let scheme = baseURL.scheme
        else { return nil }

        // Try high-res sources first, then fall back to lower-res
        let candidates = [
            "\(scheme)://\(host)/apple-touch-icon.png",
            "\(scheme)://\(host)/apple-touch-icon-precomposed.png",
            "\(scheme)://\(host)/favicon-192x192.png",
            "\(scheme)://\(host)/favicon-96x96.png",
            "\(scheme)://\(host)/favicon-32x32.png",
            "\(scheme)://\(host)/favicon.ico",
        ]

        for candidate in candidates {
            if let data = await fetchURL(candidate), isValidImage(data) {
                AppLogger.favicon.debug("Favicon found at \(candidate)")
                return data
            }
        }

        // Try parsing HTML for <link rel="icon"> tags
        if let data = await fetchFromHTMLLinks(url: baseURL) {
            return data
        }

        // Google favicon API fallback — opt-in only; see googleFallbackEnabled.
        if googleFallbackEnabled {
            let googleAPI = "https://www.google.com/s2/favicons?domain=\(host)&sz=128"
            if let data = await fetchURL(googleAPI), isValidImage(data) {
                AppLogger.favicon.debug("Favicon from Google API for \(host)")
                return data
            }
        }

        AppLogger.favicon.debug("No favicon found for \(host)")
        return nil
    }

    private func fetchFromHTMLLinks(url: URL) async -> Data? {
        guard let htmlData = await fetchURL(url.absoluteString),
              let html = String(data: htmlData, encoding: .utf8)
        else { return nil }

        let iconURLs = Self.parseIconLinks(from: html, baseURL: url)

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
            if let data = await fetchURL(iconInfo.url), isValidImage(data) {
                AppLogger.favicon.debug("Favicon from HTML link: \(iconInfo.url)")
                return data
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
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        return !isPrivateOrReservedHost(host)
    }

    /// Recognizes literal loopback / link-local / private / reserved IPs so they
    /// can't be reached via a parsed favicon href. A normal hostname (not a
    /// literal IP) returns false — DNS-level rebinding is out of scope.
    nonisolated static func isPrivateOrReservedHost(_ host: String) -> Bool {
        if host.contains(":") {  // IPv6 literal
            let h = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
            let lower = h.lowercased()
            if lower == "::1" || lower == "::" { return true }
            return lower.hasPrefix("fe80") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
        }
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }),
              let a = Int(parts[0]), let b = Int(parts[1]) else {
            return false  // not a dotted-quad IPv4 → treat as a normal hostname
        }
        switch a {
        case 0, 10, 127: return true                      // this-network, private, loopback
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

    private func fetchURL(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            // Stream so we can stop at the cap instead of buffering an unbounded
            // response all at once (memory DoS via an oversized favicon/HTML body).
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
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
            return data.isEmpty ? nil : data
        } catch {
            AppLogger.favicon.debug("Fetch failed for \(urlString): \(error.localizedDescription)")
        }
        return nil
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
