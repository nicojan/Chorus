import AppKit
import ChorusEngine
import SwiftUI

/// Asks about a staged update that asks for more than the installed version.
/// Built from the staged update alone; it never reads the staged folder.
/// Closes itself when the record goes, when another version is staged in its
/// place, or once the update no longer waits for an OK.
struct ExtensionUpdateSheet: View {
    let recordID: UUID
    let folder: String
    let onClose: () -> Void
    /// Shows an alert in Settings: a title and a message.
    let onError: (String, String) -> Void
    @Environment(AppState.self) private var appState

    private var manager: ExtensionManager { appState.extensions }

    /// The record and its update, while the update is the one this sheet
    /// asks about and still waits for an OK.
    private var waiting: (record: WebExtensionRecord, update: WebExtensionRecord.StagedUpdate)? {
        guard let record = manager.record(recordID), let update = record.stagedUpdate,
              update.folder == folder, !update.isReady else { return nil }
        return (record, update)
    }

    var body: some View {
        Group {
            if let waiting {
                review(waiting.record, waiting.update)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .onChange(of: waiting == nil, initial: true) { _, gone in
            if gone { onClose() }
        }
    }

    private func review(_ record: WebExtensionRecord, _ update: WebExtensionRecord.StagedUpdate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                icon(for: record)
                Text("Update \(record.name) to version \(update.version)?").font(.headline)
            }
            asks(update)
            Text("Chorus installs it the next time it starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(width: 440)
        .frame(minHeight: 260)
    }

    private func asks(_ update: WebExtensionRecord.StagedUpdate) -> some View {
        let asks = Self.asks(newPermissions: update.newPermissions, newMatchPatterns: update.newMatchPatterns)
        return VStack(alignment: .leading, spacing: 4) {
            Text("This version asks for more than the one you have. If you allow it, it can also:")
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(asks.lines, id: \.self) { line in
                Label(line, systemImage: "checkmark").labelStyle(.titleAndIcon)
            }
            if let caption = asks.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the sheet lists for an update's new asks.
    struct Asks: Equatable {
        /// One checkmark line each.
        let lines: [String]
        /// The asks with no line of their own, by raw name, or nil when
        /// every ask has a line.
        let caption: String?
    }

    /// Every new ask shows up: as a line, or by raw name in the caption. A
    /// permission with no line, and match patterns that make no site line,
    /// go in the caption, so the sheet never claims new asks and then lists
    /// nothing.
    nonisolated static func asks(newPermissions: [String], newMatchPatterns: [String]) -> Asks {
        let site = WebExtensionPermissionText.siteLine(forMatchPatterns: newMatchPatterns)
        let lines = (site.map { [$0] } ?? []) + WebExtensionPermissionText.lines(forPermissions: newPermissions)
        let quiet = newPermissions.filter { WebExtensionPermissionText.lines(forPermissions: [$0]).isEmpty }
        let unlisted = quiet + (site == nil ? newMatchPatterns : [])
        let caption = unlisted.isEmpty ? nil : "It also asks for: \(unlisted.joined(separator: ", "))."
        return Asks(lines: lines, caption: caption)
    }

    private var buttons: some View {
        HStack {
            Button("Skip This Version") {
                answer { manager.skipStagedUpdate(of: recordID, folder: folder) }
            }
            Spacer()
            Button("Not Now", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("Allow Update") {
                answer { manager.approveStagedUpdate(of: recordID, folder: folder) }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// Runs Allow or Skip and closes. A false result is an alert only when
    /// this update still waits for an OK, meaning the save failed; a folder
    /// restaged or gone meanwhile closes quietly.
    private func answer(_ save: () -> Bool) {
        let name = waiting?.record.name ?? ""
        let saved = save()
        let saveFailed = !saved && waiting != nil
        onClose()
        if saveFailed {
            onError("Chorus couldn't update \(name)", "Chorus couldn't save its list of extensions, so nothing changed.")
        }
    }

    @ViewBuilder
    private func icon(for record: WebExtensionRecord) -> some View {
        if let image = runningIcon(record.id) {
            Image(nsImage: image).resizable().frame(width: 48, height: 48)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32))
                .frame(width: 48, height: 48)
                .foregroundStyle(.secondary)
        }
    }

    private func runningIcon(_ id: UUID) -> NSImage? {
        guard #available(macOS 15.4, *), let host = manager.host, host.loadedIDs.contains(id) else { return nil }
        return host.details(for: id)?.icon
    }
}
