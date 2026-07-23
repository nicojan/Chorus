import SwiftUI
import SwiftData

struct SpaceStripView: View {
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Binding var selectedSpaceID: UUID?
    var axis: Axis = .vertical
    /// Inset applied to the content (top for a vertical rail, leading for a
    /// horizontal bar) to clear the window traffic lights — kept inside so the
    /// rail's background and dividers still run full-length.
    var contentInset: CGFloat = 0
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @State private var showingAddSpace = false
    @State private var editingSpace: Space?
    @State private var confirmingDeleteSpace: Space?
    /// The space cell that currently holds keyboard focus. Two-way bound to each
    /// cell's `.focused` so the arrow keys move relative to it.
    @FocusState private var focusedSpaceID: UUID?

    /// Measured size of each drop cell, so a drop's before/after split uses the
    /// target's true midpoint. Falls back to the constants below until the first
    /// geometry pass records a size.
    @State private var cellSizes: [UUID: CGSize] = [:]
    private static let spaceDropMidpoint: CGFloat = 22          // vertical cell ≈ 44pt
    private static let spaceDropMidpointHorizontal: CGFloat = 40

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
            Spacer().frame(height: 6 + contentInset)

            // Scroll the cells so more spaces than fit the window height stay
            // reachable; the divider and add button below stay pinned.
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(spaces) { space in
                        spaceCell(space)
                    }
                }
            }

            Divider().padding(.horizontal, 8)

            addSpaceButton

            Spacer().frame(height: 6)
        }
        .frame(width: 52)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var horizontalBody: some View {
        HStack(spacing: 0) {
            chipStrip

            // Empty stretch. It draws nothing and takes no hit of its own, so a
            // click here falls through to the window-drag handle behind the row.
            Spacer(minLength: 40)
        }
        .frame(height: ServiceTabView.height + 4)
        // The OS window drag is off in this layout (chip drags reorder), so a
        // full-width drag handle behind the row makes every empty area move the
        // window; the chips sit in front and take their own clicks. Mirrors
        // ServiceSidebarView.horizontalBody.
        .background(WindowDragHandle())
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The chip strip hugs its content when the spaces fit — leaving the rest of
    /// the row as draggable empty space — and scrolls only on overflow.
    /// `ViewThatFits` is deterministic where measuring the content width and
    /// capping the scroll view was not (it could leave the scroll view filling
    /// half the row, so only the far side dragged).
    private var chipStrip: some View {
        ViewThatFits(in: .horizontal) {
            chipRow
            ScrollView(.horizontal, showsIndicators: false) {
                chipRow
            }
        }
    }

    /// The row of space chips plus the add button. A plain `HStack` (not lazy)
    /// so `ViewThatFits` can measure its width to decide whether the chips fit.
    private var chipRow: some View {
        HStack(spacing: 4) {
            ForEach(spaces) { space in
                spaceCell(space)
            }
            addSpaceButton
        }
        .padding(.leading, 8 + contentInset)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func spaceCell(_ space: Space) -> some View {
        // Resolve members via the same reliable link fetch the service rail uses,
        // not Space.serviceLinks — the inverse relationship can be stale, which
        // left the aggregate summing an empty list (no badge) even while the
        // per-service tab badges showed.
        let serviceIDs = appState.servicesForSpace(space.id).map(\.id)
        let muted = space.isMutedEffective
        let badgeCount = muted ? 0 : appState.badgeManager.aggregateCount(for: serviceIDs)
        SpaceButton(
            space: space,
            isSelected: selectedSpaceID == space.id,
            badgeCount: badgeCount,
            isMuted: muted,
            axis: axis
        ) {
            // Co-locate keyboard focus with selection so a click leaves the
            // arrow keys an anchor to move from (a plain Button click doesn't
            // reliably focus the enclosing `.focusable()` on its own).
            selectedSpaceID = space.id
            focusedSpaceID = space.id
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
        .dropDestination(for: String.self) { items, location in
            guard let droppedIDString = items.first,
                  let droppedID = UUID(uuidString: droppedIDString),
                  droppedID != space.id
            else { return false }
            // Split at the target's real midpoint so a chip can be dropped after
            // the last space (before-only would leave the final slot unreachable
            // by drag). Returns false when the dropped id isn't a space in this
            // rail (e.g. a service tab), so the drop isn't reported as a no-op success.
            let placement: ServiceReorderPlacement = {
                let size = cellSizes[space.id]
                if axis == .vertical {
                    let mid = (size?.height).map { $0 / 2 } ?? Self.spaceDropMidpoint
                    return location.y < mid ? .before : .after
                }
                let mid = (size?.width).map { $0 / 2 } ?? Self.spaceDropMidpointHorizontal
                return location.x < mid ? .before : .after
            }()
            return reorderSpace(droppedSpaceID: droppedID, relativeTo: space, placement: placement)
        }
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) {
                    cellSizes[space.id] = proxy.size
                }
            }
        )
        .accessibilityAction(named: "Move up") { moveSpaceUp(space) }
        .accessibilityAction(named: "Move down") { moveSpaceDown(space) }
        .focusable()
        .focused($focusedSpaceID, equals: space.id)
        // Suppress the rectangular system focus ring, matching the service rail
        // (see ServiceSidebarView). Selection co-locates focus onto the chip, so
        // the system ring stacked on top of the chip's own accent border and pill
        // — a doubled box that the narrow strip then clipped. The app's own
        // indicator already shows where focus is.
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            handleSpaceKey(press, for: space)
        }
        .contextMenu {
            Toggle("Mute Notifications", isOn: Binding(
                get: { space.isMutedEffective },
                set: { newValue in
                    space.isMuted = newValue
                    save("toggle space mute")
                    // Refresh BadgeManager for every member service so the
                    // per-service badge and the aggregate chip badge zero out
                    // (or come back) immediately, without waiting for a poll.
                    // Use the reliable link fetch, not space.serviceLinks — that
                    // inverse relationship can be stale (see the badge-count code
                    // above), which would skip members and leave their badges.
                    for serviceID in appState.servicesForSpace(space.id).map(\.id) {
                        appState.refreshBadgeState(for: serviceID)
                    }
                }
            ))

            Divider()
            Button("Edit Space...") {
                editingSpace = space
            }
            // No delete when this is the only space: the app has no valid state
            // with zero spaces (AppState.deleteSpace also refuses).
            if spaces.count > 1 {
                Divider()
                Button("Delete Space", role: .destructive) {
                    confirmingDeleteSpace = space
                }
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

    /// Arrow keys move the space selection along the rail's axis (↑/↓ vertical,
    /// ←/→ horizontal); ⌥+arrow reorders the focused space, reusing the move
    /// helpers behind the VoiceOver actions. Selection stops at the ends.
    private func handleSpaceKey(_ press: KeyPress, for space: Space) -> KeyPress.Result {
        let forward: Bool
        switch (axis, press.key) {
        case (.vertical, .upArrow), (.horizontal, .leftArrow):
            forward = false
        case (.vertical, .downArrow), (.horizontal, .rightArrow):
            forward = true
        default:
            return .ignored
        }

        if press.modifiers.contains(.option) {
            if forward { moveSpaceDown(space) } else { moveSpaceUp(space) }
            focusedSpaceID = space.id
            return .handled
        }

        guard let index = spaces.firstIndex(where: { $0.id == space.id }) else { return .handled }
        let neighborIndex = forward ? index + 1 : index - 1
        guard spaces.indices.contains(neighborIndex) else { return .handled }
        let neighborID = spaces[neighborIndex].id
        selectedSpaceID = neighborID
        focusedSpaceID = neighborID
        return .handled
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

    @discardableResult
    private func reorderSpace(droppedSpaceID: UUID, relativeTo target: Space, placement: ServiceReorderPlacement) -> Bool {
        let orderedSpaces = spaces
        let spacesByID = Dictionary(uniqueKeysWithValues: orderedSpaces.map { ($0.id, $0) })
        // Reuse the service rail's tested reorder math. The old inline version
        // inserted at a pre-removal index, so a forward drag landed one slot past
        // the target; ServiceReorder decrements the index when moving forward.
        guard let reorderedIDs = ServiceReorder.reorderedIDs(
            orderedSpaces.map(\.id),
            moving: droppedSpaceID,
            relativeTo: target.id,
            placement: placement
        ) else {
            return false
        }

        for (index, id) in reorderedIDs.enumerated() {
            spacesByID[id]?.sortOrder = index
        }
        save("reorder spaces")
        return true
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
            if axis == .vertical {
                verticalCell
            } else {
                horizontalTab
            }
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

    /// Vertical rail: an emoji tile with a leading accent pill when selected.
    private var verticalCell: some View {
        ZStack(alignment: .topTrailing) {
            Text(space.emoji)
                .font(.title2)
                .opacity(isMuted ? 0.5 : 1.0)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(fillStyle))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            isSelected ? AnyShapeStyle(.tint.opacity(0.55)) : AnyShapeStyle(Color.clear),
                            lineWidth: 1
                        )
                )
                .overlay(alignment: .leading) {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.tint)
                            .frame(width: 3, height: 20)
                    }
                }
                .frame(width: 44, height: 44)

            if badgeCount > 0 {
                BadgeCountView(count: badgeCount).offset(x: 2, y: -2)
            }
            if isMuted {
                muteGlyph
            }
        }
        .frame(width: 44, height: 44)
    }

    /// Horizontal top bar: an emoji + name tab, matching the service tabs, with an
    /// accent border when selected.
    private var horizontalTab: some View {
        HStack(spacing: 8) {
            Text(space.emoji).font(.system(size: 15))

            Text(space.name)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? .primary : .secondary)

            if badgeCount > 0 {
                BadgeCountView(count: badgeCount)
            } else if isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ServiceTabView.height)
        .opacity(isMuted ? 0.7 : 1.0)
        .background(fillStyle)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear),
                    lineWidth: 1.5
                )
        )
        .contentShape(Rectangle())
    }

    private var muteGlyph: some View {
        Image(systemName: "bell.slash.fill")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(2)
            .background(Circle().fill(.background))
            .offset(x: 2, y: 4)
            .accessibilityHidden(true)
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

    private var fillStyle: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(.tint.opacity(0.12))
        } else if isHovering {
            return AnyShapeStyle(Color.primary.opacity(0.06))
        }
        return AnyShapeStyle(Color.clear)
    }
}
