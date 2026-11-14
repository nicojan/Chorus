import CryptoKit
import XCTest
@testable import ChorusEngine

/// Asking a catalog extension's publisher for its latest version, then
/// downloading, verifying and importing it. Every answer here is recorded
/// (trimmed from real GitHub and AMO responses, 2026-11-13); nothing touches
/// the network.
final class WebExtensionSourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-source-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    private let bitwarden = WebExtensionSource.github(owner: "bitwarden", repo: "clients", assetPattern: "dist-chrome-*.zip", tagPrefix: "browser-v")
    private let ubol = WebExtensionSource.github(owner: "uBlockOrigin", repo: "uBOL-home", assetPattern: "uBOLite_*.chromium.zip", tagPrefix: nil)
    private let simpleTranslate = WebExtensionSource.amo(slug: "simple-translate")

    // MARK: - Recorded answers

    /// Bitwarden's repo holds every product. The newest entries are a desktop
    /// release and a browser beta; the newest browser release has a second,
    /// look-alike asset (`bit-dist-chrome-…`) the pattern must not take.
    private let bitwardenReleases = #"""
    [
      {"tag_name": "desktop-v2026.10.4", "draft": false, "prerelease": false, "assets": [
        {"name": "Bitwarden-2026.10.4-universal.dmg", "browser_download_url": "https://github.com/bitwarden/clients/releases/download/desktop-v2026.10.4/Bitwarden-2026.10.4-universal.dmg", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}]},
      {"tag_name": "browser-v2026.11.0", "draft": true, "prerelease": false, "assets": [
        {"name": "dist-chrome-2026.11.0.zip", "browser_download_url": "https://github.com/bitwarden/clients/releases/download/browser-v2026.11.0/dist-chrome-2026.11.0.zip", "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"}]},
      {"tag_name": "browser-v2026.10.3-beta.1", "draft": false, "prerelease": true, "assets": [
        {"name": "dist-chrome-2026.10.3-beta.1.zip", "browser_download_url": "https://github.com/bitwarden/clients/releases/download/browser-v2026.10.3-beta.1/dist-chrome-2026.10.3-beta.1.zip", "digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333"}]},
      {"tag_name": "browser-v2026.10.2", "draft": false, "prerelease": false, "assets": [
        {"name": "bit-dist-chrome-2026.10.2.zip", "browser_download_url": "https://github.com/bitwarden/clients/releases/download/browser-v2026.10.2/bit-dist-chrome-2026.10.2.zip", "digest": "sha256:8d67fc26f8a983a952df3c5cd5f079a04be58205ca041ef7e7cba71ecd2d5087"},
        {"name": "dist-chrome-2026.10.2.zip", "browser_download_url": "https://github.com/bitwarden/clients/releases/download/browser-v2026.10.2/dist-chrome-2026.10.2.zip", "digest": "sha256:2ebc61246a2ea82a65c589b8484e26a5678253fa6474c26dc5b6a7a7fcacbda4"},
        {"name": "dist-firefox-2026.10.2.zip", "browser_download_url": "https://github.com/bitwarden/clients/releases/download/browser-v2026.10.2/dist-firefox-2026.10.2.zip", "digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444"}]},
      {"tag_name": "browser-v2026.10.1", "draft": false, "prerelease": false, "assets": [
        {"name": "dist-chrome-2026.10.1.zip", "browser_download_url": "https://github.com/bitwarden/clients/releases/download/browser-v2026.10.1/dist-chrome-2026.10.1.zip", "digest": "sha256:d7c2d924f0d21ccb36f57e39bdaf732732644e94db95d5dd967629d8b878b93a"}]}
    ]
    """#

    private let ubolReleases = #"""
    [
      {"tag_name": "2026.1110.1816", "draft": false, "prerelease": false, "assets": [
        {"name": "uBOLite_2026.1110.1816.chromium.zip", "browser_download_url": "https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.1110.1816/uBOLite_2026.1110.1816.chromium.zip", "digest": "sha256:85fe5909366e8ada66c5b331bbdbf69cf5100245ed6161b1e4e2f1f848ec7d03"},
        {"name": "uBOLite_2026.1110.1816.safari.zip", "browser_download_url": "https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.1110.1816/uBOLite_2026.1110.1816.safari.zip", "digest": "sha256:3b8188b557a932bec578eebeb8d8b312ae1108e48b0978da25eef488711a9e32"}]}
    ]
    """#

    private let simpleTranslateAddon = #"""
    {"id": 818581, "slug": "simple-translate", "guid": "simple-translate@sienori",
     "current_version": {"version": "3.1.0", "file": {
       "url": "https://addons.mozilla.org/firefox/downloads/file/4979122/simple_translate-3.1.0.xpi",
       "hash": "sha256:c27591eae7363fb0635f21277ac4e0bc5709e6cff299d33bec4de8106c298951",
       "status": "public"}}}
    """#

    // MARK: - A fake network

    /// Answers each URL with what `answers` holds, and records the requests.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { stored } }
        func add(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    }

    private func fetcher(
        _ answers: [String: (Int, Data)],
        headers: [String: String] = [:],
        recorder: Recorder = Recorder()
    ) -> WebExtensionFetcher {
        let scratch = root!
        @Sendable func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
            recorder.add(request)
            let key = request.url?.absoluteString ?? ""
            guard let (status, body) = answers[key] else { throw URLError(.cannotFindHost) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (body, response)
        }
        let network = WebExtensionFetcher.Network(
            data: { try answer($0) },
            download: { request in
                let (body, response) = try answer(request)
                let file = scratch.appending(path: "download-\(UUID().uuidString)")
                try body.write(to: file)
                return (file, response)
            }
        )
        return WebExtensionFetcher(userAgent: "Chorus", network: network)
    }

    private let bitwardenAPI = "https://api.github.com/repos/bitwarden/clients/releases?per_page=100"
    private let ubolAPI = "https://api.github.com/repos/uBlockOrigin/uBOL-home/releases?per_page=100"
    private let simpleTranslateAPI = "https://addons.mozilla.org/api/v5/addons/addon/simple-translate/"

    // MARK: - Latest release

    func testGitHubTakesTheNewestStableReleaseWithTheTagPrefixAndExactAsset() async throws {
        let release = try await fetcher([bitwardenAPI: (200, Data(bitwardenReleases.utf8))]).latestRelease(of: bitwarden)
        XCTAssertEqual(release.version, "2026.10.2", "skips the desktop release, the draft and the beta; drops the tag prefix")
        XCTAssertEqual(release.downloadURL.absoluteString, "https://github.com/bitwarden/clients/releases/download/browser-v2026.10.2/dist-chrome-2026.10.2.zip")
        XCTAssertEqual(release.sha256, "2ebc61246a2ea82a65c589b8484e26a5678253fa6474c26dc5b6a7a7fcacbda4")
    }

    func testGitHubWithoutATagPrefixPicksTheChromiumBuild() async throws {
        let release = try await fetcher([ubolAPI: (200, Data(ubolReleases.utf8))]).latestRelease(of: ubol)
        XCTAssertEqual(release.version, "2026.1110.1816")
        XCTAssertTrue(release.downloadURL.lastPathComponent.hasSuffix(".chromium.zip"))
    }

    func testGitHubRequestNamesNoOneAndAsksForJSON() async throws {
        let recorder = Recorder()
        _ = try await fetcher([ubolAPI: (200, Data(ubolReleases.utf8))], recorder: recorder).latestRelease(of: ubol)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Chorus")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testGitHubReleaseWithoutAChecksumIsRefused() async {
        let noDigest = #"[{"tag_name": "2026.1.1", "draft": false, "prerelease": false, "assets": [{"name": "uBOLite_2026.1.1.chromium.zip", "browser_download_url": "https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.1.1/uBOLite_2026.1.1.chromium.zip"}]}]"#
        await assertThrows(.noChecksum) {
            _ = try await self.fetcher([self.ubolAPI: (200, Data(noDigest.utf8))]).latestRelease(of: self.ubol)
        }
    }

    func testGitHubAssetHostedElsewhereIsRefused() async {
        let elsewhere = #"[{"tag_name": "2026.1.1", "draft": false, "prerelease": false, "assets": [{"name": "uBOLite_2026.1.1.chromium.zip", "browser_download_url": "https://github.com/someone-else/uBOL-home/releases/download/2026.1.1/uBOLite_2026.1.1.chromium.zip", "digest": "sha256:85fe5909366e8ada66c5b331bbdbf69cf5100245ed6161b1e4e2f1f848ec7d03"}]}]"#
        await assertThrows(.untrustedDownload) {
            _ = try await self.fetcher([self.ubolAPI: (200, Data(elsewhere.utf8))]).latestRelease(of: self.ubol)
        }
    }

    func testGitHubWithNoMatchingReleaseSaysSo() async {
        await assertThrows(.noRelease) {
            _ = try await self.fetcher([self.ubolAPI: (200, Data("[]".utf8))]).latestRelease(of: self.ubol)
        }
    }

    func testGitHubRateLimitIsToldApartFromARefusal() async {
        let body = Data(#"{"message": "API rate limit exceeded"}"#.utf8)
        await assertThrows(.rateLimited) {
            _ = try await self.fetcher([self.ubolAPI: (403, body)], headers: ["x-ratelimit-remaining": "0"]).latestRelease(of: self.ubol)
        }
        await assertThrows(.badResponse(403)) {
            _ = try await self.fetcher([self.ubolAPI: (403, body)], headers: ["x-ratelimit-remaining": "41"]).latestRelease(of: self.ubol)
        }
        await assertThrows(.rateLimited) {
            _ = try await self.fetcher([self.ubolAPI: (429, body)]).latestRelease(of: self.ubol)
        }
    }

    /// GitHub orders by date, not version: a patch for an older line can be
    /// listed first. The highest version wins.
    func testGitHubTakesTheHighestVersionNotTheFirstListed() async throws {
        let answer = #"""
        [{"tag_name": "1.9.5", "draft": false, "prerelease": false, "assets": [{"name": "uBOLite_1.9.5.chromium.zip", "browser_download_url": "https://github.com/uBlockOrigin/uBOL-home/releases/download/1.9.5/uBOLite_1.9.5.chromium.zip", "digest": "sha256:85fe5909366e8ada66c5b331bbdbf69cf5100245ed6161b1e4e2f1f848ec7d03"}]},
         {"tag_name": "2.0.1", "draft": false, "prerelease": false, "assets": [{"name": "uBOLite_2.0.1.chromium.zip", "browser_download_url": "https://github.com/uBlockOrigin/uBOL-home/releases/download/2.0.1/uBOLite_2.0.1.chromium.zip", "digest": "sha256:85fe5909366e8ada66c5b331bbdbf69cf5100245ed6161b1e4e2f1f848ec7d03"}]}]
        """#
        let release = try await fetcher([ubolAPI: (200, Data(answer.utf8))]).latestRelease(of: ubol)
        XCTAssertEqual(release.version, "2.0.1")
    }

    func testGitHubSkipsATagThatIsNotAPlainVersion() async throws {
        let answer = #"""
        [{"tag_name": "2.1.0-rc1", "draft": false, "prerelease": false, "assets": [{"name": "uBOLite_2.1.0-rc1.chromium.zip", "browser_download_url": "https://github.com/uBlockOrigin/uBOL-home/releases/download/2.1.0-rc1/uBOLite_2.1.0-rc1.chromium.zip", "digest": "sha256:85fe5909366e8ada66c5b331bbdbf69cf5100245ed6161b1e4e2f1f848ec7d03"}]},
         {"tag_name": "2.0.1", "draft": false, "prerelease": false, "assets": [{"name": "uBOLite_2.0.1.chromium.zip", "browser_download_url": "https://github.com/uBlockOrigin/uBOL-home/releases/download/2.0.1/uBOLite_2.0.1.chromium.zip", "digest": "sha256:85fe5909366e8ada66c5b331bbdbf69cf5100245ed6161b1e4e2f1f848ec7d03"}]}]
        """#
        let release = try await fetcher([ubolAPI: (200, Data(answer.utf8))]).latestRelease(of: ubol)
        XCTAssertEqual(release.version, "2.0.1", "an unmarked release candidate is not taken for a release")
    }

    func testGitHubSkipsAReleaseWithTwoMatchingAssets() async {
        let answer = #"""
        [{"tag_name": "2.0.1", "draft": false, "prerelease": false, "assets": [
          {"name": "uBOLite_2.0.1.chromium.zip", "browser_download_url": "https://github.com/uBlockOrigin/uBOL-home/releases/download/2.0.1/uBOLite_2.0.1.chromium.zip", "digest": "sha256:85fe5909366e8ada66c5b331bbdbf69cf5100245ed6161b1e4e2f1f848ec7d03"},
          {"name": "uBOLite_2.0.1-mv2.chromium.zip", "browser_download_url": "https://github.com/uBlockOrigin/uBOL-home/releases/download/2.0.1/uBOLite_2.0.1-mv2.chromium.zip", "digest": "sha256:85fe5909366e8ada66c5b331bbdbf69cf5100245ed6161b1e4e2f1f848ec7d03"}]}]
        """#
        await assertThrows(.noRelease) {
            _ = try await self.fetcher([self.ubolAPI: (200, Data(answer.utf8))]).latestRelease(of: self.ubol)
        }
    }

    /// An answer that names another release's file under this release's
    /// version is refused, even though the file is in the right repository.
    func testGitHubAssetFromAnotherReleaseIsRefused() async {
        let answer = #"[{"tag_name": "2.0.1", "draft": false, "prerelease": false, "assets": [{"name": "uBOLite_2.0.1.chromium.zip", "browser_download_url": "https://github.com/uBlockOrigin/uBOL-home/releases/download/1.0.0/uBOLite_2.0.1.chromium.zip", "digest": "sha256:85fe5909366e8ada66c5b331bbdbf69cf5100245ed6161b1e4e2f1f848ec7d03"}]}]"#
        await assertThrows(.untrustedDownload) {
            _ = try await self.fetcher([self.ubolAPI: (200, Data(answer.utf8))]).latestRelease(of: self.ubol)
        }
    }

    func testGarbageIsUnreadable() async {
        await assertThrows(.unreadableResponse) {
            _ = try await self.fetcher([self.ubolAPI: (200, Data("<html>".utf8))]).latestRelease(of: self.ubol)
        }
    }

    func testAMOGivesVersionURLAndChecksum() async throws {
        let release = try await fetcher([simpleTranslateAPI: (200, Data(simpleTranslateAddon.utf8))]).latestRelease(of: simpleTranslate)
        XCTAssertEqual(release.version, "3.1.0")
        XCTAssertEqual(release.downloadURL.absoluteString, "https://addons.mozilla.org/firefox/downloads/file/4979122/simple_translate-3.1.0.xpi")
        XCTAssertEqual(release.sha256, "c27591eae7363fb0635f21277ac4e0bc5709e6cff299d33bec4de8106c298951")
    }

    func testAMOFileOffMozillaIsRefused() async {
        let elsewhere = simpleTranslateAddon.replacingOccurrences(of: "https://addons.mozilla.org/firefox", with: "https://example.com/firefox")
        await assertThrows(.untrustedDownload) {
            _ = try await self.fetcher([self.simpleTranslateAPI: (200, Data(elsewhere.utf8))]).latestRelease(of: self.simpleTranslate)
        }
    }

    func testAMOListingWithNoPublicVersionHasNoRelease() async {
        await assertThrows(.noRelease) {
            _ = try await self.fetcher([self.simpleTranslateAPI: (200, Data(#"{"slug": "simple-translate", "current_version": null}"#.utf8))])
                .latestRelease(of: self.simpleTranslate)
        }
    }

    func testGitHubOwnerOrRepoCannotReachAnotherPath() async {
        for source in [WebExtensionSource.github(owner: "a/b", repo: "c", assetPattern: "*", tagPrefix: nil),
                       .github(owner: "a", repo: "..", assetPattern: "*", tagPrefix: nil),
                       .github(owner: "a", repo: "c?x=1", assetPattern: "*", tagPrefix: nil),
                       .github(owner: "", repo: "c", assetPattern: "*", tagPrefix: nil)] {
            await assertThrows(.invalidSource) {
                _ = try await self.fetcher([:]).latestRelease(of: source)
            }
        }
    }

    /// One known-bad URL per check in `publishes`, against a URL that passes.
    func testOnlyTheSourcesOwnDownloadsAreAccepted() {
        let good = "https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.1.1/uBOLite_2026.1.1.chromium.zip"
        XCTAssertTrue(ubol.publishes(URL(string: good)!))
        XCTAssertTrue(ubol.publishes(URL(string: good.replacingOccurrences(of: "uBlockOrigin/uBOL-home", with: "ublockorigin/ubol-home"))!), "GitHub names ignore case")
        let bad = [
            good.replacingOccurrences(of: "https://", with: "http://"),
            good.replacingOccurrences(of: "https://", with: "https://user@"),
            good.replacingOccurrences(of: "github.com", with: "github.com:8443"),
            good.replacingOccurrences(of: "github.com", with: "github.com.evil.example"),
            good + "?x=1",
            good + "#x",
            good.replacingOccurrences(of: "uBOLite_2026.1.1.chromium.zip", with: "uBOLite_2026.1.1.safari.zip"),
            good.replacingOccurrences(of: "/releases/download/2026.1.1/", with: "/releases/download/2026.1.1/../x/"),
            good.replacingOccurrences(of: "/releases/download/2026.1.1/", with: "/releases/download/../"),
            good.replacingOccurrences(of: "/releases/download/", with: "/releases/download/..%2F..%2Fother%2F"),
            good.replacingOccurrences(of: "/releases/download/", with: "/raw/main/"),
            good.replacingOccurrences(of: "2026.1.1/", with: "2026.1.1/sub/"),
        ]
        for url in bad {
            XCTAssertFalse(ubol.publishes(URL(string: url)!), url)
        }

        let amoGood = "https://addons.mozilla.org/firefox/downloads/file/4979122/simple_translate-3.1.0.xpi"
        XCTAssertTrue(simpleTranslate.publishes(URL(string: amoGood)!))
        for url in [
            amoGood.replacingOccurrences(of: "/file/4979122/", with: "/file/abc/"),
            amoGood.replacingOccurrences(of: ".xpi", with: ".zip"),
            amoGood.replacingOccurrences(of: "/firefox/downloads/file/", with: "/user-media/"),
            amoGood.replacingOccurrences(of: "addons.mozilla.org", with: "addons.mozilla.org.evil.example"),
        ] {
            XCTAssertFalse(simpleTranslate.publishes(URL(string: url)!), url)
        }
    }

    func testAMOSlugCannotReachAnotherPath() async {
        await assertThrows(.invalidSource) {
            _ = try await self.fetcher([:]).latestRelease(of: .amo(slug: "../users/1"))
        }
    }

    // MARK: - Download

    private func makeZippedExtension(version: String = "2026.1110.1816") throws -> Data {
        let folder = root.appending(path: "src/dist", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 3, "name": "Probe", "version": "\#(version)"}"#.utf8).write(to: folder.appending(path: "manifest.json"))
        let zip = root.appending(path: "probe.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: zip)
    }

    private func release(for data: Data, sha256: String? = nil, byteCount: Int? = nil) -> WebExtensionRelease {
        WebExtensionRelease(
            version: "2026.1110.1816",
            downloadURL: URL(string: "https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.1110.1816/uBOLite_2026.1110.1816.chromium.zip")!,
            sha256: sha256 ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: byteCount
        )
    }

    private var packagesPresent: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: library.directory.appending(path: "Packages").path)) ?? []
    }

    func testDownloadVerifiesAndImports() async throws {
        let zip = try makeZippedExtension()
        let release = release(for: zip)
        let folder = try await fetcher([release.downloadURL.absoluteString: (200, zip)])
            .download(release, from: ubol, into: library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.packageURL(folder: folder).appending(path: "manifest.json").path))
    }

    func testDownloadWithTheWrongChecksumImportsNothing() async throws {
        let zip = try makeZippedExtension()
        let release = release(for: zip, sha256: String(repeating: "0", count: 64))
        await assertThrows(.checksumMismatch) {
            _ = try await self.fetcher([release.downloadURL.absoluteString: (200, zip)])
                .download(release, from: self.ubol, into: self.library)
        }
        XCTAssertEqual(packagesPresent, [])
    }

    func testDownloadRefusesAReleaseReportedTooLargeBeforeFetching() async throws {
        let recorder = Recorder()
        let release = release(for: Data(), byteCount: WebExtensionFetcher.maxDownloadBytes + 1)
        await assertThrows(.tooLarge) {
            _ = try await self.fetcher([release.downloadURL.absoluteString: (200, Data())], recorder: recorder)
                .download(release, from: self.ubol, into: self.library)
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testDownloadOfTheWrongSizeImportsNothing() async throws {
        let zip = try makeZippedExtension()
        let release = release(for: zip, byteCount: zip.count + 1)
        await assertThrows(.checksumMismatch) {
            _ = try await self.fetcher([release.downloadURL.absoluteString: (200, zip)])
                .download(release, from: self.ubol, into: self.library)
        }
        XCTAssertEqual(packagesPresent, [])
    }

    /// A tag that disagrees with the manifest would be saved as the installed
    /// version, so it is refused and the imported copy removed.
    func testDownloadWhoseManifestDisagreesWithTheTagImportsNothing() async throws {
        let zip = try makeZippedExtension(version: "1.0")
        let release = release(for: zip)
        await assertThrows(.versionMismatch) {
            _ = try await self.fetcher([release.downloadURL.absoluteString: (200, zip)])
                .download(release, from: self.ubol, into: self.library)
        }
        XCTAssertEqual(packagesPresent, [])
    }

    func testDownloadReportsAServerError() async throws {
        let release = release(for: Data())
        await assertThrows(.badResponse(404)) {
            _ = try await self.fetcher([release.downloadURL.absoluteString: (404, Data())])
                .download(release, from: self.ubol, into: self.library)
        }
    }

    func testDownloadRefusesAURLOffTheSource() async throws {
        let zip = try makeZippedExtension()
        let release = release(for: zip)
        await assertThrows(.untrustedDownload) {
            _ = try await self.fetcher([release.downloadURL.absoluteString: (200, zip)])
                .download(release, from: self.bitwarden, into: self.library)
        }
    }

    // MARK: - Versions

    func testVersionOrder() {
        func newer(_ a: String, _ b: String) -> Bool {
            WebExtensionRelease(version: a, downloadURL: URL(string: "https://x/")!, sha256: "").isNewer(than: b)
        }
        XCTAssertTrue(newer("2026.10.2", "2026.10.1"))
        XCTAssertTrue(newer("2026.10.10", "2026.10.9"), "numbers, not text")
        XCTAssertTrue(newer("2026.1110.1816", "2026.1103.1743"))
        XCTAssertTrue(newer("3.1", "3.0.9"))
        XCTAssertFalse(newer("3.1.0", "3.1"), "a trailing zero is the same version")
        XCTAssertFalse(newer("2026.10.1", "2026.10.2"))
        XCTAssertFalse(newer("1.0", "1.0"))
        XCTAssertFalse(newer("1.2.0-beta.1", "1.1"), "a suffixed version is never taken as newer")
        XCTAssertFalse(newer("99999999999999999999", "1"), "an overflowing part is unreadable, not zero")
        XCTAssertFalse(newer("١.٢", "1.0"), "only ASCII digits")
        XCTAssertFalse(newer("", "1.0"))
        XCTAssertFalse(newer("1..2", "1.0"))
        XCTAssertTrue(newer("1.0", "garbage"), "an unreadable installed version updates")
    }

    // MARK: - Helper

    private func assertThrows(
        _ expected: WebExtensionSourceError,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: @escaping () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as WebExtensionSourceError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
