import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Export and Import for the setup file, in Settings ▸ General ▸ Data. See
/// `SetupArchive` for what the file carries and what it leaves behind.
struct SetupTransferSection: View {
    @Environment(AppState.self) private var appState

    @State private var pendingImport: SetupArchive?
    @State private var message: Message?

    struct Message: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Move your setup")
                Text("Save your spaces and services to a file, or add them from one. The file holds each service's address and settings, but no sign-ins, so you sign in again after an import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // On a view of its own: the result follows the confirmation's Add
            // straight away, and two alerts on one view can drop the second
            // while the first is still going away.
            .alert(item: $message) { message in
                Alert(title: Text(message.title), message: Text(message.body))
            }
            Spacer()
            Button("Export…", action: export)
            Button("Import…", action: chooseFile)
        }
        .alert(
            importTitle,
            isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
            presenting: pendingImport
        ) { archive in
            Button("Add") { runImport(archive) }
            Button("Cancel", role: .cancel) {}
        } message: { archive in
            Text(Self.importDetails(archive))
        }
    }

    private var importTitle: String {
        guard let archive = pendingImport else { return "" }
        return "Add \(Self.count(archive.listedServiceIndices.count, "service")) in \(Self.count(archive.spaces.count, "space"))?"
    }

    /// The sites the file points at, since a file can call a service "Slack"
    /// and send it anywhere; a warning when it brings CSS, which runs inside
    /// those sites; and what happens to spaces you already have.
    static func importDetails(_ archive: SetupArchive) -> String {
        let hosts = archive.hosts
        let shown = hosts.prefix(6).joined(separator: ", ")
        let more = hosts.count > 6 ? ", and \(hosts.count - 6) more" : ""
        var lines = ["Sites: \(shown)\(more)."]
        let apps = archive.macApps.map(appName)
        if !apps.isEmpty {
            lines.append("Mac apps: \(apps.joined(separator: ", ")).")
        }
        if archive.hasCustomCSS {
            lines.append("Some of these services bring their own CSS. It runs inside those sites while you're signed in, and it can hide or change what a page shows, such as a warning or a phone number. Add this only if you trust whoever made the file.")
        }
        lines.append("If you already have a space with one of these names, its new services go into yours. Nothing you have now is removed.")
        return lines.joined(separator: "\n\n")
    }

    /// An app's name when it is installed here, else its bundle id.
    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SetupArchive.suggestedFilename
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.exportSetup().write(to: url, options: .atomic)
        } catch {
            message = Message(title: "Chorus couldn't save your setup", body: error.localizedDescription)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int, size > SetupArchive.Limit.fileBytes {
                throw SetupArchive.ReadError.tooLarge
            }
            pendingImport = try SetupArchive.decode(Data(contentsOf: url))
        } catch {
            message = Message(title: "Chorus couldn't read this file", body: error.localizedDescription)
        }
    }

    private func runImport(_ archive: SetupArchive) {
        do {
            let summary = try appState.importSetup(archive)
            var parts = ["Added \(Self.count(summary.servicesAdded, "service"))"]
            if summary.spacesAdded > 0 { parts.append("\(Self.count(summary.spacesAdded, "new space"))") }
            message = Message(
                title: parts.joined(separator: " and ") + ".",
                body: "Open each one to sign in."
            )
        } catch {
            message = Message(title: "Chorus couldn't add this setup", body: error.localizedDescription)
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
