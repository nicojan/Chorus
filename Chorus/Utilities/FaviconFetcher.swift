import Foundation
import os

actor FaviconFetcher {
    private static let logger = Logger(subsystem: "com.nicojan.Chorus", category: "FaviconFetcher")

    func fetchFavicon(for urlString: String) async -> Data? {
        guard let baseURL = URL(string: urlString),
              let host = baseURL.host,
              let scheme = baseURL.scheme
        else { return nil }

        let candidates = [
            "\(scheme)://\(host)/apple-touch-icon.png",
            "\(scheme)://\(host)/favicon.ico",
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   !data.isEmpty {
                    return data
                }
            } catch {
                Self.logger.debug("Favicon fetch failed for \(candidate): \(error.localizedDescription)")
            }
        }

        return nil
    }
}
