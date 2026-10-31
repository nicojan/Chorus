import ChorusEngine
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
    /// Whether the bar draws the global group. Off in the hybrid layout
    /// while the placement puts the global services in the space strip.
    var showsGlobals: Bool = true
    /// Draw only the global group, as a column, for the space strip to hold
    /// above or below its spaces. Rows follow the strip's width and its names setting.
    var globalsOnly: Bool = false
    /// The space strip's height while this view draws the global group in it
    /// (`globalsOnly`), so the column can be capped as a pinned one. Zero for
    /// none.
    var stripHeight: CGFloat = 0

    @Query private var allLinks: [SpaceServiceLink]
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    /// Global services have no links, so `allLinks` never sees them.
    @Query(filter: #Predicate<ServiceInstance> { $0.isGlobal == true })
    private var globalQuery: [ServiceInstance]
    @Query private var allDividers: [RailDivider]
    @Query private var allGroups: [ServiceGroup]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    /// What any rail is dragging. See `RailDragState`.
    private var drag: RailDragState { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Draws the focus ring only once the keyboard is in use. See
    /// `FocusVisibility`. Computed, not stored: a private stored property
    /// makes the memberwise initialiser private on Xcode 16's compiler.
    private var focusVisibility: FocusVisibility { .shared }

    /// Whether service cells carry their names. See `ServiceNameVisibility`.
    @AppStorage(ServiceNameVisibility.defaultsKey) private var showServiceNames = true
    /// The rail's width while it carries names. See `RailWidth`.
    @AppStorage(RailWidth.defaultsKey) private var namedWidth = Double(RailWidth.defaultNamed)
    /// The space strip's names setting, which global rows follow when this
    /// view draws them inside the strip. See `globalsOnly`.
    @AppStorage(SpaceStripMetrics.defaultsKey) private var stripShowsNames = true
    /// Where the global group sits. See `GlobalPlacement`. Read here rather
    /// than through `GlobalPlacement.current()` so a change redraws the rail.
    @AppStorage(GlobalPlacement.edgeKey) private var globalEdgeRaw = GlobalEdge.start.rawValue
    @AppStorage(GlobalPlacement.barKey) private var globalBarRaw = GlobalBar.spaces.rawValue

    private var globalPlacement: GlobalPlacement {
        GlobalPlacement(edgeRaw: globalEdgeRaw, barRaw: globalBarRaw)
    }

    /// Whether the global group goes after the rest of its rail or bar.
    private var globalsAtEnd: Bool { globalPlacement.edge == .end }

    /// The vertical rail's laid-out height, which caps a global box pinned
    /// outside its scrolling list. See `GlobalBoxView.maxHeight`.
    @State private var railHeight: CGFloat = 0
    @State private var showingPalette = false
    /// The palette was opened by a group drag resting on the header, so it
    /// closes again when that drag ends.
    @State private var paletteSprung = false
    @State private var showingAddService = false
    @State private var showingAddSpace = false
    @State private var editingSpace: Space?
    @State private var confirmingDeleteSpace: Space?
    @State private var confirmingDelete: ServiceInstance?
    @State private var editingService: ServiceInstance?
    /// The link whose service is being moved into a brand-new space: set when the
    /// user picks "New Space…", it presents the space editor and, on create,
    /// moves the service into the freshly made space.
    @State private var movingToNewSpace: SpaceServiceLink?
    /// The same for a global service, which has no link to move.
    @State private var movingGlobalToNewSpace: ServiceInstance?
    /// The group the Name Group sheet is naming. See `GroupNaming`.
    @State private var namingGroup: GroupNameRequest?
    /// The service cell that currently holds keyboard focus. Two-way bound to
    /// each cell's `.focused`, so a click or Tab that focuses a cell records it
    /// here and the arrow keys move relative to it.
    @FocusState private var focusedServiceID: UUID?
    /// The all-services rail can show one service in more than one space, so
    /// focus follows the membership link rather than the shared service id.
    @FocusState private var focusedAllServicesLinkID: UUID?

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
        if globalsOnly { return SpaceStripMetrics.width(showingNames: stripShowsNames) }
        return showServiceNames ? RailWidth.clampNamed(CGFloat(namedWidth)) : ServiceRowView.compactRailWidth
    }

    /// Whether rows carry names: the rail's setting, or the strip's when this
    /// view draws the global group inside the strip.
    private var namesShown: Bool {
        globalsOnly ? stripShowsNames : showServiceNames
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

    /// Global services in rail order.
    private var globalServices: [ServiceInstance] {
        RailItems.liveGlobals(globalQuery)
    }

    /// The global group as drawn. Empty, and not drawn at all, while there are
    /// no global services: dividers alone make no group.
    private var globalItems: [RailItem] {
        let services = globalServices
        guard !services.isEmpty else { return [] }
        return RailItems.globals(services, dividers: RailItems.dividers(allDividers, in: .global))
    }

    /// A space's services and dividers as drawn.
    private func items(in spaceID: UUID) -> [RailItem] {
        RailItems.members(links(in: spaceID), dividers: RailItems.dividers(allDividers, in: .space(spaceID)))
    }

    /// A space's list as the rail draws it: rows, and a box round each group.
    /// The row being dragged stays inside a box it sits in, without splitting
    /// it. Which box is lit is the drag's call (`RailDragState.litGroupID`).
    private func runs(_ items: [RailItem], in spaceID: UUID) -> [RailRun] {
        RailGroupLookup(groups: allGroups, spaceID: spaceID).runs(items, dragged: drag.linkID)
    }

    /// The direction a list runs: the bar's, except the columns that are
    /// always vertical.
    private var listAxis: Axis {
        globalsOnly || showsAllSpaces ? .vertical : axis
    }

    /// The selected space's services and dividers.
    private var filteredItems: [RailItem] {
        guard let spaceID = selectedSpaceID else { return [] }
        return items(in: spaceID)
    }

    /// The spaces and the dividers between them.
    private var spaceListItems: [RailItem] {
        RailItems.spaces(spaces.filter { $0.modelContext != nil }, dividers: RailItems.dividers(allDividers, in: .spaces))
    }

    /// A list's ids in the order on screen: the input to every reorder.
    private func orderedIDs(_ scope: RailScope) -> [UUID] {
        switch scope {
        case .space(let spaceID):
            return items(in: spaceID).map(\.id)
        case .global:
            return RailItems.globals(globalServices, dividers: RailItems.dividers(allDividers, in: .global)).map(\.id)
        case .spaces:
            return spaceListItems.map(\.id)
        }
    }

    private var currentSpace: Space? {
        guard let selectedSpaceID else { return nil }
        return spaces.first { $0.modelContext != nil && $0.id == selectedSpaceID }
    }

    // MARK: - Layout

    var body: some View {
        content
        .modifier(GroupNaming(request: $namingGroup) { groupID, name in
            withAnimation(reorderAnimation) { _ = appState.nameGroup(groupID, name) }
        })
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
            editingService = visibleServices.first { $0.id == id }
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
        .sheet(item: $movingGlobalToNewSpace) { service in
            SpaceEditorSheet(
                editingSpace: nil,
                selectedSpaceID: $selectedSpaceID,
                onCreate: { newSpace in
                    appState.moveGlobalService(service.id, toSpace: newSpace.id, follow: true)
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
            "Delete \(confirmingDelete?.label ?? "service")?",
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let service = confirmingDelete {
                    appState.deleteServiceEntirely(service.id)
                }
                confirmingDelete = nil
            }
        } message: {
            Text(deleteMessage)
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
            Text(AppState.deleteSpaceMessage(goingWithIt: confirmingDeleteSpace.map { appState.servicesOnlyIn(space: $0.id).map(\.label).sorted() } ?? []))
        }
    }

    @ViewBuilder
    private var content: some View {
        if globalsOnly {
            globalsOnlyBody
        } else if showsAllSpaces {
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
        // Built once per render: the rows and the reorder key both need them.
        let globals = globalItems
        let entries = spaceListItems
        let groups: [UUID: [RailItem]] = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            guard case .space(let space) = entry else { return nil }
            return (space.id, items(in: space.id))
        })
        // The global box keys its own reorders; see `GlobalBoxView`.
        let reorderIDs = entries.flatMap { [$0.id] + (groups[$0.id] ?? []).map(\.id) }
        let globalsLead = !globals.isEmpty && !globalsAtEnd
        return VStack(spacing: 0) {
            // Pinned above the scrolling spaces, not first inside them: with the
            // box at the end and the list scrolled down, a target inside would
            // be out of sight, and nothing scrolls during a drag.
            if offersDrop(at: .railTop) {
                GlobalSpotDropTarget(spot: .railTop, axis: .vertical)
            }

            // No scroller: with "Always show scroll bars" on, it took width from
            // the fixed-width cells and pushed them off the rail's centre line.
            FadingVerticalScrollView {
                // A plain VStack, not lazy: a membership that moves between
                // spaces would keep the same `link.id`, and a lazy stack
                // matches that id across groups and reuses the cell. The cell
                // then keeps the old selection/focus marks, so the moved icon
                // stays highlighted after another service is actually in use.
                VStack(spacing: 0) {
                    // The global group has no heading: at the start it sits
                    // first, in a card of its own, and its rows say what they are.
                    if globalsLead {
                        globalBox(axis: .vertical)
                    }

                    ForEach(entries) { entry in
                        let isFirst = !globalsLead && entry.id == entries.first?.id
                        switch entry {
                        case .space(let space):
                            allServicesHeading(for: space)
                                .padding(.top, isFirst ? 0 : Self.groupGap)
                                .padding(.bottom, 4)

                            let spaceItems = groups[space.id] ?? []
                            VStack(spacing: 2) {
                                if spaceItems.isEmpty {
                                    emptySpaceCell(for: space)
                                } else {
                                    allServicesRuns(spaceItems, in: space)
                                }
                            }
                            .padding(ChorusCard.railPadding)
                            .railCard()
                        case .divider(let divider):
                            dividerRow(divider, in: .spaces, length: railColumnWidth)
                                .padding(.top, isFirst ? 0 : Self.groupGap)
                        case .member, .global:
                            EmptyView()
                        }
                    }
                }
                .animation(reorderAnimation, value: ReorderKey(ids: reorderIDs))
                .padding(.bottom, ChorusCard.railPadding)
            }

            // At the end the box is pinned below the scrolling spaces, over the
            // add buttons, and does not scroll with them.
            if globalsAtEnd {
                globalBox(axis: .vertical, pinned: true)
            }
            if offersDrop(at: .railBottom) {
                GlobalSpotDropTarget(spot: .railBottom, axis: .vertical)
            }

            allServicesAddButtons
                .padding(.vertical, ChorusCard.railPadding)
        }
        .measuringHeight(into: $railHeight)
        .railCardFrame(width: railColumnWidth, topInset: contentInset, carded: false)
        .railDropZone()
        .environment(\.railWidth, railFootprint)
        // Names on and off move the rail between its two forms; the width
        // itself follows the pointer while it is dragged and does not animate.
        .animation(ChorusMotion.animation(ChorusMotion.sidebar, reduceMotion: reduceMotion), value: showServiceNames)
    }

    /// One entry of a group's card in the all-services rail.
    @ViewBuilder
    private func allServicesItem(
        _ item: RailItem,
        in scope: RailScope,
        space: Space?,
        group: ServiceAccessibility.GroupContext? = nil,
        box: LiveReorderDropDelegate.Box? = nil
    ) -> some View {
        switch item {
        case .member(let link, let service):
            if let space {
                allServicesRow(for: link, service: service, in: space, group: group, box: box)
            }
        case .divider(let divider):
            dividerRow(divider, in: scope, length: namedOrCompactRowWidth)
        case .global, .space:
            // The global group is drawn through `globalBox`, never here.
            EmptyView()
        }
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
            drag.spaceID = space.id
            return LiveReorder.itemProvider(for: space.id, type: LiveReorder.spaceType)
        } preview: {
            Text(space.emoji)
                .font(.title3)
                .padding(6)
                .background(.ultraThickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: ChorusRadius.control))
        }
        .liveReorderDrop([
            .init(type: LiveReorder.spaceType, draggingID: { drag.spaceID }, move: { dragged, _ in liveMove(dragged, over: space.id, in: .spaces) }),
            .init(type: LiveReorder.dividerType, draggingID: { drag.dividerID }, move: { dragged, _ in liveMove(dragged, over: space.id, in: .spaces) }),
            .init(
                type: LiveReorder.serviceType,
                draggingID: { drag.linkID },
                move: { dragged, _ in liveMoveLinkToTop(dragged, of: space) },
                drop: { dropLinkAtTop($0, of: space) }
            ),
            .init(type: LiveReorder.globalServiceType, draggingID: { drag.globalID }, drop: { dragged in
                dropGlobal(dragged, into: space.id, before: orderedIDs(.space(space.id)).first)
            }),
            .init(
                type: LiveReorder.groupType,
                draggingID: { drag.groupID },
                move: { dragged, _ in liveMoveGroupToTop(dragged, of: space.id) },
                drop: { requestGroupMove($0, into: space.id, before: orderedIDs(.space(space.id)).first) },
                accepts: { appState.groupDrop($0, into: space.id) != .refuse }
            ),
        ])
        .contextMenu { spaceContextMenu(for: space) }
        .accessibilityAction(named: "Move up") { step(space.id, forward: false, in: .spaces) }
        .accessibilityAction(named: "Move down") { step(space.id, forward: true, in: .spaces) }
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
            .init(type: LiveReorder.serviceType, draggingID: { drag.linkID }, drop: { dropLinkAtTop($0, of: space) }),
            .init(type: LiveReorder.globalServiceType, draggingID: { drag.globalID }, drop: { dropGlobal($0, into: space.id, before: nil) }),
            .init(
                type: LiveReorder.groupType,
                draggingID: { drag.groupID },
                drop: { requestGroupMove($0, into: space.id, before: nil) },
                accepts: { appState.groupDrop($0, into: space.id) == .ask }
            ),
        ])
    }

    @ViewBuilder
    private func allServicesRow(
        for link: SpaceServiceLink,
        service: ServiceInstance,
        in space: Space,
        group: ServiceAccessibility.GroupContext? = nil,
        box: LiveReorderDropDelegate.Box? = nil
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
            group: group,
            selectionAction: {
                NativeAppDocker.reselect(service, wasSelected: isSelected)
                selectedSpaceID = space.id
                selectedServiceID = service.id
                focusedAllServicesLinkID = link.id
            }
        )
        .modifier(GroupSwell(isOn: drag.pausedTargetID == link.id))
        // Live reorder, within a space or into another one. See `LiveReorder`.
        .overlay(linkDragSource(for: link, service: service))
        .liveReorderDrop([
            .init(
                type: LiveReorder.serviceType,
                draggingID: { drag.linkID },
                move: { liveMove($0, over: link.id, in: .space(space.id), zone: $1) },
                drop: { dropLink($0, over: link, in: space) },
                groups: { sameSpace($0, as: space.id) }
            ),
            .init(type: LiveReorder.globalServiceType, draggingID: { drag.globalID }, drop: { dropGlobal($0, into: space.id, before: link.id) }),
            .init(type: LiveReorder.dividerType, draggingID: { drag.dividerID }, move: { liveMove($0, over: link.id, in: .space(space.id), zone: $1) }),
            groupLane(over: link.id, in: space.id),
        ], row: link.id, axis: .vertical, box: box)
        .accessibilityAction(named: "Move up") { step(link.id, forward: false, in: .space(space.id)) }
        .accessibilityAction(named: "Move down") { step(link.id, forward: true, in: .space(space.id)) }
        .modifier(groupRowActions(for: link))
        .contextMenu { serviceContextMenu(for: link) }
        .focusable()
        .focused($focusedAllServicesLinkID, equals: link.id)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            handleNavigationKey(press, focusID: link.id, reorderID: link.id, in: .space(space.id))
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
                disabled: selectedSpaceID == nil,
                menuTitle: "Add Service…",
                dividerScope: selectedSpaceID.map { .space($0) }
            ) {
                showingAddService = true
            }
            .featureTip(.addMacApp, arrowEdge: .trailing, isEnabled: selectedSpaceID != nil, appState: appState)
            allServicesAddButton(
                title: "Add space",
                systemImage: "folder.badge.plus",
                disabled: false,
                menuTitle: "Add Space…",
                dividerScope: .spaces
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
        menuTitle: String,
        dividerScope: RailScope?,
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
        .help("\(title). Right-click to add a divider.")
        .accessibilityLabel(title)
        .disabled(disabled)
        // The same choice as the button, plus a divider at the end of the
        // list, so dividers can be found without right-clicking a row.
        .contextMenu {
            Button(menuTitle, action: action)
            Button("Add Divider") { addDividerAtEnd(of: dividerScope) }
        }
        .accessibilityAction(named: "Add divider") { addDividerAtEnd(of: dividerScope) }
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
        Button("Add Divider Below") {
            withAnimation(reorderAnimation) { _ = appState.addDivider(in: .spaces, after: space.id) }
        }

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

    /// The global group alone, as a column for the hybrid layout's space
    /// strip, in a card of its own. Nothing at all while there are no global
    /// services. It takes the strip's drop zone from the environment rather
    /// than marking its own, so a divider dragged from here onto the spaces
    /// below is still on the rail.
    @ViewBuilder
    private var globalsOnlyBody: some View {
        if !globalItems.isEmpty {
            // The strip puts this above or below its spaces; either way the
            // gap below sets it off from the spaces or from the hairline.
            GlobalBoxView(
                items: globalItems,
                axis: .vertical,
                reorderAnimation: reorderAnimation,
                maxHeight: GlobalBoxCap.height(forRail: stripHeight)
            ) { item in
                railItemRow(item, in: .global)
            }
            .padding(.bottom, ChorusCard.railPadding)
            .environment(\.railWidth, railFootprint)
        }
    }

    /// The global group in its box, a column or a row. Every layout draws it
    /// through here, so this is the one view the box's drag and menu belong
    /// on. Draws nothing while there are no global services.
    ///
    /// A box `pinned` outside a vertical rail's scrolling list is capped at a
    /// share of the rail's height, so many global services in a short window
    /// cannot squeeze the list to nothing.
    private func globalBox(axis boxAxis: Axis, pinned: Bool = false) -> some View {
        GlobalBoxView(
            items: globalItems,
            axis: boxAxis,
            reorderAnimation: reorderAnimation,
            maxHeight: pinned ? GlobalBoxCap.height(forRail: railHeight) : nil
        ) { item in
            railItemRow(item, in: .global)
        }
    }

    /// One list, on the window under the traffic lights, as wide as the rail
    /// has been dragged (see `RailWidth`); its top edge is level with the web
    /// card's. The header sits at y 58: the 52 point band, then 6 of padding.
    private var verticalBody: some View {
        let globals = globalItems
        let spaceItems = filteredItems
        return VStack(spacing: 0) {
            // The global group sits in a box of its own, above the space it is
            // not part of or pinned below it, and is not drawn while empty.
            if !globals.isEmpty && !globalsAtEnd {
                globalBox(axis: .vertical, pinned: true)
            }
            if offersDrop(at: .railTop) {
                GlobalSpotDropTarget(spot: .railTop, axis: .vertical)
            }

            spaceHeader
                .padding(.top, ChorusCard.railPadding)
                .padding(.bottom, 2)

            // No scroller: with "Always show scroll bars" on, it took width from
            // the fixed-width cells and pushed them off the rail's centre line.
            FadingVerticalScrollView {
                // 2 points between 28 point rows is the drawn 30 point pitch.
                LazyVStack(spacing: 2) {
                    if let spaceID = selectedSpaceID {
                        spaceRuns(spaceItems, in: spaceID, showsName: showServiceNames) { item, group, box in
                            railItemRow(item, in: .space(spaceID), group: group, box: box)
                        }
                    }
                }
                .animation(reorderAnimation, value: ReorderKey(ids: spaceItems.map(\.id)))
                .padding(.vertical, ChorusCard.railPadding)
            }

            // Tested here, not left to the box: an empty box would still
            // carry its padding.
            if !globals.isEmpty && globalsAtEnd {
                globalBox(axis: .vertical, pinned: true)
                    .padding(.bottom, ChorusCard.railPadding)
            }
            if offersDrop(at: .railBottom) {
                GlobalSpotDropTarget(spot: .railBottom, axis: .vertical)
            }

            railRule

            addServiceButton
                .padding(.vertical, ChorusCard.railPadding)
        }
        // One list needs no card of its own: it sits on the window, and the
        // web card beside it is the one card in the layout.
        .measuringHeight(into: $railHeight)
        .railCardFrame(width: railColumnWidth, topInset: contentInset, carded: false)
        .railDropZone()
        .environment(\.railWidth, railFootprint)
        .animation(ChorusMotion.animation(ChorusMotion.sidebar, reduceMotion: reduceMotion), value: showServiceNames)
    }

    /// The bar: the header, the global box at the start, the space's tabs,
    /// then empty stretch, the global box at the end, and the nav buttons.
    /// While the box is dragged, the end it is not at holds a drop target.
    /// Only the tabs scroll; the boxes and the buttons stay whole.
    private var horizontalBody: some View {
        // Off in the hybrid layout while the space strip holds the box.
        let hasGlobals = showsGlobals && !globalItems.isEmpty
        let globalsLead = hasGlobals && !globalsAtEnd
        // 82 points of traffic light, then 8, puts the header at x 90. With
        // no header, whatever comes first spends the inset and clears what the
        // traffic lights overhang onto this bar.
        let leadingInset = 8 + contentInset
        let ends = GlobalSpot.barEnds(in: appState.railLayout)
        let startTarget = offersDrop(at: ends[0])
        return HStack(spacing: 8) {
            if showsSpaceHeader {
                spaceHeader
                    .padding(.leading, leadingInset)

                Divider().frame(width: 1, height: 20)
            }

            if globalsLead {
                barGlobalBox
                    .padding(.leading, showsSpaceHeader ? 0 : leadingInset)
            }

            if startTarget {
                GlobalSpotDropTarget(spot: ends[0], axis: .horizontal)
                    .padding(.leading, showsSpaceHeader ? 0 : leadingInset)
            }

            tabStrip
                .padding(.leading, showsSpaceHeader || globalsLead || startTarget ? 0 : leadingInset)

            // Empty stretch between the tabs and the nav buttons. It draws
            // nothing and takes no hit of its own, so a click here falls through
            // to the window-drag handle behind the row.
            Spacer(minLength: 40)

            if hasGlobals && globalsAtEnd {
                barGlobalBox
            }
            if offersDrop(at: ends[1]) {
                GlobalSpotDropTarget(spot: ends[1], axis: .horizontal)
            }

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
        .railDropZone()
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

    /// Whether the box is being dragged and this layout offers `spot` to let
    /// it go on: every spot but the one it sits at. See `GlobalSpotDropTarget`.
    private func offersDrop(at spot: GlobalSpot) -> Bool {
        drag.globalBoxDragging && globalPlacement.dropSpots(in: appState.railLayout).contains(spot)
    }

    /// The global box as a row of tabs. Held at its full width, so an
    /// overflowing bar scrolls its tabs rather than squeezing the box.
    private var barGlobalBox: some View {
        globalBox(axis: .horizontal)
            .fixedSize(horizontal: true, vertical: false)
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
        // A group's box resting here opens the palette, where the spaces it
        // can be let go on are. It closes again as that drag ends.
        .onDrop(of: [LiveReorder.groupType], delegate: SpringLoadDropDelegate(types: [LiveReorder.groupType]) {
            guard !showingPalette, drag.groupID != nil else { return }
            paletteSprung = true
            showingPalette = true
        })
        .onChange(of: drag.groupID) { _, groupID in
            guard groupID == nil, paletteSprung else { return }
            paletteSprung = false
            showingPalette = false
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
    /// can measure its width to decide whether the tabs fit. It starts flush:
    /// whatever comes before it in the bar (the header, the global box or the
    /// box's drop target) spends the traffic-light inset, and with none of
    /// them `horizontalBody` pads the strip itself.
    private var tabRow: some View {
        // The global tabs are not here: they sit in their own box, beside the
        // strip rather than in it. See `horizontalBody`.
        let spaceItems = filteredItems
        return HStack(spacing: 4) {
            if let spaceID = selectedSpaceID {
                spaceRuns(spaceItems, in: spaceID, showsName: true) { item, group, box in
                    // Keyed by the service where there is one, so the scroll
                    // view can bring the selected tab into view by its id.
                    railItemRow(item, in: .space(spaceID), group: group, box: box)
                        .id(item.service?.id ?? item.id)
                }
            }
        }
        .animation(reorderAnimation, value: ReorderKey(ids: spaceItems.map(\.id)))
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
              let service = visibleServices.first(where: { $0.id == id })
        else { return nil }
        return URL(string: service.url)
    }

    /// The services the rail shows now, in its order: the global group at the
    /// end the placement names, and the selected space's own.
    private var visibleServices: [ServiceInstance] {
        globalPlacement.ordered(globals: globalServices, rest: filteredLinks.compactMap(\.liveService))
    }

    // MARK: - Service cells

    /// A space's rows in the single-space rail or the bar, with a box round
    /// each group. `row` draws one entry and is told the group it sits in.
    @ViewBuilder
    private func spaceRuns<Row: View>(
        _ items: [RailItem],
        in spaceID: UUID,
        showsName: Bool,
        @ViewBuilder row: @escaping (RailItem, ServiceAccessibility.GroupContext?, LiveReorderDropDelegate.Box?) -> Row
    ) -> some View {
        ForEach(runs(items, in: spaceID)) { run in
            switch run {
            case .row(let item):
                row(item, nil, nil)
            case .group(let groupID, let name, let members, _):
                let box = boxLane(groupID, in: spaceID)
                GroupBox(
                    name: name,
                    axis: axis,
                    showsName: showsName,
                    isLit: drag.litGroupID == groupID,
                    memberNames: members.compactMap { $0.service?.label }
                ) {
                    ForEach(members) { item in
                        row(item, RailGroupLookup.context(for: item, name: name, in: members), box)
                    }
                }
                .groupBoxDrop(box, draggingID: { drag.linkID })
                .overlay(groupDragSource(groupID, in: spaceID, members: members))
                .modifier(groupBoxMenu(groupID, name: name, in: spaceID))
            }
        }
    }

    /// A space's entries in its all-services card, with a box round each group
    /// inside the card. The rows in a box narrow by the box's padding, so the
    /// box fits the card; a nameless row cannot narrow, so its box takes no
    /// side padding.
    private func allServicesRuns(_ items: [RailItem], in space: Space) -> some View {
        ForEach(runs(items, in: space.id)) { run in
            switch run {
            case .row(let item):
                allServicesItem(item, in: .space(space.id), space: space)
                    .id("\(space.id.uuidString)-\(item.id.uuidString)")
            case .group(let groupID, let name, let members, _):
                let box = boxLane(groupID, in: space.id)
                GroupBox(
                    name: name,
                    axis: .vertical,
                    showsName: showServiceNames,
                    isLit: drag.litGroupID == groupID,
                    sideInset: showServiceNames ? ChorusCard.railPadding : 0,
                    memberNames: members.compactMap { $0.service?.label }
                ) {
                    ForEach(members) { item in
                        allServicesItem(
                            item,
                            in: .space(space.id),
                            space: space,
                            group: RailGroupLookup.context(for: item, name: name, in: members),
                            box: box
                        )
                        .id("\(space.id.uuidString)-\(item.id.uuidString)")
                    }
                }
                .groupBoxDrop(box, draggingID: { drag.linkID })
                .overlay(groupDragSource(groupID, in: space.id, members: members))
                .environment(\.railWidth, railFootprint - 2 * ChorusCard.railPadding)
                .modifier(groupBoxMenu(groupID, name: name, in: space.id))
            }
        }
    }

    /// One entry of the single-space rail or the bar.
    @ViewBuilder
    private func railItemRow(
        _ item: RailItem,
        in scope: RailScope,
        group: ServiceAccessibility.GroupContext? = nil,
        box: LiveReorderDropDelegate.Box? = nil
    ) -> some View {
        switch item {
        case .member(let link, let service):
            serviceRow(for: link, service: service, group: group, box: box)
        case .global(let service):
            globalRow(service)
        case .divider(let divider):
            dividerRow(divider, in: scope, length: axis == .vertical ? namedOrCompactRowWidth : nil)
        case .space:
            EmptyView()
        }
    }

    /// A row's width in a vertical list, with or without names.
    private var namedOrCompactRowWidth: CGFloat {
        namesShown ? namedRowWidth : ServiceRowView.compactRailCellWidth
    }

    @ViewBuilder
    private func serviceRow(
        for link: SpaceServiceLink,
        service: ServiceInstance,
        group: ServiceAccessibility.GroupContext? = nil,
        box: LiveReorderDropDelegate.Box? = nil
    ) -> some View {
        let isSel = selectedServiceID == service.id
        let badge = appState.badgeManager.badgeCount(for: service.id)
        let hibernated = !isSel && appState.webViewPool.isHibernated(service.id)
        let muted = service.isEffectivelyMuted
        let media = appState.webViewPool.mediaCaptureStates[service.id]
        // A hibernated service has no page to be healthy or broken, and the moon
        // already says why it is not loaded — so it reports live and draws no dot.
        let health = hibernated ? ServiceHealth.live : appState.webViewPool.health(for: service.id)

        cell(for: link, service: service, isSelected: isSel, badge: badge, hibernated: hibernated, muted: muted, media: media, health: health, focused: focusedServiceID == service.id && focusVisibility.isVisible, group: group)
            // Only the selected service points at its settings.
            .featureTip(.editSelectedService, arrowEdge: axis == .vertical ? .trailing : .bottom,
                        isEnabled: isSel, appState: appState)
            .modifier(GroupSwell(isOn: drag.pausedTargetID == link.id))
            // Live reorder along the rail or the bar. See `LiveReorder`.
            .overlay(linkDragSource(for: link, service: service))
            .liveReorderDrop(memberLanes(for: link), row: link.id, axis: listAxis, box: box)
            .accessibilityAction(named: "Move up") { stepLink(link, forward: false) }
            .accessibilityAction(named: "Move down") { stepLink(link, forward: true) }
            .modifier(groupRowActions(for: link))
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
                guard let spaceID = link.liveSpace?.id else { return .ignored }
                return handleNavigationKey(press, focusID: service.id, reorderID: link.id, in: .space(spaceID))
            }
    }

    // MARK: - Starting a service drag

    /// The rail's handler for the end of a service drag. See `RailDragEnding`.
    private var serviceDragEnding: RailServiceDragEnding {
        RailServiceDragEnding(appState: appState, animation: reorderAnimation)
    }

    /// A space's service row as a drag source. AppKit starts the drag, so its
    /// end is known and Escape can put the lists back. See `RailDragSession`.
    private func linkDragSource(for link: SpaceServiceLink, service: ServiceInstance) -> some View {
        let linkID = link.id
        let spaceID = link.liveSpace?.id
        return RowDragSource(
            id: linkID,
            type: LiveReorder.serviceType,
            ending: serviceDragEnding,
            onDragStart: {
                drag.reset()
                drag.linkID = linkID
                // Its own space reorders live; the global group is where a
                // drop can take it.
                let scopes: [RailScope] = (spaceID.map { [.space($0)] } ?? []) + [.global]
                drag.startSnapshot = appState.railSnapshot(scopes)
            },
            preview: { ServiceDragPreview(service: service) }
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A global service's row as a drag source. Only the global group
    /// reorders live under it.
    private func globalDragSource(for service: ServiceInstance) -> some View {
        let serviceID = service.id
        return RowDragSource(
            id: serviceID,
            type: LiveReorder.globalServiceType,
            ending: serviceDragEnding,
            onDragStart: {
                drag.reset()
                drag.globalID = serviceID
                drag.startSnapshot = appState.railSnapshot([.global])
            },
            preview: { ServiceDragPreview(service: service) }
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// What a service's row in the single-space rail or the bar takes: a
    /// service of the same space reorders live, a global service moves into
    /// the space on release, and a divider of the space reorders live.
    private func memberLanes(for link: SpaceServiceLink) -> [LiveReorderDropDelegate.Lane] {
        guard let spaceID = link.liveSpace?.id else { return [] }
        return [
            .init(
                type: LiveReorder.serviceType,
                draggingID: { drag.linkID },
                move: { liveMove($0, over: link.id, in: .space(spaceID), zone: $1) },
                groups: { sameSpace($0, as: spaceID) }
            ),
            .init(type: LiveReorder.globalServiceType, draggingID: { drag.globalID }, drop: { dropGlobal($0, into: spaceID, before: link.id) }),
            .init(type: LiveReorder.dividerType, draggingID: { drag.dividerID }, move: { liveMove($0, over: link.id, in: .space(spaceID), zone: $1) }),
            groupLane(over: link.id, in: spaceID),
        ]
    }

    /// Whether a dragged link belongs to this space: only then can it group
    /// here. A service of another space, or a global one, never swells a row.
    private func sameSpace(_ linkID: UUID, as spaceID: UUID) -> Bool {
        links(in: spaceID).contains { $0.id == linkID }
    }

    /// A group's box as a drop target: a service of its space joins when it
    /// sits in the run or right next to either end. See `GroupRules.touchesRun`.
    private func boxLane(_ groupID: UUID, in spaceID: UUID) -> LiveReorderDropDelegate.Box {
        LiveReorderDropDelegate.Box(id: groupID) { dragged in
            sameSpace(dragged, as: spaceID)
                && GroupRules.touchesRun(dragged, of: groupID, in: groupEntries(in: spaceID))
        }
    }

    /// A global service's row, in every layout. Selecting it leaves the space
    /// as it is: the service shows in all of them.
    @ViewBuilder
    private func globalRow(_ service: ServiceInstance) -> some View {
        let isSel = selectedServiceID == service.id
        let badge = appState.badgeManager.badgeCount(for: service.id)
        let hibernated = !isSel && appState.webViewPool.isHibernated(service.id)
        let media = appState.webViewPool.mediaCaptureStates[service.id]
        let health = hibernated ? ServiceHealth.live : appState.webViewPool.health(for: service.id)
        let focused = showsAllSpaces
            ? focusedAllServicesLinkID == service.id
            : focusedServiceID == service.id

        cell(
            service: service,
            isSelected: isSel,
            badge: badge,
            hibernated: hibernated,
            muted: service.isEffectivelyMuted,
            media: media,
            health: health,
            focused: focused && focusVisibility.isVisible,
            showsName: namesShown,
            spaceName: showsAllSpaces ? "Global" : nil,
            selectionAction: {
                NativeAppDocker.reselect(service, wasSelected: isSel)
                selectedServiceID = service.id
                if showsAllSpaces {
                    focusedAllServicesLinkID = service.id
                } else {
                    focusedServiceID = service.id
                }
            }
        )
        .overlay(globalDragSource(for: service))
        .liveReorderDrop([
            .init(type: LiveReorder.globalServiceType, draggingID: { drag.globalID }, move: { liveMove($0, over: service.id, in: .global, zone: $1) }),
            .init(type: LiveReorder.serviceType, draggingID: { drag.linkID }, drop: { dropLinkIntoGlobal($0, before: service.id) }),
            .init(type: LiveReorder.dividerType, draggingID: { drag.dividerID }, move: { liveMove($0, over: service.id, in: .global, zone: $1) }),
            // A group never goes global. Refused here rather than ignored, so
            // its release puts back what the drag moved on the way.
            .init(type: LiveReorder.groupType, draggingID: { drag.groupID }, accepts: { _ in false }),
        ], row: service.id, axis: listAxis, box: nil)
        .accessibilityAction(named: "Move up") { step(service.id, forward: false, in: .global) }
        .accessibilityAction(named: "Move down") { step(service.id, forward: true, in: .global) }
        .contextMenu { globalContextMenu(for: service) }
        .focusable()
        .focused(showsAllSpaces ? $focusedAllServicesLinkID : $focusedServiceID, equals: service.id)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            handleNavigationKey(press, focusID: service.id, reorderID: service.id, in: .global)
        }
    }

    /// A divider in one of the rail's lists. Rows of the same list pass over
    /// it live; dragged off the rail it is removed.
    private func dividerRow(_ divider: RailDivider, in scope: RailScope, length: CGFloat?) -> some View {
        let dividerID = divider.id
        return RailDividerView(
            dividerID: dividerID,
            axis: scope == .spaces ? .vertical : axis,
            length: length,
            onDragStart: {
                drag.dividerID = dividerID
                drag.dividerStartOrder = orderedIDs(scope)
            },
            onRemove: { removeDivider(dividerID) },
            onMove: { step(dividerID, forward: $0, in: scope) },
            isDragging: drag.dividerID == dividerID,
            onDragEnd: {
                drag.reset()
                // The live moves can carry a divider into a group's run; it
                // steps out past the run as the drag ends.
                if case .space(let spaceID) = scope {
                    withAnimation(reorderAnimation) { _ = appState.tidyGroups(inSpace: spaceID) }
                }
            },
            onCancel: {
                withAnimation(reorderAnimation) { _ = appState.reorderRail(drag.dividerStartOrder, in: scope) }
            }
        )
        .liveReorderDrop(dividerLanes(over: dividerID, in: scope))
    }

    /// What a divider takes: anything that reorders live in its list moves
    /// past it, and a service crossing between the global group and a space
    /// lands where it is let go.
    private func dividerLanes(over dividerID: UUID, in scope: RailScope) -> [LiveReorderDropDelegate.Lane] {
        let divider = LiveReorderDropDelegate.Lane(
            type: LiveReorder.dividerType, draggingID: { drag.dividerID }, move: { dragged, _ in liveMove(dragged, over: dividerID, in: scope) }
        )
        switch scope {
        case .space(let spaceID):
            return [
                divider,
                .init(
                    type: LiveReorder.serviceType,
                    draggingID: { drag.linkID },
                    move: { dragged, _ in liveMove(dragged, over: dividerID, in: scope) },
                    drop: { dropLinkOverDivider($0, dividerID: dividerID, spaceID: spaceID) }
                ),
                .init(type: LiveReorder.globalServiceType, draggingID: { drag.globalID }, drop: { dropGlobal($0, into: spaceID, before: dividerID) }),
                groupLane(over: dividerID, in: spaceID),
            ]
        case .global:
            return [
                divider,
                .init(type: LiveReorder.globalServiceType, draggingID: { drag.globalID }, move: { dragged, _ in liveMove(dragged, over: dividerID, in: scope) }),
                .init(type: LiveReorder.serviceType, draggingID: { drag.linkID }, drop: { dropLinkIntoGlobal($0, before: dividerID) }),
            ]
        case .spaces:
            return [
                divider,
                .init(type: LiveReorder.spaceType, draggingID: { drag.spaceID }, move: { dragged, _ in liveMove(dragged, over: dividerID, in: scope) }),
            ]
        }
    }

    @ViewBuilder
    private func cell(
        for link: SpaceServiceLink? = nil,
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
        group: ServiceAccessibility.GroupContext? = nil,
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
            group: group,
            isFocused: focused
        ) {
            if let selectionAction {
                selectionAction()
            } else if let link {
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

    /// One place the arrow keys can land: the cell that takes focus, and what
    /// selecting it selects. A nil space leaves the current one, which is
    /// what a global service needs.
    private struct NavigationStop {
        let focusID: UUID
        let spaceID: UUID?
        let serviceID: UUID
    }

    /// Every service the arrow keys walk through, in the rail's order: the
    /// global group at the end the placement names, and the selected space, or
    /// every space in the all-services rail. Dividers are not stops.
    private var navigationStops: [NavigationStop] {
        let globals = globalServices.map { NavigationStop(focusID: $0.id, spaceID: nil, serviceID: $0.id) }
        let placement = globalPlacement
        if showsAllSpaces {
            return placement.ordered(globals: globals, rest: spaces.flatMap { space in
                links(in: space.id).compactMap { link in
                    link.liveService.map { NavigationStop(focusID: link.id, spaceID: space.id, serviceID: $0.id) }
                }
            })
        }
        return placement.ordered(globals: globals, rest: filteredLinks.compactMap { link in
            link.liveService.map { NavigationStop(focusID: $0.id, spaceID: nil, serviceID: $0.id) }
        })
    }

    /// Arrow keys move the selection along the rail's axis (↑/↓ vertical,
    /// ←/→ horizontal); ⌥+arrow reorders the focused service within its list,
    /// reusing the helpers that back the VoiceOver actions. Selection stops at
    /// the ends (no wrap). Cross-axis arrows are left unhandled so the scroll
    /// view keeps them.
    private func handleNavigationKey(
        _ press: KeyPress,
        focusID: UUID,
        reorderID: UUID,
        in scope: RailScope
    ) -> KeyPress.Result {
        let forward: Bool
        switch (axis, press.key) {
        case (.vertical, .upArrow), (.horizontal, .leftArrow):
            forward = false
        case (.vertical, .downArrow), (.horizontal, .rightArrow):
            forward = true
        default:
            return .ignored
        }

        // Option-Shift moves a member's whole box, as Move up / Move down on
        // the box do; a row in no box steps as with Option alone.
        if press.modifiers.contains(.option), press.modifiers.contains(.shift),
           case .space(let spaceID) = scope,
           let groupID = groupEntries(in: spaceID).first(where: { $0.id == reorderID })?.groupID {
            stepGroup(groupID, forward: forward, in: spaceID)
            setFocus(focusID)
            return .handled
        }

        if press.modifiers.contains(.option) {
            step(reorderID, forward: forward, in: scope)
            // The service kept its id but changed slot — hold focus on it.
            setFocus(focusID)
            return .handled
        }

        let stops = navigationStops
        guard let index = stops.firstIndex(where: { $0.focusID == focusID }) else { return .handled }
        let neighborIndex = forward ? index + 1 : index - 1
        guard stops.indices.contains(neighborIndex) else { return .handled }
        let destination = stops[neighborIndex]
        if let spaceID = destination.spaceID {
            selectedSpaceID = spaceID
        }
        selectedServiceID = destination.serviceID
        setFocus(destination.focusID)
        return .handled
    }

    private func setFocus(_ focusID: UUID) {
        if showsAllSpaces {
            focusedAllServicesLinkID = focusID
        } else {
            focusedServiceID = focusID
        }
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
        .help("Add service. Right-click to add a divider.")
        .accessibilityLabel("Add service")
        // Where a divider can be found without first right-clicking a
        // service. It goes at the end of the space.
        .contextMenu {
            Button("Add Service…") { showingAddService = true }
            Button("Add Divider") { addDividerAtEnd(of: selectedSpaceID.map { .space($0) }) }
        }
        .accessibilityAction(named: "Add divider") { addDividerAtEnd(of: selectedSpaceID.map { .space($0) }) }
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
        commonServiceMenuItems(for: service)

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
        // Takes it out of every space it is in, not only this one, so the
        // name says where it goes rather than where it leaves.
        Button("Show in Every Space") {
            withAnimation(reorderAnimation) { _ = appState.makeServiceGlobal(service.id) }
        }
        // Only when it is in another space too. In its only space, removing it
        // deletes the service and its sign-in, which is what Delete does,
        // except Delete asks first; offering both read as two names for one
        // thing, one of them without the question.
        if memberships(of: service) > 1 {
            Button("Remove from this space") {
                removeFromSpace(link: link)
            }
        }
        groupMenuItems(for: link)
        Divider()
        addDividerButton(after: link.id, in: link.liveSpace.map { .space($0.id) })
        Divider()
        Button("Delete service entirely", role: .destructive) {
            confirmingDelete = service
        }
    }

    /// A global service's menu. It is in no space, so instead of moving
    /// between spaces or leaving one, it can only go into one.
    @ViewBuilder
    private func globalContextMenu(for service: ServiceInstance) -> some View {
        if service.modelContext != nil {
            commonServiceMenuItems(for: service)

            Divider()
            Menu("Move to Space") {
                ForEach(spaces.filter { $0.modelContext != nil }) { space in
                    Button {
                        withAnimation(reorderAnimation) { _ = appState.moveGlobalService(service.id, toSpace: space.id) }
                    } label: {
                        Text("\(space.emoji)  \(space.name)")
                    }
                    .accessibilityLabel(space.name)
                }
                Divider()
                Button("New Space…") {
                    movingGlobalToNewSpace = service
                }
            }
            // The box's own menu, here too: VoiceOver and the keyboard reach
            // a row's menu but not the card's.
            GlobalPlacementMenu(layout: appState.railLayout)
            Divider()
            addDividerButton(after: service.id, in: .global)
            Divider()
            Button("Delete service entirely", role: .destructive) {
                confirmingDelete = service
            }
        }
    }

    /// "Add Divider Below" in a vertical list, "After" along the bar.
    @ViewBuilder
    private func addDividerButton(after itemID: UUID, in scope: RailScope?) -> some View {
        if let scope {
            Button(axis == .horizontal ? "Add Divider After" : "Add Divider Below") {
                withAnimation(reorderAnimation) { _ = appState.addDivider(in: scope, after: itemID) }
            }
        }
    }

    /// The items every service's menu has, wherever it sits.
    @ViewBuilder
    private func commonServiceMenuItems(for service: ServiceInstance) -> some View {
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
    }

    /// What deleting the service in `confirmingDelete` removes. A sign-in it
    /// shares stays for the services still using it.
    private var deleteMessage: String {
        guard let service = confirmingDelete else { return "" }
        let partners = appState.signInPartners(of: service.id).map(\.label)
        guard !partners.isEmpty else {
            return "This will permanently remove the service and all its data."
        }
        let use = partners.count == 1 ? "uses" : "use"
        return "This will permanently remove the service. Its sign-in stays, since \(AppState.listed(partners)) still \(use) it."
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

    /// How many spaces a service is in, read from the link query rather than
    /// the inverse relationship, which can be stale.
    private func memberships(of service: ServiceInstance) -> Int {
        allLinks.compactMap(\.liveEnds).filter { $0.service.id == service.id }.count
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
    /// list and leaves its group (see `RailEdits.moveMembership`).
    /// `followToSpace` switches the view to the target and re-selects the
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

        // A failed move rolled back and changed nothing, so the selection
        // stays as it is.
        guard RailEdits.moveMembership(link.id, toSpace: targetSpace.id, context: modelContext) else { return }

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
        let linkID = link.id
        guard let service = link.liveService else {
            if RailEdits.leaveSpace(link, context: modelContext) {
                save("remove dangling link from space")
            }
            return
        }
        let serviceID = service.id
        let wasSelectedMembership = selectedSpaceID == link.liveSpace?.id && selectedServiceID == serviceID

        if wasSelectedMembership {
            selectedServiceID = nil
        }

        // Deletes the link and tidies the groups of the space it leaves. A
        // link already gone leaves nothing to do, and the service must not be
        // judged orphaned on the strength of a delete that never happened.
        guard RailEdits.leaveSpace(link, context: modelContext) else { return }

        // Check remaining links *after* the delete so the count is current.
        // A link deleted earlier can linger in this inverse on macOS 14, and
        // reading its id faults the freed row: check it is still live first.
        let hasOtherLinks = service.spaceLinks.contains { $0.modelContext != nil && $0.id != linkID }
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

    /// Moves the dragged entry into the slot of the one under the pointer and
    /// saves at once, numbering the list's rows and dividers together (see
    /// `RailOrder`). Only an entry already in the list moves, so a service
    /// from another space, or a divider of another list, passing over does
    /// nothing until it is let go. See `LiveReorder`.
    ///
    /// With a `zone`, the end of the row the pointer is over decides:
    /// `GroupDrag.reordered` puts the entry right before or after it, so the
    /// row stays under the pointer. Without one (a row that is not measured),
    /// the entry takes the row's slot.
    private func liveMove(_ dragged: UUID, over target: UUID, in scope: RailScope, zone: GroupDrag.Zone? = nil) {
        let ids = orderedIDs(scope)
        guard ids.contains(dragged) else { return }
        let reordered = zone.map { GroupDrag.reordered(dragged, over: target, zone: $0, in: ids) }
            ?? LiveReorder.moving(dragged, over: target, in: ids)
        guard let moved = reordered else { return }
        // Explicit, so the rows slide whatever the list's own reorder key
        // makes of the change.
        withAnimation(reorderAnimation) { _ = appState.reorderRail(moved, in: scope) }
    }

    /// Moves an entry one place along its list, past a divider as readily as
    /// past a row. Backs the VoiceOver actions and Option-arrow. In a space,
    /// `GroupRules.stepping` decides: a member moves only within its box, and
    /// a row or divider outside one steps over a whole box, so neither ever
    /// lands inside a run.
    private func step(_ id: UUID, forward: Bool, in scope: RailScope) {
        let ids = orderedIDs(scope)
        let moved: [UUID]
        if case .space(let spaceID) = scope {
            moved = GroupRules.stepping(id, forward: forward, in: groupEntries(in: spaceID))
        } else {
            guard let index = ids.firstIndex(of: id) else { return }
            let destination = forward ? index + 1 : index - 1
            guard ids.indices.contains(destination) else { return }
            moved = LiveReorder.moving(id, over: ids[destination], in: ids) ?? ids
        }
        guard moved != ids else { return }
        withAnimation(reorderAnimation) { _ = appState.reorderRail(moved, in: scope) }
    }

    /// Moves a whole box one place along its space, past a row, a divider or
    /// another box.
    private func stepGroup(_ groupID: UUID, forward: Bool, in spaceID: UUID) {
        let entries = groupEntries(in: spaceID)
        let moved = GroupRules.steppingGroup(groupID, forward: forward, in: entries)
        guard moved != entries.map(\.id) else { return }
        withAnimation(reorderAnimation) { _ = appState.reorderGroup(groupID, order: moved, inSpace: spaceID) }
    }

    private func stepLink(_ link: SpaceServiceLink, forward: Bool) {
        guard let spaceID = link.liveSpace?.id else { return }
        step(link.id, forward: forward, in: .space(spaceID))
    }

    /// Over a space's heading: a service of that same space goes to its top,
    /// live. One from another space waits for the drop (`dropLinkAtTop`).
    private func liveMoveLinkToTop(_ dragged: UUID, of space: Space) {
        guard let first = orderedIDs(.space(space.id)).first else { return }
        liveMove(dragged, over: first, in: .space(space.id))
    }

    /// Released in a space: a global service moves into it, before `beforeID`
    /// or at the end, once confirmed, and stops being global. One that was
    /// showing goes along with the view. Refused while another move waits for
    /// its answer, or when the service is no longer global.
    private func dropGlobal(_ serviceID: UUID, into spaceID: UUID, before beforeID: UUID?) -> Bool {
        guard appState.pendingRailMove == nil, globalServices.contains(where: { $0.id == serviceID }) else { return false }
        appState.pendingRailMove = .globalIntoSpace(serviceID: serviceID, spaceID: spaceID, before: beforeID)
        return true
    }

    /// Released in the global group: a space's service becomes global, before
    /// `beforeID` or at the end of the group, once confirmed. Its other
    /// memberships go too.
    private func dropLinkIntoGlobal(_ linkID: UUID, before beforeID: UUID?) -> Bool {
        guard appState.pendingRailMove == nil,
              allLinks.contains(where: { $0.id == linkID && $0.liveService != nil })
        else { return false }
        appState.pendingRailMove = .intoGlobal(linkID: linkID, before: beforeID)
        return true
    }

    /// Adds a divider at the end of a list, from a + button's menu.
    private func addDividerAtEnd(of scope: RailScope?) {
        guard let scope else { return }
        withAnimation(reorderAnimation) { _ = appState.addDivider(in: scope, after: nil) }
    }

    /// Takes a divider away, closing the gap it leaves.
    private func removeDivider(_ dividerID: UUID) {
        withAnimation(reorderAnimation) {
            _ = appState.removeDivider(dividerID)
        }
    }

    /// Released over a row: a service from another space moves into this one
    /// at that row, once confirmed (see `RailMove`). Within its own space the
    /// live move has already put it there.
    private func dropLink(_ dragged: UUID, over target: SpaceServiceLink, in space: Space) -> Bool {
        requestMoveIntoSpace(dragged, spaceID: space.id, before: target.id)
    }

    /// Released over a divider in another space: as over a row, at the divider.
    private func dropLinkOverDivider(_ dragged: UUID, dividerID: UUID, spaceID: UUID) -> Bool {
        requestMoveIntoSpace(dragged, spaceID: spaceID, before: dividerID)
    }

    /// Released over a space's heading or its empty slot: a service from
    /// another space goes to the top of this one, once confirmed.
    private func dropLinkAtTop(_ dragged: UUID, of space: Space) -> Bool {
        requestMoveIntoSpace(dragged, spaceID: space.id, before: orderedIDs(.space(space.id)).first)
    }

    /// Asks to move a membership into another space. A drop in its own space
    /// is taken and needs nothing more; one into a space that already holds
    /// the service is refused, as two links to one service there are invalid.
    private func requestMoveIntoSpace(_ dragged: UUID, spaceID: UUID, before beforeID: UUID?) -> Bool {
        guard let ends = allLinks.first(where: { $0.id == dragged })?.liveEnds else { return false }
        guard ends.space.id != spaceID else { return true }
        // One question at a time: a second drop while one waits is refused.
        guard appState.pendingRailMove == nil else { return false }
        guard !links(in: spaceID).contains(where: { $0.liveService?.id == ends.service.id }) else { return false }
        // Drop the keyboard focus before the cell is recreated in the new
        // group. Holding it on the same link id is what left a ring on the
        // moved icon after another service was selected.
        focusedAllServicesLinkID = nil
        appState.pendingRailMove = .intoSpace(linkID: dragged, spaceID: spaceID, before: beforeID)
        return true
    }
}

// MARK: - Groups

extension UnifiedRailView {
    /// A space's list for `GroupRules`, as drawn: each row with the group it
    /// is drawn in, and the dividers.
    private func groupEntries(in spaceID: UUID) -> [GroupEntry] {
        let lookup = RailGroupLookup(groups: allGroups, spaceID: spaceID)
        return items(in: spaceID).compactMap { item in
            switch item {
            case .member(let link, _):
                return GroupEntry(id: link.id, groupID: lookup.group(of: link.groupID), isDivider: false)
            case .divider(let divider):
                return GroupEntry(id: divider.id, groupID: nil, isDivider: true)
            case .global, .space:
                return nil
            }
        }
    }

    /// The group a row is drawn in, with its name.
    private func drawnGroup(of link: SpaceServiceLink, in spaceID: UUID) -> GroupNameRequest? {
        let lookup = RailGroupLookup(groups: allGroups, spaceID: spaceID)
        guard let groupID = lookup.group(of: link.groupID) else { return nil }
        return GroupNameRequest(id: groupID, name: lookup.name(of: groupID))
    }

    /// The rows next to this one that "Group with" can offer: above and below,
    /// not dividers, not already in its group.
    private func groupCandidates(for link: SpaceServiceLink, in spaceID: UUID) -> [GroupCandidate] {
        let spaceLinks = links(in: spaceID)
        return GroupRules.groupWithCandidates(for: link.id, in: groupEntries(in: spaceID)).compactMap { id in
            spaceLinks.first { $0.id == id }?.liveService.map { GroupCandidate(id: id, label: $0.label) }
        }
    }

    /// Joins the target's group, or makes a new one with it. The row stays on
    /// its side of the target.
    private func groupWith(_ linkID: UUID, onto targetID: UUID) {
        withAnimation(reorderAnimation) { _ = appState.groupLink(linkID, onto: targetID) }
    }

    private func removeFromGroup(_ linkID: UUID) {
        withAnimation(reorderAnimation) { _ = appState.removeFromGroup(linkID) }
    }

    /// Group with, Remove from Group and Name Group in a space service's menu.
    @ViewBuilder
    private func groupMenuItems(for link: SpaceServiceLink) -> some View {
        if let spaceID = link.liveSpace?.id {
            let candidates = groupCandidates(for: link, in: spaceID)
            let group = drawnGroup(of: link, in: spaceID)
            if !candidates.isEmpty || group != nil {
                Divider()
            }
            if !candidates.isEmpty {
                Menu("Group with") {
                    ForEach(candidates) { candidate in
                        Button(candidate.label) { groupWith(link.id, onto: candidate.id) }
                    }
                }
            }
            if let group {
                Button("Remove from Group") { removeFromGroup(link.id) }
                Button("Name Group…") { namingGroup = group }
            }
        }
    }

    /// The same three as VoiceOver actions on the row.
    private func groupRowActions(for link: SpaceServiceLink) -> GroupRowActions {
        let spaceID = link.liveSpace?.id
        let group = spaceID.flatMap { drawnGroup(of: link, in: $0) }
        return GroupRowActions(
            candidates: spaceID.map { groupCandidates(for: link, in: $0) } ?? [],
            inGroup: group != nil,
            groupWith: { groupWith(link.id, onto: $0) },
            remove: { removeFromGroup(link.id) },
            rename: { namingGroup = group }
        )
    }

    /// The box's menu and VoiceOver actions. Move Group goes through the same
    /// question as dragging the box to a space.
    private func groupBoxMenu(_ groupID: UUID, name: String?, in spaceID: UUID) -> GroupBoxMenu {
        GroupBoxMenu(
            targets: {
                RailEdits.eligibleSpaces(forGroup: groupID, context: modelContext).compactMap { id in
                    spaces.first { $0.id == id && $0.modelContext != nil }
                }
            },
            moveTo: { target in
                guard appState.pendingRailMove == nil else { return }
                focusedAllServicesLinkID = nil
                appState.pendingRailMove = .groupIntoSpace(groupID: groupID, spaceID: target, before: nil)
            },
            rename: { namingGroup = GroupNameRequest(id: groupID, name: name) },
            ungroup: { withAnimation(reorderAnimation) { _ = appState.ungroup(groupID) } },
            step: { stepGroup(groupID, forward: $0, in: spaceID) }
        )
    }

    // MARK: Dragging a whole group

    /// A group's box as a drag source, by its name and its padding: the rows
    /// inside have smaller sources of their own, which win a press on them
    /// (see `RailDragSession`). Only its own space reorders live under it.
    private func groupDragSource(_ groupID: UUID, in spaceID: UUID, members: [RailItem]) -> some View {
        let services = members.compactMap(\.service)
        return RowDragSource(
            id: groupID,
            type: LiveReorder.groupType,
            ending: serviceDragEnding,
            onDragStart: {
                drag.reset()
                drag.groupID = groupID
                drag.startSnapshot = appState.railSnapshot([.space(spaceID)])
            },
            preview: { GroupDragPreview(services: services) }
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// What a row or divider of a space takes from a group's box: in its own
    /// space the run moves past it live; in another space (the all-services
    /// list) a release there asks to move the group before it. A space that
    /// already holds one of its services refuses it.
    private func groupLane(over targetID: UUID, in spaceID: UUID) -> LiveReorderDropDelegate.Lane {
        .init(
            type: LiveReorder.groupType,
            draggingID: { drag.groupID },
            move: { liveMoveGroup($0, over: targetID, in: spaceID, zone: $1) },
            drop: { requestGroupMove($0, into: spaceID, before: targetID) },
            accepts: { appState.groupDrop($0, into: spaceID) != .refuse }
        )
    }

    /// Moves the run past the unit under the pointer and saves at once. See
    /// `GroupDrag.reorderedGroup`.
    private func liveMoveGroup(_ groupID: UUID, over target: UUID, in spaceID: UUID, zone: GroupDrag.Zone?) {
        guard let moved = GroupDrag.reorderedGroup(groupID, over: target, zone: zone, in: groupEntries(in: spaceID)) else { return }
        withAnimation(reorderAnimation) { _ = appState.reorderGroup(groupID, order: moved, inSpace: spaceID) }
    }

    /// Over its own space's heading: the run goes to the top, live.
    private func liveMoveGroupToTop(_ groupID: UUID, of spaceID: UUID) {
        guard let first = groupEntries(in: spaceID).first?.id else { return }
        liveMoveGroup(groupID, over: first, in: spaceID, zone: .before)
    }

    /// See `AppState.requestGroupMove`. The keyboard focus lets go first, as
    /// for a service moving between spaces.
    private func requestGroupMove(_ groupID: UUID, into spaceID: UUID, before beforeID: UUID?) -> Bool {
        if appState.groupDrop(groupID, into: spaceID) == .ask { focusedAllServicesLinkID = nil }
        return appState.requestGroupMove(groupID, into: spaceID, before: beforeID)
    }
}
