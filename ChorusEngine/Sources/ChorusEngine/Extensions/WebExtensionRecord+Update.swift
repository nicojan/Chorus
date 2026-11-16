import Foundation

/// Updating a catalog extension, as pure record changes. A newer version is
/// unpacked to a second package folder and staged on the record; the next load
/// tries it, and the record then either moves to it or drops it. Each step
/// returns a new record, and the caller saves it before deleting any folder.
extension WebExtensionRecord {
    /// A downloaded version waiting for its next load. Any field added later
    /// must be Optional, so a list saved by this version still decodes.
    public struct StagedUpdate: Codable, Sendable, Equatable, Hashable {
        /// The package folder holding the new version.
        public let folder: String
        /// The version as the release named it.
        public let version: String
        /// Permissions the new version asks for beyond the grants when it was
        /// staged, sorted, once each.
        public let newPermissions: [String]
        /// Match patterns the new version asks for that no grant covered.
        public let newMatchPatterns: [String]
        /// Whether the user agreed to the new asks.
        public let isApproved: Bool
        /// Trial loads begun and not finished. Saved before each trial, so a
        /// version that crashes the app at load is given up after
        /// `maxAttempts` instead of crashing every launch.
        public let attempts: Int

        public static let maxAttempts = 2

        /// Ready to load: it asks for nothing new, or the user agreed.
        public var isReady: Bool {
            isApproved || (newPermissions.isEmpty && newMatchPatterns.isEmpty)
        }

        public init(
            folder: String,
            version: String,
            newPermissions: [String],
            newMatchPatterns: [String],
            isApproved: Bool = false,
            attempts: Int = 0
        ) {
            self.folder = folder
            self.version = version
            self.newPermissions = newPermissions.sortedUnique()
            self.newMatchPatterns = newMatchPatterns.sortedUnique()
            self.isApproved = isApproved
            self.attempts = attempts
        }

        func approved() -> StagedUpdate {
            StagedUpdate(folder: folder, version: version, newPermissions: newPermissions,
                         newMatchPatterns: newMatchPatterns, isApproved: true, attempts: attempts)
        }

        func counting(_ attempts: Int) -> StagedUpdate {
            StagedUpdate(folder: folder, version: version, newPermissions: newPermissions,
                         newMatchPatterns: newMatchPatterns, isApproved: isApproved, attempts: max(0, attempts))
        }
    }

    /// The package folders this record needs kept: the one it runs from and
    /// the staged one. Empty for a Safari extension.
    public var packageFolders: Set<String> {
        var folders = Set<String>()
        if case .package(let folder) = source { folders.insert(folder) }
        if let staged = stagedUpdate { folders.insert(staged.folder) }
        return folders
    }

    /// Stages `update`, replacing any earlier one. Does nothing for a Safari
    /// extension, which updates with its app.
    public func staging(_ update: StagedUpdate) -> WebExtensionRecord {
        guard case .package = source else { return self }
        return replacingUpdate(update, skippedVersion: skippedVersion)
    }

    /// Marks the staged update as agreed to by the user.
    public func approvingStagedUpdate() -> WebExtensionRecord {
        guard let staged = stagedUpdate else { return self }
        return replacingUpdate(staged.approved(), skippedVersion: skippedVersion)
    }

    /// Drops the staged update. With `skipping`, its version is not offered
    /// again. The caller deletes the folder once the record is saved.
    public func droppingStagedUpdate(skipping: Bool) -> WebExtensionRecord {
        guard let staged = stagedUpdate else { return self }
        return replacingUpdate(nil, skippedVersion: skipping ? staged.version : skippedVersion)
    }

    /// Counts a trial load about to begin. Save this before the trial.
    public func startingUpdateAttempt() -> WebExtensionRecord {
        guard let staged = stagedUpdate else { return self }
        return replacingUpdate(staged.counting(staged.attempts + 1), skippedVersion: skippedVersion)
    }

    /// Takes back a trial that never finished through no fault of the
    /// version, such as the user turning the extension off mid-load.
    public func cancellingUpdateAttempt() -> WebExtensionRecord {
        guard let staged = stagedUpdate else { return self }
        return replacingUpdate(staged.counting(staged.attempts - 1), skippedVersion: skippedVersion)
    }

    /// The record as it runs once the staged update is in: the new folder and
    /// version, and the new asks added to the current grants. Nil unless a
    /// ready update is staged on a package. Grants the extension gave up at
    /// runtime stay given up, since only the new asks are added back.
    public func applyingStagedUpdate() -> WebExtensionRecord? {
        guard let staged = stagedUpdate, staged.isReady, case .package = source else { return nil }
        return WebExtensionRecord(
            id: id, source: .package(folder: staged.folder), name: name, isEnabled: isEnabled,
            grantedPermissions: (grantedPermissions + staged.newPermissions).sortedUnique(),
            grantedMatchPatterns: (grantedMatchPatterns + staged.newMatchPatterns).sortedUnique(),
            addedAt: addedAt, catalogID: catalogID, installedVersion: staged.version,
            stagedUpdate: nil, skippedVersion: nil
        )
    }

    /// Applies a trial's result to this record, which should be the current
    /// one, not the copy the trial ran. A result for a folder other than the
    /// staged one is stale and changes nothing.
    public func settling(_ trial: WebExtensionUpdateTrial) -> WebExtensionRecord {
        guard let folder = trial.folder, stagedUpdate?.folder == folder else { return self }
        switch trial {
        case .notAttempted:
            return self
        case .updated:
            return applyingStagedUpdate() ?? self
        case .rolledBack:
            return droppingStagedUpdate(skipping: true)
        case .cancelled:
            return cancellingUpdateAttempt()
        }
    }

    /// Whether `release` is worth downloading for this record: a catalog
    /// package, newer than what is staged or installed, and not the version
    /// the user skipped.
    public func wantsUpdate(to release: WebExtensionRelease) -> Bool {
        guard catalogID != nil, case .package = source else { return false }
        guard release.isNewer(than: stagedUpdate?.version ?? installedVersion ?? "") else { return false }
        return WebExtensionVersion(release.version) != skippedVersion.flatMap(WebExtensionVersion.init)
    }

    private func replacingUpdate(_ update: StagedUpdate?, skippedVersion: String?) -> WebExtensionRecord {
        WebExtensionRecord(
            id: id, source: source, name: name, isEnabled: isEnabled,
            grantedPermissions: grantedPermissions, grantedMatchPatterns: grantedMatchPatterns,
            addedAt: addedAt, catalogID: catalogID, installedVersion: installedVersion,
            stagedUpdate: update, skippedVersion: skippedVersion
        )
    }
}

/// What a trial load of a staged update came to. Every case but
/// `notAttempted` names the staged folder it was about, so a result can be
/// matched to the record it belongs to.
public enum WebExtensionUpdateTrial: Sendable, Equatable {
    /// Nothing was tried: no ready update, already loaded or loading, or no
    /// attempt marker saved.
    case notAttempted
    /// The new version loaded and is running.
    case updated(folder: String, version: String)
    /// The new version would not load; the old one stays.
    case rolledBack(folder: String, version: String, reason: String)
    /// The load stopped before it finished, such as the user turning the
    /// extension off. Not the version's fault.
    case cancelled(folder: String)

    var folder: String? {
        switch self {
        case .notAttempted: return nil
        case .updated(let folder, _), .rolledBack(let folder, _, _), .cancelled(let folder): return folder
        }
    }
}
