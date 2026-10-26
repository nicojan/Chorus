import SwiftUI

/// A group waiting to be named: its id and the name it has now.
struct GroupNameRequest: Identifiable, Equatable {
    let id: UUID
    let name: String?
}

/// The Name Group sheet on the rail. Kept out of `UnifiedRailView.body`, whose
/// modifier chain is already as long as the macOS 15 type-checker allows.
struct GroupNaming: ViewModifier {
    @Binding var request: GroupNameRequest?
    let save: (UUID, String?) -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            NameGroupSheet(request: request) { save(request.id, $0) }
                .coveredWhenLocked()
        }
    }
}

/// One field and two buttons. Return saves; an empty name takes the name away.
struct NameGroupSheet: View {
    let request: GroupNameRequest
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    /// Return can reach both the field's submit and the default button.
    @State private var saved = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name Group")
                .font(.headline)
            TextField("Name", text: $name, prompt: Text("No name"))
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            name = request.name ?? ""
            fieldFocused = true
        }
    }

    private func save() {
        guard !saved else { return }
        saved = true
        onSave(name)
        dismiss()
    }
}

/// The box's own menu and VoiceOver actions: Move Group to a space, Name
/// Group, Ungroup, and Move up / Move down for the whole run. The rows inside
/// keep their own menus; this one answers a right-click on the box's edge or
/// its name.
struct GroupBoxMenu: ViewModifier {
    /// The spaces the group can move to, read when the menu is built.
    let targets: () -> [Space]
    let moveTo: (UUID) -> Void
    let rename: () -> Void
    let ungroup: () -> Void
    let step: (_ forward: Bool) -> Void

    func body(content: Content) -> some View {
        content
            // The padding round the rows and the band under the name are
            // empty, so give them a shape to right-click.
            .contentShape(Rectangle())
            .contextMenu {
                let spaces = targets()
                Menu("Move Group to") {
                    ForEach(spaces) { space in
                        Button("\(space.emoji)  \(space.name)") { moveTo(space.id) }
                            .accessibilityLabel(space.name)
                    }
                }
                .disabled(spaces.isEmpty)
                Button("Name Group…", action: rename)
                Divider()
                Button("Ungroup", action: ungroup)
            }
            .accessibilityActions {
                ForEach(targets()) { space in
                    Button("Move group to \(space.name)") { moveTo(space.id) }
                }
                Button("Name group", action: rename)
                Button("Ungroup", action: ungroup)
            }
            .accessibilityAction(named: "Move up") { step(false) }
            .accessibilityAction(named: "Move down") { step(true) }
    }
}

/// The group items of a service row as VoiceOver actions, the same three as
/// its menu: Group with each neighbour, Remove from group, Name group.
struct GroupRowActions: ViewModifier {
    /// The neighbours it can be grouped with, by link id and label.
    let candidates: [GroupCandidate]
    let inGroup: Bool
    let groupWith: (UUID) -> Void
    let remove: () -> Void
    let rename: () -> Void

    func body(content: Content) -> some View {
        content.accessibilityActions {
            ForEach(candidates) { candidate in
                Button("Group with \(candidate.label)") { groupWith(candidate.id) }
            }
            if inGroup {
                Button("Remove from group", action: remove)
                Button("Name group", action: rename)
            }
        }
    }
}

/// A row "Group with" can offer: the neighbour's link id and its label.
struct GroupCandidate: Identifiable, Equatable {
    let id: UUID
    let label: String
}
