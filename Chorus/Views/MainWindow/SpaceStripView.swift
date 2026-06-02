import SwiftUI
import SwiftData

struct SpaceStripView: View {
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Binding var selectedSpaceID: UUID?
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @State private var showingAddSpace = false
    @State private var editingSpace: Space?
    @State private var confirmingDeleteSpace: Space?
    @State private var draggingSpaceID: UUID?

    var body: some View {
        VStack(spacing: 2) {
            Spacer()
                .frame(height: 6)

            ForEach(spaces) { space in
                let serviceIDs = space.serviceLinks.map(\.service.id)
                let badgeCount = appState.badgeManager.aggregateCount(for: serviceIDs)
                SpaceButton(
                    space: space,
                    isSelected: selectedSpaceID == space.id,
                    badgeCount: badgeCount
                ) {
                    selectedSpaceID = space.id
                }
                .opacity(draggingSpaceID == space.id ? 0.4 : 1.0)
                .draggable(space.id.uuidString) {
                    Text(space.emoji)
                        .font(.title3)
                        .padding(6)
                        .background(.ultraThickMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onAppear { draggingSpaceID = space.id }
                        .onDisappear { draggingSpaceID = nil }
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let droppedIDString = items.first,
                          let droppedID = UUID(uuidString: droppedIDString),
                          droppedID != space.id
                    else { return false }
                    reorderSpace(droppedSpaceID: droppedID, beforeSpace: space)
                    draggingSpaceID = nil
                    return true
                }
                .accessibilityAction(named: "Move up") { moveSpaceUp(space) }
                .accessibilityAction(named: "Move down") { moveSpaceDown(space) }
                .contextMenu {
                    Button("Edit Space...") {
                        editingSpace = space
                    }
                    Divider()
                    Button("Delete Space", role: .destructive) {
                        confirmingDeleteSpace = space
                    }
                }
            }

            Spacer()

            Divider()
                .padding(.horizontal, 8)

            Button {
                showingAddSpace = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 32, height: 28)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add space")
            .accessibilityLabel("Add space")

            Spacer()
                .frame(height: 6)
        }
        .frame(width: 52)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingAddSpace) {
            SpaceEditorSheet(editingSpace: nil, selectedSpaceID: $selectedSpaceID)
        }
        .sheet(item: $editingSpace) { space in
            SpaceEditorSheet(editingSpace: space, selectedSpaceID: $selectedSpaceID)
        }
        .confirmationDialog(
            "Delete \(confirmingDeleteSpace?.name ?? "space")?",
            isPresented: Binding(
                get: { confirmingDeleteSpace != nil },
                set: { if !$0 { confirmingDeleteSpace = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let space = confirmingDeleteSpace {
                    deleteSpace(space)
                }
                confirmingDeleteSpace = nil
            }
        } message: {
            Text("Services in this space won't be deleted, but the space will be removed.")
        }
    }

    private func save(_ context: String) {
        do {
            try modelContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save (\(context)): \(error.localizedDescription)")
        }
    }

    private func moveSpaceUp(_ space: Space) {
        var orderedSpaces = Array(spaces)
        guard let index = orderedSpaces.firstIndex(where: { $0.id == space.id }), index > 0 else { return }
        orderedSpaces.swapAt(index, index - 1)
        for (i, s) in orderedSpaces.enumerated() { s.sortOrder = i }
        save("move space up")
    }

    private func moveSpaceDown(_ space: Space) {
        var orderedSpaces = Array(spaces)
        guard let index = orderedSpaces.firstIndex(where: { $0.id == space.id }), index < orderedSpaces.count - 1 else { return }
        orderedSpaces.swapAt(index, index + 1)
        for (i, s) in orderedSpaces.enumerated() { s.sortOrder = i }
        save("move space down")
    }

    private func reorderSpace(droppedSpaceID: UUID, beforeSpace target: Space) {
        var orderedSpaces = spaces
        guard let fromIndex = orderedSpaces.firstIndex(where: { $0.id == droppedSpaceID }),
              let toIndex = orderedSpaces.firstIndex(where: { $0.id == target.id })
        else { return }

        let moved = orderedSpaces.remove(at: fromIndex)
        orderedSpaces.insert(moved, at: toIndex)

        for (index, space) in orderedSpaces.enumerated() {
            space.sortOrder = index
        }
        save("reorder spaces")
    }

    private func deleteSpace(_ space: Space) {
        if selectedSpaceID == space.id {
            selectedSpaceID = spaces.first(where: { $0.id != space.id })?.id
        }
        modelContext.delete(space)
        save("delete space")
    }
}

private struct SpaceButton: View {
    let space: Space
    let isSelected: Bool
    var badgeCount: Int = 0
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    // Selection indicator — a 3pt accent-colored pill on the leading edge
                    // following the macOS sidebar selection pattern
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isSelected ? Color.accentColor : .clear)
                        .frame(width: 3, height: 20)
                        .padding(.leading, 2)

                    Text(space.emoji)
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(backgroundColor)
                        )
                        .padding(.horizontal, 4)
                }
                .frame(width: 52)

                if badgeCount > 0 {
                    BadgeCountView(count: badgeCount)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .help(space.name)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits([.isButton, isSelected ? .isSelected : []])
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.15)
        } else if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }
}
