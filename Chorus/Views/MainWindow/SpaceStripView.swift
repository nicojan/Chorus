import SwiftUI
import SwiftData

/// The column of spaces down the left of the hybrid layout, with the current
/// space's services in a bar along the top beside it.
///
/// Restored from the two-rail layouts: the arrow keys and the VoiceOver move
/// actions come back as they were, and dragging a space reorders the strip
/// live (see `LiveReorder`). What is new is that
/// a cell can carry its space's name, which answers the finding that retired the
/// strip: a column of unlabelled emoji, with the name only in a tooltip. The
/// setting that turns the names on widens the strip to fit them.
///
/// Only the vertical arrangement survives. Spaces along the top was the third
/// of the three old arrangements and `UnifiedRailView` draws that one now, with
/// the space as its header.
struct SpaceStripView: View {
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Binding var selectedSpaceID: UUID?
    /// Room above the card for the window traffic lights. The hybrid layout
    /// passes the bar's height, so the card's top edge is level with the web
    /// card's.
    var contentInset: CGFloat = 0

    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(SpaceStripMetrics.defaultsKey) private var showsNames = true

    @State private var showingAddSpace = false
    @State private var editingSpace: Space?
    @State private var confirmingDeleteSpace: Space?
    /// The space cell that currently holds keyboard focus. Two-way bound to each
    /// cell's `.focused` so the arrow keys move relative to it.
    @FocusState private var focusedSpaceID: UUID?

    /// The space being dragged, so the rows it crosses know what to move.
    @State private var draggingSpaceID: UUID?

    /// The card is the strip's width less the gutter beside it.
    private var cardWidth: CGFloat { SpaceStripMetrics.width(showingNames: showsNames) - ChorusCard.gutter }

    var body: some View {
        content
            .sheet(isPresented: $showingAddSpace) {
                SpaceEditorSheet(editingSpace: nil, selectedSpaceID: $selectedSpaceID)
                    .coveredWhenLocked()
            }
            .sheet(item: $editingSpace) { space in
                SpaceEditorSheet(editingSpace: space, selectedSpaceID: $selectedSpaceID)
                    .coveredWhenLocked()
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

    private var content: some View {
        VStack(spacing: 2) {
            // Scroll the cells so more spaces than fit the window height stay
            // reachable; the divider and add button below stay pinned.
            // No scroller: with "Always show scroll bars" on, it took width from
            // the fixed-width cells and pushed them off the rail's centre line.
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(spaces) { space in
                        spaceCell(space)
                    }
                }
                // Only a reorder animates. See `ReorderKey`.
                .animation(
                    ChorusMotion.animation(ChorusMotion.reorder, reduceMotion: reduceMotion),
                    value: ReorderKey(ids: spaces.map(\.id))
                )
                .padding(.vertical, ChorusCard.railPadding)
            }

            Rectangle()
                .fill(ChorusColor.hairline)
                .frame(height: 1)
                .padding(.horizontal, 8)

            addSpaceButton
                .padding(.bottom, ChorusCard.railPadding)
        }
        // One list, so no card: it sits on the window beside the web card.
        .railCardFrame(width: cardWidth, topInset: contentInset, carded: false)
        // The OS window drag is off in this layout, because the service bar
        // beside the strip holds draggable tabs in the title-bar band (see
        // WindowMovableConfigurator). Without a handle of its own the strip
        // would be the one part of the window's top edge that could not move it.
        // The handle gets the clicks in the gutter and the card's padding; the
        // scroll view takes them over the cells.
        .background(WindowDragHandle())
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
            needsAttention: !muted && appState.badgeManager.needsAttention(anyOf: serviceIDs),
            isMuted: muted,
            showsName: showsNames
        ) {
            // Co-locate keyboard focus with selection so a click leaves the
            // arrow keys an anchor to move from (a plain Button click doesn't
            // reliably focus the enclosing `.focusable()` on its own).
            selectedSpaceID = space.id
            focusedSpaceID = space.id
        }
        // Live reorder: the space moves as the pointer crosses other spaces,
        // and the order is saved as it goes. See `LiveReorder`.
        .onDrag {
            draggingSpaceID = space.id
            return LiveReorder.itemProvider(for: space.id, type: LiveReorder.spaceType)
        } preview: {
            Text(space.emoji)
                .font(.title3)
                .padding(6)
                .background(.ultraThickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: ChorusRadius.control))
        }
        .liveReorderDrop([
            .init(type: LiveReorder.spaceType, draggingID: { draggingSpaceID }, move: { liveMoveSpace($0, over: space.id) }),
        ])
        .accessibilityAction(named: "Move up") { moveSpaceUp(space) }
        .accessibilityAction(named: "Move down") { moveSpaceDown(space) }
        .focusable()
        .focused($focusedSpaceID, equals: space.id)
        // Suppress the rectangular system focus ring, matching the service rail.
        // Selection co-locates focus onto the cell, so the system ring stacked on
        // top of the cell's own accent border and pill — a doubled box that the
        // narrow strip then clipped. The app's own indicator already shows where
        // focus is.
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            handleSpaceKey(press, for: space)
        }
        .contextMenu {
            Toggle("Mute Notifications", isOn: Binding(
                get: { space.isMutedEffective },
                set: { newValue in
                    space.isMuted = newValue
                    save("toggle space mute")
                    // Refresh BadgeManager for every member service so the
                    // per-service badge and the aggregate cell badge zero out
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
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                if showsNames {
                    Text("Add Space")
                        .font(ChorusType.label)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.chromeRow)
        // In from the column's edges, as the space rows are, so the hover
        // fill lines up with theirs.
        .padding(.horizontal, ChorusCard.railPadding)
        .help("Add space")
        .accessibilityLabel("Add space")
    }

    private func save(_ context: String) {
        modelContext.saveOrRollBack(context)
    }

    /// ↑/↓ move the space selection along the strip; ⌥+arrow reorders the
    /// focused space, reusing the move helpers behind the VoiceOver actions.
    /// Selection stops at the ends.
    private func handleSpaceKey(_ press: KeyPress, for space: Space) -> KeyPress.Result {
        let forward: Bool
        switch press.key {
        case .upArrow: forward = false
        case .downArrow: forward = true
        default: return .ignored
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

    /// Moves the dragged space into the slot of the one under the pointer and
    /// saves at once, so a drag that ends outside the strip keeps what it showed.
    private func liveMoveSpace(_ dragged: UUID, over target: UUID) {
        guard let ids = LiveReorder.moving(dragged, over: target, in: spaces.map(\.id)) else { return }
        let spacesByID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        for (index, id) in ids.enumerated() {
            spacesByID[id]?.sortOrder = index
        }
        save("reorder spaces")
    }

    private func deleteSpace(_ space: Space) {
        // Routes through AppState so services that lived only in this space are
        // reclaimed (web view torn down + data store scheduled for removal)
        // instead of becoming invisible orphans. It also deletes the join rows
        // itself rather than trusting the cascade rule, which macOS 14 does not
        // honour (see CLAUDE.md), and fixes up the selection.
        appState.deleteSpace(space.id)
    }
}

private struct SpaceButton: View {
    let space: Space
    let isSelected: Bool
    var badgeCount: Int = 0
    /// A service in this space has a count waiting to be seen.
    var needsAttention: Bool = false
    var isMuted: Bool = false
    /// Whether the cell carries the space's name, which the strip decides from
    /// its own width.
    var showsName: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    private static let cornerRadius = ChorusRadius.control

    var body: some View {
        Button(action: action) {
            if showsName {
                namedRow
            } else {
                emojiTile
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

    /// The narrow strip: an emoji tile, filled grey when selected. The accent
    /// pill and stroke it used to carry went with the move to one selection mark.
    private var emojiTile: some View {
        // The tile fills what the card leaves inside its padding, so its 8
        // point corners sit concentric with the card's 14.
        let side = SpaceStripMetrics.compactWidth - ChorusCard.gutter - 2 * ChorusCard.railPadding
        return ZStack(alignment: .topTrailing) {
            Text(space.emoji)
                .font(.title2)
                .opacity(isMuted ? 0.5 : 1.0)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: Self.cornerRadius).fill(fillStyle))
                .cornerBadge(badgeCount, needsAttention: needsAttention)

            if isMuted {
                muteGlyph
            }
        }
        .frame(width: side, height: side)
    }

    /// The wide strip: emoji and name, laid out like a service row so the two
    /// rails read as one piece of chrome. It fills the strip's width rather than
    /// hugging its name, so the named strip's rows all line up.
    private var namedRow: some View {
        HStack(spacing: 8) {
            Text(space.emoji)
                .font(.system(size: 16))
                .opacity(isMuted ? 0.5 : 1.0)

            Text(space.name)
                .font(ChorusType.label)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            if badgeCount > 0 {
                SidebarCount(count: badgeCount, isSelected: isSelected, needsAttention: needsAttention)
            } else if isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ServiceRowView.rowHeight)
        .background(RoundedRectangle(cornerRadius: Self.cornerRadius).fill(fillStyle))
        .padding(.horizontal, ChorusCard.railPadding)
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
            return AnyShapeStyle(ChorusColor.selectedFill)
        } else if isHovering {
            return AnyShapeStyle(ChorusColor.hoverFill)
        }
        return AnyShapeStyle(Color.clear)
    }
}
