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
    @Query private var allDividers: [RailDivider]
    @Binding var selectedSpaceID: UUID?
    /// The selected service, for the global services the strip holds above
    /// or below its spaces.
    @Binding var selectedServiceID: UUID?
    /// Room above the card for the window traffic lights. The hybrid layout
    /// passes the bar's height, so the card's top edge is level with the web
    /// card's.
    var contentInset: CGFloat = 0

    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    /// What any rail is dragging. See `RailDragState`.
    private var drag: RailDragState { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(SpaceStripMetrics.defaultsKey) private var showsNames = true
    /// Where the global services sit. See `GlobalPlacement`.
    @AppStorage(GlobalPlacement.edgeKey) private var globalEdgeRaw = GlobalEdge.start.rawValue
    @AppStorage(GlobalPlacement.barKey) private var globalBarRaw = GlobalBar.spaces.rawValue

    private var globalPlacement: GlobalPlacement {
        GlobalPlacement(edgeRaw: globalEdgeRaw, barRaw: globalBarRaw)
    }

    /// Whether the strip holds the global services, rather than the bar.
    private var holdsGlobals: Bool { globalPlacement.bar == .spaces }

    /// Whether the global box is being dragged and can be let go at `spot`:
    /// either end of the strip it is not at. See `GlobalSpotDropTarget`.
    private func offersDrop(at spot: GlobalSpot) -> Bool {
        drag.globalBoxDragging && globalPlacement.dropSpots(in: .hybrid).contains(spot)
    }

    @State private var showingAddSpace = false
    @State private var editingSpace: Space?
    @State private var confirmingDeleteSpace: Space?
    /// The space cell that currently holds keyboard focus. Two-way bound to each
    /// cell's `.focused` so the arrow keys move relative to it.
    @FocusState private var focusedSpaceID: UUID?


    /// The spaces and the dividers between them, as drawn.
    private var items: [RailItem] {
        RailItems.spaces(spaces.filter { $0.modelContext != nil }, dividers: RailItems.dividers(allDividers, in: .spaces))
    }

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
                Text(AppState.deleteSpaceMessage(goingWithIt: confirmingDeleteSpace.map { appState.servicesOnlyIn(space: $0.id).map(\.label).sorted() } ?? []))
            }
    }

    private var content: some View {
        VStack(spacing: 2) {
            if holdsGlobals && globalPlacement.edge == .start {
                globalServicesBox
            }
            if offersDrop(at: .spaceStripTop) {
                GlobalSpotDropTarget(spot: .spaceStripTop, axis: .vertical)
            }

            // Scroll the cells so more spaces than fit the window height stay
            // reachable; the divider and add button below stay pinned.
            // No scroller: with "Always show scroll bars" on, it took width from
            // the fixed-width cells and pushed them off the rail's centre line.
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: SpaceStripMetrics.spacing(showingNames: showsNames)) {
                    ForEach(items) { item in
                        switch item {
                        case .space(let space):
                            spaceCell(space)
                        case .divider(let divider):
                            dividerRow(divider)
                        case .member, .global:
                            EmptyView()
                        }
                    }
                }
                // Only a reorder animates. See `ReorderKey`.
                .animation(reorderAnimation, value: ReorderKey(ids: items.map(\.id)))
                .padding(.vertical, ChorusCard.railPadding)
            }

            // At the end the box is pinned under the scrolling spaces, over
            // the hairline and the add button.
            if holdsGlobals && globalPlacement.edge == .end {
                globalServicesBox
            }
            if offersDrop(at: .spaceStripBottom) {
                GlobalSpotDropTarget(spot: .spaceStripBottom, axis: .vertical)
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
        .railDropZone()
        // The OS window drag is off in this layout, because the service bar
        // beside the strip holds draggable tabs in the title-bar band (see
        // WindowMovableConfigurator). Without a handle of its own the strip
        // would be the one part of the window's top edge that could not move it.
        // The handle gets the clicks in the gutter and the card's padding; the
        // scroll view takes them over the cells.
        .background(WindowDragHandle())
    }

    /// The global services, in a box of their own above or below the spaces,
    /// since they belong to none of them. The bar beside the strip then holds
    /// only the selected space's own services. Draws nothing while there are
    /// no global services.
    private var globalServicesBox: some View {
        UnifiedRailView(
            selectedSpaceID: $selectedSpaceID,
            selectedServiceID: $selectedServiceID,
            axis: .vertical,
            showsSpaceHeader: false,
            globalsOnly: true
        )
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
            drag.spaceID = space.id
            return LiveReorder.itemProvider(for: space.id, type: LiveReorder.spaceType)
        } preview: {
            Text(space.emoji)
                .font(.title3)
                .padding(6)
                .background(.ultraThickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: ChorusRadius.control))
        }
        .liveReorderDrop(lanes(over: space.id) + serviceLanes(into: space.id))
        .accessibilityAction(named: "Move up") { step(space.id, forward: false) }
        .accessibilityAction(named: "Move down") { step(space.id, forward: true) }
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
            Button("Add Divider Below") {
                withAnimation(reorderAnimation) { _ = appState.addDivider(in: .spaces, after: space.id) }
            }

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
        .help("Add space. Right-click to add a divider.")
        .accessibilityLabel("Add space")
        // A divider between spaces, at the end, found without right-clicking
        // a space first.
        .contextMenu {
            Button("Add Space…") { showingAddSpace = true }
            Button("Add Divider") { addDividerAtEnd() }
        }
        .accessibilityAction(named: "Add divider") { addDividerAtEnd() }
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
            step(space.id, forward: forward)
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

    private func addDividerAtEnd() {
        withAnimation(reorderAnimation) { _ = appState.addDivider(in: .spaces, after: nil) }
    }

    private var reorderAnimation: Animation? {
        ChorusMotion.animation(ChorusMotion.reorder, reduceMotion: reduceMotion)
    }

    /// A divider between spaces. Spaces pass over it live; dragged off the
    /// strip it is removed.
    private func dividerRow(_ divider: RailDivider) -> some View {
        let dividerID = divider.id
        return RailDividerView(
            dividerID: dividerID,
            onDragStart: {
                drag.dividerID = dividerID
                drag.dividerStartOrder = items.map(\.id)
            },
            onRemove: {
                withAnimation(reorderAnimation) { _ = appState.removeDivider(dividerID) }
            },
            onMove: { step(dividerID, forward: $0) },
            isDragging: drag.dividerID == dividerID,
            onDragEnd: { drag.dividerID = nil },
            onCancel: {
                withAnimation(reorderAnimation) { _ = appState.reorderRail(drag.dividerStartOrder, in: .spaces) }
            }
        )
        .padding(.horizontal, ChorusCard.railPadding)
        .liveReorderDrop(lanes(over: dividerID))
    }

    /// A space or a divider moves into the slot of the entry under the
    /// pointer, live. See `LiveReorder`.
    private func lanes(over target: UUID) -> [LiveReorderDropDelegate.Lane] {
        [
            .init(type: LiveReorder.spaceType, draggingID: { drag.spaceID }, move: { dragged, _ in liveMove(dragged, over: target) }),
            .init(type: LiveReorder.dividerType, draggingID: { drag.dividerID }, move: { dragged, _ in liveMove(dragged, over: target) }),
        ]
    }

    /// A service dragged from the bar beside the strip, or a global service
    /// from the top of it, goes to the end of the space it is let go on, once
    /// confirmed (see `RailMove`). A service already in that space is refused.
    private func serviceLanes(into spaceID: UUID) -> [LiveReorderDropDelegate.Lane] {
        [
            .init(type: LiveReorder.serviceType, draggingID: { drag.linkID }, drop: { linkID in
                let links = RailEdits.links(inSpace: spaceID, context: modelContext)
                let all = (try? modelContext.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
                guard let ends = all.first(where: { $0.id == linkID })?.liveEnds else { return false }
                guard ends.space.id != spaceID else { return true }
                guard appState.pendingRailMove == nil,
                      !links.contains(where: { $0.liveService?.id == ends.service.id })
                else { return false }
                appState.pendingRailMove = .intoSpace(linkID: linkID, spaceID: spaceID, before: nil)
                return true
            }),
            .init(type: LiveReorder.globalServiceType, draggingID: { drag.globalID }, drop: { serviceID in
                // Still global, and no other move waiting for its answer.
                let globals = RailEdits.globalServices(in: modelContext)
                guard appState.pendingRailMove == nil, globals.contains(where: { $0.id == serviceID }) else { return false }
                appState.pendingRailMove = .globalIntoSpace(serviceID: serviceID, spaceID: spaceID, before: nil)
                return true
            }),
            // A group's box goes to the end of the space, once confirmed. Its
            // own space takes it with nothing more; a refusal puts it back.
            .init(
                type: LiveReorder.groupType,
                draggingID: { drag.groupID },
                drop: { appState.requestGroupMove($0, into: spaceID, before: nil) },
                accepts: { appState.groupDrop($0, into: spaceID) != .refuse }
            ),
        ]
    }

    /// Moves the dragged entry into the slot of the one under the pointer and
    /// saves at once, so a drag that ends outside the strip keeps what it
    /// showed. Spaces and dividers are numbered together (see `RailOrder`).
    private func liveMove(_ dragged: UUID, over target: UUID) {
        let ids = items.map(\.id)
        guard let moved = LiveReorder.moving(dragged, over: target, in: ids) else { return }
        withAnimation(reorderAnimation) { _ = appState.reorderRail(moved, in: .spaces) }
    }

    /// Moves an entry one place along the strip, for VoiceOver and Option-arrow.
    private func step(_ id: UUID, forward: Bool) {
        let ids = items.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let destination = forward ? index + 1 : index - 1
        guard ids.indices.contains(destination),
              let moved = LiveReorder.moving(id, over: ids[destination], in: ids)
        else { return }
        withAnimation(reorderAnimation) { _ = appState.reorderRail(moved, in: .spaces) }
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
