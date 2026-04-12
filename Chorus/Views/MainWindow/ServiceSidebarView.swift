import SwiftUI
import SwiftData

struct ServiceSidebarView: View {
    let spaceID: UUID
    @Binding var selectedServiceID: UUID?
    @Query private var allLinks: [SpaceServiceLink]

    private var filteredLinks: [SpaceServiceLink] {
        allLinks
            .filter { $0.space.id == spaceID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
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
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 64)
        .background(.background)
    }
}
