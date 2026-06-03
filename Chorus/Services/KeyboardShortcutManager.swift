import SwiftUI

struct KeyboardShortcutCommands: Commands {
    @Binding var selectedServiceID: UUID?
    @Binding var selectedSpaceID: UUID?
    let getServicesForSpace: (UUID) -> [ServiceInstance]
    let getSpaces: () -> [Space]

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            // Cmd+1 through Cmd+9 for service switching
            ForEach(1...9, id: \.self) { index in
                Button("Switch to Service \(index)") {
                    switchToService(at: index - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }

            Divider()

            Button("Previous Service") {
                switchServiceOffset(-1)
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("Next Service") {
                switchServiceOffset(1)
            }
            .keyboardShortcut("]", modifiers: .command)

            Divider()

            Button("Next Space") {
                switchSpaceOffset(1)
            }
            .keyboardShortcut(KeyEquivalent.tab, modifiers: .control)

            Button("Previous Space") {
                switchSpaceOffset(-1)
            }
            .keyboardShortcut(KeyEquivalent.tab, modifiers: [.control, .shift])

        }
    }

    private func switchToService(at index: Int) {
        guard let spaceID = selectedSpaceID else { return }
        let services = getServicesForSpace(spaceID)
        guard index < services.count else { return }
        selectedServiceID = services[index].id
    }

    private func switchServiceOffset(_ offset: Int) {
        guard let spaceID = selectedSpaceID else { return }
        let services = getServicesForSpace(spaceID)
        guard !services.isEmpty else { return }

        let currentIndex = services.firstIndex(where: { $0.id == selectedServiceID }) ?? 0
        let newIndex = (currentIndex + offset + services.count) % services.count
        selectedServiceID = services[newIndex].id
    }

    private func switchSpaceOffset(_ offset: Int) {
        let spaces = getSpaces()
        guard !spaces.isEmpty else { return }

        let currentIndex = spaces.firstIndex(where: { $0.id == selectedSpaceID }) ?? 0
        let newIndex = (currentIndex + offset + spaces.count) % spaces.count
        selectedSpaceID = spaces[newIndex].id
    }
}
