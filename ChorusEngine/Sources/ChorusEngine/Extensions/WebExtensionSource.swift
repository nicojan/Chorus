import Foundation

/// Where a catalog extension comes from: its publisher's own releases, never a
/// copy Chorus hosts. The catalog pins one of these per extension, and both
/// the version check and the download stay on it.
public enum WebExtensionSource: Codable, Sendable, Equatable, Hashable {
    /// A GitHub repository's releases. `assetPattern` is a shell glob matched
    /// against the whole asset name, such as `dist-chrome-*.zip`. `tagPrefix`
    /// picks one product out of a repository that releases several, such as
    /// `browser-v` in Bitwarden's; it is dropped from the version.
    case github(owner: String, repo: String, assetPattern: String, tagPrefix: String?)
    /// An addons.mozilla.org listing, by its slug. Mozilla reviews and signs
    /// these files; Chorus does not check that signature, only the sha256.
    case amo(slug: String)

    /// The API address that answers "what is the latest version", or nil when
    /// a name holds characters that could steer the request somewhere else.
    var apiURL: URL? {
        switch self {
        case .github(let owner, let repo, _, _):
            guard Self.isPlainName(owner), Self.isPlainName(repo) else { return nil }
            return URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=100")
        case .amo(let slug):
            guard Self.isPlainName(slug), !slug.contains(".") else { return nil }
            return URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/")
        }
    }

    /// Whether `url` is a download this source publishes: on GitHub, a file
    /// under `/<owner>/<repo>/releases/download/<tag>/` whose name matches the
    /// asset pattern; on AMO, a numbered file on Mozilla's file path. The API
    /// answer names the download; this keeps a changed or forged answer from
    /// pointing it anywhere else.
    func publishes(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              let host = url.host?.lowercased() else { return false }
        // An encoded slash or dot could hide a path step from the checks below.
        let encodedPath = url.path(percentEncoded: true).lowercased()
        guard !encodedPath.contains("%2f"), !encodedPath.contains("%2e"), !encodedPath.contains("%5c") else { return false }
        let parts = url.pathComponents
        guard !parts.contains(".."), !parts.contains(".") else { return false }

        switch self {
        case .github(let owner, let repo, let pattern, _):
            guard host == "github.com", parts.count == 7 else { return false }
            return parts[1].lowercased() == owner.lowercased()
                && parts[2].lowercased() == repo.lowercased()
                && parts[3] == "releases" && parts[4] == "download"
                && fnmatch(pattern, parts[6], 0) == 0
        case .amo:
            guard host == "addons.mozilla.org", parts.count == 6 else { return false }
            return parts[1] == "firefox" && parts[2] == "downloads" && parts[3] == "file"
                && !parts[4].isEmpty && parts[4].allSatisfy(\.isASCII) && parts[4].allSatisfy(\.isNumber)
                && parts[5].lowercased().hasSuffix(".xpi")
        }
    }

    private static func isPlainName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return !name.isEmpty && name != "." && name != ".."
            && name.unicodeScalars.allSatisfy(allowed.contains)
    }
}
