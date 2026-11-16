import Foundation

/// One published version of a catalog extension.
public struct WebExtensionRelease: Sendable, Equatable {
    public let version: String
    public let downloadURL: URL
    /// Lowercase hex, as the publisher reports it.
    public let sha256: String
    /// The size the publisher reports, when it does.
    public let byteCount: Int?

    public init(version: String, downloadURL: URL, sha256: String, byteCount: Int? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    /// Whether this release is later than `installed`. A version Chorus can't
    /// read on this release is never newer; one it can't read on the
    /// installed side is always older, so a damaged record still updates.
    public func isNewer(than installed: String) -> Bool {
        guard let mine = WebExtensionVersion(version) else { return false }
        guard let theirs = WebExtensionVersion(installed) else { return true }
        return mine > theirs
    }
}

/// A version of one to six dot-separated whole numbers, as Chrome's manifest
/// requires and as the catalog's publishers tag their releases. Anything else,
/// such as `1.2.0-beta.1`, is refused rather than guessed at, since a wrong
/// guess either skips a release or pins someone to a beta.
struct WebExtensionVersion: Comparable {
    let parts: [Int]

    init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...6).contains(pieces.count) else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard (1...9).contains(piece.count),
                  piece.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        parts = numbers
    }

    /// Pads the shorter with zeros, so 3.1.0 equals 3.1.
    private static func padded(_ a: [Int], _ b: [Int]) -> ([Int], [Int]) {
        let count = max(a.count, b.count)
        return (a + Array(repeating: 0, count: count - a.count), b + Array(repeating: 0, count: count - b.count))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let (a, b) = padded(lhs.parts, rhs.parts)
        return a.lexicographicallyPrecedes(b)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        let (a, b) = padded(lhs.parts, rhs.parts)
        return a == b
    }
}

public enum WebExtensionSourceError: LocalizedError, Equatable {
    case invalidSource
    case rateLimited
    case badResponse(Int)
    case unreadableResponse
    case noRelease
    case noChecksum
    case untrustedDownload
    case tooLarge
    case checksumMismatch
    case versionMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "This catalog entry has a bad source address."
        case .rateLimited:
            return "The publisher's server asked Chorus to wait. Chorus will try again later."
        case .badResponse(404):
            return "The publisher's server can't find this extension. It may have moved."
        case .badResponse(let status):
            return "The publisher's server answered with error \(status)."
        case .unreadableResponse:
            return "Chorus couldn't read the publisher's answer."
        case .noRelease:
            return "The publisher has no release of this extension that Chorus can use."
        case .noChecksum:
            return "The publisher gave no checksum for this release, so Chorus can't check the download."
        case .untrustedDownload:
            return "Chorus didn't fetch the download: it is not on the publisher's own site."
        case .tooLarge:
            return "The download is larger than any extension Chorus expects, so Chorus stopped."
        case .checksumMismatch:
            return "The download doesn't match the publisher's checksum, so Chorus didn't install it."
        case .versionMismatch:
            return "The download's version differs from the release it came from. Chorus didn't install it."
        }
    }
}
