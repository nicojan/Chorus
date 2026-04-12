import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 0) {
            SpaceStripView(
                selectedSpaceID: $state.selectedSpaceID
            )

            Divider()

            if let spaceID = appState.selectedSpaceID {
                ServiceSidebarView(
                    spaceID: spaceID,
                    selectedServiceID: $state.selectedServiceID
                )

                Divider()
            }

            WebContentView(
                selectedServiceID: appState.selectedServiceID
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $state.showAddService) {
            if let spaceID = appState.selectedSpaceID {
                AddServiceSheet(spaceID: spaceID)
            }
        }
    }
}
