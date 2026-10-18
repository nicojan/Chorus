import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os

/// The service rail. Its ordinary modes hold the current space as a header and
/// that space's services beneath or beside it; the compact all-services mode
/// draws every space as a separator followed by its service icons.
///
/// This is build step 5 of concept C, and it replaces two views rather than
/// bending either into shape: `ServiceSidebarView` drew the services in two
/// axes and `SpaceStripView` drew a second rail of spaces beside it. Dropping
/// the second rail is what the concept buys — 161 points of chrome back in the
/// vertical layout, a whole 34 point bar in the horizontal one — and it is why
/// `hybrid` and `topBars` collapsed into a single layout: with one rail there
/// are only two arrangements left, on the left or along the top.
///
/// The arrow keys, the VoiceOver move actions and the donation button's
/// reserved corner came across from the old rails. Drag and drop has since
/// been rewritten as a live reorder; see `LiveReorder`. The space half of that
/// plumbing now lives in `SpacePaletteView`, which the header opens.
struct UnifiedRailView: View {
    @Binding var selectedSpaceID: UUID?
    @Binding var selectedServiceID: UUID?
    var axis: Axis = .vertical
    /// Room left for the window traffic lights: above the card in the vertical
    /// rail, and before the first control in the horizontal bar.
    var contentInset: CGFloat = 0
    /// Whether the rail draws the current space as its header. False in the
    /// hybrid layout, where a strip of spaces sits down the left and saying
    /// where you are twice would only cost the tabs their room.
    var showsSpaceHeader: Bool = true
    /// Draw every space and its services in one compact vertical rail.
    var showsAllSpaces: Bool = false

    @Query private var allLinks: [SpaceServiceLink]
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Draws the focus ring only once the keyboard is in use. See
    /// `FocusVisibility`. Computed, not stored: a private stored property
    /// makes the memberwise initialiser private on Xcode 16's compiler.
    private var focusVisibility: FocusVisibility { .shared }

    /// Whether service cells carry their names. See `ServiceNameVisibility`.
    @AppStorage(ServiceNameVisibility.defaultsKey) private var showServiceNames = true
    /// The rail's width while it carries names. See `RailWidth`.
    @AppStorage(RailWidth.defaultsKey) private var namedWidth = Double(RailWidth.defaultNamed)

    @State private var showingPalette = false
    @State private var showingAddService = false
    @State private var showingAddSpace = false
    @State private var editingSpace: Space?
    @State private var confirmingDeleteSpace: Space?
    @State private var confirmingDelete: SpaceServiceLink?
    @State private var editingService: ServiceInstance?
    /// The link whose service is being moved into a brand-new space: set when the
    /// user picks "New Space…", it presents the space editor and, on create,
    /// moves the service into the freshly made space.
    @State private var movingToNewSpace: SpaceServiceLink?
    /// The service cell that currently holds keyboard focus. Two-way bound to
    /// each cell's `.focused`, so a click or Tab that focuses a cell records it
    /// here and the arrow keys move relative to it.
    @FocusState private var focusedServiceID: UUID?
    /// The all-services rail can show one service in more than one space, so
    /// focus follows the membership link rather than the shared service id.
    @FocusState private var focusedAllServicesLinkID: UUID?
    /// The space being dragged in the all-services rail. See `LiveReorder`.
    @State private var draggingSpaceID: UUID?
    /// The service membership being dragged. See `LiveReorder`.
    @State private var draggingLinkID: UUID?

    /// The horizontal bar is the top band: a 32 point header and 32 point tabs
    /// with 10 points clear above and below.
    static let barHeight: CGFloat = ChorusCard.topBand
    /// How much of the scrolling tab row's trailing edge is softened to say the
    /// row runs past the window.
    private static let overflowFadeFraction: CGFloat = 0.06
    /// Room above each space's heading in the all-services rail, between one
    /// group's card and the next.
    private static let groupGap: CGFloat = 10

    private var filteredLinks: [SpaceServiceLink] {
        guard let spaceID = selectedSpaceID else { return [] }
        return links(in: spaceID)
    }

    /// What the vertical rail takes from the window now, gutter included.
    private var railFootprint: CGFloat {
        showServiceNames ? RailWidth.clampNamed(CGFloat(namedWidth)) : ServiceRowView.compactRailWidth
    }

    /// The rail's column, less the gutter.
    private var railColumnWidth: CGFloat { railFootprint - ChorusCard.gutter }

    /// A named row's width at the rail's current width.
    private var namedRowWidth: CGFloat { ServiceRowView.rowWidth(forRail: railFootprint) }

    private func links(in spaceID: UUID) -> [SpaceServiceLink] {
        allLinks
            // Both ends have to be live before reading the space's id: a link
            // whose Space or ServiceInstance is gone would fault the freed model
            // and trap on this hot render path. Matches `AppState.servicesForSpace`.
            .filter { $0.liveEnds?.space.id == spaceID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var currentSpace: Space? {
        guard let selectedSpaceID else { return nil }
        return spaces.first { $0.modelContext != nil && $0.id == selectedSpaceID }
    }

    // MARK: - Layout

    var body: some View {
        content
        .sheet(isPresented: $showingAddService) {
            if let spaceID = selectedSpaceID {
                AddServiceSheet(spaceID: spaceID)
                    .coveredWhenLocked()
            }
        }
        .sheet(item: $editingService) { service in
            EditServiceSheet(service: service)
                .coveredWhenLocked()
        }
        .onChange(of: appState.pendingEditServiceID) { _, id in
            // A tip asked for this service's settings.
            guard let id else { return }
            appState.pendingEditServiceID = nil
            editingService = filteredLinks.compactMap(\.liveService).first { $0.id == id }
        }
        .sheet(item: $movingToNewSpace) { link in
            SpaceEditorSheet(
                editingSpace: nil,
                selectedSpaceID: $selectedSpaceID,
                onCreate: { newSpace in
                    moveService(link: link, to: newSpace, followToSpace: true)
                }
            )
            .coveredWhenLocked()
        }
        .sheet(isPresented: $showingAddSpace) {
            SpaceEditorSheet(editingSpace: nil, selectedSpaceID: $selectedSpaceID)
                .coveredWhenLocked()
        }
        .sheet(item: $editingSpace) { space in
            SpaceEditorSheet(editingSpace: space, selectedSpaceID: $selectedSpaceID)
                .coveredWhenLocked()
        }
        .confirmationDialog(
            "Delete \(confirmingDelete?.liveService?.label ?? "service")?",
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let link = confirmingDelete {
                    deleteService(link: link)
                }
                confirmingDelete = nil
            }
        } message: {
            Text("This will permanently remove the service and all its data.")
        }
        // Kept on the outside of the service dialog above rather than beside it:
        // two confirmation dialogs bound to one view can race when both are
        // attached at the same level, and only one of these is ever up.
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
                    appState.deleteSpace(space.id)
                }
                confirmingDeleteSpace = nil
            }
        } message: {
            Text("Services in this space won't be deleted, but the space will be removed.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if showsAllSpaces {
            allServicesBody
        } else if axis == .vertical {
            verticalBody
        } else {
            horizontalBody
        }
    }

    /// Every space in sort order, each as a card of its services with the
    /// space's name (or, without names, its emoji) above the card, on the
    /// window itself. The card does the grouping, so there are no rules
    /// between groups and the rows are not indented.
    private var allServicesBody: some View {
        // Grouped once per render: the rows and the reorder key both need it.
        let groups = spaces.map { (space: $0, links: links(in: $0.id)) }
        return VStack(spacing: 0) {
            // No scroller: with "Always show scroll bars" on, it took width from
            // the fixed-width cells and pushed them off the rail's centre line.
            FadingVerticalScrollView {
                // A plain VStack, not lazy: a membership that moves between
                // spaces would keep the same `link.id`, and a lazy stack
                // matches that id across groups and reuses the cell. The cell
                // then keeps the old selection/focus marks, so the moved icon
                // stays highlighted after another service is actually in use.
                VStack(spacing: 0) {
                    ForEach(groups, id: \.space.id) { group in
                        let space = group.space
                        let spaceLinks = group.links
                        allServicesHeading(for: space)
                            .padding(.top, space.id == spaces.first?.id ? 0 : Self.groupGap)
                            .padding(.bottom, 4)

                        VStack(spacing: 2) {
                            if spaceLinks.isEmpty {
                                emptySpaceCell(for: space)
                            } else {
                                ForEach(spaceLinks) { link in
                                    if let service = link.liveService {
                                        allServicesRow(for: link, service: service, in: space)
                                            .id("\(space.id.uuidString)-\(link.id.uuidString)")
                                    }
                                }
                            }
                        }
                        .padding(ChorusCard.railPadding)
                        .railCard()
                    }
                }
                .animation(reorderAnimation, value: ReorderKey(ids: groups.flatMap(\.links).map(\.id)))
                .padding(.bottom, ChorusCard.railPadding)
            }

            allServicesAddButtons
                .padding(.vertical, ChorusCard.railPadding)
        }
        .railCardFrame(width: railColumnWidth, topInset: contentInset, carded: false)
        .environment(\.railWidth, railFootprint)
        // Names on and off move the rail between its two forms; the width
        // itself follows the pointer while it is dragged and does not animate.
        .animation(ChorusMotion.animation(ChorusMotion.sidebar, reduceMotion: reduceMotion), value: showServiceNames)
    }

    /// A space's name over its card, lined up with the service names in it:
    /// the emoji over their icons, the name over their names. Without names,
    /// the emoji alone, centred over the card.
    private func allServicesHeading(for space: Space) -> some View {
        let selected = selectedSpaceID == space.id

        return Button {
            selectSpaceFromAllServicesRail(space)
        } label: {
            Group {
                if showServiceNames {
                    HStack(spacing: 8) {
                        Text(space.emoji)
                            .font(.system(size: 14))
                            .frame(width: 18)
                            .opacity(space.isMutedEffective ? 0.5 : 1)
                            .accessibilityHidden(true)
                        // Set like a Notes section heading: the row size, bold,
                        // grey; the current space's in the label colour.
                        Text(space.name)
                            .font(ChorusType.label)
                            .fontWeight(.bold)
                            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(ChorusColor.secondaryText))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    // Card padding plus the row's own, so the emoji sits over
                    // the service icons.
                    .padding(.horizontal, ChorusCard.railPadding + 8)
                    .frame(width: railColumnWidth)
                } else {
                    Text(space.emoji)
                        .font(.system(size: 16))
                        .fixedSize()
                        .opacity(space.isMutedEffective ? 0.5 : 1)
                        .accessibilityHidden(true)
                        .frame(width: ServiceRowView.railCardWidth(showsName: false))
                }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(space.isMutedEffective ? "\(space.name) (muted)" : space.name)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Spaces reorder live as a heading is dragged over the others; a
        // service dropped on a heading moves into that space. See
        // `LiveReorder`.
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
            .init(
                type: LiveReorder.serviceType,
                draggingID: { draggingLinkID },
                move: { liveMoveLinkToTop($0, of: space) },
                drop: { dropLinkAtTop($0, of: space) }
            ),
        ])
        .contextMenu { spaceContextMenu(for: space) }
        .accessibilityAction(named: "Move up") { moveSpace(space, forward: false) }
        .accessibilityAction(named: "Move down") { moveSpace(space, forward: true) }
    }

    /// The rule over the add buttons, inset to the rows' width.
    private var railRule: some View {
        Rectangle()
            .fill(ChorusColor.hairline)
            .frame(height: 1)
            .padding(.horizontal, 8)
    }

    private func emptySpaceCell(for space: Space) -> some View {
        Button {
            selectedSpaceID = space.id
            selectedServiceID = nil
        } label: {
            Text("Empty")
                .font(ChorusType.caption)
                .foregroundStyle(ChorusColor.secondaryText)
                // Where the row labels start.
                .frame(maxWidth: .infinity, alignment: showServiceNames ? .leading : .center)
                .padding(.horizontal, showServiceNames ? 34 : 0)
                .frame(height: ServiceRowView.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(space.name), empty")
        .accessibilityLabel("\(space.name), empty")
        .liveReorderDrop([
            .init(type: LiveReorder.serviceType, draggingID: { draggingLinkID }, drop: { dropLinkAtTop($0, of: space) }),
        ])
    }

    @ViewBuilder
    private func allServicesRow(
        for link: SpaceServiceLink,
        service: ServiceInstance,
        in space: Space
    ) -> some View {
        let isSelected = selectedSpaceID == space.id && selectedServiceID == service.id
        let badge = appState.badgeManager.badgeCount(for: service.id)
        let hibernated = !isSelected && appState.webViewPool.isHibernated(service.id)
        let muted = service.isEffectivelyMuted
        let media = appState.webViewPool.mediaCaptureStates[service.id]
        let health = hibernated ? ServiceHealth.live : appState.webViewPool.health(for: service.id)

        cell(
            for: link,
            service: service,
            isSelected: isSelected,
            badge: badge,
            hibernated: hibernated,
            muted: muted,
            media: media,
            health: health,
            focused: focusedAllServicesLinkID == link.id && focusVisibility.isVisible,
            showsName: showServiceNames,
            spaceName: space.name,
            selectionAction: {
                NativeAppDocker.reselect(service, wasSelected: isSelected)
                selectedSpaceID = space.id
                selectedServiceID = service.id
                focusedAllServicesLinkID = link.id
            }
        )
        // Live reorder, within a space or into another one. See `LiveReorder`.
        .onDrag {
            draggingLinkID = link.id
            return LiveReorder.itemProvider(for: link.id, type: LiveReorder.serviceType)
        } preview: {
            ServiceDragPreview(service: service)
        }
        .liveReorderDrop([
            .init(
                type: LiveReorder.serviceType,
                draggingID: { draggingLinkID },
                move: { liveMoveLink($0, over: link, in: space) },
                drop: { dropLink($0, over: link, in: space) }
            ),
        ])
        .accessibilityAction(named: "Move up") { moveServiceWithinSpace(link, forward: false) }
        .accessibilityAction(named: "Move down") { moveServiceWithinSpace(link, forward: true) }
        .contextMenu { serviceContextMenu(for: link) }
        .focusable()
        .focused($focusedAllServicesLinkID, equals: link.id)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            handleAllServicesKey(press, for: link)
        }
    }

    /// Add service over Add space, one full cell each with or without names:
    /// side by side, the nameless pair shared 32 points and read as one
    /// cramped control.
    private var allServicesAddButtons: some View {
        VStack(spacing: 2) {
            allServicesAddButton(
                title: "Add service",
                systemImage: "plus",
                disabled: selectedSpaceID == nil
            ) {
                showingAddService = true
            }
            .featureTip(.addMacApp, arrowEdge: .trailing, isEnabled: selectedSpaceID != nil, appState: appState)
            allServicesAddButton(
                title: "Add space",
                systemImage: "folder.badge.plus",
                disabled: false
            ) {
                showingAddSpace = true
            }
        }
        .foregroundStyle(.secondary)
    }

    private func allServicesAddButton(
        title: String,
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if showServiceNames {
                    HStack(spacing: 8) {
                        Image(systemName: systemImage)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18, height: 18)
                        Text(title)
                            .font(ChorusType.label)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: namedRowWidth, height: ServiceRowView.rowHeight)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: ServiceRowView.compactRailCellWidth, height: ServiceRowView.rowHeight)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.chromeRow)
        .help(title)
        .accessibilityLabel(title)
        .disabled(disabled)
    }

    private func selectSpaceFromAllServicesRail(_ space: Space) {
        let spaceLinks = links(in: space.id)
        selectedSpaceID = space.id

        if let selectedServiceID,
           spaceLinks.contains(where: { $0.liveService?.id == selectedServiceID }) {
            return
        }
        selectedServiceID = spaceLinks.first?.liveService?.id
    }

    private func handleAllServicesKey(
        _ press: KeyPress,
        for link: SpaceServiceLink
    ) -> KeyPress.Result {
        let forward: Bool
        switch press.key {
        case .upArrow: forward = false
        case .downArrow: forward = true
        default: return .ignored
        }

        if press.modifiers.contains(.option) {
            moveServiceWithinSpace(link, forward: forward)
            focusedAllServicesLinkID = link.id
            return .handled
        }

        let orderedLinks = spaces.flatMap { links(in: $0.id) }
        guard let index = orderedLinks.firstIndex(where: { $0.id == link.id }) else {
            return .handled
        }
        let neighborIndex = forward ? index + 1 : index - 1
        guard orderedLinks.indices.contains(neighborIndex),
              let destination = orderedLinks[neighborIndex].liveEnds
        else { return .handled }

        selectedSpaceID = destination.space.id
        selectedServiceID = destination.service.id
        focusedAllServicesLinkID = orderedLinks[neighborIndex].id
        return .handled
    }

    @ViewBuilder
    private func spaceContextMenu(for space: Space) -> some View {
        Button("Add Service…") {
            selectedSpaceID = space.id
            showingAddService = true
        }

        Toggle("Mute Notifications", isOn: Binding(
            get: { space.isMutedEffective },
            set: { newValue in
                space.isMuted = newValue
                guard save("toggle space mute") else { return }
                for serviceID in appState.servicesForSpace(space.id).map(\.id) {
                    appState.refreshBadgeState(for: serviceID)
                }
            }
        ))

        Divider()
        Button("Edit Space…") {
            editingSpace = space
        }

        if spaces.count > 1 {
            Button("Delete Space", role: .destructive) {
                confirmingDeleteSpace = space
            }
        }
    }

    /// One list, on the window under the traffic lights, as wide as the rail
    /// has been dragged (see `RailWidth`); its top edge is level with the web
    /// card's. The header sits at y 58: the 52 point band, then 6 of padding.
    private var verticalBody: some View {
        VStack(spacing: 0) {
            spaceHeader
                .padding(.top, ChorusCard.railPadding)
                .padding(.bottom, 2)

            // No scroller: with "Always show scroll bars" on, it took width from
            // the fixed-width cells and pushed them off the rail's centre line.
            FadingVerticalScrollView {
                // 2 points between 28 point rows is the drawn 30 point pitch.
                LazyVStack(spacing: 2) {
                    ForEach(filteredLinks) { link in
                        if let service = link.liveService {
                            serviceRow(for: link, service: service)
                        }
                    }
                }
                .animation(reorderAnimation, value: ReorderKey(ids: filteredLinks.map(\.id)))
                .padding(.vertical, ChorusCard.railPadding)
            }

            railRule

            addServiceButton
                .padding(.vertical, ChorusCard.railPadding)
        }
        // One list needs no card of its own: it sits on the window, and the
        // web card beside it is the one card in the layout.
        .railCardFrame(width: railColumnWidth, topInset: contentInset, carded: false)
        .environment(\.railWidth, railFootprint)
        .animation(ChorusMotion.animation(ChorusMotion.sidebar, reduceMotion: reduceMotion), value: showServiceNames)
    }

    private var horizontalBody: some View {
        HStack(spacing: 8) {
            if showsSpaceHeader {
                spaceHeader
                    // 82 points of traffic light, then 8, puts the header at x 90.
                    .padding(.leading, 8 + contentInset)

                Divider().frame(width: 1, height: 20)

                tabStrip
            } else {
                // No header to spend the inset, so the tabs clear whatever the
                // traffic lights overhang onto this bar themselves.
                tabStrip
                    .padding(.leading, 8 + contentInset)
            }

            // Empty stretch between the tabs and the nav buttons. It draws
            // nothing and takes no hit of its own, so a click here falls through
            // to the window-drag handle behind the row.
            Spacer(minLength: 40)

            // Nav buttons live at the far right of the bar (top-right corner of
            // the window), acting on the active service.
            WebNavButtons(webViewState: appState.webViewState, homeURL: activeHomeURL)
                // Room for the donation button, which ContentView overlays on the
                // window's top-right corner — the same corner this row ends in.
                // Without the reserve the two sit on top of each other as soon as
                // the Home button appears and widens this group.
                .padding(.trailing, SupportButtonMetrics.reservedWidth)
        }
        .frame(height: Self.barHeight)
        // The OS window drag is off in the bar layout, so tab drags reorder
        // instead of moving the window (see WindowMovableConfigurator). A
        // full-width drag handle behind the row restores "click any empty part
        // of the bar to move the window": the header, tabs and nav buttons sit
        // in front and take their own clicks, and every empty area falls through
        // to here.
        // No fill of its own: the bar sits on the window canvas, and the web
        // card below it carries the edge the divider used to draw.
        .background(WindowDragHandle())
    }

    // MARK: - The space header, and the palette it opens

    private var spaceHeader: some View {
        let space = currentSpace
        let muted = space?.isMutedEffective ?? false
        let serviceIDs = space.map { appState.servicesForSpace($0.id).map(\.id) } ?? []
        let badgeCount = muted ? 0 : appState.badgeManager.aggregateCount(for: serviceIDs)

        return SpaceHeaderView(
            spaceName: space?.name,
            emoji: space?.emoji ?? "🏠",
            axis: axis,
            badgeCount: badgeCount,
            needsAttention: !muted && appState.badgeManager.needsAttention(anyOf: serviceIDs),
            isMuted: muted,
            showsName: axis == .horizontal || showServiceNames,
            isPaletteOpen: showingPalette
        ) {
            showingPalette = true
        }
        .popover(isPresented: $showingPalette, arrowEdge: axis == .vertical ? .trailing : .bottom) {
            SpacePaletteView(
                selectedSpaceID: $selectedSpaceID,
                onEditSpace: { editingSpace = $0 },
                onDeleteSpace: { confirmingDeleteSpace = $0 },
                onAddSpace: { showingAddSpace = true }
            )
            // Re-injected rather than left to inheritance, matching how
            // ContentView presents the quick switcher: the palette is
            // @Query-backed and a popover that came up without the container
            // would render an empty list.
            .environment(appState)
            .modelContainer(appState.modelContainer)
        }
    }

    /// The tab strip hugs its content when the tabs fit — leaving the rest of the
    /// bar as draggable empty space — and scrolls only when there are too many to
    /// fit. `ViewThatFits` picks the plain (hugging) row first and falls back to
    /// the scrolling row, which is deterministic where measuring the content
    /// width and capping the scroll view was not.
    ///
    /// The add button sits outside both, pinned to the trailing edge, the way the
    /// vertical rail has always pinned it below its scroll view. Inside the row
    /// it scrolled off the end with the tabs, so the one control that is not a
    /// tab was the first thing an overflowing bar took away.
    private var tabStrip: some View {
        HStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                tabRow
                scrollingTabRow
            }
            addServiceButton
        }
        .padding(.trailing, 8)
        .padding(.vertical, 2)
    }

    /// The overflow case. It is reached only when the tabs do not fit, so the
    /// softened trailing edge appears only when there is in fact more bar than
    /// window — it says the row runs on, next to the pinned add button that no
    /// longer moves. Before this, an overflowing bar cut the last tab mid-icon
    /// with nothing to say it scrolled, and a clipped icon reads as broken.
    private var scrollingTabRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                tabRow
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 1 - Self.overflowFadeFraction),
                        .init(color: .black.opacity(0.15), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            // Keep the active service visible when it's selected off-screen
            // (⌘1–9, quick switcher, or a routed link).
            .onChange(of: selectedServiceID) { _, newID in
                guard let newID else { return }
                if reduceMotion {
                    proxy.scrollTo(newID, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    /// The row of service tabs. A plain `HStack` (not lazy) so `ViewThatFits`
    /// can measure its width to decide whether the tabs fit. The traffic-light
    /// inset is spent by the header now, so this starts flush.
    private var tabRow: some View {
        HStack(spacing: 4) {
            ForEach(filteredLinks) { link in
                // filteredLinks already proved both ends live; the bind is what
                // carries that proof into the row rather than re-deriving it.
                if let service = link.liveService {
                    serviceRow(for: link, service: service)
                        .id(service.id)
                }
            }
        }
        .animation(reorderAnimation, value: ReorderKey(ids: filteredLinks.map(\.id)))
    }

    /// Rows and tabs settle into a new order with the chrome's spring, and
    /// jump there under Reduce Motion. Keyed on `ReorderKey`, so a change of
    /// selection or of space does not animate.
    private var reorderAnimation: Animation? {
        ChorusMotion.animation(ChorusMotion.reorder, reduceMotion: reduceMotion)
    }

    /// Home URL of the currently selected service, for the nav home button.
    private var activeHomeURL: URL? {
        guard let id = selectedServiceID,
              let service = filteredLinks.compactMap(\.liveService).first(where: { $0.id == id })
        else { return nil }
        return URL(string: service.url)
    }

    // MARK: - Service cells

    @ViewBuilder
    private func serviceRow(for link: SpaceServiceLink, service: ServiceInstance) -> some View {
        let isSel = selectedServiceID == service.id
        let badge = appState.badgeManager.badgeCount(for: service.id)
        let hibernated = !isSel && appState.webViewPool.isHibernated(service.id)
        let muted = service.isEffectivelyMuted
        let media = appState.webViewPool.mediaCaptureStates[service.id]
        // A hibernated service has no page to be healthy or broken, and the moon
        // already says why it is not loaded — so it reports live and draws no dot.
        let health = hibernated ? ServiceHealth.live : appState.webViewPool.health(for: service.id)

        cell(for: link, service: service, isSelected: isSel, badge: badge, hibernated: hibernated, muted: muted, media: media, health: health, focused: focusedServiceID == service.id && focusVisibility.isVisible)
            // Only the selected service points at its settings.
            .featureTip(.editSelectedService, arrowEdge: axis == .vertical ? .trailing : .bottom,
                        isEnabled: isSel, appState: appState)
            // Live reorder along the rail or the bar. See `LiveReorder`.
            .onDrag {
                draggingLinkID = link.id
                return LiveReorder.itemProvider(for: link.id, type: LiveReorder.serviceType)
            } preview: {
                ServiceDragPreview(service: service)
            }
            .liveReorderDrop([
                .init(type: LiveReorder.serviceType, draggingID: { draggingLinkID }, move: { liveMoveLinkInSpace($0, over: link) }),
            ])
            .accessibilityAction(named: "Move up") { moveServiceUp(link) }
            .accessibilityAction(named: "Move down") { moveServiceDown(link) }
            .contextMenu { serviceContextMenu(for: link) }
            .focusable()
            .focused($focusedServiceID, equals: service.id)
            // The system's rectangular ring stays off, but the signal it used to
            // carry is now drawn by the row itself (`RowMark`): a fill for
            // selection, a ring for focus, never the same mark. 1.5.10 switched
            // the system ring off because it stacked on the app's own border and
            // the 52 point strip clipped the result; the rail is 240 wide now,
            // and the app draws one ring rather than two.
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                handleServiceKey(press, for: link)
            }
    }

    @ViewBuilder
    private func cell(
        for link: SpaceServiceLink,
        service: ServiceInstance,
        isSelected: Bool,
        badge: Int,
        hibernated: Bool,
        muted: Bool,
        media: WebViewPool.MediaCaptureState?,
        health: ServiceHealth,
        focused: Bool,
        showsName: Bool? = nil,
        spaceName: String? = nil,
        selectionAction: (() -> Void)? = nil
    ) -> some View {
        ServiceRowView(
            instance: service,
            isSelected: isSelected,
            axis: axis,
            badgeCount: badge,
            needsAttention: appState.badgeManager.needsAttention(service.id),
            isHibernated: hibernated,
            isMuted: muted,
            cameraActive: media?.cameraActive ?? false,
            micActive: media?.micActive ?? false,
            micMuted: media?.micMuted ?? false,
            isPlayingAudio: appState.webViewPool.isPlayingAudio(service.id),
            health: health,
            showsName: showsName ?? showServiceNames,
            spaceName: spaceName,
            isFocused: focused
        ) {
            if let selectionAction {
                selectionAction()
            } else {
                selectService(link)
            }
        }
    }

    /// Selects a service and co-locates keyboard focus on its cell, so a click
    /// (or ⌘-digit) leaves the arrow keys with an anchor to move from — a plain
    /// Button click doesn't reliably promote the enclosing `.focusable()` to
    /// focused on its own.
    private func selectService(_ link: SpaceServiceLink) {
        guard let service = link.liveService else { return }
        NativeAppDocker.reselect(service, wasSelected: selectedServiceID == service.id)
        selectedServiceID = service.id
        focusedServiceID = service.id
    }

    /// Arrow keys move the selection along the rail's axis (↑/↓ vertical,
    /// ←/→ horizontal); ⌥+arrow reorders the focused service, reusing the same
    /// move helpers that back the VoiceOver actions. Selection stops at the ends
    /// (no wrap). Cross-axis arrows are left unhandled so the scroll view keeps
    /// them.
    private func handleServiceKey(_ press: KeyPress, for link: SpaceServiceLink) -> KeyPress.Result {
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
            if forward { moveServiceDown(link) } else { moveServiceUp(link) }
            // The service kept its id but changed slot — hold focus on it.
            focusedServiceID = link.liveService?.id
            return .handled
        }

        let links = filteredLinks
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return .handled }
        let neighborIndex = forward ? index + 1 : index - 1
        guard links.indices.contains(neighborIndex) else { return .handled }
        guard let neighborID = links[neighborIndex].liveService?.id else { return .handled }
        selectedServiceID = neighborID
        focusedServiceID = neighborID
        return .handled
    }

    /// In the wide vertical rail this is a labelled row like the services above
    /// it, with the plus sitting in an 18 point box so its text starts on the same
    /// x as theirs. Everywhere else it is the plus alone: the horizontal bar has
    /// no width to spare, and a nameless rail is 52 points wide, so the full-width
    /// labelled row would hang out of it.
    private var addServiceButton: some View {
        Button {
            showingAddService = true
        } label: {
            Group {
                if axis == .vertical && showServiceNames {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18, height: 18)
                        Text("Add service")
                            .font(ChorusType.label)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: namedRowWidth, height: ServiceRowView.rowHeight)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(
                            width: axis == .vertical ? ServiceRowView.compactRailCellWidth : ServiceRowView.compactCellWidth,
                            height: axis == .vertical ? ServiceRowView.rowHeight : ServiceRowView.tabHeight
                        )
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.chromeRow)
        .help("Add service")
        .accessibilityLabel("Add service")
        // Without a space there is nothing to add a service to, and
        // AddServiceSheet needs one.
        .disabled(selectedSpaceID == nil)
        .featureTip(.addMacApp, arrowEdge: axis == .vertical ? .trailing : .bottom,
                    isEnabled: selectedSpaceID != nil, appState: appState)
    }

    @ViewBuilder
    private func serviceContextMenu(for link: SpaceServiceLink) -> some View {
        if let service = link.liveService {
            serviceContextMenuItems(for: link, service: service)
        }
    }

    @ViewBuilder
    private func serviceContextMenuItems(for link: SpaceServiceLink, service: ServiceInstance) -> some View {
        Button("Edit Service…") {
            editingService = service
        }

        Toggle("Mute Notifications", isOn: Binding(
            get: { service.isMuted },
            set: { newValue in
                service.isMuted = newValue
                save("toggle service mute")
                syncBadge(for: service)
            }
        ))

        if appState.webViewPool.isPlayingAudio(service.id) {
            Button("Pause Audio") {
                appState.webViewPool.pauseAudio(for: service.id)
            }
        }

        // A Mac app has no page to open in a browser.
        if service.nativeAppBundleID == nil {
            Divider()

            Button("Open in Browser") {
                openInDefaultBrowser(service)
            }
        }

        Divider()

        if appState.webViewPool.hasWebView(for: service.id) {
            Button("Hibernate") {
                appState.webViewPool.hibernate(service.id)
                if selectedServiceID == service.id {
                    selectedServiceID = nil
                }
            }
        }

        Divider()
        Button("Change Icon...") {
            pickCustomIcon(for: service)
        }
        if service.customIconData != nil {
            Button("Reset Icon") {
                resetIcon(for: service)
            }
        }
        Divider()
        Menu("Move to Space") {
            let targets = eligibleSpaces(for: service)
            ForEach(targets) { space in
                Button {
                    moveService(link: link, to: space, followToSpace: false)
                } label: {
                    Text("\(space.emoji)  \(space.name)")
                }
                .accessibilityLabel(space.name)
            }
            if !targets.isEmpty {
                Divider()
            }
            Button("New Space…") {
                movingToNewSpace = link
            }
        }
        Button("Remove from this space") {
            removeFromSpace(link: link)
        }
        Divider()
        Button("Delete service entirely", role: .destructive) {
            confirmingDelete = link
        }
    }

    // MARK: - Mutations
    //
    // Everything below moved across from `ServiceSidebarView` unchanged. The
    // delete and move paths in particular are the ones that cost this repo real
    // user data when they were got wrong, and their guards (save-before-teardown,
    // rollback on failure) are load-bearing.

    @discardableResult
    /// Destructive callers skip their irreversible teardown on `false`, when
    /// the store didn't actually change.
    private func save(_ context: String) -> Bool {
        modelContext.saveOrRollBack(context)
    }

    /// Opens the service's current page in the system default browser,
    /// preferring the live WKWebView's URL over the catalog/home URL so
    /// the user lands where they actually were.
    private func openInDefaultBrowser(_ service: ServiceInstance) {
        let liveURL = appState.webViewPool.liveWebView(for: service.id)?.url
        let target = liveURL ?? URL(string: service.url)
        if let target {
            WebViewCoordinator.openExternally(target)
        }
    }

    /// Re-applies BadgeManager state for a service after its mute/showBadge
    /// changed, so the rail and dock totals update immediately instead of
    /// waiting for the next poll tick.
    private func syncBadge(for service: ServiceInstance) {
        appState.refreshBadgeState(for: service.id)
    }

    /// Spaces the service can be moved into: every space except the ones it's
    /// already in. Membership is read from the reliable `allLinks` query, not the
    /// service's inverse `spaceLinks` relationship, which can be stale.
    private func eligibleSpaces(for service: ServiceInstance) -> [Space] {
        let memberIDs = Set(
            allLinks
                .compactMap(\.liveEnds)
                .filter { $0.service.id == service.id }
                .map { $0.space.id }
        )
        let eligible = Set(SpaceMove.eligibleSpaceIDs(allSpaceIDs: spaces.map(\.id), memberSpaceIDs: memberIDs))
        return spaces.filter { eligible.contains($0.id) }
    }

    /// Relocates a service to another space by repointing its existing link
    /// (rather than delete-then-create), so the service never drops to zero links
    /// and no data store is orphaned. The link lands at the end of the target's
    /// list. `followToSpace` switches the view to the target and re-selects the
    /// service there — used for the new-space path, where the target is empty and
    /// landing on it makes sense; the existing-space path leaves the view put and
    /// just clears selection if the moved service was showing, matching
    /// "Remove from this space".
    private func moveService(link: SpaceServiceLink, to targetSpace: Space, followToSpace: Bool) {
        guard link.modelContext != nil,
              let currentSpace = link.liveSpace, currentSpace.id != targetSpace.id,
              let serviceID = link.liveService?.id
        else { return }
        let wasSelectedMembership = selectedSpaceID == currentSpace.id && selectedServiceID == serviceID

        // Compute the tail order before repointing, so the link's old order in
        // its current space doesn't count toward the target's max.
        let targetOrders = allLinks
            .filter { $0.modelContext != nil && $0.liveSpace?.id == targetSpace.id }
            .map(\.sortOrder)
        link.sortOrder = (targetOrders.max() ?? -1) + 1
        link.space = targetSpace
        save("move service to space")

        if followToSpace {
            selectedSpaceID = targetSpace.id
            selectedServiceID = serviceID
        } else if wasSelectedMembership {
            selectedServiceID = nil
        }
    }

    private func removeFromSpace(link: SpaceServiceLink) {
        // A link whose service is already gone has nothing to remove; drop the
        // link itself and stop, rather than reasoning about a missing model.
        guard let service = link.liveService else {
            modelContext.delete(link)
            save("remove dangling link from space")
            return
        }
        let serviceID = service.id
        let wasSelectedMembership = selectedSpaceID == link.liveSpace?.id && selectedServiceID == serviceID

        if wasSelectedMembership {
            selectedServiceID = nil
        }

        modelContext.delete(link)

        // Check remaining links *after* the delete so the count is current.
        let hasOtherLinks = service.spaceLinks.contains { $0.id != link.id }
        // Capture the identifier before the service is deleted — reading it off a
        // deleted model would fault the freed backing data.
        let orphanedIdentifier: UUID? = hasOtherLinks ? nil : service.dataStoreIdentifier
        if !hasOtherLinks {
            modelContext.delete(service)
        }

        // Only run the irreversible teardown (web-view removal, on-disk data-store
        // wipe) once the delete actually commits. A failed save rolls back, so
        // doing these first would log the user out / drop cookies for a service
        // whose row still exists — the data-loss pattern `deleteSpace` avoids.
        guard save("remove service from space") else { return }

        if !hasOtherLinks {
            appState.webViewPool.removeWebView(for: serviceID)
        }
        if let orphanedIdentifier {
            appState.markDataStoreOrphaned(orphanedIdentifier)
            appState.cleanUpOrphanedDataStores()
        }
    }

    private func pickCustomIcon(for service: ServiceInstance) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .icns]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an icon for \(service.label)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let raw = try Data(contentsOf: url)
            // Guard against a pathologically large source before decoding it.
            guard raw.count <= 20 * 1024 * 1024 else {
                AppLogger.ui.error("Icon file too large (\(raw.count) bytes); ignoring")
                return
            }
            // Store a small PNG, not the raw file: the icon renders at ~24pt, so a
            // full-size source would bloat the SwiftData row and be re-decoded on
            // every render. Fall back to the raw bytes only if it can't be decoded.
            service.customIconData = Self.downscaledIconPNG(from: raw) ?? raw
            save("set custom icon")
        } catch {
            AppLogger.ui.error("Failed to read icon file: \(error.localizedDescription)")
        }
    }

    /// Re-encodes a picked icon to a PNG no larger than `maxDimension` on its long
    /// edge, preserving aspect ratio. Returns nil if the data isn't a decodable
    /// image (caller keeps the raw bytes then).
    private static func downscaledIconPNG(from data: Data, maxDimension: CGFloat = 128) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let rep = image.representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
        let srcW = CGFloat(rep?.pixelsWide ?? Int(image.size.width))
        let srcH = CGFloat(rep?.pixelsHigh ?? Int(image.size.height))
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1, maxDimension / max(srcW, srcH))
        let target = NSSize(width: (srcW * scale).rounded(), height: (srcH * scale).rounded())
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    private func resetIcon(for service: ServiceInstance) {
        // A Mac app's own icon is its default; there is no favicon to fetch.
        if let bundleID = service.nativeAppBundleID {
            service.customIconData = NativeApp.appURL(bundleID: bundleID).flatMap { NativeApp.iconPNG(of: $0) }
            save("reset icon")
            return
        }
        service.customIconData = nil
        save("reset icon")
        if service.fetchedIconData == nil {
            // The fetch can take a minute, and the service may be deleted
            // meanwhile; writing to a deleted model traps. Hold the id, not
            // the model, and look it up again after the await.
            let serviceID = service.id
            let serviceURL = service.url
            Task {
                guard let data = await FaviconFetcher.shared.fetchFavicon(for: serviceURL) else { return }
                let descriptor = FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == serviceID })
                guard let current = try? modelContext.fetch(descriptor).first else { return }
                current.fetchedIconData = data
                current.faviconFetchedAt = Date()
                save("cache fetched icon")
            }
        }
    }

    private func moveSpace(_ space: Space, forward: Bool) {
        var orderedSpaces = Array(spaces)
        guard let index = orderedSpaces.firstIndex(where: { $0.id == space.id }) else { return }
        let destination = forward ? index + 1 : index - 1
        guard orderedSpaces.indices.contains(destination) else { return }

        orderedSpaces.swapAt(index, destination)
        for (order, item) in orderedSpaces.enumerated() {
            item.sortOrder = order
        }
        save(forward ? "move space down" : "move space up")
    }

    /// Moves the dragged space into the slot of the one under the pointer and
    /// saves at once. See `LiveReorder`.
    private func liveMoveSpace(_ dragged: UUID, over target: UUID) {
        guard let ids = LiveReorder.moving(dragged, over: target, in: spaces.map(\.id)) else { return }
        let spacesByID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        for (index, id) in ids.enumerated() {
            spacesByID[id]?.sortOrder = index
        }
        save("reorder spaces")
    }

    /// Moves the dragged service into the slot of the one under the pointer,
    /// in the rail or the bar that shows one space. Saves at once.
    private func liveMoveLinkInSpace(_ dragged: UUID, over target: SpaceServiceLink) {
        let links = filteredLinks
        guard let ids = LiveReorder.moving(dragged, over: target.id, in: links.map(\.id)) else { return }
        let linksByID = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
        for (index, id) in ids.enumerated() {
            linksByID[id]?.sortOrder = index
        }
        save("reorder services")
    }

    /// In the all-services rail, over a row of the dragged service's own space:
    /// it takes that row's slot, live. Over another space's row nothing moves
    /// until the drop (`dropLink`), so a cancelled drag leaves the service
    /// where it was.
    private func liveMoveLink(_ dragged: UUID, over target: SpaceServiceLink, in space: Space) {
        guard let source = allLinks.first(where: { $0.id == dragged })?.liveSpace,
              source.id == space.id
        else { return }
        let links = links(in: space.id)
        guard let ids = LiveReorder.moving(dragged, over: target.id, in: links.map(\.id)) else { return }
        let linksByID = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
        for (index, id) in ids.enumerated() {
            linksByID[id]?.sortOrder = index
        }
        save("reorder services")
    }

    /// Over a space's heading: a service of that same space goes to its top,
    /// live. One from another space waits for the drop (`dropLinkAtTop`).
    private func liveMoveLinkToTop(_ dragged: UUID, of space: Space) {
        guard let first = links(in: space.id).first else { return }
        liveMoveLink(dragged, over: first, in: space)
    }

    /// Released over a row: a service from another space moves into this one
    /// at that row. `placeService` keeps the membership and its data, and
    /// refuses a second copy of a service in one space, which reports the
    /// drop as not taken.
    private func dropLink(_ dragged: UUID, over target: SpaceServiceLink, in space: Space) -> Bool {
        guard let source = allLinks.first(where: { $0.id == dragged })?.liveSpace else { return false }
        guard source.id != space.id else { return true }
        return moveLinkAcrossSpaces(dragged, into: space, relativeTo: target)
    }

    /// Released over a space's heading or its empty slot: a service from
    /// another space goes to the top of this one.
    private func dropLinkAtTop(_ dragged: UUID, of space: Space) -> Bool {
        guard let source = allLinks.first(where: { $0.id == dragged })?.liveSpace else { return false }
        guard source.id != space.id else { return true }
        return moveLinkAcrossSpaces(dragged, into: space, relativeTo: links(in: space.id).first)
    }

    /// Moves a membership into another space and brings its badge up to date,
    /// since the new space may be muted when the old one was not.
    private func moveLinkAcrossSpaces(_ dragged: UUID, into space: Space, relativeTo target: SpaceServiceLink?) -> Bool {
        let serviceID = allLinks.first(where: { $0.id == dragged })?.liveService?.id
        let moved = placeService(droppedLinkID: dragged, in: space, relativeTo: target, placement: .before)
        if moved, let serviceID {
            appState.refreshBadgeState(for: serviceID)
        }
        return moved
    }

    private func moveServiceWithinSpace(_ link: SpaceServiceLink, forward: Bool) {
        guard let spaceID = link.liveSpace?.id else { return }
        var spaceLinks = links(in: spaceID)
        guard let index = spaceLinks.firstIndex(where: { $0.id == link.id }) else { return }
        let destination = forward ? index + 1 : index - 1
        guard spaceLinks.indices.contains(destination) else { return }

        spaceLinks.swapAt(index, destination)
        for (order, item) in spaceLinks.enumerated() {
            item.sortOrder = order
        }
        save(forward ? "move service down" : "move service up")
    }

    /// Reorders a membership inside one group or repoints it into another. A
    /// cross-space drop keeps the service instance and its web data intact.
    /// When the service is already a member of the target space the drop is
    /// rejected, because two identical links in one space are invalid.
    @discardableResult
    private func placeService(
        droppedLinkID: UUID,
        in targetSpace: Space,
        relativeTo targetLink: SpaceServiceLink?,
        placement: ServiceReorderPlacement
    ) -> Bool {
        guard let droppedLink = allLinks.first(where: { $0.id == droppedLinkID }),
              let droppedEnds = droppedLink.liveEnds,
              targetSpace.modelContext != nil
        else { return false }

        let sourceSpace = droppedEnds.space
        let service = droppedEnds.service
        let sourceLinks = links(in: sourceSpace.id)
        let targetLinks = sourceSpace.id == targetSpace.id
            ? sourceLinks
            : links(in: targetSpace.id)

        if sourceSpace.id != targetSpace.id,
           targetLinks.contains(where: { $0.liveService?.id == service.id }) {
            return false
        }

        guard let reorderedIDs = ServicePlacement.orderedIDs(
            targetLinks.map(\.id),
            moving: droppedLink.id,
            relativeTo: targetLink?.id,
            placement: placement
        ) else { return false }

        if sourceSpace.id == targetSpace.id {
            let linksByID = Dictionary(uniqueKeysWithValues: targetLinks.map { ($0.id, $0) })
            for (order, id) in reorderedIDs.enumerated() {
                linksByID[id]?.sortOrder = order
            }
            return save("reorder services")
        }

        return commitServicePlacement(
            droppedLink: droppedLink,
            service: service,
            sourceSpace: sourceSpace,
            targetSpace: targetSpace,
            sourceLinks: sourceLinks,
            targetLinks: targetLinks,
            orderedTargetIDs: reorderedIDs
        )
    }

    private func commitServicePlacement(
        droppedLink: SpaceServiceLink,
        service: ServiceInstance,
        sourceSpace: Space,
        targetSpace: Space,
        sourceLinks: [SpaceServiceLink],
        targetLinks: [SpaceServiceLink],
        orderedTargetIDs: [UUID]
    ) -> Bool {
        let wasSelected = selectedSpaceID == sourceSpace.id && selectedServiceID == service.id
        let targetByID = Dictionary(
            uniqueKeysWithValues: (targetLinks + [droppedLink]).map { ($0.id, $0) }
        )

        droppedLink.space = targetSpace
        for (order, item) in sourceLinks.filter({ $0.id != droppedLink.id }).enumerated() {
            item.sortOrder = order
        }
        for (order, id) in orderedTargetIDs.enumerated() {
            targetByID[id]?.sortOrder = order
        }

        guard save("move service to space") else { return false }
        // Drop the keyboard focus before the cell is recreated in the new
        // group. Holding it on the same link id is what left a ring on the
        // moved icon after another service was selected.
        focusedAllServicesLinkID = nil
        if wasSelected {
            selectedSpaceID = targetSpace.id
            selectedServiceID = service.id
        }
        return true
    }

    private func moveServiceUp(_ link: SpaceServiceLink) {
        var links = filteredLinks
        guard let index = links.firstIndex(where: { $0.id == link.id }), index > 0 else { return }
        links.swapAt(index, index - 1)
        for (i, l) in links.enumerated() { l.sortOrder = i }
        save("move service up")
    }

    private func moveServiceDown(_ link: SpaceServiceLink) {
        var links = filteredLinks
        guard let index = links.firstIndex(where: { $0.id == link.id }), index < links.count - 1 else { return }
        links.swapAt(index, index + 1)
        for (i, l) in links.enumerated() { l.sortOrder = i }
        save("move service down")
    }

    private func deleteService(link: SpaceServiceLink) {
        // As in removeFromSpace: a link with no service left is just a stale row.
        guard let service = link.liveService else {
            modelContext.delete(link)
            save("delete dangling link")
            return
        }
        let serviceID = service.id
        let dataStoreIdentifier = service.dataStoreIdentifier

        if selectedServiceID == serviceID {
            selectedServiceID = nil
        }

        // Delete links explicitly first — avoids cascade-delete leaving dangling
        // relationship references in the @Query results during the re-render.
        for spaceLink in service.spaceLinks {
            modelContext.delete(spaceLink)
        }
        modelContext.delete(service)

        // Gate the irreversible teardown behind a committed save (see
        // removeFromSpace) so a failed save can't wipe a still-present service's
        // web view and on-disk data store.
        guard save("delete service") else { return }

        appState.webViewPool.removeWebView(for: serviceID)
        appState.markDataStoreOrphaned(dataStoreIdentifier)
        appState.cleanUpOrphanedDataStores()
    }
}
