import Foundation

actor FaviconFetcher {
    static let shared = FaviconFetcher()

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

        // Google favicon API fallback
        let googleAPI = "https://www.google.com/s2/favicons?domain=\(host)&sz=128"
        if let data = await fetchURL(googleAPI), isValidImage(data) {
            AppLogger.favicon.debug("Favicon from Google API for \(host)")
            return data
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
            if let data = await fetchURL(iconInfo.url), isValidImage(data) {
                AppLogger.favicon.debug("Favicon from HTML link: \(iconInfo.url)")
                return data
            }
        }

        return nil
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

    private func fetchURL(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                return data
            }
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
        // WebP (RIFF)
        if header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46 { return true }
        return false
    }
}
