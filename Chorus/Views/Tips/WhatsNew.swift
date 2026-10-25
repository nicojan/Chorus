import SwiftUI

/// What changed in a release, shown once after updating to it. Add an entry
/// under the new version's number when a release has something worth showing;
/// a version with no entry shows nothing.
enum WhatsNew {
    struct Item: Identifiable {
        let id: String
        let systemImage: String
        let title: String
        let detail: String
        let action: FeatureAction?
        let actionTitle: String
    }

    static let releases: [String: [Item]] = [
        "1.5.29": [
            Item(
                id: "global-services",
                systemImage: "square.stack.3d.up",
                title: "Services in every space",
                detail: "Right-click a service and choose Show in Every Space. It stays at the top of the rail wherever you are, with one sign-in and one badge.",
                action: nil,
                actionTitle: ""
            ),
            Item(
                id: "dividers",
                systemImage: "minus",
                title: "Dividers",
                detail: "Right-click a service and choose Add Divider to draw a line after it. Drag a divider to move it, or drag it off the rail to remove it.",
                action: nil,
                actionTitle: ""
            ),
            Item(
                id: "shared-sign-in",
                systemImage: "person.2",
                title: "One sign-in per space",
                detail: "Services you add to a space now share its sign-in, so signing in to Google once covers Gmail and Calendar there. The services you had keep their own sign-ins, so nobody is signed out. To keep a second account apart, choose its own sign-in when you add it.",
                action: nil,
                actionTitle: ""
            ),
        ],
        "1.5.27": [
            Item(
                id: "service-tabs",
                systemImage: "square.on.square",
                title: "Pages open as tabs",
                detail: "When a service opens one of its own pages in a new window, such as a design in Canva, the page now opens as a tab inside the service. Press ⌘W to close it.",
                action: nil,
                actionTitle: ""
            ),
        ],
        "1.5.26": [
            Item(
                id: "mac-apps",
                systemImage: "macwindow",
                title: "Mac apps in the rail",
                detail: "Add an app with no web version, such as LINE. Chorus opens it over the page area and shows its unread count.",
                action: .addMacApp,
                actionTitle: "Show Me"
            ),
            Item(
                id: "layouts",
                systemImage: "rectangle.split.3x1",
                title: "Four layouts",
                detail: "Keep the rail on the left, move your services to a bar along the top, or mix the two. They're in Settings, under General.",
                action: .showLayouts,
                actionTitle: "Show Layouts"
            ),
        ],
    ]

    /// The version whose sheet was last shown, so it shows only once.
    static let shownVersionKey = "chorus.whatsNewShownVersion"

    #if DEBUG
    /// Shows the newest release's sheet at every Debug launch.
    static let debugShowKey = "debugShowWhatsNew"
    #endif

    static func items(for version: String) -> [Item] {
        releases[version] ?? []
    }

    /// Whether to show the sheet: only after an update (a fresh install has
    /// no previous version), only once per version, and only when the new
    /// version has something to show.
    static func shouldShow(previousVersion: String?, currentVersion: String, shownVersion: String?) -> Bool {
        guard let previousVersion, !previousVersion.isEmpty, !currentVersion.isEmpty,
              previousVersion != currentVersion,
              shownVersion != currentVersion
        else { return false }
        return !items(for: currentVersion).isEmpty
    }

    /// The newest version with entries, for the Debug preview.
    static var newestVersion: String? {
        releases.keys.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }
}

struct WhatsNewSheet: View {
    let version: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New in Chorus \(version)")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(WhatsNew.items(for: version)) { item in
                    row(item)
                }
            }

            HStack {
                Spacer()
                Button("Continue") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(28)
        .frame(width: 460)
    }

    private func row(_ item: WhatsNew.Item) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                Text(item.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = item.action {
                    Button(item.actionTitle) {
                        dismiss()
                        // One sheet has to go before another can come up.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            appState.perform(action)
                        }
                    }
                    .buttonStyle(.link)
                    .padding(.top, 2)
                }
            }
        }
    }
}
