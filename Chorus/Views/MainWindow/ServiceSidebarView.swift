import SwiftUI
import SwiftData

struct ServiceSidebarView: View {
    let spaceID: UUID
    @Binding var selectedServiceID: UUID?
    @Query private var allLinks: [SpaceServiceLink]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @State private var showingAddService = false

    private var filteredLinks: [SpaceServiceLink] {
        allLinks
            .filter { $0.space.id == spaceID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredLinks) { link in
                        ServiceIconView(
                            instance: link.service,
                            isSelected: selectedServiceID == link.service.id
                        )
                        .onTapGesture {
                            selectedServiceID = link.service.id
                        }
                        .contextMenu {
                            Button("Remove from this space") {
                                removeFromSpace(link: link)
                            }
                            Divider()
                            Button("Delete service entirely", role: .destructive) {
                                deleteService(link: link)
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
        }
        .frame(width: 64)
        .background(.background)
        .sheet(isPresented: $showingAddService) {
            AddServiceSheet(spaceID: spaceID)
        }
    }

    private func removeFromSpace(link: SpaceServiceLink) {
        let service = link.service
        let remainingLinks = service.spaceLinks.filter { $0.id != link.id }

        if selectedServiceID == service.id {
            selectedServiceID = nil
        }

        modelContext.delete(link)

        if remainingLinks.isEmpty {
            // Last link removed — clean up the service entirely
            appState.webViewPool.removeWebView(for: service.id)
            Task {
                try? await appState.dataStoreManager.deleteDataStore(for: service)
            }
            modelContext.delete(service)
        }

        try? modelContext.save()
    }

    private func deleteService(link: SpaceServiceLink) {
        let service = link.service

        if selectedServiceID == service.id {
            selectedServiceID = nil
        }

        appState.webViewPool.removeWebView(for: service.id)
        Task {
            try? await appState.dataStoreManager.deleteDataStore(for: service)
        }
        modelContext.delete(service)
        try? modelContext.save()
    }
}
