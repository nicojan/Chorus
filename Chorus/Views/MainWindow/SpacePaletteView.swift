import SwiftUI
import SwiftData

/// The words and the keyboard arithmetic behind the space palette. Split out
/// from the view so both can be pinned by a test, the same way
/// `ServiceAccessibility` is.
enum SpacePalette {
    // The rows carried ⌘1, ⌘2 down their trailing edge until 1.5.19, and the
    // digits never worked. `KeyboardShortcutManager` binds ⌘1–⌘9 to service
    // switching as menu command key equivalents, and the menu dispatches a key
    // equivalent before the event reaches the first responder, so the palette's
    // `.onKeyPress` was never asked. The plan of borrowing the digits while the
    // palette is open (decided 2026-08-17) cannot be done from `.onKeyPress` at
    // all; it would have to be done in the menu command, which is where the key
    // actually lands. Rather than ship a label for a shortcut that switches
    // services, the labels are gone. Arrows, Return, Escape and click are the
    // ways through the palette.

    static func subtitle(serviceCount: Int) -> String {
        switch serviceCount {
        case 0: return "No services"
        case 1: return "1 service"
        default: return "\(serviceCount) services"
        }
    }

    /// Everything the row shows, spoken. Mirrors `ServiceAccessibility.label`.
    static func rowLabel(name: String, serviceCount: Int, badgeCount: Int, isMuted: Bool) -> String {
        var parts = [name, subtitle(serviceCount: serviceCount)]
        if badgeCount > 0 {
            parts.append(badgeCount == 1 ? "1 unread" : "\(badgeCount) unread")
        }
        if isMuted { parts.append("muted") }
        return parts.joined(separator: ", ")
    }
}

/// The space switcher the rail header opens.
///
/// Concept C takes the always-visible space rail away, so this is where the
/// other spaces live: a list with the emoji, the name, how many services are in
/// it, and its aggregate unread count. Two things that were free on the old
/// rail are paid for here, and both are kept rather than dropped —
/// drag-to-reorder and the per-space context menu — because `SpaceStripView`
/// goes away at build step 5 and this is their new home. Reordering is the live
/// drag of `LiveReorder`, shared with the strip and the all-services rail.
///
/// The owner presents it, and owns any sheet it asks for:
///
/// ```swift
/// SpaceHeaderView(…, isPaletteOpen: showingPalette) { showingPalette = true }
///     .popover(isPresented: $showingPalette) {
///         SpacePaletteView(selectedSpaceID: $selectedSpaceID, onEditSpace: …)
///     }
/// ```
///
/// A sheet cannot be raised from inside a popover — the popover closes and takes
/// the sheet with it — so editing, deleting and adding are reported upward
/// instead of handled here.
struct SpacePaletteView: View {
    @Binding var selectedSpaceID: UUID?
    /// Reported upward rather than handled: see the note above about sheets.
    var onEditSpace: (Space) -> Void = { _ in }
    var onDeleteSpace: (Space) -> Void = { _ in }
    var onAddSpace: () -> Void = {}

    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Query private var allDividers: [RailDivider]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    /// What any rail is dragging. See `RailDragState`.
    private var drag: RailDragState { .shared }

    /// The row the keyboard is on. Separate from `selectedSpaceID`, which only
    /// changes when a row is actually picked — arrowing through the list should
    /// not switch spaces underneath the palette.
    @State private var highlightedIndex = 0
    @FocusState private var isFocused: Bool

    /// The spaces and the dividers between them, as drawn. The keyboard walks
    /// `spaces` alone: a divider is not somewhere to go.
    private var items: [RailItem] {
        RailItems.spaces(spaces.filter { $0.modelContext != nil }, dividers: RailItems.dividers(allDividers, in: .spaces))
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let paletteWidth: CGFloat = 260
    /// Radius 14 is the spec's one value for sheets and palettes.
    private static let cornerRadius = ChorusRadius.surface

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            addSpaceButton
        }
        .frame(width: Self.paletteWidth)
        .railDropZone()
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            highlightedIndex = spaces.firstIndex { $0.id == selectedSpaceID } ?? 0
            isFocused = true
        }
        .onKeyPress(phases: .down) { handleKey($0) }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        // Keyed by the space, not its index, so a row keeps its
                        // identity when a drag moves it and slides into place.
                        switch item {
                        case .space(let space):
                            if let index = spaces.firstIndex(where: { $0.id == space.id }) {
                                row(space, index: index)
                                    .id(space.id)
                            }
                        case .divider(let divider):
                            dividerRow(divider)
                        case .member, .global:
                            EmptyView()
                        }
                    }
                }
                .animation(reorderAnimation, value: ReorderKey(ids: items.map(\.id)))
                .padding(6)
            }
            // 4 rows and a bit, so a fifth space reads as "there is more here"
            // rather than being cut off flush.
            .frame(maxHeight: 220)
            .onChange(of: highlightedIndex) { _, new in
                guard spaces.indices.contains(new) else { return }
                proxy.scrollTo(spaces[new].id, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func row(_ space: Space, index: Int) -> some View {
        // Resolve members through the same reliable link fetch the rail uses,
        // not `Space.serviceLinks` — that inverse relationship can be stale,
        // which once left the aggregate summing an empty list. See SpaceStripView.
        let serviceIDs = appState.servicesForSpace(space.id).map(\.id)
        let muted = space.isMutedEffective
        let badgeCount = muted ? 0 : appState.badgeManager.aggregateCount(for: serviceIDs)

        SpacePaletteRow(
            space: space,
            serviceCount: serviceIDs.count,
            badgeCount: badgeCount,
            needsAttention: !muted && appState.badgeManager.needsAttention(anyOf: serviceIDs),
            isMuted: muted,
            isCurrent: space.id == selectedSpaceID,
            isHighlighted: index == highlightedIndex
        ) {
            select(space)
        }
        .onHover { hovering in
            if hovering { highlightedIndex = index }
        }
        // Live reorder, as in the strip. See `LiveReorder`.
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
        .liveReorderDrop(lanes(over: space.id) + [groupLane(into: space.id)])
        .accessibilityAction(named: "Move up") { step(space.id, forward: false) }
        .accessibilityAction(named: "Move down") { step(space.id, forward: true) }
        .contextMenu {
            Toggle("Mute Notifications", isOn: Binding(
                get: { space.isMutedEffective },
                set: { newValue in
                    space.isMuted = newValue
                    save("toggle space mute")
                    // Refresh every member so the per-service badges and this
                    // row's aggregate zero out (or come back) now, rather than
                    // at the next poll. The reliable link fetch again, not
                    // space.serviceLinks.
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
                dismiss()
                onEditSpace(space)
            }
            // No delete when this is the only space: the app has no valid state
            // with zero spaces, and AppState.deleteSpace refuses too.
            if spaces.count > 1 {
                Divider()
                Button("Delete Space", role: .destructive) {
                    dismiss()
                    onDeleteSpace(space)
                }
            }
        }
    }

    private var addSpaceButton: some View {
        Button {
            dismiss()
            onAddSpace()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 20)
                Text("New Space")
                    .font(ChorusType.label)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New space")
        .help("New space. Right-click to add a divider.")
        // A divider between spaces, at the end, found without right-clicking
        // a space first. The palette stays open to show where it went.
        .contextMenu {
            Button("New Space…") {
                dismiss()
                onAddSpace()
            }
            Button("Add Divider") { addDividerAtEnd() }
        }
        .accessibilityAction(named: "Add divider") { addDividerAtEnd() }
    }

    // MARK: - Keyboard

    /// Arrows move the highlight, Return picks it, Escape closes. Anything
    /// carrying Command is left alone: those are the app's shortcuts, and the
    /// menu has already had them by the time this runs.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }

        switch press.key {
        case .upArrow:
            moveHighlight(-1)
            return .handled
        case .downArrow:
            moveHighlight(1)
            return .handled
        case .return:
            guard spaces.indices.contains(highlightedIndex) else { return .handled }
            select(spaces[highlightedIndex])
            return .handled
        case .escape:
            dismiss()
            return .handled
        default:
            return .ignored
        }
    }

    private func moveHighlight(_ offset: Int) {
        guard !spaces.isEmpty else { return }
        highlightedIndex = (highlightedIndex + offset + spaces.count) % spaces.count
        let space = spaces[highlightedIndex]
        AccessibilityNotification.Announcement(space.name).post()
    }

    private func select(_ space: Space) {
        selectedSpaceID = space.id
        dismiss()
    }

    // MARK: - Reordering

    private func addDividerAtEnd() {
        withAnimation(reorderAnimation) { _ = appState.addDivider(in: .spaces, after: nil) }
    }

    private var reorderAnimation: Animation? {
        ChorusMotion.animation(ChorusMotion.reorder, reduceMotion: reduceMotion)
    }

    /// A divider between spaces. Spaces pass over it live; dragged out of the
    /// palette it is removed.
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

    /// A group's box, dragged from the rail and let go on a space here, goes
    /// to the end of that space once confirmed. The palette closes so the
    /// question can show.
    private func groupLane(into spaceID: UUID) -> LiveReorderDropDelegate.Lane {
        .init(
            type: LiveReorder.groupType,
            draggingID: { drag.groupID },
            drop: { groupID in
                guard appState.requestGroupMove(groupID, into: spaceID, before: nil) else { return false }
                dismiss()
                return true
            },
            accepts: { appState.groupDrop($0, into: spaceID) == .ask }
        )
    }

    /// Moves the dragged entry into the slot of the one under the pointer and
    /// saves at once. Spaces and dividers are numbered together (see
    /// `RailOrder`).
    private func liveMove(_ dragged: UUID, over target: UUID) {
        let ids = items.map(\.id)
        guard let moved = LiveReorder.moving(dragged, over: target, in: ids) else { return }
        withAnimation(reorderAnimation) { _ = appState.reorderRail(moved, in: .spaces) }
    }

    /// Moves an entry one place along the list, for VoiceOver.
    private func step(_ id: UUID, forward: Bool) {
        let ids = items.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let destination = forward ? index + 1 : index - 1
        guard ids.indices.contains(destination),
              let moved = LiveReorder.moving(id, over: ids[destination], in: ids)
        else { return }
        withAnimation(reorderAnimation) { _ = appState.reorderRail(moved, in: .spaces) }
    }

    private func save(_ context: String) {
        modelContext.saveOrRollBack(context)
    }
}

/// One space in the palette: emoji, name, how many services, unread count, and
/// the digit that picks it.
private struct SpacePaletteRow: View {
    let space: Space
    let serviceCount: Int
    let badgeCount: Int
    let needsAttention: Bool
    let isMuted: Bool
    /// The space you are in now. Marked with a tint fill that stays put while
    /// the highlight moves over it.
    let isCurrent: Bool
    /// Where the keyboard is. A separate, lighter mark, so the two never read as
    /// the same thing — the spec's selection-against-focus rule.
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(space.emoji)
                    .font(.system(size: 16))
                    .opacity(isMuted ? 0.5 : 1.0)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(space.name)
                        .font(ChorusType.label)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)

                    Text(SpacePalette.subtitle(serviceCount: serviceCount))
                        .font(ChorusType.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if badgeCount > 0 {
                    BadgeCountView(count: badgeCount, needsAttention: needsAttention)
                } else if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: ChorusRadius.control)
                    .fill(isCurrent ? AnyShapeStyle(ChorusColor.selectedFill) : AnyShapeStyle(Color.clear))
                    .overlay {
                        RoundedRectangle(cornerRadius: ChorusRadius.control)
                            .strokeBorder(
                                isHighlighted ? AnyShapeStyle(Color.primary.opacity(0.25)) : AnyShapeStyle(Color.clear),
                                lineWidth: 1
                            )
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpacePalette.rowLabel(
            name: space.name,
            serviceCount: serviceCount,
            badgeCount: badgeCount,
            isMuted: isMuted
        ))
        .accessibilityAddTraits([.isButton, isCurrent ? .isSelected : []])
    }
}
