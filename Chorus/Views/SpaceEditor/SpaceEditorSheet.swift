import SwiftUI
import SwiftData

struct SpaceEditorSheet: View {
    let editingSpace: Space?
    @Binding var selectedSpaceID: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \Space.sortOrder) private var spaces: [Space]

    @State private var name: String = ""
    @State private var selectedEmoji: String = "📁"
    @State private var showDeleteConfirmation = false

    var isEditing: Bool { editingSpace != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEditing ? "Edit space" : "New space")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(spacing: 20) {
                HStack(spacing: 16) {
                    Text(selectedEmoji)
                        .font(.system(size: 40))
                        .frame(width: 60, height: 60)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Selected emoji: \(selectedEmoji)")
                        .accessibilityHint("Use the picker below to change")

                    TextField("Space name", text: $name, prompt: Text("Work, Personal, etc."))
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                }

                EmojiPickerView(selectedEmoji: $selectedEmoji)
            }
            .padding(20)

            Divider()

            HStack {
                if isEditing {
                    Button("Delete Space", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .confirmationDialog(
                        "Delete \(editingSpace?.name ?? "space")?",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) {
                            deleteSpace()
                        }
                    } message: {
                        Text("This will permanently delete the space and remove all service links.")
                    }
                }
                Spacer()
                Button(isEditing ? "Save" : "Create") {
                    saveSpace()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420, height: 520)
        .onAppear {
            if let space = editingSpace {
                name = space.name
                selectedEmoji = space.emoji
            }
        }
    }

    private func saveSpace() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        var createdSpaceID: UUID?
        if let space = editingSpace {
            space.name = trimmed
            space.emoji = selectedEmoji
        } else {
            let nextOrder = (spaces.map(\.sortOrder).max() ?? -1) + 1
            let space = Space(name: trimmed, emoji: selectedEmoji, sortOrder: nextOrder)
            modelContext.insert(space)
            createdSpaceID = space.id
        }

        do {
            try modelContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save space: \(error.localizedDescription)")
        }

        // Switch to a freshly created space. It has no services yet, so clear the
        // service selection — the content area shows the empty state for it.
        if let createdSpaceID {
            selectedSpaceID = createdSpaceID
            appState.selectedServiceID = nil
        }
        dismiss()
    }

    private func deleteSpace() {
        guard let space = editingSpace else { return }
        // Routes through AppState so services orphaned by the deletion are
        // reclaimed and selection is moved off the deleted space.
        appState.deleteSpace(space.id)
        dismiss()
    }
}
