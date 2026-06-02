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
        if let data = await fetchFromHTMLLinks(scheme: scheme, host: host, url: baseURL) {
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

    private func fetchFromHTMLLinks(scheme: String, host: String, url: URL) async -> Data? {
        guard let htmlData = await fetchURL(url.absoluteString),
              let html = String(data: htmlData, encoding: .utf8)
        else { return nil }

        let iconURLs = parseIconLinks(from: html, baseScheme: scheme, baseHost: host)

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

    private struct IconLink {
        let url: String
        let size: Int
    }

    private func parseIconLinks(from html: String, baseScheme: String, baseHost: String) -> [IconLink] {
        var results: [IconLink] = []

        let linkPattern = /<link[^>]*rel\s*=\s*["'](?:apple-touch-icon|icon|shortcut icon)["'][^>]*>/

        for match in html.matches(of: linkPattern) {
            let tag = String(match.output)

            // Extract href
            let hrefPattern = /href\s*=\s*["']([^"']+)["']/
            guard let hrefMatch = tag.firstMatch(of: hrefPattern) else { continue }
            var href = String(hrefMatch.1)

            // Resolve relative URLs
            if href.hasPrefix("//") {
                href = "\(baseScheme):\(href)"
            } else if href.hasPrefix("/") {
                href = "\(baseScheme)://\(baseHost)\(href)"
            } else if !href.hasPrefix("http") {
                href = "\(baseScheme)://\(baseHost)/\(href)"
            }

            // Extract size hint
            var size = 0
            let sizePattern = /sizes\s*=\s*["'](\d+)x\d+["']/
            if let sizeMatch = tag.firstMatch(of: sizePattern),
               let parsed = Int(sizeMatch.1) {
                size = parsed
            }

            results.append(IconLink(url: href, size: size))
        }

        return results
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
