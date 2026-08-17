import SwiftUI
import SwiftData

/// How the other spaces reach the screen.
///
/// Concept C put the current space on the rail as a header and moved the rest
/// behind a popover, which cost the one thing the old space rail was good at:
/// you could see, without clicking, that another space had unread messages.
/// Rather than pick one answer, the app offers all three and remembers the
/// choice.
///
/// This is chrome visibility rather than user data, so it lives in defaults
/// instead of `AppPreferences` — a stored property there is a new schema
/// version and a migration (see CLAUDE.md), which a layout toggle does not
/// earn. Same reasoning as `SupportButtonVisibility`.
enum SpacesPresentation: String, CaseIterable {
    /// Spaces listed in the service rail, above the services (the default).
    case inRail
    /// Spaces in a rail of their own, beside or above the service rail.
    case ownRail
    /// Only the current space is on screen; the rest are one click away in the
    /// header's popover. What concept C shipped.
    case switcher

    static let defaultsKey = "spacesPresentation"

    var displayName: String {
        switch self {
        case .inRail: return "In the rail, above the services"
        case .ownRail: return "In a rail of their own"
        case .switcher: return "Behind the header, one click away"
        }
    }

    /// Reads a stored raw value. An unknown string means a build that wrote a
    /// case this one does not have, and the safe landing is the default rather
    /// than a blank rail.
    static func resolving(_ raw: String?) -> SpacesPresentation {
        guard let raw, let known = SpacesPresentation(rawValue: raw) else { return .inRail }
        return known
    }

    /// Whether this presentation shows every space without a click.
    var showsAllSpaces: Bool { self != .switcher }
}

/// How much of a space a row draws. The palette has room for the service count
/// and the shortcut digit; a row in the rail has 224 points and shares them
/// with the services below it.
enum SpaceRowStyle {
    case palette
    case rail

    var height: CGFloat {
        switch self {
        case .palette: return 38
        case .rail: return 30
        }
    }

    var showsSubtitle: Bool { self == .palette }
    var showsShortcut: Bool { self == .palette }
}

/// The spaces, drawn as rows, with everything that hangs off them: click to
/// switch, drag to reorder, and the per-space context menu.
///
/// One view for three homes — the palette popover, the inline section at the
/// top of the service rail, and the rail of their own — because the reorder
/// maths and the mute plumbing were the expensive parts to get right and there
/// is no version of this worth writing twice.
struct SpaceListRows: View {
    @Binding var selectedSpaceID: UUID?
    var style: SpaceRowStyle = .palette
    /// Where the keyboard is, when a keyboard is driving this list. The rail
    /// presentations pass nil: they have no highlight of their own.
    var highlightedIndex: Int?
    var onHover: (Int) -> Void = { _ in }
    /// Called after the selection changes, so the palette can dismiss itself.
    var onSelect: () -> Void = {}
    var onEditSpace: (Space) -> Void = { _ in }
    var onDeleteSpace: (Space) -> Void = { _ in }

    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    /// Measured row heights, so a drop's before/after split uses the row's true
    /// midpoint rather than a guess.
    @State private var rowSizes: [UUID: CGSize] = [:]
    private static let rowMidpointFallback: CGFloat = 17

    var body: some View {
        ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
            row(space, index: index)
                .id(index)
        }
    }

    @ViewBuilder
    private func row(_ space: Space, index: Int) -> some View {
        // Resolve members through the same reliable link fetch the rail uses,
        // not `Space.serviceLinks` — that inverse relationship can be stale,
        // which once left the aggregate summing an empty list.
        let serviceIDs = appState.servicesForSpace(space.id).map(\.id)
        let muted = space.isMutedEffective
        let badgeCount = muted ? 0 : appState.badgeManager.aggregateCount(for: serviceIDs)

        SpaceRowCell(
            space: space,
            serviceCount: serviceIDs.count,
            badgeCount: badgeCount,
            isMuted: muted,
            isCurrent: space.id == selectedSpaceID,
            isHighlighted: index == highlightedIndex,
            shortcutDigit: style.showsShortcut ? SpacePalette.shortcutDigit(forIndex: index) : nil,
            style: style
        ) {
            selectedSpaceID = space.id
            onSelect()
        }
        .onHover { hovering in
            if hovering { onHover(index) }
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
            SpaceContextMenu(
                space: space,
                canDelete: spaces.count > 1,
                onEdit: { onEditSpace(space) },
                onDelete: { onDeleteSpace(space) }
            )
        }
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

/// Mute, edit and delete for one space. Its own view so the palette, the rail
/// section and the space rail all raise the same menu.
///
/// Edit and delete are reported upward rather than handled: a sheet cannot be
/// raised from inside a popover — the popover closes and takes the sheet with
/// it — so the owner presents them.
struct SpaceContextMenu: View {
    let space: Space
    let canDelete: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    var body: some View {
        Toggle("Mute Notifications", isOn: Binding(
            get: { space.isMutedEffective },
            set: { newValue in
                space.isMuted = newValue
                do {
                    try modelContext.save()
                } catch {
                    AppLogger.dataStore.error("Failed to save (toggle space mute): \(error.localizedDescription)")
                }
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
        Button("Edit Space...") { onEdit() }

        // No delete when this is the only space: the app has no valid state
        // with zero spaces, and AppState.deleteSpace refuses too.
        if canDelete {
            Divider()
            Button("Delete Space", role: .destructive) { onDelete() }
        }
    }
}

/// One space as a row: emoji, name, how many services, unread count, and the
/// digit that picks it. What it leaves out depends on the style — see
/// `SpaceRowStyle`.
struct SpaceRowCell: View {
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
    var style: SpaceRowStyle = .palette
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(space.emoji)
                    .font(.system(size: style == .palette ? 16 : 14))
                    .opacity(isMuted ? 0.5 : 1.0)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(space.name)
                        .font(.subheadline)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isCurrent ? .primary : .secondary)

                    if style.showsSubtitle {
                        Text(SpacePalette.subtitle(serviceCount: serviceCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
            .frame(height: style.height)
            .background {
                let mark = RowMark(isSelected: isCurrent, isFocused: false, isHovering: isHovering)
                RoundedRectangle(cornerRadius: ChorusRadius.control)
                    .fill(mark.fillStyle)
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
        .onHover { isHovering = $0 }
        .help(space.name)
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

/// One space as a chip, for the horizontal layouts, where a full row would eat
/// the bar. Emoji, name and badge; the name goes when the bar runs out of room
/// before the emoji does.
struct SpaceChipCell: View {
    let space: Space
    let badgeCount: Int
    let isMuted: Bool
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovering = false

    static let chipHeight: CGFloat = 28

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(space.emoji)
                    .font(.system(size: 14))
                    .opacity(isMuted ? 0.5 : 1.0)
                    .accessibilityHidden(true)

                Text(space.name)
                    .font(.subheadline)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isCurrent ? .primary : .secondary)

                if badgeCount > 0 {
                    BadgeCountView(count: badgeCount)
                } else if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Self.chipHeight)
            .background {
                let mark = RowMark(isSelected: isCurrent, isFocused: false, isHovering: isHovering)
                RoundedRectangle(cornerRadius: ChorusRadius.control)
                    .fill(mark.fillStyle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(space.name)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpaceHeader.label(
            spaceName: space.name,
            badgeCount: badgeCount,
            isMuted: isMuted
        ))
        .accessibilityAddTraits([.isButton, isCurrent ? .isSelected : []])
    }
}
