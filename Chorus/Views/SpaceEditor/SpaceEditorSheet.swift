import SwiftUI
import SwiftData

struct SpaceEditorSheet: View {
    let editingSpace: Space?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Space.sortOrder) private var spaces: [Space]

    @State private var name: String = ""
    @State private var selectedEmoji: String = "📁"

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
                        deleteSpace()
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
        .frame(width: 400, height: 420)
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

        if let space = editingSpace {
            space.name = trimmed
            space.emoji = selectedEmoji
        } else {
            let nextOrder = (spaces.map(\.sortOrder).max() ?? -1) + 1
            let space = Space(name: trimmed, emoji: selectedEmoji, sortOrder: nextOrder)
            modelContext.insert(space)
        }

        try? modelContext.save()
        dismiss()
    }

    private func deleteSpace() {
        guard let space = editingSpace else { return }
        modelContext.delete(space)
        try? modelContext.save()
        dismiss()
    }
}
