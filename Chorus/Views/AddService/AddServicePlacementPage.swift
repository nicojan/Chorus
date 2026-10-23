import SwiftUI

/// The second page of Add Service: where the picked service goes, and whose
/// sign-in it uses. It is a page of its own, after the pick, because a choice
/// at the foot of the catalog went unseen: by the time someone has found
/// their service, they click it and are done.
///
/// The sheet works out what each choice means (who the service would share a
/// sign-in with, whether the same site is already on it) and passes it in, so
/// this view only lays it out.
struct AddServicePlacementPage: View {
    let serviceName: String
    let spaceName: String
    /// A Mac app has no sign-in, so it only chooses where it shows.
    let isMacApp: Bool
    @Binding var showInEverySpace: Bool
    @Binding var keepSeparate: Bool
    /// The services already on the sign-in it would share, by name.
    let sharers: [String]
    /// A service of the same site already on that sign-in, if any.
    let sameSite: String?
    /// The site is a chat service, whose two copies on one sign-in compete
    /// for it, so sharing is not offered when it is already there.
    let isChat: Bool
    let error: String?
    let onBack: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            Text("Add \(serviceName)")
                .font(.title3)
                .fontWeight(.semibold)

            section("Show it") {
                Picker("Show it", selection: $showInEverySpace) {
                    Text("In \(spaceName)").tag(false)
                    Text("In every space").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            if !isMacApp {
                section("Sign-in") {
                    Picker("Sign-in", selection: $keepSeparate) {
                        Text("Shared").tag(false)
                            .disabled(sharingBlocked)
                        Text("Its own").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    Text(signInNote)
                        .font(.callout)
                        .foregroundStyle(sameSite != nil && !keepSeparate ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Add \(serviceName)", action: onAdd)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!keepSeparate && sharingBlocked && !isMacApp)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sharingBlocked: Bool { isChat && sameSite != nil }

    /// What the chosen sign-in means, in the words that matter.
    private var signInNote: String {
        let place = showInEverySpace ? "every space" : spaceName
        if keepSeparate {
            if let sameSite {
                return "It starts signed out, apart from \(sameSite), so it can use another account."
            }
            return "It starts signed out and keeps its own cookies, for a second account of a site."
        }
        if let sameSite {
            return isChat
                ? "\(sameSite) already uses this sign-in. Two copies of a chat service on one sign-in compete for it, so this one needs its own."
                : "\(sameSite) already uses this sign-in, so this one would open the same account."
        }
        if sharers.isEmpty {
            return "It starts signed out. Services you add to \(place) after it share its sign-in."
        }
        return "It shares a sign-in with \(AppState.listed(sharers)), so signing in to one signs in the others."
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
