import SwiftUI

struct ServiceShortcutDestination: Equatable {
    let spaceID: UUID
    let serviceID: UUID
}

enum ServiceShortcutNavigation {
    static func destination(
        at index: Int,
        in destinations: [ServiceShortcutDestination]
    ) -> ServiceShortcutDestination? {
        guard destinations.indices.contains(index) else { return nil }
        return destinations[index]
    }

    static func destination(
        movingBy offset: Int,
        fromSpaceID spaceID: UUID?,
        serviceID: UUID?,
        in destinations: [ServiceShortcutDestination]
    ) -> ServiceShortcutDestination? {
        guard !destinations.isEmpty else { return nil }
        guard let currentIndex = destinations.firstIndex(where: {
            $0.spaceID == spaceID && $0.serviceID == serviceID
        }) else {
            return offset < 0 ? destinations.last : destinations.first
        }

        let newIndex = (currentIndex + offset % destinations.count + destinations.count)
            % destinations.count
        return destinations[newIndex]
    }
}

struct KeyboardShortcutCommands: Commands {
    @Binding var selectedServiceID: UUID?
    @Binding var selectedSpaceID: UUID?
    let railLayout: RailLayout
    let getServicesForSpace: (UUID) -> [ServiceInstance]
    let getAllServiceDestinations: () -> [ServiceShortcutDestination]
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
        if railLayout == .allServices {
            guard let destination = ServiceShortcutNavigation.destination(
                at: index,
                in: getAllServiceDestinations()
            ) else { return }
            select(destination)
            return
        }

        guard let spaceID = selectedSpaceID else { return }
        let services = getServicesForSpace(spaceID)
        guard index < services.count else { return }
        selectedServiceID = services[index].id
    }

    private func switchServiceOffset(_ offset: Int) {
        if railLayout == .allServices {
            guard let destination = ServiceShortcutNavigation.destination(
                movingBy: offset,
                fromSpaceID: selectedSpaceID,
                serviceID: selectedServiceID,
                in: getAllServiceDestinations()
            ) else { return }
            select(destination)
            return
        }

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

    private func select(_ destination: ServiceShortcutDestination) {
        selectedSpaceID = destination.spaceID
        selectedServiceID = destination.serviceID
    }
}
