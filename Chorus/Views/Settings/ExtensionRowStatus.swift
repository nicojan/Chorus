import ChorusEngine
import Foundation

/// The status line under an installed extension's name, and the button
/// beside it, if any. Pure: the row passes in everything it knows, and the
/// first rung of the ladder in `make` that matches wins.
struct ExtensionRowStatus: Equatable {
    /// Secondary, orange or red text.
    enum Tone: Equatable { case normal, warning, failure }

    enum Action: Equatable {
        case none
        /// "Review…": opens the sheet for the staged update in `folder`.
        case review(folder: String)
        /// "Update": stages the available release now.
        case update
    }

    let text: String
    let tone: Tone
    let action: Action
    let showsSpinner: Bool

    init(_ text: String, tone: Tone = .normal, action: Action = .none, showsSpinner: Bool = false) {
        self.text = text
        self.tone = tone
        self.action = action
        self.showsSpinner = showsSpinner
    }

    /// - Parameters:
    ///   - failure: why the extension is not running, if it is not.
    ///   - runningVersion: the running copy's manifest version, if it runs.
    ///   - downloadingVersion: the version being downloaded for it now.
    ///   - available: the newest release seen while automatic updates are off.
    ///   - lastTrial: what its last trial came to this session.
    ///   - isInCatalog: whether its catalog id is still in the catalog.
    static func make(record: WebExtensionRecord, failure: String?, runningVersion: String?,
                     downloadingVersion: String?, available: WebExtensionRelease?,
                     lastTrial: WebExtensionUpdateTrial?, isInCatalog: Bool) -> ExtensionRowStatus {
        if let failure { return ExtensionRowStatus(failure, tone: .failure) }
        if let downloadingVersion {
            return ExtensionRowStatus("Downloading version \(downloadingVersion)\u{2026}", showsSpinner: true)
        }
        if let staged = record.stagedUpdate, !staged.isReady {
            return ExtensionRowStatus("Version \(staged.version) needs your OK", tone: .warning,
                                      action: .review(folder: staged.folder))
        }
        guard record.isEnabled else {
            guard let staged = record.stagedUpdate else { return ExtensionRowStatus("Off") }
            return ExtensionRowStatus("Off \u{00B7} Version \(staged.version) installs when you turn it on")
        }
        if let staged = record.stagedUpdate {
            return ExtensionRowStatus("Version \(staged.version) installs when Chorus restarts")
        }
        if let available, record.wantsUpdate(to: available) {
            return ExtensionRowStatus("Version \(available.version) is available", action: .update)
        }
        let installed = record.installedVersion ?? runningVersion ?? ""
        switch lastTrial {
        case .rolledBack(_, let version, _):
            return ExtensionRowStatus("Version \(version) wouldn't start, so Chorus kept version \(installed)",
                                      tone: .warning)
        case .updated(_, let version):
            return ExtensionRowStatus("Updated to version \(version)")
        case .notAttempted, .cancelled, nil:
            return base(record: record, runningVersion: runningVersion, isInCatalog: isInCatalog)
        }
    }

    /// The installed version, from the record before the manifest, since a
    /// manifest's display version can be a name.
    private static func base(record: WebExtensionRecord, runningVersion: String?, isInCatalog: Bool) -> ExtensionRowStatus {
        if record.catalogID != nil {
            let version = "Version \(record.installedVersion ?? runningVersion ?? "")"
            return ExtensionRowStatus(isInCatalog ? version : version + " \u{00B7} Chorus no longer updates it")
        }
        let source: String
        switch record.source {
        case .appExtension: source = "Safari extension"
        case .package: source = "Added from a file"
        }
        return ExtensionRowStatus((runningVersion.map { "Version \($0) \u{00B7} " } ?? "") + source)
    }
}
