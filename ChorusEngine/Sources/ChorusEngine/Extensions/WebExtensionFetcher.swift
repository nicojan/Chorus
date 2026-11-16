import CryptoKit
import Foundation

/// Asks a catalog extension's source for its latest release, and downloads,
/// checks and imports one. Requests carry a plain user agent and nothing that
/// identifies the person: no cookies, no cache, no credentials.
public struct WebExtensionFetcher: Sendable {
    /// How the fetcher reaches the network. Swapped out in tests so they never
    /// use it. `download` saves the body to a file the caller then removes.
    public struct Network: Sendable {
        public let data: @Sendable (URLRequest) async throws -> (Data, URLResponse)
        public let download: @Sendable (URLRequest) async throws -> (URL, URLResponse)

        public init(
            data: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
            download: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse)
        ) {
            self.data = data
            self.download = download
        }

        /// An ephemeral session, so nothing a server sets is kept or sent back.
        public static let live: Network = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            let session = URLSession(configuration: configuration)
            return Network(
                data: { try await session.data(for: $0) },
                download: { try await session.download(for: $0) }
            )
        }()
    }

    /// The largest download Chorus takes. Bitwarden's Chrome zip, the largest
    /// in the catalog, was 25.7 MB in November 2026.
    public static let maxDownloadBytes = 100_000_000

    private let userAgent: String
    private let network: Network

    public init(userAgent: String, network: Network = .live) {
        self.userAgent = userAgent
        self.network = network
    }

    /// The newest release the source publishes that Chorus can use.
    public func latestRelease(of source: WebExtensionSource) async throws -> WebExtensionRelease {
        guard let url = source.apiURL else { throw WebExtensionSourceError.invalidSource }
        var request = prepared(URLRequest(url: url))
        if case .github = source {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await network.data(request)
        try Self.check(response)
        return try source.release(fromAPIAnswer: data)
    }

    /// Downloads `release`, checks its size, its sha256 and the version in its
    /// manifest, and imports it into `library`. Returns the new package
    /// folder. Nothing stays in the library when any check fails.
    public func download(
        _ release: WebExtensionRelease,
        from source: WebExtensionSource,
        into library: WebExtensionLibrary
    ) async throws -> String {
        guard source.publishes(release.downloadURL) else { throw WebExtensionSourceError.untrustedDownload }
        guard WebExtensionVersion(release.version) != nil else { throw WebExtensionSourceError.versionMismatch }
        if let size = release.byteCount, size > Self.maxDownloadBytes { throw WebExtensionSourceError.tooLarge }

        let (file, response) = try await network.download(prepared(URLRequest(url: release.downloadURL)))
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.check(response)
        let extensionName = release.downloadURL.pathExtension.lowercased()

        return try await Task.detached(priority: .utility) {
            try Self.verifyAndImport(file: file, extensionName: extensionName, release: release, into: library)
        }.value
    }

    // MARK: - Steps

    private func prepared(_ original: URLRequest) -> URLRequest {
        var request = original
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        // GitHub answers an exhausted allowance with 403 and no calls left.
        let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
        if http.statusCode == 429 || (http.statusCode == 403 && remaining == "0") {
            throw WebExtensionSourceError.rateLimited
        }
        throw WebExtensionSourceError.badResponse(http.statusCode)
    }

    /// Blocking work: hashing, unpacking with ditto. Runs off the caller.
    private static func verifyAndImport(
        file: URL, extensionName: String, release: WebExtensionRelease, into library: WebExtensionLibrary
    ) throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? Int.max
        guard size <= maxDownloadBytes else { throw WebExtensionSourceError.tooLarge }
        if let expected = release.byteCount, expected != size { throw WebExtensionSourceError.checksumMismatch }
        guard try sha256(of: file) == release.sha256.lowercased() else {
            AppLogger.extensions.error("Checksum mismatch for \(release.downloadURL.absoluteString, privacy: .public)")
            throw WebExtensionSourceError.checksumMismatch
        }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "chorus-download-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        // The import picks the unpacker by extension; the name itself is ours.
        let named = staging.appending(path: "package.\(extensionName)")
        try fm.copyItem(at: file, to: named)
        let folder = try library.importPackage(from: named)

        // A tag that does not match the manifest would be recorded as the
        // installed version and could make every later release look older.
        let manifest = WebExtensionLibrary.readManifest(at: library.packageURL(folder: folder))
        let manifestVersion = (manifest?["version"] as? String).flatMap(WebExtensionVersion.init)
        guard let manifestVersion, manifestVersion == WebExtensionVersion(release.version) else {
            library.removePackage(folder: folder)
            AppLogger.extensions.error("Version \(release.version, privacy: .public) differs from the manifest's \(manifest?["version"] as? String ?? "none", privacy: .public)")
            throw WebExtensionSourceError.versionMismatch
        }
        return folder
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
