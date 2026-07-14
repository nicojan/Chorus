import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os

enum ServiceReorderPlacement {
    case before
    case after
}

/// Sets whether the user can move the window by dragging its background.
///
/// With `.windowStyle(.hiddenTitleBar)` the top ~32px stays a title-bar drag
/// band. In the top-bar and hybrid layouts the rails sit in that band, so a
/// click-drag on a tab was grabbed by the window move before SwiftUI's
/// `.draggable` reorder could start — the window slid instead of the tab
/// reordering. A view nested in a SwiftUI `ScrollView` can't opt out of that
/// drag (the scroll view short-circuits AppKit hit-testing, so a
/// `mouseDownCanMoveWindow == false` nested view is never consulted).
///
/// So we turn the OS window drag off for those layouts and hand dragging to
/// explicit `WindowDragHandle`s instead (Chrome's model). The sidebar layout,
/// whose rails don't hold draggable tabs in the band, keeps the normal drag.
struct WindowMovableConfigurator: NSViewRepresentable {
    let isMovable: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        applyWhenAttached(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyWhenAttached(to: nsView)
    }

    private func applyWhenAttached(to view: NSView) {
        let isMovable = isMovable
        DispatchQueue.main.async {
            view.window?.isMovable = isMovable
        }
    }
}

/// A transparent strip that moves the window on click-drag, the way Chrome lets
/// you drag the empty part of its tab strip. Used to fill the reserved gap in
/// the top-bar rails, where the OS window drag is off (see
/// `WindowMovableConfigurator`). A double-click zooms, matching a title bar.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                window.performZoom(nil)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

enum SpaceMove {
    /// The spaces a service can be moved into: every space except the ones it
    /// already belongs to. Moving into a space it's already in would just
    /// double-link it, and the current space is one of those memberships, so
    /// this naturally leaves it out too. Order follows `allSpaceIDs` (the
    /// sorted space rail).
    static func eligibleSpaceIDs(allSpaceIDs: [UUID], memberSpaceIDs: Set<UUID>) -> [UUID] {
        allSpaceIDs.filter { !memberSpaceIDs.contains($0) }
    }
}

enum ServiceReorder {
    static func reorderedIDs(
        _ ids: [UUID],
        moving droppedID: UUID,
        relativeTo targetID: UUID,
        placement: ServiceReorderPlacement
    ) -> [UUID]? {
        guard droppedID != targetID,
              let fromIndex = ids.firstIndex(of: droppedID),
              let targetIndex = ids.firstIndex(of: targetID) else {
            return nil
        }

        var reordered = ids
        let moved = reordered.remove(at: fromIndex)

        var toIndex = targetIndex
        if placement == .after {
            toIndex += 1
        }
        if fromIndex < toIndex {
            toIndex -= 1
        }
        guard fromIndex != toIndex else {
            return nil
        }

        reordered.insert(moved, at: toIndex)
        return reordered
    }
}

struct ServiceSidebarView: View {
    let spaceID: UUID
    @Binding var selectedServiceID: UUID?
    @Query private var allLinks: [SpaceServiceLink]
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    var axis: Axis = .vertical
    /// Inset applied to the content (top for the vertical rail, leading for the
    /// horizontal tab bar) to clear the window traffic lights, kept inside so the
    /// background and dividers still run full-length.
    var contentInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showingAddService = false
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
    // cell's real size. The horizontal fallback matches an icon-only tab (~34pt
    // wide) rather than a full-width tab — a wrong (too large) value would make
    // every horizontal drop resolve `.before` and leave the last slot unreachable.
    private static let serviceDropMidpoint: CGFloat = 23
    private static let serviceDropMidpointHorizontal: CGFloat = 17
    /// Measured size of each drop cell, so the before/after split uses the target's
    /// true midpoint instead of a hardcoded guess.
    @State private var cellSizes: [UUID: CGSize] = [:]

    private var filteredLinks: [SpaceServiceLink] {
        allLinks
            // Guard all three relationships before reading `$0.space.id`: a link
            // whose Space (or service) was deleted would fault the freed model
            // and trap on this hot render path. Matches `AppState.servicesForSpace`.
            .filter { $0.modelContext != nil && $0.service.modelContext != nil && $0.space.modelContext != nil && $0.space.id == spaceID }
            .sorted { $0.sortOrder < $1.sortOrder }
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

    @ViewBuilder
    private var content: some View {
        if axis == .vertical {
            verticalBody
        } else {
            horizontalBody
        }
    }

    private var verticalBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredLinks) { link in
                        serviceRow(for: link)
                    }
                }
                .padding(.top, 8 + contentInset)
                .padding(.bottom, 8)
            }

            Divider()

            addServiceButton
        }
        .frame(width: 52)
        .background(.background)
    }

    private var horizontalBody: some View {
        HStack(spacing: 8) {
            tabStrip

            // Empty stretch between the tabs and the nav buttons. It draws
            // nothing and takes no hit of its own, so a click here falls through
            // to the window-drag handle behind the row.
            Spacer(minLength: 40)

            // Nav buttons live at the far right of the tab bar (top-right corner
            // of the window), acting on the active service.
            WebNavButtons(webViewState: appState.webViewState, homeURL: activeHomeURL)
                .padding(.trailing, 10)
        }
        .frame(height: ServiceTabView.height + 4)
        // The OS window drag is off in the top-bar and hybrid layouts, so tab
        // drags reorder instead of moving the window (see
        // WindowMovableConfigurator). A full-width drag handle behind the row
        // restores "click any empty part of the bar to move the window": the
        // tabs and nav buttons sit in front and take their own clicks, and every
        // empty area falls through to here. This replaces a measure-and-cap on
        // the tab scroll view that could leave it greedily filling half the row
        // — so only the far side dragged.
        .background(WindowDragHandle())
        .background(Color(nsColor: .windowBackgroundColor))
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
    private var tabRow: some View {
        HStack(spacing: 4) {
            ForEach(filteredLinks) { link in
                serviceRow(for: link)
                    .id(link.service.id)
            }
            addServiceButton
        }
        .padding(.leading, 8 + contentInset)
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

    @ViewBuilder
    private func serviceRow(for link: SpaceServiceLink) -> some View {
        let isSel = selectedServiceID == link.service.id
        let badge = appState.badgeManager.badgeCount(for: link.service.id)
        let hibernated = !isSel && appState.webViewPool.isHibernated(link.service.id)
        let muted = link.service.isEffectivelyMuted
        let media = appState.webViewPool.mediaCaptureStates[link.service.id]

        cell(for: link, isSelected: isSel, badge: badge, hibernated: hibernated, muted: muted, media: media)
            .draggable(link.id.uuidString) {
                // Custom drag preview. Source-dimming is left to SwiftUI (as in
                // SpaceStripView): manually tracking a "dragging" id can't be
                // cleared reliably — a drop on itself or a cancelled drag never
                // fires the drop handler — which left the row stuck at 0.4 opacity.
                Text(link.service.label)
                    .font(.caption)
                    .padding(6)
                    .background(.ultraThickMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                handleServiceKey(press, for: link)
            }
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

    @ViewBuilder
    private func cell(
        for link: SpaceServiceLink,
        isSelected: Bool,
        badge: Int,
        hibernated: Bool,
        muted: Bool,
        media: WebViewPool.MediaCaptureState?
    ) -> some View {
        if axis == .vertical {
            Button {
                selectService(link)
            } label: {
                ServiceIconView(
                    instance: link.service,
                    isSelected: isSelected,
                    badgeCount: badge,
                    isHibernated: hibernated,
                    isMuted: muted,
                    cameraActive: media?.cameraActive ?? false,
                    micActive: media?.micActive ?? false,
                    micMuted: media?.micMuted ?? false
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else {
            ServiceTabView(
                instance: link.service,
                isSelected: isSelected,
                badgeCount: badge,
                isHibernated: hibernated,
                isMuted: muted,
                iconOnly: true,
                cameraActive: media?.cameraActive ?? false,
                micActive: media?.micActive ?? false,
                micMuted: media?.micMuted ?? false
            ) {
                selectService(link)
            }
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

    private var addServiceButton: some View {
        Button {
            showingAddService = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(
                    width: axis == .vertical ? 44 : 36,
                    height: axis == .vertical ? 32 : ServiceTabView.height
                )
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add service")
        .accessibilityLabel("Add service")
    }

    var body: some View {
        content
        .sheet(isPresented: $showingAddService) {
            AddServiceSheet(spaceID: spaceID)
        }
        .sheet(item: $editingService) { service in
            EditServiceSheet(service: service)
        }
        .sheet(item: $movingToNewSpace) { link in
            SpaceEditorSheet(
                editingSpace: nil,
                selectedSpaceID: Binding(
                    get: { appState.selectedSpaceID },
                    set: { appState.selectedSpaceID = $0 }
                ),
                onCreate: { newSpace in
                    moveService(link: link, to: newSpace, followToSpace: true)
                }
            )
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
    }

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
            NSWorkspace.shared.open(target)
        }
    }

    /// Re-applies BadgeManager state for a service after its mute/showBadge
    /// changed, so the sidebar and dock totals update immediately instead of
    /// waiting for the next poll tick.
    private func syncBadge(for service: ServiceInstance) {
        appState.refreshBadgeState(for: service.id)
    }

    /// Spaces the service can be moved into: every space except the ones it's
    /// already in. Membership is read from the reliable `allLinks` query, not the
    /// service's inverse `spaceLinks` relationship, which can be stale (see the
    /// badge-count note in SpaceStripView).
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
            .filter { $0.modelContext != nil && $0.space.id == targetSpace.id }
            .map(\.sortOrder)
        link.sortOrder = (targetOrders.max() ?? -1) + 1
        link.space = targetSpace
        save("move service to space")

        if followToSpace {
            appState.selectedSpaceID = targetSpace.id
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
            let data = try Data(contentsOf: url)
            service.customIconData = data
            save("set custom icon")
        } catch {
            AppLogger.ui.error("Failed to read icon file: \(error.localizedDescription)")
        }
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
