import Foundation

/// One web extension the user added, as the library stores it. Pure data: the
/// running extension lives in `WebExtensionHost`, which builds it from this.
public struct WebExtensionRecord: Codable, Sendable, Equatable, Identifiable {
    /// Where the extension's files come from.
    public enum Source: Codable, Sendable, Equatable, Hashable {
        /// A Safari web extension installed with a Mac app: the path to its
        /// `.appex`. Chorus reads it in place, so updating the app updates it.
        case appExtension(path: String)
        /// A Chrome, Firefox or Safari build the user picked as a folder, zip,
        /// `.crx` or `.xpi`, copied into the library's Packages folder under
        /// this folder name.
        case package(folder: String)
    }

    /// Also the extension context's `uniqueIdentifier` and the host of its base
    /// URL, so the extension keeps its storage from one launch to the next.
    public let id: UUID
    public let source: Source
    /// The name when it was added, shown when the extension fails to load and
    /// so cannot name itself.
    public let name: String
    public let isEnabled: Bool
    /// `WKWebExtension.Permission` raw values the user granted.
    public let grantedPermissions: [String]
    /// Match pattern strings the user granted, such as `<all_urls>`.
    public let grantedMatchPatterns: [String]
    public let addedAt: Date
    /// The catalog entry this extension came from, or nil for one the user
    /// added by hand. Only a catalog extension updates itself.
    public let catalogID: String?
    /// The version Chorus installed, as the release named it. Nil for one
    /// added by hand or saved before Chorus kept it.
    public let installedVersion: String?
    /// A newer version downloaded and waiting for its next load. See
    /// `WebExtensionRecord+Update.swift`.
    public let stagedUpdate: StagedUpdate?
    /// A version whose trial failed or that the user turned down. Chorus does
    /// not offer it again, but does offer a later one.
    public let skippedVersion: String?

    public init(
        id: UUID = UUID(),
        source: Source,
        name: String,
        isEnabled: Bool = true,
        grantedPermissions: [String],
        grantedMatchPatterns: [String],
        addedAt: Date = Date(),
        catalogID: String? = nil,
        installedVersion: String? = nil
    ) {
        self.init(
            id: id, source: source, name: name, isEnabled: isEnabled,
            grantedPermissions: grantedPermissions, grantedMatchPatterns: grantedMatchPatterns,
            addedAt: addedAt, catalogID: catalogID, installedVersion: installedVersion,
            stagedUpdate: nil, skippedVersion: nil
        )
    }

    /// Every field, with no defaults, so a helper that forgets a new field
    /// fails to compile instead of dropping it.
    init(
        id: UUID,
        source: Source,
        name: String,
        isEnabled: Bool,
        grantedPermissions: [String],
        grantedMatchPatterns: [String],
        addedAt: Date,
        catalogID: String?,
        installedVersion: String?,
        stagedUpdate: StagedUpdate?,
        skippedVersion: String?
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.isEnabled = isEnabled
        self.grantedPermissions = grantedPermissions
        self.grantedMatchPatterns = grantedMatchPatterns
        self.addedAt = addedAt
        self.catalogID = catalogID
        self.installedVersion = installedVersion
        self.stagedUpdate = stagedUpdate
        self.skippedVersion = skippedVersion
    }

    public func enabled(_ value: Bool) -> WebExtensionRecord {
        WebExtensionRecord(
            id: id, source: source, name: name, isEnabled: value,
            grantedPermissions: grantedPermissions, grantedMatchPatterns: grantedMatchPatterns,
            addedAt: addedAt, catalogID: catalogID, installedVersion: installedVersion,
            stagedUpdate: stagedUpdate, skippedVersion: skippedVersion
        )
    }

    public func granting(permissions: [String], matchPatterns: [String]) -> WebExtensionRecord {
        WebExtensionRecord(
            id: id, source: source, name: name, isEnabled: isEnabled,
            grantedPermissions: permissions.sortedUnique(), grantedMatchPatterns: matchPatterns.sortedUnique(),
            addedAt: addedAt, catalogID: catalogID, installedVersion: installedVersion,
            stagedUpdate: stagedUpdate, skippedVersion: skippedVersion
        )
    }

    /// The URL the extension's own pages load from. Fixed per record, because
    /// WebKit keys an extension page's storage (IndexedDB, local storage) by
    /// origin, and a fresh random origin each launch would empty a password
    /// manager's vault cache every time.
    public var baseURL: URL {
        URL(string: "webkit-extension://\(id.uuidString.lowercased())/")!
    }
}

extension Array where Element == String {
    func sortedUnique() -> [String] {
        Array(Set(self)).sorted()
    }
}
