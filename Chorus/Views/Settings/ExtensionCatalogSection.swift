import ChorusEngine
import SwiftUI

/// The automatic-updates switch for the extensions got from the catalog.
struct ExtensionUpdatesSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let controller = appState.extensionCatalog
        Section {
            Toggle("Update extensions automatically", isOn: Binding(
                get: { controller.isAutomatic },
                set: { controller.setAutomatic($0) }
            ))
        } footer: {
            Text("Chorus looks for new versions when it opens and once a day after that. An update that asks for more access waits for your OK.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Get Extensions: an intro, one section per category, and the link to
/// suggest one.
struct ExtensionCatalogSections: View {
    /// Settings' one gate: something is being read or got, or a sheet is up.
    let isBusy: Bool
    let onError: (String, String) -> Void
    @Environment(AppState.self) private var appState

    static let suggestURL = URL(string: "https://github.com/nicojan/Chorus/issues/new?template=suggest-extension.yml")!

    var body: some View {
        Section {
            Text("Chorus downloads each of these from its publisher and checks the file before adding it. We tried each one in Chorus.")
                .foregroundStyle(.secondary)
        } header: {
            Text("Get Extensions")
        }
        ForEach(appState.extensionCatalog.catalog.sections, id: \.category) { section in
            Section {
                ForEach(section.entries) { entry in
                    ExtensionCatalogRow(entry: entry, isBusy: isBusy, onError: onError)
                }
            } header: {
                Text(section.category.title)
            }
        }
        Section {
            Link(destination: Self.suggestURL) {
                Label("Suggest an Extension", systemImage: "arrow.up.right.square")
            }
        } footer: {
            Text("Opens a form on GitHub. Tell us the extension's name and where its publisher posts it.")
                .foregroundStyle(.secondary)
        }
    }
}

/// One catalog entry and its Get button.
struct ExtensionCatalogRow: View {
    let entry: ExtensionCatalogEntry
    let isBusy: Bool
    let onError: (String, String) -> Void
    @Environment(AppState.self) private var appState

    private var controller: ExtensionCatalogController { appState.extensionCatalog }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 18))
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                Text("\(entry.publisherLine) \u{00B7} \(entry.licence)").font(.caption2).foregroundStyle(.tertiary)
                if let gap = entry.knownGaps {
                    Text(gap).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if appState.extensions.isAdded(catalogID: entry.id) {
            Text("Added").foregroundStyle(.secondary)
        } else if controller.gettingID == entry.id {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Getting\u{2026}").foregroundStyle(.secondary)
            }
        } else {
            Button("Get", action: get)
                .controlSize(.small)
                .accessibilityLabel("Get \(entry.name)")
                .disabled(isBusy)
        }
    }

    private func get() {
        let entry = entry
        Task {
            do {
                try await controller.get(entry)
            } catch {
                onError("Chorus couldn't get \(entry.name)", ExtensionManager.describe(error))
            }
        }
    }
}
