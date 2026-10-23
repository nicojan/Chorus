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

    var id: String {
        switch self {
        case .intoSpace(let link, let space, _): return "space-\(link)-\(space)"
        case .intoGlobal(let link, _): return "global-\(link)"
        case .globalIntoSpace(let service, let space, _): return "global-space-\(service)-\(space)"
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
        }
    }

    /// What the confirmation says: where the service goes, and that its
    /// cookies go with it, naming any services it still shares them with.
    func prompt(for move: RailMove) -> RailMovePrompt? {
        guard let service = moveSubject(move) else { return nil }
        let partners = signInPartners(of: service.id).map(\.label)
        let shared = partners.isEmpty ? "" : " It still shares them with \(Self.listed(partners))."
        let message = "\(service.label) keeps its sign-in, so its cookies come with it.\(shared)"
        switch move {
        case .intoSpace(_, let spaceID, _), .globalIntoSpace(_, let spaceID, _):
            let spaces = (try? modelContainer.mainContext.fetch(FetchDescriptor<Space>(predicate: #Predicate { $0.id == spaceID }))) ?? []
            guard let space = spaces.first else { return nil }
            return RailMovePrompt(title: "Move \(service.label) to \(space.name)?", message: message, confirm: "Move")
        case .intoGlobal:
            return RailMovePrompt(
                title: "Show \(service.label) in every space?",
                message: message + " It leaves the spaces it is in now.",
                confirm: "Show in Every Space"
            )
        }
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
        }
    }
}
