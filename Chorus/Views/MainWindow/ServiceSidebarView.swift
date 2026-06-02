import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os

struct ServiceSidebarView: View {
    let spaceID: UUID
    @Binding var selectedServiceID: UUID?
    @Query private var allLinks: [SpaceServiceLink]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @State private var showingAddService = false
    @State private var confirmingDelete: SpaceServiceLink?
    @State private var draggingLinkID: UUID?

    private var filteredLinks: [SpaceServiceLink] {
        allLinks
            .filter { $0.modelContext != nil && $0.service.modelContext != nil && $0.space.id == spaceID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredLinks) { link in
                        Button {
                            selectedServiceID = link.service.id
                        } label: {
                            ServiceIconView(
                                instance: link.service,
                                isSelected: selectedServiceID == link.service.id,
                                badgeCount: appState.badgeManager.badgeCount(for: link.service.id),
                                isHibernated: selectedServiceID != link.service.id
                                    && appState.webViewPool.isHibernated(link.service.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .opacity(draggingLinkID == link.id ? 0.4 : 1.0)
                        .draggable(link.id.uuidString) {
                            Text(link.service.label)
                                .font(.caption)
                                .padding(6)
                                .background(.ultraThickMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .onAppear { draggingLinkID = link.id }
                                .onDisappear { draggingLinkID = nil }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let droppedIDString = items.first,
                                  let droppedID = UUID(uuidString: droppedIDString),
                                  droppedID != link.id
                            else { return false }
                            reorderService(droppedLinkID: droppedID, beforeLink: link)
                            draggingLinkID = nil
                            return true
                        }
                        .accessibilityAction(named: "Move up") { moveServiceUp(link) }
                        .accessibilityAction(named: "Move down") { moveServiceDown(link) }
                        .contextMenu {
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
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            Button {
                showingAddService = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 44, height: 32)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add service")
            .accessibilityLabel("Add service")
        }
        .frame(width: 52)
        .background(.background)
        .sheet(isPresented: $showingAddService) {
            AddServiceSheet(spaceID: spaceID)
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

    private func removeFromSpace(link: SpaceServiceLink) {
        let service = link.service
        let serviceID = service.id

        if selectedServiceID == serviceID {
            selectedServiceID = nil
        }

        modelContext.delete(link)

        // Check remaining links *after* the delete so the count is current
        let hasOtherLinks = service.spaceLinks.contains { $0.id != link.id }
        if !hasOtherLinks {
            appState.webViewPool.removeWebView(for: serviceID)
            modelContext.delete(service)
        }

        save("remove service from space")
        if !hasOtherLinks {
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

    private func reorderService(droppedLinkID: UUID, beforeLink target: SpaceServiceLink) {
        var links = filteredLinks
        guard let fromIndex = links.firstIndex(where: { $0.id == droppedLinkID }),
              let originalToIndex = links.firstIndex(where: { $0.id == target.id })
        else { return }

        let moved = links.remove(at: fromIndex)
        // Removing fromIndex shifts every later element left by one — so
        // when dragging downward (fromIndex < originalToIndex) we need to
        // insert one slot earlier to land *before* the target. Without
        // this, every downward drag drops the item one past where the
        // user pointed.
        let toIndex = fromIndex < originalToIndex ? originalToIndex - 1 : originalToIndex
        links.insert(moved, at: toIndex)

        for (index, link) in links.enumerated() {
            link.sortOrder = index
        }
        save("reorder services")
    }

    private func deleteService(link: SpaceServiceLink) {
        let service = link.service
        let serviceID = service.id

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
        appState.cleanUpOrphanedDataStores()
    }
}
