import SwiftUI
import SwiftData

/// The words and the keyboard arithmetic behind the space palette. Split out
/// from the view so both can be pinned by a test, the same way
/// `ServiceAccessibility` is.
enum SpacePalette {
    /// The digit that picks the row at `index`, or nil past the ninth. There is
    /// no ⌘0 row; a tenth space is reached by arrow or by click.
    static func shortcutDigit(forIndex index: Int) -> Int? {
        guard (0..<9).contains(index) else { return nil }
        return index + 1
    }

    /// The row a digit picks, or nil when the digit reaches past the last row.
    ///
    /// Returning nil matters as much as returning an index. The digits are
    /// palette-local (decided 2026-08-17): `⌘1`–`⌘9` still switches services
    /// globally through `KeyboardShortcutManager`, and the palette only borrows
    /// them while it is open. A digit with no row behind it has to go
    /// unhandled rather than be swallowed.
    static func index(forDigit digit: Int, rowCount: Int) -> Int? {
        guard (1...9).contains(digit) else { return nil }
        let index = digit - 1
        return index < rowCount ? index : nil
    }

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
/// goes away at build step 5 and this is their new home. The reorder maths is
/// `ServiceReorder`, moved across untouched.
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    /// The row the keyboard is on. Separate from `selectedSpaceID`, which only
    /// changes when a row is actually picked — arrowing through the list should
    /// not switch spaces underneath the palette.
    @State private var highlightedIndex = 0
    @FocusState private var isFocused: Bool
    /// Measured row heights, so a drop's before/after split uses the row's true
    /// midpoint. Mirrors `SpaceStripView`.
    @State private var rowSizes: [UUID: CGSize] = [:]

    static let paletteWidth: CGFloat = 260
    /// Radius 14 is the spec's one value for sheets and palettes.
    private static let cornerRadius = ChorusRadius.surface
    private static let rowMidpointFallback: CGFloat = 19

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            addSpaceButton
        }
        .frame(width: Self.paletteWidth)
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
                    ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                        row(space, index: index)
                            .id(index)
                    }
                }
                .padding(6)
            }
            // 4 rows and a bit, so a fifth space reads as "there is more here"
            // rather than being cut off flush.
            .frame(maxHeight: 220)
            .onChange(of: highlightedIndex) { _, new in
                proxy.scrollTo(new, anchor: .center)
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
            isMuted: muted,
            isCurrent: space.id == selectedSpaceID,
            isHighlighted: index == highlightedIndex,
            shortcutDigit: SpacePalette.shortcutDigit(forIndex: index)
        ) {
            select(space)
        }
        .onHover { hovering in
            if hovering { highlightedIndex = index }
        }
        .draggable(space.id.uuidString) {
            Text(space.emoji)
                .font(.title3)
                .padding(6)
                .background(.ultraThickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: ChorusRadius.control))
        }
        .dropDestination(for: String.self) { items, location in
            guard let droppedIDString = items.first,
                  let droppedID = UUID(uuidString: droppedIDString),
                  droppedID != space.id
            else { return false }
            let mid = (rowSizes[space.id]?.height).map { $0 / 2 } ?? Self.rowMidpointFallback
            return reorder(
                droppedSpaceID: droppedID,
                relativeTo: space,
                placement: location.y < mid ? .before : .after
            )
        }
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) {
                    rowSizes[space.id] = proxy.size
                }
            }
        )
        .accessibilityAction(named: "Move up") { move(space, forward: false) }
        .accessibilityAction(named: "Move down") { move(space, forward: true) }
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
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New space")
    }

    // MARK: - Keyboard

    /// Arrows move the highlight, Return picks it, Escape closes, and ⌘1–⌘9 pick
    /// a row outright. The digits are borrowed only while this is open; anything
    /// else is left unhandled so it reaches the shortcuts underneath.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            guard let digit = Int(press.characters),
                  let index = SpacePalette.index(forDigit: digit, rowCount: spaces.count)
            else { return .ignored }
            select(spaces[index])
            return .handled
        }

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

    private func move(_ space: Space, forward: Bool) {
        var ordered = Array(spaces)
        guard let index = ordered.firstIndex(where: { $0.id == space.id }) else { return }
        let target = forward ? index + 1 : index - 1
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        for (i, s) in ordered.enumerated() { s.sortOrder = i }
        save(forward ? "move space down" : "move space up")
    }

    @discardableResult
    private func reorder(droppedSpaceID: UUID, relativeTo target: Space, placement: ServiceReorderPlacement) -> Bool {
        let spacesByID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        // The service rail's tested reorder maths, reused rather than rewritten:
        // it decrements the index when moving forward, which an inline version
        // here got wrong before (a forward drag landed one slot past the target).
        guard let reorderedIDs = ServiceReorder.reorderedIDs(
            spaces.map(\.id),
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

    private func save(_ context: String) {
        do {
            try modelContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save (\(context)): \(error.localizedDescription)")
        }
    }
}

/// One space in the palette: emoji, name, how many services, unread count, and
/// the digit that picks it.
private struct SpacePaletteRow: View {
    let space: Space
    let serviceCount: Int
    let badgeCount: Int
    let isMuted: Bool
    /// The space you are in now. Marked with a tint fill that stays put while
    /// the highlight moves over it.
    let isCurrent: Bool
    /// Where the keyboard is. A separate, lighter mark, so the two never read as
    /// the same thing — the spec's selection-against-focus rule.
    let isHighlighted: Bool
    let shortcutDigit: Int?
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
                        .font(.subheadline)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)

                    Text(SpacePalette.subtitle(serviceCount: serviceCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if badgeCount > 0 {
                    BadgeCountView(count: badgeCount)
                } else if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                if let shortcutDigit {
                    Text("⌘\(shortcutDigit)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: ChorusRadius.control)
                    .fill(isCurrent ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(Color.clear))
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
