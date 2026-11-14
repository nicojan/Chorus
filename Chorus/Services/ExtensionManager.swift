import AppKit
import ChorusEngine
import Foundation

/// The user's web extensions: the saved list, and the engine host that runs
/// them. The list lives in a JSON file beside the store (see
/// `WebExtensionLibrary`), not in SwiftData, so extensions add no schema
/// version.
///
/// Extensions need macOS 15.4. Below that the host is nil, the list still
/// loads, and Settings says what is needed.
@MainActor
@Observable
final class ExtensionManager {
    /// Names the controller's storage (extension settings, `storage.local`).
    /// Fixed so it survives launches; Debug and release builds keep separate
    /// storage anyway, because WebKit files it under the bundle id.
    static let storageIdentifier = UUID(uuidString: "7C3E9B52-4F1A-4D8E-9A2B-6E0F1C5D8A34")!

    private(set) var records: [WebExtensionRecord]
    /// Why an enabled extension is not running, by record id.
    private(set) var failures: [UUID: String] = [:]
    /// Extensions went from none on to some on while pages were open. Those
    /// pages were built without the extension controller; they get it when
    /// Chorus next starts. Rebuilding them in place would skip the save
    /// handshake the quit path gives chat pages, and drop calls.
    private(set) var needsRestart = false

    let library: WebExtensionLibrary
    /// A library a test made, which may start its extensions.
    private let isTestLibrary: Bool
    /// A `WebExtensionHost` on macOS 15.4 and later. Typed loosely because a
    /// stored property cannot name a type the deployment target lacks.
    @ObservationIgnored private let hostObject: AnyObject?
    /// Records whose staged update is being tried right now.
    @ObservationIgnored private var trialsRunning: Set<UUID> = []
    /// The latest grants reported during a record's trial. They belong to
    /// the new version, so they land only if it does.
    @ObservationIgnored private var grantsDuringTrial: [UUID: Grants] = [:]

    private struct Grants {
        let permissions: [String]
        let matchPatterns: [String]
    }

    /// `storageIdentifier` nil keeps extension data off disk, for tests.
    init(library: WebExtensionLibrary, storageIdentifier: UUID? = ExtensionManager.storageIdentifier) {
        self.library = library
        isTestLibrary = storageIdentifier == nil
        let saved = Self.droppingMissingStagedUpdates(library.loadRecords(), library: library)
        records = saved
        // Packages copied in for an extension the user then didn't add, when
        // Chorus quit with the confirmation up, and folders a saved list
        // stopped naming before they were deleted. A staged update's folder
        // stays. Only here, at launch: during a session a package waiting at
        // the Add confirmation is named by no record yet.
        library.removeUnusedPackages(keeping: Set(saved.flatMap(\.packageFolders)))
        if #available(macOS 15.4, *) {
            let host = WebExtensionHost(storageIdentifier: storageIdentifier)
            host.isActive = saved.contains(where: \.isEnabled)
            hostObject = host
        } else {
            hostObject = nil
        }
    }

    /// Drops a staged update whose folder is gone, without skipping its
    /// version, and saves the list when that changed it. An older Chorus
    /// sweeps the folder away at launch without saving the list, and the
    /// trial would then roll back and skip a version nothing was wrong with.
    private static func droppingMissingStagedUpdates(
        _ records: [WebExtensionRecord],
        library: WebExtensionLibrary
    ) -> [WebExtensionRecord] {
        let fixed = records.map { record in
            guard let staged = record.stagedUpdate,
                  !FileManager.default.fileExists(atPath: library.packageURL(folder: staged.folder).path) else { return record }
            AppLogger.extensions.error("The update of \(record.name, privacy: .public) to \(staged.version, privacy: .public) is gone from disk; dropped, not skipped")
            return record.droppingStagedUpdate(skipping: false)
        }
        guard fixed != records else { return records }
        do {
            try library.saveRecords(fixed)
        } catch {
            AppLogger.extensions.error("Could not save the extension list: \(error.localizedDescription, privacy: .public)")
        }
        return fixed
    }

    /// Beside the store: `Chorus-debug` for a Debug build, `Chorus` for
    /// release, so the two never share a list.
    static var defaultDirectory: URL {
        #if DEBUG
        let folder = "Chorus-debug"
        #else
        let folder = StoreRelocation.folderName
        #endif
        return URL.applicationSupportDirectory.appending(path: folder).appending(path: "Extensions", directoryHint: .isDirectory)
    }

    var isSupported: Bool { hostObject != nil }

    @available(macOS 15.4, *)
    var host: WebExtensionHost? { hostObject as? WebExtensionHost }

    /// What the web view pool talks to.
    var hosting: (any WebExtensionHosting)? { hostObject as? any WebExtensionHosting }

    var enabledIDs: [UUID] { records.filter(\.isEnabled).map(\.id) }

    func isRunning(_ id: UUID) -> Bool {
        guard #available(macOS 15.4, *), let host else { return false }
        return host.loadedIDs.contains(id)
    }

    // MARK: - Launch

    func startEnabled() async {
        // App-hosted tests build an AppState; they must not run the
        // developer's own extensions.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil || isTestLibrary else { return }
        for record in records where record.isEnabled {
            await start(record)
        }
    }

    /// Starts the current copy of `record`, trying its staged update first
    /// when one is ready.
    private func start(_ record: WebExtensionRecord) async {
        guard #available(macOS 15.4, *), let host else { return }
        await tryStagedUpdate(of: record.id, host: host)
        // The current record, not the parameter: the trial may have moved it
        // to the new folder, or dropped the update. When the trial left the
        // new version running, this load does nothing. Turned off or removed
        // during the trial: the trial used up the cancellation, so stop here
        // rather than load the old version.
        guard let current = records.first(where: { $0.id == record.id }), current.isEnabled else { return }
        do {
            try await host.load(current, library: library)
            failures = failures.filter { $0.key != record.id }
            // Turned off or removed while it loaded.
            if records.first(where: { $0.id == record.id })?.isEnabled != true {
                host.unload(record.id)
            }
        } catch {
            guard records.first(where: { $0.id == record.id })?.isEnabled == true else { return }
            failures = failures.merging([record.id: Self.describe(error)]) { $1 }
            AppLogger.extensions.error("Could not start \(record.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tries a ready staged update, with two saves in this order: the
    /// attempt marker before the trial, so a version that crashes the app at
    /// load is given up after `maxAttempts`, then the result, applied to the
    /// current record. Folders go only after a save succeeds.
    @available(macOS 15.4, *)
    private func tryStagedUpdate(of id: UUID, host: WebExtensionHost) async {
        guard let current = records.first(where: { $0.id == id }),
              current.applyingStagedUpdate() != nil else { return }
        guard commit(records.map { $0.id == id ? $0.startingUpdateAttempt() : $0 }),
              let marked = records.first(where: { $0.id == id }),
              let folder = marked.stagedUpdate?.folder else {
            AppLogger.extensions.error("Could not save the update attempt for \(current.name, privacy: .public), so it was not tried")
            return
        }
        let ownsTrial = trialsRunning.insert(id).inserted
        let trial = await host.loadStagedUpdate(of: marked, library: library)
        let grants = ownsTrial ? grantsDuringTrial.removeValue(forKey: id) : nil
        if ownsTrial { trialsRunning.remove(id) }
        // The host was busy with this id: another start's trial or load. No
        // trial ran, so take back the attempt saved for it, or the count
        // drifts up until a healthy version is rolled back as crashing.
        let result = trial == .notAttempted ? .cancelled(folder: folder) : trial
        commit(records.map { $0.id == id ? Self.settle($0, with: result, grants: grants) : $0 })
    }

    /// The trial's result on the current record. Grants reported during the
    /// trial came from the new version: they replace the record's when it
    /// landed, and are dropped otherwise, so the old version keeps the grants
    /// it had.
    private static func settle(_ record: WebExtensionRecord, with trial: WebExtensionUpdateTrial,
                               grants: Grants?) -> WebExtensionRecord {
        let settled = record.settling(trial)
        guard case .updated = trial, let grants, settled.stagedUpdate == nil, record.stagedUpdate != nil else { return settled }
        return settled.granting(permissions: grants.permissions, matchPatterns: grants.matchPatterns)
    }

    // MARK: - Adding

    /// Copies a picked folder or archive into the library. The caller inspects
    /// the result and either adds it or calls `discard(_:)`.
    func importPackage(at url: URL) async throws -> WebExtensionRecord.Source {
        let library = library
        let folder = try await Task.detached { try library.importPackage(from: url) }.value
        return .package(folder: folder)
    }

    /// Throws away a copied package the user decided not to add.
    func discard(_ source: WebExtensionRecord.Source) {
        guard case .package(let folder) = source,
              !records.contains(where: { $0.packageFolders.contains(folder) }) else { return }
        library.removePackage(folder: folder)
    }

    func inspect(_ source: WebExtensionRecord.Source) async throws -> WebExtensionSummary {
        guard #available(macOS 15.4, *), let host else { throw ExtensionError.unsupported }
        return try await host.inspect(source, library: library)
    }

    /// Whether this Safari extension is already in the list.
    func contains(_ source: WebExtensionRecord.Source) -> Bool {
        records.contains { $0.source == source }
    }

    /// Adds an extension the user agreed to, granting what it asked for up
    /// front except talking to its Mac app, which Chorus cannot do.
    @discardableResult
    func add(_ source: WebExtensionRecord.Source, summary: WebExtensionSummary) async -> WebExtensionRecord {
        let record = WebExtensionRecord(
            source: source,
            name: summary.name,
            grantedPermissions: summary.permissions.filter { $0 != WebExtensionPermissionText.nativeMessaging },
            grantedMatchPatterns: summary.matchPatterns
        )
        records = records + [record]
        save()
        activateIfFirst()
        await start(record)
        return record
    }

    // MARK: - Changing

    func setEnabled(_ id: UUID, _ enabled: Bool) async {
        guard let record = records.first(where: { $0.id == id }), record.isEnabled != enabled else { return }
        records = records.map { $0.id == id ? $0.enabled(enabled) : $0 }
        save()
        if enabled {
            activateIfFirst()
            await start(record.enabled(true))
        } else {
            if #available(macOS 15.4, *) { host?.unload(id) }
            failures = failures.filter { $0.key != id }
        }
    }

    /// Takes an extension out: its stored data, its running context, the
    /// copies in Packages (a staged update's too), and its record. Returns false when its stored data could
    /// not be reached and so stays on disk.
    @discardableResult
    func remove(_ id: UUID) async -> Bool {
        guard let record = records.first(where: { $0.id == id }) else { return true }
        // Out of the list first, so a load still in flight sees it gone.
        records = records.filter { $0.id != id }
        failures = failures.filter { $0.key != id }
        let saved = save()
        var dataRemoved = true
        if #available(macOS 15.4, *), let host {
            host.unload(id)
            // Loads the extension from its folder to reach its data, so the
            // folders go after this.
            dataRemoved = await host.removeStoredData(for: record, library: library)
        }
        // A list that did not save still names the folders; the launch sweep
        // takes them once a later save drops the record.
        if saved {
            library.removePackages(releasedFrom: [record], to: records)
        }
        return dataRemoved
    }

    /// Saves grants an extension got or lost while running. During a trial
    /// they are held until the trial settles; see `settle`.
    func updateGrants(_ id: UUID, permissions: [String], matchPatterns: [String]) {
        guard !trialsRunning.contains(id) else {
            grantsDuringTrial[id] = Grants(permissions: permissions, matchPatterns: matchPatterns)
            return
        }
        records = records.map { $0.id == id ? $0.granting(permissions: permissions, matchPatterns: matchPatterns) : $0 }
        save()
    }

    // MARK: - Private

    /// The first extension to go on: from now, new pages get the controller.
    /// Pages built before it lack one until rebuilt.
    private func activateIfFirst() {
        guard #available(macOS 15.4, *), let host, !host.isActive else { return }
        host.isActive = true
        needsRestart = true
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try library.saveRecords(records)
            return true
        } catch {
            AppLogger.extensions.error("Could not save the extension list: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Makes `updated` the list, saves it, and only then deletes the package
    /// folders the old list named and the new one does not. Returns false,
    /// deleting nothing and keeping the list as it was, when the save failed,
    /// so memory never holds a change the disk lacks for a later save to
    /// write out.
    @discardableResult
    private func commit(_ updated: [WebExtensionRecord]) -> Bool {
        let before = records
        records = updated
        guard save() else {
            records = before
            return false
        }
        library.removePackages(releasedFrom: before, to: updated)
        return true
    }

    static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.isEmpty ? "Chorus couldn't start this extension." : text
    }

    enum ExtensionError: LocalizedError {
        case unsupported

        var errorDescription: String? {
            "Extensions need macOS 15.4 or later."
        }
    }
}
