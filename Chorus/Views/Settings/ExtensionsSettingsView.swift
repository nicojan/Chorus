import AppKit
import ChorusEngine
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Extensions: the extensions the user added, and the ways to add
/// one.
struct ExtensionsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var sheet: ExtensionSheet?
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var manager: ExtensionManager { appState.extensions }

    var body: some View {
        if manager.isSupported {
            content
        } else {
            ContentUnavailableView(
                "Extensions need macOS 15.4",
                systemImage: "puzzlepiece.extension",
                description: Text("Update macOS to use web extensions in Chorus.")
            )
        }
    }

    private var content: some View {
        Form {
            if manager.needsRestart {
                Section {
                    HStack {
                        Text("Pages open now get extensions when Chorus restarts.")
                        Spacer()
                        Button("Restart Chorus") { appState.restartForExtensions() }
                    }
                }
            }

            Section {
                if manager.records.isEmpty {
                    Text("No extensions yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.records) { record in
                        ExtensionRow(record: record) { remove(record) }
                    }
                }
            } header: {
                Text("Extensions")
            } footer: {
                Text("An extension that needs its Mac app can't reach it from Chorus: macOS lets only Safari do that. Where an extension comes in a Chrome version that works alone, such as Bitwarden's, add that one.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Add Safari Extension\u{2026}") { sheet = .safariList }
                    Button("Add from a Folder or File\u{2026}") { pickPackage() }
                    if isWorking { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text("A file can be a .zip, .crx or .xpi, or a folder with a manifest.json in it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .safariList:
                SafariExtensionPicker(isAdded: manager.contains) { found in
                    self.sheet = nil
                    inspect(.appExtension(path: found.path))
                }
            case .confirm(let pending):
                ExtensionConfirmSheet(pending: pending) { agreed in
                    self.sheet = nil
                    finish(pending, agreed: agreed)
                }
            }
        }
        .alert("Chorus couldn't add the extension", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func pickPackage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .zip] + ["crx", "xpi"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose an extension folder, or a .zip, .crx or .xpi file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        Task {
            do {
                let source = try await manager.importPackage(at: url)
                inspect(source)
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func inspect(_ source: WebExtensionRecord.Source) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let summary = try await manager.inspect(source)
                sheet = .confirm(PendingExtension(source: source, summary: summary))
            } catch {
                manager.discard(source)
                errorMessage = ExtensionManager.describe(error)
            }
        }
    }

    private func finish(_ pending: PendingExtension, agreed: Bool) {
        guard agreed else {
            manager.discard(pending.source)
            return
        }
        Task { await manager.add(pending.source, summary: pending.summary) }
    }

    private func remove(_ record: WebExtensionRecord) {
        let alert = NSAlert()
        alert.messageText = "Remove \(record.name)?"
        alert.informativeText = "Chorus deletes the extension's settings and anything it stored."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let dataRemoved = await manager.remove(record.id)
            if !dataRemoved {
                errorMessage = "Chorus removed \(record.name), but couldn't reach the settings it stored, because its files are missing or damaged. They stay on this Mac."
            }
        }
    }
}

/// An extension read and waiting for the user to agree to it.
struct PendingExtension: Identifiable {
    let id = UUID()
    let source: WebExtensionRecord.Source
    let summary: WebExtensionSummary
}

private enum ExtensionSheet: Identifiable {
    case safariList
    case confirm(PendingExtension)

    var id: String {
        switch self {
        case .safariList: return "safari"
        case .confirm(let pending): return pending.id.uuidString
        }
    }
}

/// One added extension: its icon, name, state, an on/off switch, and a menu
/// with its settings page and Remove.
private struct ExtensionRow: View {
    let record: WebExtensionRecord
    let onRemove: () -> Void
    @Environment(AppState.self) private var appState

    private var manager: ExtensionManager { appState.extensions }

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(details?.name ?? record.name)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(manager.failures[record.id] == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("On", isOn: Binding(
                get: { record.isEnabled },
                set: { value in Task { await manager.setEnabled(record.id, value) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
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

    private var status: String {
        if let failure = manager.failures[record.id] { return failure }
        guard record.isEnabled else { return "Off" }
        let source: String
        switch record.source {
        case .appExtension: source = "Safari extension"
        case .package: source = "Added from a file"
        }
        let version = details?.version.map { "Version \($0) · " } ?? ""
        return version + source
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
