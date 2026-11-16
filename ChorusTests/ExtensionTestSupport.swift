import CryptoKit
import WebKit
import XCTest
@testable import Chorus
@testable import ChorusEngine

/// Holds every extension background start until the test opens it, through
/// the host's test seam. Once open, it lets later starts through at once,
/// with the same result.
@available(macOS 15.4, *)
@MainActor
final class BackgroundGate {
    /// Starts that reached the gate, so held ones only.
    private(set) var starts = 0
    /// The record ids of those starts, in the order they arrived.
    private(set) var reached: [UUID] = []
    private var waiting: [CheckedContinuation<Void, Error>] = []
    private var result: Result<Void, Error>?

    /// `holding` nil holds every start. Otherwise only those records' starts
    /// are held, and the rest start as the host would start them.
    func install(on host: WebExtensionHost, holding: Set<UUID>? = nil) {
        host.startBackgroundContent = { [self] context in
            guard Self.isHeld(context, holding: holding) else { return try await context.loadBackgroundContent() }
            try await self.pass(UUID(uuidString: context.uniqueIdentifier))
        }
    }

    private static func isHeld(_ context: WKWebExtensionContext, holding: Set<UUID>?) -> Bool {
        guard let holding else { return true }
        return UUID(uuidString: context.uniqueIdentifier).map(holding.contains) ?? false
    }

    func open(failing failure: Error? = nil) {
        let outcome: Result<Void, Error> = failure.map { .failure($0) } ?? .success(())
        result = outcome
        let held = waiting
        waiting = []
        held.forEach { $0.resume(with: outcome) }
    }

    /// Waits until `count` starts have reached the gate. Fails the test
    /// after five seconds.
    func waitForStarts(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while starts < count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if starts < count {
            XCTFail("\(starts) of \(count) background starts reached the gate in 5 s", file: file, line: line)
        }
    }

    private func pass(_ id: UUID?) async throws {
        starts += 1
        reached = reached + (id.map { [$0] } ?? [])
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { waiting = waiting + [$0] }
    }
}

/// Extension folders and zips for tests, written under a test's own folder.
enum ExtensionFixtures {
    /// An unpacked MV3 extension named Probe. With `background`, it has a
    /// service worker, so a `BackgroundGate` can hold its load.
    static func folder(in root: URL, version: String = "2.1", permissions: [String] = ["storage"],
                       background: Bool = false) throws -> URL {
        let folder = root.appending(path: "ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let worker = background ? #", "background": {"service_worker": "bg.js"}"# : ""
        let manifest = #"{"manifest_version": 3, "name": "Probe", "version": "\#(version)", "permissions": [\#(list)], "action": {}\#(worker)}"#
        try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
        if background {
            try Data("self.started = true;".utf8).write(to: folder.appending(path: "bg.js"))
        }
        return folder
    }

    /// A probe whose background appends every `runtime.onInstalled` and
    /// `runtime.onStartup` it gets to `events` in `chrome.storage.local`, and
    /// whose `events.html` page reads them back. Copied from the engine's
    /// `WebExtensionInstallEventTests`. With `broken`, the worker throws on
    /// its first line, which WebKit records as a failed background.
    static func eventProbe(in root: URL, version: String, broken: Bool = false) throws -> URL {
        let folder = root.appending(path: "probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Installed Probe", "description": "Records install events.",
            "version": version, "permissions": ["storage"],
            "background": ["service_worker": "bg.js"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "manifest.json"))
        try Data(((broken ? "throw new Error('boom');\n" : "") + eventWorker).utf8).write(to: folder.appending(path: "bg.js"))
        try Data(#"<!doctype html><html><head><script src="events.js"></script></head><body></body></html>"#.utf8)
            .write(to: folder.appending(path: "events.html"))
        try Data("""
        window.readEvents = async () => JSON.stringify((await chrome.storage.local.get('events')).events ?? []);
        window.probeReady = 'yes';
        """.utf8).write(to: folder.appending(path: "events.js"))
        return folder
    }

    /// Listeners at the top level, as Chrome requires. One promise chain keeps
    /// the events in order; a failed save is saved as an event too.
    private static let eventWorker = """
    let saving = Promise.resolve();
    const save = (event) => {
      saving = saving.then(async () => {
        const stored = await chrome.storage.local.get('events');
        await chrome.storage.local.set({events: [...(stored.events ?? []), event]});
      }).catch((error) => {
        saving = Promise.resolve();
        save({reason: 'error: ' + error, previous: null, version: 'none'});
      });
    };
    const version = chrome.runtime.getManifest().version;
    chrome.runtime.onInstalled.addListener((details) => {
      save({reason: details.reason, previous: details.previousVersion ?? null, version});
    });
    chrome.runtime.onStartup.addListener(() => save({reason: 'startup', previous: null, version}));
    """

    struct Zip {
        let data: Data
        let sha256: String
        var size: Int { data.count }
    }

    /// `folder` zipped with ditto, as a publisher would post it.
    static func zip(of folder: URL) throws -> Zip {
        let zip = folder.deletingLastPathComponent().appending(path: "\(folder.lastPathComponent).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        let data = try Data(contentsOf: zip)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Zip(data: data, sha256: digest)
    }

    /// Where an AMO listing's file number `file` downloads from.
    static func amoDownloadURL(file: Int) -> String {
        "https://addons.mozilla.org/firefox/downloads/file/\(file)/probe.xpi"
    }

    static func amoAPIURL(slug: String) -> String {
        "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/"
    }

    static func githubAPIURL(owner: String, repo: String) -> String {
        "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=100"
    }

    /// AMO's answer for a listing whose current version is `version`.
    static func amoAnswer(version: String, file: Int, zip: Zip) -> Data {
        let json = #"{"current_version":{"version":"\#(version)","file":{"url":"\#(amoDownloadURL(file: file))","hash":"sha256:\#(zip.sha256)","size":\#(zip.size)}}}"#
        return Data(json.utf8)
    }

    /// GitHub's answer listing one release tagged `version` with one asset.
    static func githubAnswer(owner: String, repo: String, version: String, asset: String, zip: Zip) -> Data {
        let url = "https://github.com/\(owner)/\(repo)/releases/download/\(version)/\(asset)"
        let json = #"[{"tag_name":"\#(version)","draft":false,"prerelease":false,"assets":[{"name":"\#(asset)","browser_download_url":"\#(url)","digest":"sha256:\#(zip.sha256)","size":\#(zip.size)}]}]"#
        return Data(json.utf8)
    }
}

/// Lets a stubbed download wait until the test opens it.
actor DownloadGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiting = waiting + [$0] }
    }

    func open() {
        isOpen = true
        let held = waiting
        waiting = []
        held.forEach { $0.resume() }
    }

    /// Waits until `count` downloads have reached the gate, or five seconds.
    func waitForArrivals(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while arrivals < count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A network that answers only the URLs in its table and records every
/// request. Any other URL throws `cannotFindHost`, so a test can never reach
/// the real network.
final class StubNetwork: @unchecked Sendable {
    struct Answer: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data

        init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    private let lock = NSLock()
    private var answers: [String: Answer] = [:]
    private var recorded: [String] = []
    private let scratch: URL
    private let downloadGate: DownloadGate?

    init(scratch: URL, downloadGate: DownloadGate? = nil) {
        self.scratch = scratch
        self.downloadGate = downloadGate
    }

    /// Every URL asked for, in order.
    var requests: [String] { lock.withLock { recorded } }

    func requests(to prefix: String) -> [String] {
        requests.filter { $0.hasPrefix(prefix) }
    }

    func answer(_ url: String, with answer: Answer) {
        lock.withLock { answers = answers.merging([url: answer]) { $1 } }
    }

    var fetcher: WebExtensionFetcher {
        WebExtensionFetcher(userAgent: "Chorus", network: network)
    }

    var network: WebExtensionFetcher.Network {
        WebExtensionFetcher.Network(
            data: { [self] request in try self.respond(to: request) },
            download: { [self] request in
                let (body, response) = try self.respond(to: request)
                if let gate = self.downloadGate { await gate.wait() }
                let file = self.scratch.appending(path: "download-\(UUID().uuidString)")
                try body.write(to: file)
                return (file, response)
            }
        )
    }

    private func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        let key = request.url?.absoluteString ?? ""
        let found: Answer? = lock.withLock {
            recorded = recorded + [key]
            return answers[key]
        }
        guard let found, let url = request.url else { throw URLError(.cannotFindHost) }
        let response = HTTPURLResponse(url: url, statusCode: found.status, httpVersion: nil, headerFields: found.headers)!
        return (found.body, response)
    }
}

/// One event an `ExtensionFixtures.eventProbe` saved.
struct ProbeEvent: Decodable, Equatable, CustomStringConvertible {
    let reason: String
    let previous: String?
    let version: String

    static func startup(_ version: String) -> ProbeEvent { ProbeEvent(reason: "startup", previous: nil, version: version) }

    var description: String { "\(reason) \(version)" + (previous.map { " from \($0)" } ?? "") }
}

extension XCTestCase {
    /// Reads an event probe's saved events from its own page once at least
    /// `count` have arrived and two reads a second apart agree. Fails the
    /// test, naming the last script error, when they never settle.
    @available(macOS 15.4, *)
    @MainActor
    func settledEvents(of id: UUID, host: WebExtensionHost, atLeast count: Int,
                       file: StaticString = #filePath, line: UInt = #line) async throws -> [ProbeEvent] {
        let context = try XCTUnwrap(host.contexts[id], file: file, line: line)
        let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration, file: file, line: line))
        page.load(URLRequest(url: context.baseURL.appending(path: "events.html")))
        let deadline = Date().addingTimeInterval(15)
        var previous: [ProbeEvent]?
        var lastRead: [ProbeEvent] = []
        var lastError: Error?
        while Date() < deadline {
            do {
                let json = try await page.callAsyncJavaScript(
                    "return window.probeReady === 'yes' && location.href.endsWith('events.html') ? await readEvents() : null",
                    contentWorld: .page
                ) as? String
                if let json {
                    let found = try JSONDecoder().decode([ProbeEvent].self, from: Data(json.utf8))
                    lastRead = found
                    if found.count >= count, found == previous { return found }
                    previous = found.count >= count ? found : nil
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: previous == nil ? .milliseconds(200) : .seconds(1))
        }
        XCTFail("events never settled at \(count) or more; last read \(lastRead), last error \(String(describing: lastError))",
                file: file, line: line)
        return lastRead
    }
}
