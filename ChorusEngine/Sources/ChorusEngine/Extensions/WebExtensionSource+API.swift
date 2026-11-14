import Foundation

/// Reading GitHub's and AMO's answers into a release.
extension WebExtensionSource {
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let digest: String?
            let size: Int?
        }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private struct AMOAddon: Decodable {
        struct Version: Decodable {
            struct File: Decodable {
                let url: String
                let hash: String?
                let size: Int?
            }
            let version: String
            let file: File
        }
        /// Null when the listing has no public version, such as a disabled one.
        let current_version: Version?
    }

    /// The latest usable release in an API answer for this source.
    func release(fromAPIAnswer data: Data) throws -> WebExtensionRelease {
        switch self {
        case .github(_, _, let pattern, let prefix):
            guard let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
                throw WebExtensionSourceError.unreadableResponse
            }
            return try githubRelease(in: releases, pattern: pattern, prefix: prefix ?? "")
        case .amo:
            guard let addon = try? JSONDecoder().decode(AMOAddon.self, from: data) else {
                throw WebExtensionSourceError.unreadableResponse
            }
            guard let current = addon.current_version, WebExtensionVersion(current.version) != nil else {
                throw WebExtensionSourceError.noRelease
            }
            return try verified(version: current.version, url: current.file.url,
                                hash: current.file.hash, size: current.file.size)
        }
    }

    /// The highest version among the page's published, stable releases that
    /// carry the tag prefix and exactly one asset matching the pattern.
    /// GitHub orders releases by date, not version, so the first is not always
    /// the highest.
    private func githubRelease(in releases: [GitHubRelease], pattern: String, prefix: String) throws -> WebExtensionRelease {
        typealias Candidate = (version: WebExtensionVersion, text: String, tag: String, asset: GitHubRelease.Asset)
        let candidates: [Candidate] = releases.compactMap { release in
            guard !release.draft, !release.prerelease, release.tag_name.hasPrefix(prefix) else { return nil }
            let text = Self.versionText(tag: release.tag_name, prefix: prefix)
            guard let version = WebExtensionVersion(text) else { return nil }
            let matches = release.assets.filter { fnmatch(pattern, $0.name, 0) == 0 }
            guard matches.count == 1, let asset = matches.first else {
                if matches.count > 1 {
                    AppLogger.extensions.error("Release \(release.tag_name, privacy: .public) has \(matches.count) assets matching \(pattern, privacy: .public); skipped")
                }
                return nil
            }
            return (version, text, release.tag_name, asset)
        }
        guard let best = candidates.max(by: { $0.version < $1.version }) else {
            AppLogger.extensions.error("No release on the first page matched \(prefix, privacy: .public) \(pattern, privacy: .public)")
            throw WebExtensionSourceError.noRelease
        }
        // The URL must be this release's own copy of this asset, so an answer
        // cannot pair one release's version with another's file.
        guard let url = URL(string: best.asset.browser_download_url),
              url.pathComponents.count == 7,
              url.pathComponents[5] == best.tag, url.pathComponents[6] == best.asset.name else {
            throw WebExtensionSourceError.untrustedDownload
        }
        return try verified(version: best.text, url: best.asset.browser_download_url,
                            hash: best.asset.digest, size: best.asset.size)
    }

    private static func versionText(tag: String, prefix: String) -> String {
        let rest = tag.dropFirst(prefix.count)
        return String(rest.first == "v" || rest.first == "V" ? rest.dropFirst() : rest)
    }

    private func verified(version: String, url: String, hash: String?, size: Int?) throws -> WebExtensionRelease {
        guard let url = URL(string: url), publishes(url) else { throw WebExtensionSourceError.untrustedDownload }
        guard let hash, hash.lowercased().hasPrefix("sha256:") else { throw WebExtensionSourceError.noChecksum }
        let hex = String(hash.dropFirst("sha256:".count)).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { throw WebExtensionSourceError.noChecksum }
        return WebExtensionRelease(version: version, downloadURL: url, sha256: hex, byteCount: size)
    }
}
