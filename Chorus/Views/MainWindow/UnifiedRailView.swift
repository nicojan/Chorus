import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os

/// One rail, in either axis, holding the current space as its header and that
/// space's services under it.
///
/// This is build step 5 of concept C, and it replaces two views rather than
/// bending either into shape: `ServiceSidebarView` drew the services in two
/// axes and `SpaceStripView` drew a second rail of spaces beside it. Dropping
/// the second rail is what the concept buys — 161 points of chrome back in the
/// vertical layout, a whole 34 point bar in the horizontal one — and it is why
/// `hybrid` and `topBars` collapsed into a single layout: with one rail there
/// are only two arrangements left, on the left or along the top.
///
/// Everything the audit rated severity 0 came across untouched: the reorder
/// maths (`ServiceReorder`), drag and drop, the arrow keys, the VoiceOver move
/// actions, and the donation button's reserved corner. The space half of that
/// plumbing now lives in `SpacePaletteView`, which the header opens.
struct UnifiedRailView: View {
    @Binding var selectedSpaceID: UUID?
    @Binding var selectedServiceID: UUID?
    var axis: Axis = .vertical
    /// Inset applied to the content (top for the vertical rail, leading for the
    /// horizontal bar) to clear the window traffic lights, kept inside so the
    /// background and dividers still run full-length.
    var contentInset: CGFloat = 0

    @Query private var allLinks: [SpaceServiceLink]
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Read only to size the gap the donation button needs at the far right of
    /// the horizontal bar; `ContentView` owns the button itself.
    @AppStorage(SupportButtonVisibility.defaultsKey) private var showSupportButton = true

    /// Where the other spaces are drawn. This rail carries them itself in
    /// `.inRail`, hands them to `SpaceRailView` in `.ownRail`, and keeps them
    /// behind the header's popover in `.switcher`.
    @Environment(\.chorusTheme) private var theme
    @AppStorage(SpacesPresentation.defaultsKey) private var spacesPresentationRaw = SpacesPresentation.inRail.rawValue
    private var presentation: SpacesPresentation { SpacesPresentation.resolving(spacesPresentationRaw) }

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
    // Fallback drop midpoints, used only until the first geometry pass records a
    // cell's real size. Both are half of what `ServiceRowView` draws: a 34 point
    // row in the vertical rail, and a labelled tab of roughly 120 points in the
    // horizontal bar. A wrong (too large) value would make every drop on that
    // axis resolve `.before` and leave the last slot unreachable.
    private static let serviceDropMidpoint: CGFloat = ServiceRowView.rowHeight / 2
    private static let serviceDropMidpointHorizontal: CGFloat = ServiceRowView.tabTypicalWidth / 2
    /// Measured size of each drop cell, so the before/after split uses the target's
    /// true midpoint instead of a hardcoded guess.
    @State private var cellSizes: [UUID: CGSize] = [:]

    /// The horizontal bar: a 32 point header and 32 point tabs with 5 points
    /// clear above and below. The drawn frame says 42.
    static let barHeight: CGFloat = 42

    private var filteredLinks: [SpaceServiceLink] {
        guard let spaceID = selectedSpaceID else { return [] }
        return allLinks
            // Guard all three relationships before reading `$0.space.id`: a link
            // whose Space (or service) was deleted would fault the freed model
            // and trap on this hot render path. Matches `AppState.servicesForSpace`.
            .filter { $0.modelContext != nil && $0.service.modelContext != nil && $0.space.modelContext != nil && $0.space.id == spaceID }
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
            }
        }
        .sheet(item: $editingService) { service in
            EditServiceSheet(service: service)
        }
        .sheet(item: $movingToNewSpace) { link in
            SpaceEditorSheet(
                editingSpace: nil,
                selectedSpaceID: $selectedSpaceID,
                onCreate: { newSpace in
                    moveService(link: link, to: newSpace, followToSpace: true)
                }
            )
        }
        .sheet(isPresented: $showingAddSpace) {
            SpaceEditorSheet(editingSpace: nil, selectedSpaceID: $selectedSpaceID)
        }
        .sheet(item: $editingSpace) { space in
            SpaceEditorSheet(editingSpace: space, selectedSpaceID: $selectedSpaceID)
        }
        .confirmationDialog(
            "Delete \(confirmingDelete?.service.label ?? "service")?",
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
        if axis == .vertical {
            verticalBody
        } else {
            horizontalBody
        }
    }

    /// 240 points wide, against the 52 + 52 and two dividers the two rails used
    /// to take. The header sits at y 38 — 28 points of traffic light, then 10 —
    /// which is where the frame draws it.
    private var verticalBody: some View {
        VStack(spacing: 0) {
            if theme.statesHealthInWords {
                // Editorial leads with the masthead in every presentation. It
                // is the direction's signature element, and the frame that
                // defines the direction draws nothing else at the top of the
                // rail. `spaceHeader` stays non-interactive unless the spaces
                // are actually behind it, so it does not offer a click that
                // would do nothing.
                //
                // The kicker lands at y 52: 28 points of window chrome, then
                // this. 28 points of air under the meta line before the first
                // row, both straight off the frame.
                spaceHeader
                    .padding(.horizontal, theme.railPadding)
                    .padding(.top, 24 + contentInset)
                    .padding(.bottom, 28)

                if presentation == .inRail {
                    spacesSection
                        .padding(.bottom, 6)
                    Divider()
                        .padding(.bottom, 6)
                }
            } else if presentation == .inRail {
                spacesSection
                    // 4 points more than the header takes in the other modes:
                    // a caption is shorter than a row and would otherwise sit
                    // level with the bottom of the traffic lights.
                    .padding(.top, 14 + contentInset)
                    .padding(.bottom, 6)
                Divider()
                    .padding(.bottom, 6)
            } else if presentation == .ownRail {
                // Beside a spaces rail, the space is a caption over its
                // services rather than a header — the same caption, at the same
                // height, so the two columns' first rows sit on one line.
                servicesCaption
                    .padding(.top, 14 + contentInset)
                    .padding(.bottom, 4)
            } else {
                spaceHeader
                    .padding(.top, 10 + contentInset)
                    .padding(.bottom, 6)
            }

            ScrollView {
                // 2 points between 34 point rows is the drawn 36 point pitch.
                // Editorial's rows abut instead: each draws its own hairline
                // along the bottom, and a gap between them would break the rule
                // into a dashed line.
                LazyVStack(spacing: theme.railRules ? 0 : 2) {
                    ForEach(filteredLinks) { link in
                        serviceRow(for: link)
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()

            addServiceButton
                .padding(.vertical, 6)
        }
        .frame(width: theme.railWidth)
        .background(theme.rail.color)
        // Editorial's rail is #FAFAF8 against a white window, a difference of
        // about two per cent. The trailing hairline is what actually separates
        // them; without it the rail and the page run together.
        .overlay(alignment: .trailing) {
            if theme.railRules {
                Rectangle()
                    .fill(theme.separator.color)
                    .frame(width: 1)
            }
        }
    }

    private var horizontalBody: some View {
        HStack(spacing: 8) {
            switch presentation {
            case .inRail:
                spaceChipStrip
                    // 72 points of traffic light, then 8, puts the first chip
                    // at x 80 — where the header sits in the other modes.
                    .padding(.leading, 8 + contentInset)
                Divider().frame(width: 1, height: 20)
            case .switcher:
                spaceHeader
                    .padding(.leading, 8 + contentInset)
                Divider().frame(width: 1, height: 20)
            case .ownRail:
                // The bar above this one is nothing but spaces, and it marks the
                // current one. Repeating it here would be the same word twice,
                // 30 points apart.
                Spacer().frame(width: 8 + contentInset)
            }

            tabStrip

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
                // the Home button appears and widens this group. Settings can hide
                // the button, and then the reserve would only be a hole, so it
                // falls back to the plain trailing gap. With a spaces bar above
                // this one, the button is up there instead and the reserve here
                // would only be a hole.
                .padding(.trailing, showSupportButton && presentation != .ownRail ? SupportButtonVisibility.reservedWidth : 10)
        }
        .frame(height: Self.barHeight)
        // The OS window drag is off in the bar layout, so tab drags reorder
        // instead of moving the window (see WindowMovableConfigurator). A
        // full-width drag handle behind the row restores "click any empty part
        // of the bar to move the window": the header, tabs and nav buttons sit
        // in front and take their own clicks, and every empty area falls through
        // to here.
        .background(WindowDragHandle())
        .background(Color(nsColor: .windowBackgroundColor))
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
            isMuted: muted,
            isPaletteOpen: showingPalette,
            // With a rail of their own, the spaces are already on screen and the
            // header has nothing to open.
            isInteractive: presentation == .switcher,
            serviceCount: serviceIDs.count
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

    // MARK: - The spaces, when the rail carries them itself

    /// Every space, listed above the services, with its own unread count. This
    /// is what `.inRail` buys back: the old rail's one real advantage was that
    /// a count in a space you were not looking at still reached your eye, and
    /// the popover cannot do that.
    ///
    /// Capped at four rows and a bit, the same as the palette, so a fifth space
    /// reads as "there is more here" and the services keep the rest of the rail.
    private var spacesSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Text("Spaces")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    showingAddSpace = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New space")
                .accessibilityLabel("New space")
            }
            .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    spaceRows
                }
            }
            // A height, not a cap. A `maxHeight` here would let the scroll view
            // take every point the rail offered it and leave two spaces sitting
            // above 130 points of nothing.
            .frame(height: spacesSectionHeight)
        }
        .frame(width: theme.railWidth - theme.railPadding * 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
    }

    /// Whose services these are, said once, quietly, at caption height — the
    /// `.ownRail` counterpart to the "Spaces" caption in the rail beside it.
    private var servicesCaption: some View {
        HStack(spacing: 6) {
            Text(currentSpace?.emoji ?? "🏠")
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(currentSpace?.name ?? "No space")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: theme.railWidth - theme.railPadding * 2)
        .accessibilityElement(children: .combine)
    }

    /// What the spaces list takes: exactly its rows, until there are more than
    /// four and a bit, and then that. Past the cap it scrolls and the rest of
    /// the rail stays the services'.
    private var spacesSectionHeight: CGFloat {
        let pitch = SpaceRowStyle.rail.height + 2
        let rows = max(1, spaces.filter { $0.modelContext != nil }.count)
        return min(CGFloat(rows) * pitch, 4.5 * pitch)
    }

    /// The shared rows, wired to this rail's sheets. Held here rather than
    /// inlined twice because `SpaceRailView` needs the same wiring.
    private var spaceRows: some View {
        SpaceListRows(
            selectedSpaceID: $selectedSpaceID,
            style: .rail,
            highlightedIndex: nil,
            onEditSpace: { editingSpace = $0 },
            onDeleteSpace: { confirmingDeleteSpace = $0 }
        )
    }

    /// The horizontal answer to `spacesSection`: the spaces as chips at the head
    /// of the bar. It scrolls rather than shrinking the tabs — the services are
    /// what the bar is mostly for — and takes at most a third of the window so a
    /// user with eight spaces still has a bar left.
    private var spaceChipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                spaceChips
                Button {
                    showingAddSpace = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: SpaceChipCell.chipHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New space")
                .accessibilityLabel("New space")
            }
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
    }

    private var spaceChips: some View {
        ForEach(spaces.filter { $0.modelContext != nil }) { space in
            let muted = space.isMutedEffective
            let serviceIDs = appState.servicesForSpace(space.id).map(\.id)
            SpaceChipCell(
                space: space,
                badgeCount: muted ? 0 : appState.badgeManager.aggregateCount(for: serviceIDs),
                isMuted: muted,
                isCurrent: space.id == selectedSpaceID
            ) {
                selectedSpaceID = space.id
            }
            .contextMenu {
                SpaceContextMenu(
                    space: space,
                    canDelete: spaces.count > 1,
                    onEdit: { editingSpace = space },
                    onDelete: { confirmingDeleteSpace = space }
                )
            }
        }
    }

    /// The tab strip hugs its content when the tabs fit — leaving the rest of the
    /// bar as draggable empty space — and scrolls only when there are too many to
    /// fit. `ViewThatFits` picks the plain (hugging) row first and falls back to
    /// the scrolling row, which is deterministic where measuring the content
    /// width and capping the scroll view was not.
    private var tabStrip: some View {
        ViewThatFits(in: .horizontal) {
            tabRow
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    tabRow
                }
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
    }

    /// The row of service tabs plus the add button. A plain `HStack` (not lazy)
    /// so `ViewThatFits` can measure its width to decide whether the tabs fit.
    /// The traffic-light inset is spent by the header now, so this starts flush.
    private var tabRow: some View {
        HStack(spacing: 4) {
            ForEach(filteredLinks) { link in
                serviceRow(for: link)
                    .id(link.service.id)
            }
            addServiceButton
        }
        .padding(.trailing, 8)
        .padding(.vertical, 2)
    }

    /// Home URL of the currently selected service, for the nav home button.
    private var activeHomeURL: URL? {
        guard let id = selectedServiceID,
              let service = filteredLinks.first(where: { $0.service.id == id })?.service
        else { return nil }
        return URL(string: service.url)
    }

    // MARK: - Service cells

    @ViewBuilder
    private func serviceRow(for link: SpaceServiceLink) -> some View {
        let isSel = selectedServiceID == link.service.id
        let badge = appState.badgeManager.badgeCount(for: link.service.id)
        let hibernated = !isSel && appState.webViewPool.isHibernated(link.service.id)
        let muted = link.service.isEffectivelyMuted
        let media = appState.webViewPool.mediaCaptureStates[link.service.id]
        // A hibernated service has no page to be healthy or broken, and the moon
        // already says why it is not loaded — so it reports live and draws no dot.
        let health = hibernated ? ServiceHealth.live : appState.webViewPool.health(for: link.service.id)

        cell(for: link, isSelected: isSel, badge: badge, hibernated: hibernated, muted: muted, media: media, health: health, focused: focusedServiceID == link.service.id)
            .draggable(link.id.uuidString) {
                // Custom drag preview. Source-dimming is left to SwiftUI:
                // manually tracking a "dragging" id can't be cleared reliably —
                // a drop on itself or a cancelled drag never fires the drop
                // handler — which left the row stuck at 0.4 opacity.
                Text(link.service.label)
                    .font(.caption)
                    .padding(6)
                    .background(.ultraThickMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: ChorusRadius.control))
            }
            .dropDestination(for: String.self) { items, location in
                guard let droppedIDString = items.first,
                      let droppedID = UUID(uuidString: droppedIDString),
                      droppedID != link.id
                else { return false }
                let placement: ServiceReorderPlacement = {
                    let size = cellSizes[link.id]
                    if axis == .vertical {
                        let mid = (size?.height).map { $0 / 2 } ?? Self.serviceDropMidpoint
                        return location.y < mid ? .before : .after
                    }
                    let mid = (size?.width).map { $0 / 2 } ?? Self.serviceDropMidpointHorizontal
                    return location.x < mid ? .before : .after
                }()
                return reorderService(
                    droppedLinkID: droppedID,
                    relativeTo: link,
                    placement: placement
                )
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size, initial: true) {
                        cellSizes[link.id] = proxy.size
                    }
                }
            )
            .accessibilityAction(named: "Move up") { moveServiceUp(link) }
            .accessibilityAction(named: "Move down") { moveServiceDown(link) }
            .contextMenu { serviceContextMenu(for: link) }
            .focusable()
            .focused($focusedServiceID, equals: link.service.id)
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
        isSelected: Bool,
        badge: Int,
        hibernated: Bool,
        muted: Bool,
        media: WebViewPool.MediaCaptureState?,
        health: ServiceHealth,
        focused: Bool
    ) -> some View {
        ServiceRowView(
            instance: link.service,
            isSelected: isSelected,
            axis: axis,
            badgeCount: badge,
            isHibernated: hibernated,
            isMuted: muted,
            cameraActive: media?.cameraActive ?? false,
            micActive: media?.micActive ?? false,
            micMuted: media?.micMuted ?? false,
            health: health,
            isFocused: focused
        ) {
            selectService(link)
        }
    }

    /// Selects a service and co-locates keyboard focus on its cell, so a click
    /// (or ⌘-digit) leaves the arrow keys with an anchor to move from — a plain
    /// Button click doesn't reliably promote the enclosing `.focusable()` to
    /// focused on its own.
    private func selectService(_ link: SpaceServiceLink) {
        selectedServiceID = link.service.id
        focusedServiceID = link.service.id
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
            focusedServiceID = link.service.id
            return .handled
        }

        let links = filteredLinks
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return .handled }
        let neighborIndex = forward ? index + 1 : index - 1
        guard links.indices.contains(neighborIndex) else { return .handled }
        let neighborID = links[neighborIndex].service.id
        selectedServiceID = neighborID
        focusedServiceID = neighborID
        return .handled
    }

    /// In the wide vertical rail this is a labelled row like the services above
    /// it, with the plus sitting in a 20 point box so its text starts on the same
    /// x as theirs. The horizontal bar has no width to spare, so it stays a plus.
    private var addServiceButton: some View {
        Button {
            showingAddService = true
        } label: {
            Group {
                if axis == .vertical {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 20, height: 20)
                        Text("Add service")
                            .font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: ServiceRowView.rowWidth, height: 30)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 36, height: ServiceRowView.tabHeight)
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add service")
        .accessibilityLabel("Add service")
        // Without a space there is nothing to add a service to, and
        // AddServiceSheet needs one.
        .disabled(selectedSpaceID == nil)
    }

    @ViewBuilder
    private func serviceContextMenu(for link: SpaceServiceLink) -> some View {
        Button("Edit Service…") {
            editingService = link.service
        }

        Toggle("Mute Notifications", isOn: Binding(
            get: { link.service.isMuted },
            set: { newValue in
                link.service.isMuted = newValue
                save("toggle service mute")
                syncBadge(for: link.service)
            }
        ))

        Divider()

        Button("Open in Safari") {
            openInDefaultBrowser(link.service)
        }

        Divider()

        if appState.webViewPool.hasWebView(for: link.service.id) {
            Button("Hibernate") {
                appState.webViewPool.hibernate(link.service.id)
                if selectedServiceID == link.service.id {
                    selectedServiceID = nil
                }
            }
        }

        Divider()
        Button("Change Icon...") {
            pickCustomIcon(for: link.service)
        }
        if link.service.customIconData != nil {
            Button("Reset Icon") {
                resetIcon(for: link.service)
            }
        }
        Divider()
        Menu("Move to Space") {
            let targets = eligibleSpaces(for: link.service)
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
    private func save(_ context: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            AppLogger.dataStore.error("Failed to save (\(context)): \(error.localizedDescription)")
            // Discard the failed mutation so it can't ride along on the next
            // unrelated successful save, and so destructive callers can skip
            // their irreversible teardown when the store didn't actually change.
            modelContext.rollback()
            return false
        }
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
                .filter { $0.modelContext != nil && $0.service.modelContext != nil && $0.space.modelContext != nil && $0.service.id == service.id }
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
        guard link.modelContext != nil, link.space.id != targetSpace.id else { return }
        let serviceID = link.service.id

        // Compute the tail order before repointing, so the link's old order in
        // its current space doesn't count toward the target's max.
        let targetOrders = allLinks
            .filter { $0.modelContext != nil && $0.space.modelContext != nil && $0.space.id == targetSpace.id }
            .map(\.sortOrder)
        link.sortOrder = (targetOrders.max() ?? -1) + 1
        link.space = targetSpace
        save("move service to space")

        if followToSpace {
            selectedSpaceID = targetSpace.id
            selectedServiceID = serviceID
        } else if selectedServiceID == serviceID {
            selectedServiceID = nil
        }
    }

    private func removeFromSpace(link: SpaceServiceLink) {
        let service = link.service
        let serviceID = service.id

        if selectedServiceID == serviceID {
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
        service.customIconData = nil
        save("reset icon")
        if service.fetchedIconData == nil {
            Task {
                let data = await FaviconFetcher.shared.fetchFavicon(for: service.url)
                if let data {
                    service.fetchedIconData = data
                    service.faviconFetchedAt = Date()
                    save("cache fetched icon")
                }
            }
        }
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

    @discardableResult
    private func reorderService(
        droppedLinkID: UUID,
        relativeTo target: SpaceServiceLink,
        placement: ServiceReorderPlacement
    ) -> Bool {
        var links = filteredLinks
        let linksByID = Dictionary(uniqueKeysWithValues: links.map { ($0.id, $0) })
        guard let reorderedIDs = ServiceReorder.reorderedIDs(
            links.map(\.id),
            moving: droppedLinkID,
            relativeTo: target.id,
            placement: placement
        ) else {
            return false
        }
        links = reorderedIDs.compactMap { linksByID[$0] }
        guard links.count == reorderedIDs.count else { return false }

        for (index, link) in links.enumerated() {
            link.sortOrder = index
        }
        save("reorder services")
        return true
    }

    private func deleteService(link: SpaceServiceLink) {
        let service = link.service
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
