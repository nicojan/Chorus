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

    /// `storageIdentifier` nil keeps extension data off disk, for tests.
    init(library: WebExtensionLibrary, storageIdentifier: UUID? = ExtensionManager.storageIdentifier) {
        self.library = library
        isTestLibrary = storageIdentifier == nil
        let saved = library.loadRecords()
        records = saved
        // Packages copied in for an extension the user then didn't add, when
        // Chorus quit with the confirmation up.
        library.removeUnusedPackages(keeping: Set(saved.compactMap {
            if case .package(let folder) = $0.source { return folder }
            return nil
        }))
        if #available(macOS 15.4, *) {
            let host = WebExtensionHost(storageIdentifier: storageIdentifier)
            host.isActive = saved.contains(where: \.isEnabled)
            hostObject = host
        } else {
            hostObject = nil
        }
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

    private func start(_ record: WebExtensionRecord) async {
        guard #available(macOS 15.4, *), let host else { return }
        do {
            try await host.load(record, library: library)
            failures = failures.filter { $0.key != record.id }
            // Turned off or removed while it loaded.
            if records.first(where: { $0.id == record.id })?.isEnabled != true {
                host.unload(record.id)
            }
        } catch {
            failures = failures.merging([record.id: Self.describe(error)]) { $1 }
            AppLogger.extensions.error("Could not start \(record.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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
              !records.contains(where: { $0.source == source }) else { return }
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

    /// Takes an extension out: its stored data, its running context, the copy
    /// in Packages, and its record. Returns false when its stored data could
    /// not be reached and so stays on disk.
    @discardableResult
    func remove(_ id: UUID) async -> Bool {
        guard let record = records.first(where: { $0.id == id }) else { return true }
        // Out of the list first, so a load still in flight sees it gone.
        records = records.filter { $0.id != id }
        failures = failures.filter { $0.key != id }
        save()
        var dataRemoved = true
        if #available(macOS 15.4, *), let host {
            host.unload(id)
            dataRemoved = await host.removeStoredData(for: record, library: library)
        }
        if case .package(let folder) = record.source {
            library.removePackage(folder: folder)
        }
        return dataRemoved
    }

    /// Saves grants an extension got or lost while running.
    func updateGrants(_ id: UUID, permissions: [String], matchPatterns: [String]) {
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

    private func save() {
        do {
            try library.saveRecords(records)
        } catch {
            AppLogger.extensions.error("Could not save the extension list: \(error.localizedDescription, privacy: .public)")
        }
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
