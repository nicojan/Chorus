import Foundation
import WebKit

/// Owns the compiled content-blocking rule lists and hands them to the web-view
/// pool. Two independently-toggled lists ship in the app bundle (regenerated per
/// release — see scripts/convert_blocklist.sh): the HaGezi ad/tracker domain
/// list, and a Fanboy annoyances list (cookie notices, newsletter pop-ups,
/// floating bars). There's no runtime download. Compilation is cached on disk by
/// `WKContentRuleListStore` keyed on a content hash, so unchanged lists load fast.
@MainActor
@Observable
final class ContentBlockerManager {

    /// Compiled ad/tracker lists (usually one; more only if a list outgrows the
    /// per-list cap and is split).
    private(set) var adLists: [WKContentRuleList] = []

    /// Compiled annoyance lists (cookie notices, nags, floating bars).
    private(set) var annoyanceLists: [WKContentRuleList] = []

    /// Ad/tracker blocking on/off, mirrored from `AppPreferences`.
    var isEnabled: Bool

    /// Annoyance hiding on/off, mirrored from `AppPreferences`. Separate because
    /// cosmetic hiding is more aggressive and can occasionally hide real content.
    var annoyanceEnabled: Bool

    /// Fired on the main actor once compilation finishes, so the app can
    /// re-attach the lists to any web views built before they were ready.
    var onReady: (() -> Void)?

    private let store = WKContentRuleListStore.default()
    private let adResource: String
    private let annoyanceResource: String
    private var hasStarted = false

    init(
        adResource: String = "hagezi-light",
        annoyanceResource: String = "fanboy-annoyance",
        isEnabled: Bool = true,
        annoyanceEnabled: Bool = false
    ) {
        self.adResource = adResource
        self.annoyanceResource = annoyanceResource
        self.isEnabled = isEnabled
        self.annoyanceEnabled = annoyanceEnabled
    }

    /// The lists to install on a web view, honoring each toggle. Empty until
    /// compilation finishes.
    func enabledLists() -> [WKContentRuleList] {
        (isEnabled ? adLists : []) + (annoyanceEnabled ? annoyanceLists : [])
    }

    /// Loads and compiles the bundled lists once. Safe to call during launch —
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

        var keptIdentifiers: Set<String> = []
        let ads = await compileResource(store, resource: adResource, prefix: adResource)
        adLists = ads.lists
        keptIdentifiers.formUnion(ads.identifiers)

        let annoyances = await compileResource(store, resource: annoyanceResource, prefix: annoyanceResource)
        annoyanceLists = annoyances.lists
        keptIdentifiers.formUnion(annoyances.identifiers)

        guard !adLists.isEmpty || !annoyanceLists.isEmpty else { return }
        await cleanUpStaleLists(store: store, prefixes: [adResource, annoyanceResource], keeping: keptIdentifiers)
        let adCount = adLists.count
        let annoyanceCount = annoyanceLists.count
        AppLogger.general.info("Content blocker ready (ads: \(adCount), annoyances: \(annoyanceCount))")
        onReady?()
    }

    /// Compiles one bundled resource into rule lists, chunking if it exceeds the
    /// per-list cap. Returns the compiled lists and their identifiers.
    private func compileResource(
        _ store: WKContentRuleListStore,
        resource: String,
        prefix: String
    ) async -> (lists: [WKContentRuleList], identifiers: [String]) {
        guard let json = loadBundledJSON(resource) else { return ([], []) }
        let chunks: [String]
        do {
            chunks = try BlocklistSupport.chunk(json: json)
        } catch {
            AppLogger.general.error("Failed to parse bundled list \(resource): \(error.localizedDescription)")
            return ([], [])
        }

        var lists: [WKContentRuleList] = []
        var identifiers: [String] = []
        for (index, chunk) in chunks.enumerated() {
            // Key the identifier on a hash of the *full* source JSON plus the
            // chunk index, not the re-serialised chunk: JSONSerialization doesn't
            // guarantee stable key ordering, so hashing the chunk text could yield
            // a different id each launch (cache miss → recompile).
            let id = BlocklistSupport.identifier(prefix: "\(prefix)-\(index)", forJSON: json)
            identifiers.append(id)
            if let cached = await lookUp(store, identifier: id) {
                lists.append(cached)
            } else if let compiled = await compile(store, identifier: id, json: chunk) {
                lists.append(compiled)
            }
        }
        return (lists, identifiers)
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
                    AppLogger.general.error("Failed to compile list \(identifier): \(error.localizedDescription)")
                }
                continuation.resume(returning: list)
            }
        }
    }

    private func loadBundledJSON(_ resource: String) -> String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            AppLogger.general.error("Bundled list \(resource).json not found")
            return nil
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            AppLogger.general.error("Failed to read bundled list \(resource): \(error.localizedDescription)")
            return nil
        }
    }

    /// Removes rule lists left in the on-disk store by earlier versions of the
    /// bundled lists, so its bytecode doesn't grow every time a list changes.
    private func cleanUpStaleLists(store: WKContentRuleListStore, prefixes: [String], keeping current: Set<String>) async {
        let existing = await availableIdentifiers(store: store)
        for id in existing where prefixes.contains(where: { id.hasPrefix($0) }) && !current.contains(id) {
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
