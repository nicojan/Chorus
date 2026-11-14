import ChorusEngine
import Foundation

/// What one daily pass came to.
enum PassOutcome: Equatable {
    /// Every catalog extension was checked, or skipped for a reason that
    /// lasts (it was busy, or its version failed this session).
    case complete
    /// A publisher was rate-limited or out of reach; check again sooner.
    case retryLater
}

/// Get Extensions and the daily update check. Record changes go through
/// `ExtensionManager`; this holds the schedule, the fetcher, the automatic
/// toggle and the row state that lives in memory only.
///
/// A download belongs to the call that made it until a saved record names it.
/// Every path that does not stage or add it deletes it.
@MainActor
@Observable
final class ExtensionCatalogController {
    /// The one setting this keeps in UserDefaults.
    static let automaticKey = "extensionUpdatesAutomatic"
    static let checkInterval: TimeInterval = 86_400
    static let tick: Duration = .seconds(3_600)
    static let firstRetryDelay: TimeInterval = 3_600

    let catalog: ExtensionCatalog
    private(set) var isAutomatic: Bool
    /// With automatic updates off: the newest release seen per record. Memory only.
    private(set) var available: [UUID: WebExtensionRelease] = [:]
    /// Record id to the version being downloaded and reviewed for it.
    private(set) var downloading: [UUID: String] = [:]
    /// The catalog entry Get is downloading.
    private(set) var gettingID: String?
    /// Drives Get's confirm sheet. Held here, not in the view, so closing
    /// Settings mid-download or with the sheet up leaves nothing stuck.
    private(set) var pendingInstall: PendingExtension?

    @ObservationIgnored let fetcher: WebExtensionFetcher
    @ObservationIgnored private let manager: ExtensionManager
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let mayRun: Bool
    @ObservationIgnored private(set) var lastCompleteCheck: Date?
    @ObservationIgnored private(set) var retryAfter: Date?
    @ObservationIgnored private var limitedPasses = 0
    /// Versions that failed for a reason a retry would not fix. Not tried
    /// again until Chorus relaunches.
    @ObservationIgnored private(set) var failedVersions: [UUID: String] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let review: Review

    /// Works out what a downloaded version asks for beyond a record's grants:
    /// folder, release version, record. A seam for tests; the app uses
    /// `ExtensionManager.reviewUpdate`.
    typealias Review = @MainActor (String, String, WebExtensionRecord) async throws -> WebExtensionRecord.StagedUpdate

    enum UpdateError: LocalizedError, Equatable {
        /// Update Now found the extension starting, or already downloading.
        case stillStarting(name: String)
        /// The update was downloaded, but the list naming it could not be saved.
        case listNotSaved

        var errorDescription: String? {
            switch self {
            case .stillStarting(let name): return "Chorus is still starting \(name). Try again in a moment."
            case .listNotSaved: return "Chorus couldn't save its list of extensions, so nothing changed."
            }
        }
    }

    /// The publisher hosts a pass can be rate-limited by, one at a time.
    private enum SourceHost {
        case github, amo

        init(_ source: WebExtensionSource) {
            switch source {
            case .github: self = .github
            case .amo: self = .amo
            }
        }
    }

    init(manager: ExtensionManager,
         catalog: ExtensionCatalog = .bundled,
         fetcher: WebExtensionFetcher = WebExtensionFetcher(userAgent: "Chorus"),
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         allowUnderTests: Bool = false,
         review: Review? = nil) {
        self.manager = manager
        self.review = review ?? { [manager] folder, version, record in
            try await manager.reviewUpdate(folder: folder, version: version, for: record)
        }
        self.catalog = catalog
        self.fetcher = fetcher
        self.defaults = defaults
        self.now = now
        // App-hosted tests build an AppState; its controller must never
        // reach the network.
        mayRun = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil || allowUnderTests
        isAutomatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    // MARK: - Schedule

    /// Starts the daily check once the enabled extensions have started.
    /// Its first turn runs at once, so every launch checks.
    func launchFinished() {
        guard mayRun, manager.isSupported, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                // Nil once the controller is gone, which ends the loop.
                guard await self?.checkIfDue() != nil else { return }
                try? await Task.sleep(for: ExtensionCatalogController.tick)
            }
        }
    }

    /// Ends the loop. For tests; the app's loop runs until quit.
    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Runs a pass when one is due, and schedules the next. Compares the
    /// wall clock each time, which covers sleep, wake and a changed clock.
    func checkIfDue() async {
        guard Self.isDue(now: now(), lastCompleteCheck: lastCompleteCheck, retryAfter: retryAfter) else { return }
        finish(await runPass())
    }

    private func finish(_ outcome: PassOutcome) {
        switch outcome {
        case .complete:
            lastCompleteCheck = now()
            limitedPasses = 0
            retryAfter = nil
        case .retryLater:
            limitedPasses += 1
            retryAfter = now().addingTimeInterval(Self.retryDelay(afterLimitedPasses: limitedPasses))
        }
    }

    static func isDue(now: Date, lastCompleteCheck: Date?, retryAfter: Date?) -> Bool {
        // A retry time more than a day ahead is stale: the clock moved back.
        if let retryAfter, now < retryAfter, retryAfter.timeIntervalSince(now) <= checkInterval { return false }
        guard let lastCompleteCheck else { return true }
        // The clock moved back.
        if now < lastCompleteCheck { return true }
        return now.timeIntervalSince(lastCompleteCheck) >= checkInterval
    }

    /// 1 h, 2 h, 4 h and so on, capped at a day.
    static func retryDelay(afterLimitedPasses passes: Int) -> TimeInterval {
        let doublings = min(max(passes - 1, 0), 10)
        return min(firstRetryDelay * Double(1 << doublings), checkInterval)
    }

    // MARK: - The pass

    /// Checks each enabled catalog extension once, in list order, one at a
    /// time. Never shows an alert; everything goes to the log.
    func runPass() async -> PassOutcome {
        let ids = manager.records.filter { checkedEntry(for: $0) != nil }.map(\.id)
        var limitedHosts: Set<SourceHost> = []
        var outcome = PassOutcome.complete
        for id in ids {
            // R0: still there, still checked, and not busy.
            guard let record = manager.record(id), let entry = checkedEntry(for: record),
                  downloading[id] == nil, !manager.isBusy(id) else { continue }
            let host = SourceHost(entry.source)
            guard !limitedHosts.contains(host) else {
                outcome = .retryLater
                continue
            }
            do {
                try await check(id, entry)
            } catch WebExtensionSourceError.rateLimited {
                AppLogger.extensions.error("\(entry.name, privacy: .public)'s publisher asked Chorus to wait; checking later")
                limitedHosts = limitedHosts.union([host])
                outcome = .retryLater
            } catch {
                AppLogger.extensions.error("Update check for \(entry.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if Self.isTransient(error) { outcome = .retryLater }
            }
        }
        return outcome
    }

    /// One record's check: ask for the latest release, then remember it or
    /// download it.
    private func check(_ id: UUID, _ entry: ExtensionCatalogEntry) async throws {
        let release = try await fetcher.latestRelease(of: entry.source)
        // R1: the current record, after the await.
        guard manager.record(id)?.wantsUpdate(to: release) == true else {
            available = available.filter { $0.key != id }
            return
        }
        guard failedVersions[id] != release.version else { return }
        guard isAutomatic else {
            available = available.merging([id: release]) { $1 }
            return
        }
        try await downloadReviewStage(id, entry, release, requireAutomatic: true)
    }

    /// The entry a pass checks this record against: an enabled catalog
    /// package whose entry is still in the catalog.
    private func checkedEntry(for record: WebExtensionRecord) -> ExtensionCatalogEntry? {
        guard record.isEnabled else { return nil }
        return catalogEntry(for: record)
    }

    private func catalogEntry(for record: WebExtensionRecord) -> ExtensionCatalogEntry? {
        guard let catalogID = record.catalogID, case .package = record.source else { return nil }
        return catalog.entry(id: catalogID)
    }

    /// A failure a later try could fix: the network, a rate limit, or a
    /// server error.
    static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        switch error as? WebExtensionSourceError {
        case .rateLimited: return true
        case .badResponse(let status): return status >= 500
        default: return false
        }
    }

    // MARK: - Download, review, stage

    /// Shared by the pass, Update Now and the toggle. When this returns, the
    /// download is either named by a saved record or deleted.
    @discardableResult
    private func downloadReviewStage(_ id: UUID, _ entry: ExtensionCatalogEntry, _ release: WebExtensionRelease,
                                     requireAutomatic: Bool) async throws -> StageOutcome {
        guard downloading[id] == nil, !manager.isBusy(id) else { return .discarded(.busy) }
        guard manager.record(id)?.wantsUpdate(to: release) == true else { return .discarded(.notWanted) }
        downloading = downloading.merging([id: release.version]) { $1 }
        defer { downloading = downloading.filter { $0.key != id } }

        var owned: String?
        // Deletes the download on every exit until `stage` takes it over.
        defer { if let owned { manager.library.removePackage(folder: owned) } }
        do {
            owned = try await fetcher.download(release, from: entry.source, into: manager.library)
        } catch {
            if !Self.isTransient(error) { markFailed(id, release.version) }
            throw error
        }

        guard let reviewed = manager.record(id) else { return .discarded(.gone) }
        guard let folder = owned else { return .discarded(.notWanted) }
        let update: WebExtensionRecord.StagedUpdate
        do {
            update = try await review(folder, release.version, reviewed)
        } catch {
            markFailed(id, release.version)
            throw error
        }

        // R2, after the last await: turned off, removed or overtaken during
        // the download or the review.
        if requireAutomatic && !isAutomatic {
            available = available.merging([id: release]) { $1 }
            return .discarded(.notWanted)
        }
        guard let current = manager.record(id) else { return .discarded(.gone) }
        guard current.wantsUpdate(to: release) else { return .discarded(.notWanted) }
        // Hand over: R3 runs inside `stage`, which deletes the folder itself
        // when it refuses.
        owned = nil
        let outcome = manager.stage(update, of: release, for: id)
        if case .staged = outcome {
            available = available.filter { $0.key != id }
        }
        AppLogger.extensions.info("Update of \(entry.name, privacy: .public) to \(release.version, privacy: .public): \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private func markFailed(_ id: UUID, _ version: String) {
        failedVersions = failedVersions.merging([id: version]) { $1 }
    }

    // MARK: - The toggle and Update Now

    /// Saves the choice. Turning it on stages the releases already seen,
    /// with no new requests to the publishers. Turning it off leaves what is
    /// staged alone. Returns the staging task, for tests.
    @discardableResult
    func setAutomatic(_ on: Bool) -> Task<Void, Never>? {
        isAutomatic = on
        defaults.set(on, forKey: Self.automaticKey)
        guard on, mayRun else { return nil }
        return Task { await stageAvailable() }
    }

    private func stageAvailable() async {
        let seen = available.sorted { $0.key.uuidString < $1.key.uuidString }
        for (id, release) in seen {
            guard let record = manager.record(id), let entry = catalogEntry(for: record),
                  failedVersions[id] != release.version else { continue }
            do {
                try await downloadReviewStage(id, entry, release, requireAutomatic: true)
            } catch {
                AppLogger.extensions.error("Update of \(entry.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The row's Update button. Returns the staged update, or nil when
    /// nothing was staged. Throws to the view, which shows an alert, also
    /// when the extension is starting or already downloading.
    func updateNow(_ id: UUID) async throws -> WebExtensionRecord.StagedUpdate? {
        guard let record = manager.record(id), let entry = catalogEntry(for: record) else { return nil }
        let release: WebExtensionRelease
        if let seen = available[id] {
            release = seen
        } else {
            release = try await fetcher.latestRelease(of: entry.source)
        }
        switch try await downloadReviewStage(id, entry, release, requireAutomatic: false) {
        case .staged(let update):
            return update
        case .discarded(.busy):
            throw UpdateError.stillStarting(name: record.name)
        case .discarded(.saveFailed):
            throw UpdateError.listNotSaved
        case .discarded:
            return nil
        }
    }

    // MARK: - Get

    /// Downloads and reads the latest release of `entry`, then asks the user
    /// through `pendingInstall`. Throws to the view, which shows an alert.
    func get(_ entry: ExtensionCatalogEntry) async throws {
        guard gettingID == nil, pendingInstall == nil, !manager.isAdded(catalogID: entry.id) else { return }
        gettingID = entry.id
        defer { gettingID = nil }

        let release = try await fetcher.latestRelease(of: entry.source)
        let folder = try await fetcher.download(release, from: entry.source, into: manager.library)
        let source = WebExtensionRecord.Source.package(folder: folder)
        let summary: WebExtensionSummary
        do {
            summary = try await manager.inspect(source)
        } catch {
            manager.discard(source)
            throw error
        }
        guard !manager.isAdded(catalogID: entry.id), pendingInstall == nil else {
            manager.discard(source)
            return
        }
        pendingInstall = PendingExtension(source: source, summary: summary,
                                          catalog: CatalogPick(entry: entry, version: release.version))
    }

    /// The confirm sheet's answer. Calling it twice is harmless. Throws when
    /// the list could not be saved; the download is deleted then.
    func finishInstall(agreed: Bool) async throws {
        guard let pending = pendingInstall else { return }
        pendingInstall = nil
        guard agreed else {
            manager.discard(pending.source)
            return
        }
        let added = await manager.add(pending.source, summary: pending.summary,
                                      catalogID: pending.catalog?.entry.id, installedVersion: pending.catalog?.version)
        guard added != nil else { throw ExtensionManager.ExtensionError.listNotSaved(name: pending.summary.name) }
    }

    /// The sheet closed without an answer.
    func cancelInstall() {
        guard let pending = pendingInstall else { return }
        pendingInstall = nil
        manager.discard(pending.source)
    }
}
