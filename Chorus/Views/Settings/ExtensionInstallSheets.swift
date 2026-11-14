import ChorusEngine
import SwiftUI

/// Lists the Safari extensions installed with Mac apps, to pick one to add.
struct SafariExtensionPicker: View {
    let isAdded: (WebExtensionRecord.Source) -> Bool
    let onPick: (SafariExtensionScanner.Found) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var found: [SafariExtensionScanner.Found]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Safari Extensions on This Mac")
                .font(.headline)
            Group {
                if let found {
                    if found.isEmpty {
                        ContentUnavailableView(
                            "None found",
                            systemImage: "puzzlepiece.extension",
                            description: Text("Chorus looks in the Applications folders for apps that come with a Safari extension.")
                        )
                    } else {
                        List(found) { item in
                            row(item)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 400)
        .task {
            found = await Task.detached { SafariExtensionScanner.scan() }.value
        }
    }

    private func row(_ item: SafariExtensionScanner.Found) -> some View {
        let added = isAdded(.appExtension(path: item.path))
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text("Comes with \(item.appName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if added {
                Text("Added").foregroundStyle(.secondary)
            } else {
                Button("Add") { onPick(item) }
            }
        }
    }
}

/// Shows what an extension can do before it is added, and asks.
struct ExtensionConfirmSheet: View {
    let pending: PendingExtension
    let onDecide: (Bool) -> Void

    private var summary: WebExtensionSummary { pending.summary }

    private var abilities: [String] {
        let site = WebExtensionPermissionText.siteLine(forMatchPatterns: summary.matchPatterns)
        return (site.map { [$0] } ?? []) + WebExtensionPermissionText.lines(forPermissions: summary.permissions)
    }

    /// For one got from the catalog, the release version and where it came
    /// from; otherwise the manifest's version.
    private var versionLine: String? {
        if let pick = pending.catalog {
            return "Version \(pick.version) \u{00B7} \(pick.entry.publisherLine)"
        }
        return summary.version.map { "Version \($0)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let icon = summary.icon {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 32))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add \(summary.name)?").font(.headline)
                    if let versionLine {
                        Text(versionLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let text = summary.summary, !text.isEmpty {
                Text(text).foregroundStyle(.secondary).lineLimit(3)
            }

            if !abilities.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("It will be able to:").fontWeight(.medium)
                    ForEach(abilities, id: \.self) { line in
                        Label(line, systemImage: "checkmark")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }

            if let gap = pending.catalog?.entry.knownGaps {
                Label(gap, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if summary.needsNativeApp {
                Label(
                    "It also asks to talk to its Mac app. macOS lets only Safari do that, so the parts that need the app won't work in Chorus.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !summary.problems.isEmpty {
                DisclosureGroup("WebKit reported \(summary.problems.count) problem\(summary.problems.count == 1 ? "" : "s")") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.problems, id: \.self) { Text($0).font(.caption) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDecide(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Add Extension") { onDecide(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .frame(minHeight: 300)
    }
}
