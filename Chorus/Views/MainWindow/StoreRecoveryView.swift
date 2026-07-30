import SwiftUI

/// Lists every store Chorus could put back: the live one and each backup it
/// kept. The user picks; nothing is written until they do.
struct StoreRecoveryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selection: StoreCandidate?

    /// Shown when the restore could not be started. Amended in after Task 9's
    /// review: `chooseStoreRestore` returns false if spawning the relaunch
    /// fails, and dismissing the sheet on that path told the user their restore
    /// had been applied when nothing had happened.
    @State private var failureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore your spaces and services")
                .font(.headline)
            Text("Chorus keeps a copy of your data before each update. Pick the one you want and Chorus will restart to put it back. Your current data is set aside first, so nothing is thrown away.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(appState.storeCandidates, selection: $selection) { candidate in
                row(for: candidate)
                    .tag(candidate)
            }
            .frame(minHeight: 200)

            if let failureMessage {
                Text(failureMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }

            HStack {
                if let folder = appState.storeCandidates.first?.url.deletingLastPathComponent() {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore and Restart") {
                    guard let selection else { return }
                    if appState.chooseStoreRestore(selection) { return }
                    failureMessage = "Chorus could not restart itself. Quit and open it again to put this backup back."
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection?.isRestorable != true)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { selection = appState.preselectedCandidate }
    }

    @ViewBuilder
    private func row(for candidate: StoreCandidate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title(for: candidate)).fontWeight(.medium)
                if candidate.kind == .live {
                    Text("Current")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
            }
            Text(detail(for: candidate))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func title(for candidate: StoreCandidate) -> String {
        switch candidate.kind {
        case .live: return "Your data now"
        case .snapshot(let version): return version.map { "Backup from before \($0)" } ?? "Backup from before an update"
        case .prerestore: return "Backup from an earlier restore"
        case .corrupt: return "Backup from before a repair"
        case .prepick: return "Your data before you restored a backup"
        }
    }

    private func detail(for candidate: StoreCandidate) -> String {
        let when: String
        if let takenAt = candidate.takenAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            when = formatter.string(from: takenAt)
        } else {
            when = "date unknown"
        }
        guard let content = candidate.content else { return "\(when) — can't be read" }
        let spaces = content.spaces == 1 ? "1 space" : "\(content.spaces) spaces"
        let services = content.services == 1 ? "1 service" : "\(content.services) services"
        let damaged = candidate.isDamaged ? " — damaged" : ""
        return "\(when) — \(spaces), \(services)\(damaged)"
    }
}
