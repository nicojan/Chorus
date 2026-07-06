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

/// Reports the width of a horizontal rail's content, so the strip can be capped
/// at its content width (hug the tabs, leave the rest of the row draggable).
struct RailContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Measures its container's width and publishes it via `RailContentWidthKey`.
struct RailContentWidthReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: RailContentWidthKey.self, value: proxy.size.width)
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
    // Content width of the horizontal tab strip; caps the ScrollView so it hugs
    // the tabs (starts unconstrained until measured). See `horizontalBody`.
    @State private var tabStripWidth: CGFloat = .infinity
    private static let serviceDropMidpoint: CGFloat = 23
    private static let serviceDropMidpointHorizontal: CGFloat = 60

    private var filteredLinks: [SpaceServiceLink] {
        allLinks
            .filter { $0.modelContext != nil && $0.service.modelContext != nil && $0.space.id == spaceID }
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
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(filteredLinks) { link in
                            serviceRow(for: link)
                                .id(link.service.id)
                        }
                        addServiceButton
                    }
                    .padding(.leading, 8 + contentInset)
                    .padding(.trailing, 8)
                    .padding(.vertical, 2)
                    .background(RailContentWidthReader())
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
            // Cap the tab strip at its content width so it hugs the tabs when
            // they fit (freeing the rest of the row for the drag gap) and
            // shrinks-and-scrolls only when there are too many to fit.
            .frame(maxWidth: tabStripWidth, alignment: .leading)
            .onPreferenceChange(RailContentWidthKey.self) { tabStripWidth = $0 }

            // A gap that moves the window on drag, filling the strip between the
            // tabs and the nav buttons. The OS window drag is off in this layout
            // so tab drags reorder (see WindowMovableConfigurator); this keeps a
            // place to move the window from, the way Chrome lets you drag the
            // empty part of its tab strip.
            WindowDragHandle()
                .frame(minWidth: 72, maxWidth: .infinity)
                .contentShape(Rectangle())
                .accessibilityHidden(true)

            // Nav buttons live at the far right of the tab bar (top-right corner
            // of the window), acting on the active service.
            WebNavButtons(webViewState: appState.webViewState, homeURL: activeHomeURL)
                .padding(.trailing, 10)
        }
        .frame(height: ServiceTabView.height + 4)
        .background(Color(nsColor: .windowBackgroundColor))
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

        cell(for: link, isSelected: isSel, badge: badge, hibernated: hibernated, muted: muted)
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
                    if axis == .vertical {
                        return location.y < Self.serviceDropMidpoint ? .before : .after
                    }
                    return location.x < Self.serviceDropMidpointHorizontal ? .before : .after
                }()
                return reorderService(
                    droppedLinkID: droppedID,
                    relativeTo: link,
                    placement: placement
                )
            }
            .accessibilityAction(named: "Move up") { moveServiceUp(link) }
            .accessibilityAction(named: "Move down") { moveServiceDown(link) }
            .contextMenu { serviceContextMenu(for: link) }
    }

    @ViewBuilder
    private func cell(
        for link: SpaceServiceLink,
        isSelected: Bool,
        badge: Int,
        hibernated: Bool,
        muted: Bool
    ) -> some View {
        if axis == .vertical {
            Button {
                selectedServiceID = link.service.id
            } label: {
                ServiceIconView(
                    instance: link.service,
                    isSelected: isSelected,
                    badgeCount: badge,
                    isHibernated: hibernated,
                    isMuted: muted
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
                iconOnly: true
            ) {
                selectedServiceID = link.service.id
            }
        }
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

    private func save(_ context: String) {
        do {
            try modelContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save (\(context)): \(error.localizedDescription)")
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

    private func removeFromSpace(link: SpaceServiceLink) {
        let service = link.service
        let serviceID = service.id

        if selectedServiceID == serviceID {
            selectedServiceID = nil
        }

        modelContext.delete(link)

        // Check remaining links *after* the delete so the count is current
        let hasOtherLinks = service.spaceLinks.contains { $0.id != link.id }
        let orphanedIdentifier: UUID? = hasOtherLinks ? nil : service.dataStoreIdentifier
        if !hasOtherLinks {
            appState.webViewPool.removeWebView(for: serviceID)
            modelContext.delete(service)
        }

        save("remove service from space")
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

        appState.webViewPool.removeWebView(for: serviceID)

        // Delete links explicitly first — avoids cascade-delete leaving dangling
        // relationship references in the @Query results during the re-render
        for spaceLink in service.spaceLinks {
            modelContext.delete(spaceLink)
        }
        modelContext.delete(service)

        save("delete service")
        appState.markDataStoreOrphaned(dataStoreIdentifier)
        appState.cleanUpOrphanedDataStores()
    }
}
