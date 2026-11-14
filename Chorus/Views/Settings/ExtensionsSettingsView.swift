import AppKit
import ChorusEngine
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Extensions: the extensions the user added, the catalog to get
/// one from, and the ways to add one of their own.
struct ExtensionsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var sheet: ExtensionSheet?
    @State private var error: SettingsError?
    @State private var isWorking = false

    private var manager: ExtensionManager { appState.extensions }
    private var controller: ExtensionCatalogController { appState.extensionCatalog }

    /// One gate for every button that can open a sheet, so two never show
    /// at once: something is being read or got, or a sheet is up.
    private var isBusy: Bool {
        isWorking || sheet != nil || controller.gettingID != nil || controller.pendingInstall != nil
    }

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

    // Each section is its own struct, and the dialogs sit in a ViewModifier:
    // the macOS 15 compiler gives up on a long chain here.
    private var content: some View {
        Form {
            if manager.needsRestart { RestartBannerSection() }
            InstalledExtensionsSection(isBusy: isBusy, onRemove: remove, onReview: review, onError: showError)
            ExtensionUpdatesSection()
            ExtensionCatalogSections(isBusy: isBusy, onError: showError)
            AddOwnExtensionSection(isWorking: isWorking, isBusy: isBusy,
                                   onSafari: { sheet = .safariList }, onFile: pickPackage)
        }
        .formStyle(.grouped)
        .modifier(ExtensionSettingsDialogs(sheet: $sheet, error: $error, onSafariPick: pickSafari, onConfirm: finish))
    }

    private func showError(_ title: String, _ message: String) {
        error = SettingsError(title: title, message: message)
    }

    private func showAddError(_ message: String) {
        showError("Chorus couldn't add the extension", message)
    }

    /// Opens the review of a staged update, unless another sheet is up. Update
    /// Now calls this when it returns, and the row offers "Review…" for an
    /// update this leaves.
    private func review(_ recordID: UUID, _ folder: String) {
        guard sheet == nil, controller.pendingInstall == nil else { return }
        sheet = .reviewUpdate(recordID: recordID, folder: folder)
    }

    private func pickSafari(_ found: SafariExtensionScanner.Found) {
        sheet = nil
        inspect(.appExtension(path: found.path))
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
                showAddError(error.localizedDescription)
            }
        }
    }

    private func inspect(_ source: WebExtensionRecord.Source) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let summary = try await manager.inspect(source)
                // Never replace a sheet that came up meanwhile.
                guard sheet == nil, controller.pendingInstall == nil else {
                    manager.discard(source)
                    return
                }
                sheet = .confirm(PendingExtension(source: source, summary: summary))
            } catch {
                manager.discard(source)
                showAddError(ExtensionManager.describe(error))
            }
        }
    }

    private func finish(_ pending: PendingExtension, agreed: Bool) {
        sheet = nil
        guard agreed else {
            manager.discard(pending.source)
            return
        }
        Task {
            guard await manager.add(pending.source, summary: pending.summary) == nil else { return }
            showAddError(ExtensionManager.describe(ExtensionManager.ExtensionError.listNotSaved(name: pending.summary.name)))
        }
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
                showError("Chorus couldn't delete everything", "Chorus removed \(record.name), but couldn't reach the settings it stored, because its files are missing or damaged. They stay on this Mac.")
            }
        }
    }
}

/// An extension read and waiting for the user to agree to it.
struct PendingExtension: Identifiable {
    let id = UUID()
    let source: WebExtensionRecord.Source
    let summary: WebExtensionSummary
    /// The catalog entry and release it came from, for one got from the
    /// catalog. Nil for one added from a file or from Safari.
    var catalog: CatalogPick? = nil
}

/// A catalog entry and the release version Get downloaded for it.
struct CatalogPick: Equatable {
    let entry: ExtensionCatalogEntry
    let version: String
}

/// The sheets Settings > Extensions shows itself. Get's confirm sheet is not
/// here: the catalog controller holds it.
enum ExtensionSheet: Identifiable {
    case safariList
    case confirm(PendingExtension)
    /// The review of a staged update that waits for the user's OK.
    case reviewUpdate(recordID: UUID, folder: String)

    var id: String {
        switch self {
        case .safariList: return "safari"
        case .confirm(let pending): return pending.id.uuidString
        case .reviewUpdate(let recordID, let folder): return "review-\(recordID.uuidString)-\(folder)"
        }
    }
}

/// An alert's title and message.
struct SettingsError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Shown once an extension changed that pages already open don't have yet.
private struct RestartBannerSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section {
            HStack {
                Text("Pages open now get extensions when Chorus restarts.")
                Spacer()
                Button("Restart Chorus") { appState.restartForExtensions() }
            }
        }
    }
}

/// The extensions the user added.
private struct InstalledExtensionsSection: View {
    let isBusy: Bool
    let onRemove: (WebExtensionRecord) -> Void
    let onReview: (UUID, String) -> Void
    let onError: (String, String) -> Void
    @Environment(AppState.self) private var appState

    var body: some View {
        Section {
            if appState.extensions.records.isEmpty {
                Text("No extensions yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.extensions.records) { record in
                    ExtensionRow(record: record, isBusy: isBusy, onRemove: { onRemove(record) },
                                     onReview: onReview, onError: onError)
                }
            }
        } header: {
            Text("Extensions")
        }
    }
}

/// The buttons that add an extension from Safari or from a file.
private struct AddOwnExtensionSection: View {
    let isWorking: Bool
    let isBusy: Bool
    let onSafari: () -> Void
    let onFile: () -> Void

    var body: some View {
        Section {
            HStack {
                Button("Add Safari Extension\u{2026}", action: onSafari)
                    .disabled(isBusy)
                Button("Add from a Folder or File\u{2026}", action: onFile)
                    .disabled(isBusy)
                if isWorking { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Your Own Extensions")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("A file can be a .zip, .crx or .xpi, or a folder with a manifest.json in it.")
                Text("An extension that needs its Mac app can't reach it from Chorus: macOS lets only Safari do that. Where an extension comes in a Chrome version that works alone, such as Bitwarden's, add that one.")
            }
            .foregroundStyle(.secondary)
        }
    }
}
