import Foundation
import SwiftData

/// A service dragged out of its place into another space or the global
/// group. It is confirmed before it happens, since a drop is easy to make by
/// accident and the service takes its sign-in with it. Reorders within one
/// list are not moves and are not confirmed.
enum RailMove: Identifiable, Equatable {
    case intoSpace(linkID: UUID, spaceID: UUID, before: UUID?)
    case intoGlobal(linkID: UUID, before: UUID?)
    case globalIntoSpace(serviceID: UUID, spaceID: UUID, before: UUID?)
    case groupIntoSpace(groupID: UUID, spaceID: UUID, before: UUID?)

    var id: String {
        switch self {
        case .intoSpace(let link, let space, _): return "space-\(link)-\(space)"
        case .intoGlobal(let link, _): return "global-\(link)"
        case .globalIntoSpace(let service, let space, _): return "global-space-\(service)-\(space)"
        case .groupIntoSpace(let group, let space, _): return "group-space-\(group)-\(space)"
        }
    }
}

/// The words of a move's confirmation.
struct RailMovePrompt: Equatable {
    let title: String
    let message: String
    let confirm: String
}

/// Global services and dividers, with the side effects the store edits in
/// `RailEdits` leave to their caller: selection, badges, web views.
extension AppState {
    /// Makes a service global, before `beforeID` in the global group or at its
    /// end. The selection stays on it if it was showing: a global service is
    /// visible in every space, so there is nowhere it has gone.
    @discardableResult
    func makeServiceGlobal(_ serviceID: UUID, before beforeID: UUID? = nil) -> Bool {
        guard RailEdits.makeGlobal(serviceID, before: beforeID, context: modelContainer.mainContext) else {
            return false
        }
        // Its space may have been muted; it no longer inherits that.
        refreshBadgeState(for: serviceID)
        return true
    }

    /// Moves a global service into a space. With `follow`, the view switches
    /// to that space and keeps the service selected, which the new-space path
    /// wants. Without it the view stays put, and if the service was showing and
    /// the space is not the current one, the selection is cleared, the same as
    /// moving a service between spaces from the context menu.
    @discardableResult
    func moveGlobalService(
        _ serviceID: UUID,
        toSpace spaceID: UUID,
        before beforeID: UUID? = nil,
        follow: Bool = false
    ) -> Bool {
        let wasSelected = selectedServiceID == serviceID
        guard RailEdits.moveIntoSpace(serviceID, spaceID: spaceID, before: beforeID, context: modelContainer.mainContext) else {
            return false
        }
        refreshBadgeState(for: serviceID)
        if follow {
            selectedSpaceID = spaceID
            selectedServiceID = serviceID
        } else if wasSelected, selectedSpaceID != spaceID {
            selectedServiceID = nil
        }
        return true
    }

    /// Moves a group with all its members into a space. Selection follows
    /// `moveGlobalService`: with `follow` the view goes to the space, without it
    /// a showing member clears the selection.
    @discardableResult
    func moveGroup(_ groupID: UUID, toSpace spaceID: UUID, before beforeID: UUID? = nil, follow: Bool = false) -> Bool {
        let context = modelContainer.mainContext
        let serviceIDs = RailEdits.groupMembers(groupID, context: context).compactMap { $0.liveEnds?.service.id }
        let wasShowing = selectedServiceID.map { serviceIDs.contains($0) } ?? false
        guard RailEdits.moveGroup(groupID, toSpace: spaceID, before: beforeID, context: context) else { return false }
        for id in serviceIDs { refreshBadgeState(for: id) }
        if follow {
            selectedSpaceID = spaceID
        } else if wasShowing, selectedSpaceID != spaceID {
            selectedServiceID = nil
        }
        return true
    }

    /// Reorders a space with one group's run moved. See `RailEdits.reorderGroup`.
    @discardableResult
    func reorderGroup(_ groupID: UUID, order: [UUID], inSpace spaceID: UUID) -> Bool {
        RailEdits.reorderGroup(groupID, order: order, inSpace: spaceID, context: modelContainer.mainContext)
    }

    /// Deletes a service from every space and the global group, then tears
    /// down its web view and schedules its data store for removal. The
    /// teardown waits for a committed save: a failed save rolls back, and
    /// wiping the sign-in of a service whose row survived is the data loss
    /// `deleteSpace` is written to avoid.
    func deleteServiceEntirely(_ serviceID: UUID) {
        let context = modelContainer.mainContext
        guard let service = try? context.fetch(FetchDescriptor<ServiceInstance>(
            predicate: #Predicate { $0.id == serviceID }
        )).first else { return }
        let dataStoreIdentifier = service.dataStoreIdentifier

        if selectedServiceID == serviceID {
            selectedServiceID = nil
        }

        // Links first, read from a fetch rather than the inverse, which can be
        // stale; leaving them to the cascade can put dangling rows in front of
        // a @Query during the re-render.
        // A group it was in may be down to one member once its links go.
        RailEdits.forgetService(serviceID, context: context)
        let links = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        for link in links where link.modelContext != nil && link.liveService?.id == serviceID {
            context.delete(link)
        }
        context.delete(service)

        guard context.saveOrRollBack("delete service") else { return }

        webViewPool.removeWebView(for: serviceID)
        markDataStoreOrphaned(dataStoreIdentifier)
        cleanUpOrphanedDataStores()
    }

    /// Adds a divider to a list, right after `afterID`, or at the end.
    @discardableResult
    func addDivider(in scope: RailScope, after afterID: UUID?) -> UUID? {
        RailEdits.addDivider(in: scope, after: afterID, context: modelContainer.mainContext)
    }

    /// Deletes a divider.
    @discardableResult
    func removeDivider(_ dividerID: UUID) -> Bool {
        RailEdits.removeDivider(dividerID, context: modelContainer.mainContext)
    }

    /// Renumbers a list after a reorder. See `RailOrder`.
    @discardableResult
    func reorderRail(_ orderedIDs: [UUID], in scope: RailScope) -> Bool {
        RailEdits.reorder(orderedIDs, in: scope, context: modelContainer.mainContext)
    }

    // MARK: - Deleting a space

    /// The services that are in this space and no other, which deleting it
    /// deletes too, with their sign-ins (see `deleteSpace`).
    func servicesOnlyIn(space spaceID: UUID) -> [ServiceInstance] {
        let links = (try? modelContainer.mainContext.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        let ends = links.compactMap(\.liveEnds)
        let here = ends.filter { $0.space.id == spaceID }.map(\.service)
        return here.filter { service in !ends.contains { $0.service.id == service.id && $0.space.id != spaceID } }
    }

    /// What deleting a space takes with it, said plainly. The old wording,
    /// "Services in this space won't be deleted", was untrue for every service
    /// in no other space.
    nonisolated static func deleteSpaceMessage(goingWithIt names: [String]) -> String {
        guard !names.isEmpty else {
            return "Its services are in other spaces too, so they stay there."
        }
        let one = names.count == 1
        return "\(listed(names)) \(one ? "is" : "are") in no other space, so deleting it deletes \(one ? "it" : "them") too. Services that are also in other spaces stay there."
    }

    // MARK: - Moves that need a yes

    /// The service a move is about.
    private func moveSubject(_ move: RailMove) -> ServiceInstance? {
        let context = modelContainer.mainContext
        switch move {
        case .intoSpace(let linkID, _, _), .intoGlobal(let linkID, _):
            let links = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
            return links.first { $0.id == linkID }?.liveService
        case .globalIntoSpace(let serviceID, _, _):
            return try? context.fetch(FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == serviceID })).first
        case .groupIntoSpace:
            return nil
        }
    }

    /// What the confirmation says: where the service goes, and that its
    /// cookies go with it, naming any services it still shares them with.
    func prompt(for move: RailMove) -> RailMovePrompt? {
        if case .groupIntoSpace(let groupID, let spaceID, _) = move {
            let context = modelContainer.mainContext
            let labels = RailEdits.groupMembers(groupID, context: context).compactMap { $0.liveService?.label }
            let spaces = (try? context.fetch(FetchDescriptor<Space>(predicate: #Predicate { $0.id == spaceID }))) ?? []
            guard !labels.isEmpty, let space = spaces.first else { return nil }
            let groups = (try? context.fetch(FetchDescriptor<ServiceGroup>(predicate: #Predicate { $0.id == groupID }))) ?? []
            return Self.groupMovePrompt(name: groups.first?.name, labels: labels, spaceName: space.name)
        }
        guard let service = moveSubject(move) else { return nil }
        let partners = signInPartners(of: service.id).map(\.label)
        let shared = partners.isEmpty ? "" : " It still shares them with \(Self.listed(partners))."
        // A Mac app has no cookies to carry.
        let message = service.nativeAppBundleID != nil
            ? "\(service.label) opens the same app from there."
            : "\(service.label) keeps its sign-in, so its cookies come with it.\(shared)"
        switch move {
        case .intoSpace(_, let spaceID, _), .globalIntoSpace(_, let spaceID, _):
            let spaces = (try? modelContainer.mainContext.fetch(FetchDescriptor<Space>(predicate: #Predicate { $0.id == spaceID }))) ?? []
            guard let space = spaces.first else { return nil }
            return RailMovePrompt(title: "Move \(service.label) to \(space.name)?", message: message, confirm: "Move")
        case .groupIntoSpace:
            return nil
        case .intoGlobal:
            return RailMovePrompt(
                title: "Show \(service.label) in every space?",
                message: message + " It leaves the spaces it is in now.",
                confirm: "Show in Every Space"
            )
        }
    }

    /// The words for moving a group: its services by name, and that each keeps
    /// its sign-in.
    nonisolated static func groupMovePrompt(name: String?, labels: [String], spaceName: String) -> RailMovePrompt {
        let title = name.map { "Move \($0) to \(spaceName)?" } ?? "Move these services to \(spaceName)?"
        return RailMovePrompt(
            title: title,
            message: "\(listed(labels)) move together. Each keeps its sign-in, so its cookies come with it.",
            confirm: "Move"
        )
    }

    /// "A", "A and B", "A, B and C".
    nonisolated static func listed(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// Carries out a confirmed move. A service that was showing goes with the
    /// view, as it does when moved by the menu into a new space.
    @discardableResult
    func performRailMove(_ move: RailMove) -> Bool {
        if case .groupIntoSpace(let groupID, let spaceID, let before) = move {
            let context = modelContainer.mainContext
            let showing = RailEdits.groupMembers(groupID, context: context)
                .contains { $0.liveEnds?.service.id == selectedServiceID }
            return moveGroup(groupID, toSpace: spaceID, before: before, follow: showing)
        }
        guard let service = moveSubject(move) else { return false }
        let serviceID = service.id
        let wasSelected = selectedServiceID == serviceID
        switch move {
        case .intoSpace(let linkID, let spaceID, let before):
            guard RailEdits.moveMembership(linkID, toSpace: spaceID, before: before, context: modelContainer.mainContext) else {
                return false
            }
            // The new space may be muted when the old one was not.
            refreshBadgeState(for: serviceID)
            if wasSelected {
                selectedSpaceID = spaceID
                selectedServiceID = serviceID
            }
            return true
        case .intoGlobal(_, let before):
            return makeServiceGlobal(serviceID, before: before)
        case .globalIntoSpace(_, let spaceID, let before):
            return moveGlobalService(serviceID, toSpace: spaceID, before: before, follow: wasSelected)
        case .groupIntoSpace:
            return false
        }
    }
}
