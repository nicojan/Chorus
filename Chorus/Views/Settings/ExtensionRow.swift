import AppKit
import ChorusEngine
import SwiftUI

/// One added extension: its icon, name, status, the status's button if it
/// has one, an on/off switch, and a menu with its settings page and Remove.
struct ExtensionRow: View {
    let record: WebExtensionRecord
    /// Settings' one gate: something is being read or got, or a sheet is up.
    let isBusy: Bool
    let onRemove: () -> Void
    /// Opens the review of the staged update in a folder, unless a sheet is up.
    let onReview: (UUID, String) -> Void
    let onError: (String, String) -> Void
    @Environment(AppState.self) private var appState

    private var manager: ExtensionManager { appState.extensions }
    private var controller: ExtensionCatalogController { appState.extensionCatalog }
    private var name: String { details?.name ?? record.name }

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                statusLine
            }
            Spacer()
            actionButton
            enabledToggle
            moreMenu
        }
    }

    private var status: ExtensionRowStatus {
        ExtensionRowStatus.make(
            record: record,
            failure: manager.failures[record.id],
            runningVersion: details?.version,
            downloadingVersion: controller.downloading[record.id],
            available: controller.available[record.id],
            lastTrial: manager.lastTrials[record.id],
            isInCatalog: record.catalogID.flatMap { controller.catalog.entry(id: $0) } != nil
        )
    }

    private var statusLine: some View {
        let status = status
        return HStack(spacing: 4) {
            if status.showsSpinner { ProgressView().controlSize(.mini) }
            Text(status.text)
                .font(.caption)
                .foregroundStyle(Self.color(for: status.tone))
                .lineLimit(2)
        }
    }

    private static func color(for tone: ExtensionRowStatus.Tone) -> Color {
        switch tone {
        case .normal: return .secondary
        case .warning: return .orange
        case .failure: return .red
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status.action {
        case .none:
            EmptyView()
        case .review(let folder):
            Button("Review\u{2026}") { onReview(record.id, folder) }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .accessibilityLabel("Review the update to \(name)")
                .disabled(isBusy)
        case .update:
            Button("Update", action: updateNow)
                .controlSize(.small)
                .buttonStyle(.bordered)
                .accessibilityLabel("Update \(name)")
                .disabled(isBusy)
        }
    }

    private func updateNow() {
        let id = record.id
        let name = name
        Task {
            do {
                // Settings opens the review only if no sheet is up by now;
                // otherwise the row offers "Review…" for it.
                if let update = try await controller.updateNow(id), !update.isReady {
                    onReview(id, update.folder)
                }
            } catch {
                onError("Chorus couldn't update \(name)", ExtensionManager.describe(error))
            }
        }
    }

    private var enabledToggle: some View {
        Toggle("On", isOn: Binding(
            get: { record.isEnabled },
            set: { value in Task { await manager.setEnabled(record.id, value) } }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel(name)
    }

    private var moreMenu: some View {
        Menu {
            if hasOptions {
                Button("Extension Settings\u{2026}") { openOptions() }
            }
            Button("Remove\u{2026}", role: .destructive, action: onRemove)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More for \(record.name)")
    }

    private var details: (name: String?, version: String?, icon: NSImage?)? {
        guard #available(macOS 15.4, *), let host = manager.host, host.loadedIDs.contains(record.id) else { return nil }
        return host.details(for: record.id)
    }

    private var hasOptions: Bool {
        guard #available(macOS 15.4, *), let host = manager.host else { return false }
        return host.loadedIDs.contains(record.id) && host.hasOptionsPage(record.id)
    }

    private func openOptions() {
        guard #available(macOS 15.4, *) else { return }
        manager.host?.openOptionsPage(record.id)
    }

    @ViewBuilder
    private var icon: some View {
        if let image = details?.icon {
            Image(nsImage: image).resizable().frame(width: 24, height: 24)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 18))
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
        }
    }
}
