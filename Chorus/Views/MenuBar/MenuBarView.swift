import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Query private var services: [ServiceInstance]
    @Query(sort: \Space.sortOrder) private var spaces: [Space]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(spaces) { space in
                Section {
                    ForEach(servicesForSpace(space)) { service in
                        Button {
                            activateService(service.id, inSpace: space.id)
                        } label: {
                            Label(service.label, systemImage: "globe")
                        }
                    }
                } header: {
                    Text("\(space.emoji) \(space.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button("Show Chorus") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Button("Quit Chorus") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func servicesForSpace(_ space: Space) -> [ServiceInstance] {
        space.serviceLinks
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.service)
    }

    private func activateService(_ serviceID: UUID, inSpace spaceID: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        // The actual navigation is handled via AppState bindings in the main window
    }
}
