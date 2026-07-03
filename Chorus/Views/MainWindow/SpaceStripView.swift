import SwiftUI
import SwiftData

struct SpaceStripView: View {
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Binding var selectedSpaceID: UUID?
    var axis: Axis = .vertical
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @State private var showingAddSpace = false
    @State private var editingSpace: Space?
    @State private var confirmingDeleteSpace: Space?

    var body: some View {
        content
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

    @ViewBuilder
    private var content: some View {
        if axis == .vertical {
            verticalBody
        } else {
            horizontalBody
        }
    }

    private var verticalBody: some View {
        VStack(spacing: 2) {
            Spacer().frame(height: 6)

            ForEach(spaces) { space in
                spaceCell(space)
            }

            Spacer()

            Divider().padding(.horizontal, 8)

            addSpaceButton

            Spacer().frame(height: 6)
        }
        .frame(width: 52)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var horizontalBody: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(spaces) { space in
                        spaceCell(space)
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider().frame(height: 28)

            addSpaceButton
                .padding(.trailing, 8)
        }
        .frame(height: 48)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func spaceCell(_ space: Space) -> some View {
        let serviceIDs = space.serviceLinks.map(\.service.id)
        let muted = space.isMutedEffective
        let badgeCount = muted ? 0 : appState.badgeManager.aggregateCount(for: serviceIDs)
        SpaceButton(
            space: space,
            isSelected: selectedSpaceID == space.id,
            badgeCount: badgeCount,
            isMuted: muted,
            axis: axis
        ) {
            selectedSpaceID = space.id
        }
        .draggable(space.id.uuidString) {
            // Custom drag preview. Source-dimming is intentionally left to
            // SwiftUI: manually tracking a "dragging" id to dim the source can't
            // be cleared reliably (a drop on itself or a cancelled drag never
            // fires the drop handler), which left the icon stuck dim.
            Text(space.emoji)
                .font(.title3)
                .padding(6)
                .background(.ultraThickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let droppedIDString = items.first,
                  let droppedID = UUID(uuidString: droppedIDString),
                  droppedID != space.id
            else { return false }
            reorderSpace(droppedSpaceID: droppedID, beforeSpace: space)
            return true
        }
        .accessibilityAction(named: "Move up") { moveSpaceUp(space) }
        .accessibilityAction(named: "Move down") { moveSpaceDown(space) }
        .contextMenu {
            Toggle("Mute Notifications", isOn: Binding(
                get: { space.isMutedEffective },
                set: { newValue in
                    space.isMuted = newValue
                    save("toggle space mute")
                    // Refresh BadgeManager for every member service so the
                    // per-service badge and the aggregate chip badge zero out
                    // (or come back) immediately, without waiting for a poll.
                    for link in space.serviceLinks {
                        appState.refreshBadgeState(for: link.service.id)
                    }
                }
            ))

            Divider()
            Button("Edit Space...") {
                editingSpace = space
            }
            Divider()
            Button("Delete Space", role: .destructive) {
                confirmingDeleteSpace = space
            }
        }
    }

    private var addSpaceButton: some View {
        Button {
            showingAddSpace = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: axis == .vertical ? 32 : 28, height: 28)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add space")
        .accessibilityLabel("Add space")
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
        // Routes through AppState so services that lived only in this space are
        // reclaimed (web view torn down + data store scheduled for removal)
        // instead of becoming invisible orphans. Handles selection fix-up too.
        appState.deleteSpace(space.id)
    }
}

private struct SpaceButton: View {
    let space: Space
    let isSelected: Bool
    var badgeCount: Int = 0
    var isMuted: Bool = false
    var axis: Axis = .vertical
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                emojiTile

                if badgeCount > 0 {
                    BadgeCountView(count: badgeCount)
                        .offset(x: 4, y: -4)
                }

                if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 2, y: 4)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .help(isMuted ? "\(space.name) (muted)" : space.name)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityAddTraits([.isButton, isSelected ? .isSelected : []])
    }

    private var emojiTile: some View {
        Text(space.emoji)
            .font(.title2)
            .opacity(isMuted ? 0.5 : 1.0)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
            )
            .overlay(alignment: axis == .vertical ? .leading : .bottom) {
                selectionIndicator
            }
            .frame(width: 44, height: 44)
    }

    /// The accent selection cue: a leading pill in the vertical rail, a bottom
    /// underline in the horizontal top bar. Selection is also carried by the
    /// `.isSelected` trait, so it isn't conveyed by color alone.
    @ViewBuilder
    private var selectionIndicator: some View {
        if isSelected {
            if axis == .vertical {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 20)
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
            }
        }
    }

    /// Folds the space name, aggregate unread count, and mute state into one
    /// spoken label so VoiceOver announces everything the badge conveys visually.
    private var accessibilityLabelText: String {
        var parts = [space.name]
        if badgeCount > 0 {
            parts.append(badgeCount == 1 ? "1 unread" : "\(badgeCount) unread")
        }
        if isMuted { parts.append("muted") }
        return parts.joined(separator: ", ")
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
