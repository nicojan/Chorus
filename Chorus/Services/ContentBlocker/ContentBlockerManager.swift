import Foundation
import WebKit

/// Owns the compiled content-blocking rule lists and hands them to the web-view
/// pool. The rule JSON ships in the app bundle (regenerated per release from a
/// pinned HaGezi Light snapshot — see scripts/convert_blocklist.sh), so there is
/// no runtime download or on-device conversion. Compilation is cached on disk by
/// `WKContentRuleListStore` keyed on a content hash, so only a changed list
/// recompiles; unchanged lists load fast on later launches.
@MainActor
@Observable
final class ContentBlockerManager {

    /// The compiled lists to attach to every eligible web view. Empty until
    /// compilation finishes (or if it fails); almost always a single element —
    /// only a list that outgrows the per-list cap splits into several.
    private(set) var compiledLists: [WKContentRuleList] = []

    /// Global on/off, mirrored from `AppPreferences`. When false, `enabledLists()`
    /// returns nothing so no web view blocks.
    var isEnabled: Bool

    /// Fired on the main actor once compilation finishes, so the app can
    /// re-attach the lists to any web views built before they were ready.
    var onReady: (() -> Void)?

    private let store = WKContentRuleListStore.default()
    private let bundledResource: String
    private let identifierPrefix = "hagezi-light"
    private var hasStarted = false

    init(bundledResource: String = "hagezi-light", isEnabled: Bool = true) {
        self.bundledResource = bundledResource
        self.isEnabled = isEnabled
    }

    /// The lists to install on a web view: the compiled lists when blocking is
    /// enabled, otherwise empty. Also empty until compilation finishes.
    func enabledLists() -> [WKContentRuleList] {
        isEnabled ? compiledLists : []
    }

    /// Loads and compiles the bundled list once. Safe to call during launch —
    /// WebKit does the work off the main thread and `onReady` fires when done.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task { await loadAndCompile() }
    }

    private func loadAndCompile() async {
        guard let store else {
            AppLogger.general.error("Content rule list store unavailable; blocking disabled")
            return
        }
        guard let json = loadBundledJSON() else { return }

        let chunks: [String]
        do {
            chunks = try BlocklistSupport.chunk(json: json)
        } catch {
            AppLogger.general.error("Failed to parse bundled blocklist: \(error.localizedDescription)")
            return
        }

        var lists: [WKContentRuleList] = []
        var identifiers: [String] = []
        for (index, chunk) in chunks.enumerated() {
            // Key each chunk's identifier on a hash of the *full* source JSON
            // plus the chunk index, not the re-serialised chunk: JSONSerialization
            // doesn't guarantee stable key ordering, so hashing the chunk text
            // could yield a different id each launch (cache miss → recompile).
            let id = BlocklistSupport.identifier(prefix: "\(identifierPrefix)-\(index)", forJSON: json)
            identifiers.append(id)
            if let cached = await lookUp(store, identifier: id) {
                lists.append(cached)
            } else if let compiled = await compile(store, identifier: id, json: chunk) {
                lists.append(compiled)
            }
        }

        guard !lists.isEmpty else { return }
        compiledLists = lists
        await cleanUpStaleLists(store: store, keeping: Set(identifiers))
        AppLogger.general.info("Content blocker ready (\(lists.count) list(s))")
        onReady?()
    }

    /// Wraps the completion-handler store APIs in continuations. The synthesized
    /// async overloads don't resolve cleanly here, so we bridge them explicitly.
    private func lookUp(_ store: WKContentRuleListStore, identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private func compile(_ store: WKContentRuleListStore, identifier: String, json: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error {
                    AppLogger.general.error("Failed to compile blocklist \(identifier): \(error.localizedDescription)")
                }
                continuation.resume(returning: list)
            }
        }
    }

    private func loadBundledJSON() -> String? {
        guard let url = Bundle.main.url(forResource: bundledResource, withExtension: "json") else {
            AppLogger.general.error("Bundled blocklist \(self.bundledResource).json not found")
            return nil
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            AppLogger.general.error("Failed to read bundled blocklist: \(error.localizedDescription)")
            return nil
        }
    }

    /// Removes rule lists left in the on-disk store by earlier versions of the
    /// bundled list, so its bytecode doesn't grow every time the list changes.
    private func cleanUpStaleLists(store: WKContentRuleListStore, keeping current: Set<String>) async {
        let existing = await availableIdentifiers(store: store)
        for id in existing where id.hasPrefix(identifierPrefix) && !current.contains(id) {
            store.removeContentRuleList(forIdentifier: id) { _ in }
        }
    }

    private func availableIdentifiers(store: WKContentRuleListStore) async -> [String] {
        await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { ids in
                continuation.resume(returning: ids ?? [])
            }
        }
    }
}
