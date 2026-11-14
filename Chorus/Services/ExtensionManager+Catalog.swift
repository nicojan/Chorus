import ChorusEngine
import Foundation

/// What `stage` did with a downloaded, reviewed update.
enum StageOutcome: Equatable {
    /// Saved on the record, with this update.
    case staged(WebExtensionRecord.StagedUpdate)
    /// Not staged; its folder was deleted.
    case discarded(Reason)

    enum Reason: Equatable {
        /// The record was removed.
        case gone
        /// The record is not a catalog package.
        case notCatalog
        /// A start (trial or load) is running for it.
        case busy
        /// The record no longer wants this version: one as new or newer is
        /// installed or staged, or the user skipped it.
        case notWanted
        /// The list could not be saved.
        case saveFailed
    }
}

/// Record changes for catalog updates. Every change goes through `commit`, so
/// a folder is deleted only after the list that stops naming it is saved.
extension ExtensionManager {
    func record(_ id: UUID) -> WebExtensionRecord? {
        records.first { $0.id == id }
    }

    func isAdded(catalogID: String) -> Bool {
        records.contains { $0.catalogID == catalogID }
    }

    /// What a downloaded version asks for beyond `record`'s grants. Throws
    /// `ExtensionError.unsupported` below macOS 15.4.
    func reviewUpdate(folder: String, version: String,
                      for record: WebExtensionRecord) async throws -> WebExtensionRecord.StagedUpdate {
        guard #available(macOS 15.4, *), let host else { throw ExtensionError.unsupported }
        return try await host.reviewUpdate(folder: folder, version: version, for: record, library: library)
    }

    /// Stages a downloaded, reviewed update on the current record in one
    /// synchronous slice, or deletes its folder. The caller hands the folder
    /// over: from here on, this either saves a record naming it or deletes it.
    func stage(_ update: WebExtensionRecord.StagedUpdate, of release: WebExtensionRelease,
               for id: UUID) -> StageOutcome {
        let outcome = stagingOutcome(update, of: release, for: id)
        if case .discarded = outcome {
            // Refuses a folder any record names, so a saved one never goes.
            discard(.package(folder: update.folder))
        }
        return outcome
    }

    private func stagingOutcome(_ update: WebExtensionRecord.StagedUpdate, of release: WebExtensionRelease,
                                for id: UUID) -> StageOutcome {
        guard let current = record(id) else { return .discarded(.gone) }
        guard current.catalogID != nil, case .package = current.source else { return .discarded(.notCatalog) }
        // Restaging while it loads would delete the folder a trial reads.
        guard !isBusy(id) else { return .discarded(.busy) }
        guard current.wantsUpdate(to: release) else { return .discarded(.notWanted) }
        let carried = Self.carryingApproval(update, from: current.stagedUpdate)
        // A replaced staged folder is deleted by commit, after the save.
        guard commit(records.map { $0.id == id ? $0.staging(carried) : $0 }) else { return .discarded(.saveFailed) }
        return .staged(carried)
    }

    /// The user's yes in the review sheet. False, changing nothing, unless
    /// `folder` is still the staged update and it still waits for an OK, so
    /// a version restaged while the sheet was open never gets this yes.
    @discardableResult
    func approveStagedUpdate(of id: UUID, folder: String) -> Bool {
        guard waitsForOK(id, folder: folder) else { return false }
        return commit(records.map { $0.id == id ? $0.approvingStagedUpdate() : $0 })
    }

    /// The user's Skip in the review sheet: the version is not offered again,
    /// and its folder goes once the list is saved. Same guards as approve.
    @discardableResult
    func skipStagedUpdate(of id: UUID, folder: String) -> Bool {
        guard waitsForOK(id, folder: folder) else { return false }
        return commit(records.map { $0.id == id ? $0.droppingStagedUpdate(skipping: true) : $0 })
    }

    /// No trial reads a staged update that is not ready, so neither answer
    /// needs `isBusy`.
    private func waitsForOK(_ id: UUID, folder: String) -> Bool {
        guard let staged = record(id)?.stagedUpdate else { return false }
        return staged.folder == folder && !staged.isReady
    }

    /// A new update keeps the user's OK when it asks for nothing beyond what
    /// they already approved, by exact strings.
    static func carryingApproval(_ new: WebExtensionRecord.StagedUpdate,
                                 from old: WebExtensionRecord.StagedUpdate?) -> WebExtensionRecord.StagedUpdate {
        guard let old, old.isApproved,
              Set(new.newPermissions).isSubset(of: old.newPermissions),
              Set(new.newMatchPatterns).isSubset(of: old.newMatchPatterns) else { return new }
        return WebExtensionRecord.StagedUpdate(
            folder: new.folder, version: new.version,
            newPermissions: new.newPermissions, newMatchPatterns: new.newMatchPatterns,
            isApproved: true, attempts: new.attempts
        )
    }
}
