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

    /// Groups one service with the one next to it. See `RailEdits.groupLink`.
    @discardableResult
    func groupLink(_ draggedLinkID: UUID, onto targetLinkID: UUID) -> Bool {
        RailEdits.groupLink(draggedLinkID, onto: targetLinkID, context: modelContainer.mainContext)
    }

    /// Takes a service out of its group, to just below the box.
    @discardableResult
    func removeFromGroup(_ linkID: UUID) -> Bool {
        RailEdits.removeFromGroup(linkID, context: modelContainer.mainContext)
    }

    /// Names a group; nil or blank takes the name away.
    @discardableResult
    func nameGroup(_ groupID: UUID, _ name: String?) -> Bool {
        RailEdits.nameGroup(groupID, name, context: modelContainer.mainContext)
    }

    /// Removes a group's box and leaves its services where they are.
    @discardableResult
    func ungroup(_ groupID: UUID) -> Bool {
        RailEdits.ungroup(groupID, context: modelContainer.mainContext)
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

    /// The one write that ends a service drag in its own space: the drag's
    /// membership, from the box that was lit at the drop. See
    /// `RailEdits.finishDrag`.
    @discardableResult
    func finishRailDrag(_ linkID: UUID, litGroup: UUID?) -> Bool {
        let context = modelContainer.mainContext
        let links = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        guard let spaceID = links.first(where: { $0.modelContext != nil && $0.id == linkID })?.liveEnds?.space.id else { return false }
        return RailEdits.finishDrag(linkID, inSpace: spaceID, litGroup: litGroup, context: context)
    }

    /// Makes a space's groups legal again, as a divider drag ends. Saves only
    /// when something changed. See `RailEdits.tidyGroups`.
    @discardableResult
    func tidyGroups(inSpace spaceID: UUID) -> Bool {
        let context = modelContainer.mainContext
        guard RailEdits.tidyGroups(inSpace: spaceID, context: context) else { return false }
        return context.saveOrRollBack("tidy groups after a divider drag")
    }

    /// Whether the move waiting on a yes came from this drag: the dragged link,
    /// global service or group is the one it moves.
    func pendingRailMove(isFromDragOf linkID: UUID?, global globalID: UUID?, group groupID: UUID? = nil) -> Bool {
        switch pendingRailMove {
        case .intoSpace(let link, _, _), .intoGlobal(let link, _):
            return link == linkID
        case .globalIntoSpace(let service, _, _):
            return service == globalID
        case .groupIntoSpace(let group, _, _):
            return group == groupID
        case nil:
            return false
        }
    }

    /// What a space does with a group's box let go on it. See
    /// `GroupDrag.spaceDrop`.
    func groupDrop(_ groupID: UUID, into spaceID: UUID) -> GroupDrag.SpaceDrop {
        let context = modelContainer.mainContext
        let groupSpace = RailEdits.groupMembers(groupID, context: context).first?.liveEnds?.space.id
        let eligible = groupSpace == nil || groupSpace == spaceID
            ? []
            : RailEdits.eligibleSpaces(forGroup: groupID, context: context)
        return GroupDrag.spaceDrop(into: spaceID, groupSpace: groupSpace, eligible: eligible, waiting: pendingRailMove != nil)
    }

    /// A group's box let go on a space: another space that can take it asks
    /// first, landing before `beforeID` or at the end. Its own space takes the
    /// drop and needs nothing more. False when the space refuses it.
    @discardableResult
    func requestGroupMove(_ groupID: UUID, into spaceID: UUID, before beforeID: UUID?) -> Bool {
        switch groupDrop(groupID, into: spaceID) {
        case .ownSpace:
            return true
        case .refuse:
            return false
        case .ask:
            pendingRailMove = .groupIntoSpace(groupID: groupID, spaceID: spaceID, before: beforeID)
            return true
        }
    }

    /// Answers the move waiting on a yes. Turned down, the lists go back as
    /// the drag that asked found them, so the live moves on its way leave
    /// nothing behind, a split group included.
    func answerPendingRailMove(confirmed: Bool) {
        guard let move = pendingRailMove else { return }
        let restore = pendingRailMoveRestore
        pendingRailMoveRestore = [:]
        pendingRailMove = nil
        if confirmed {
            _ = performRailMove(move)
        } else if !restore.isEmpty {
            _ = restoreRail(restore)
        }
    }

    /// Puts lists back as a drag found them. See `RailEdits.restore`.
    @discardableResult
    func restoreRail(_ snapshot: [RailScope: [GroupEntry]]) -> Bool {
        RailEdits.restore(snapshot, context: modelContainer.mainContext)
    }

    /// The lists a drag can change, as they stand. See `RailEdits.snapshot`.
    func railSnapshot(_ scopes: [RailScope]) -> [RailScope: [GroupEntry]] {
        RailEdits.snapshot(scopes, context: modelContainer.mainContext)
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
            let services = RailEdits.groupMembers(groupID, context: context).compactMap(\.liveService)
            let spaces = (try? context.fetch(FetchDescriptor<Space>(predicate: #Predicate { $0.id == spaceID }))) ?? []
            guard !services.isEmpty, let space = spaces.first else { return nil }
            let groups = (try? context.fetch(FetchDescriptor<ServiceGroup>(predicate: #Predicate { $0.id == groupID }))) ?? []
            return Self.groupMovePrompt(
                name: groups.first?.name,
                members: services.map { (label: $0.label, isMacApp: $0.nativeAppBundleID != nil) },
                sharingSignIn: signInPartnersLeftBehind(by: services).map(\.label),
                spaceName: space.name
            )
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

    /// The services outside a group that share a sign-in with one of its web
    /// members, each once, in the order first met. A Mac app carries no
    /// cookies, so it has no partners to leave behind.
    private func signInPartnersLeftBehind(by services: [ServiceInstance]) -> [ServiceInstance] {
        let memberIDs = Set(services.map(\.id))
        var seen: Set<UUID> = []
        return services
            .filter { $0.nativeAppBundleID == nil }
            .flatMap { signInPartners(of: $0.id) }
            .filter { !memberIDs.contains($0.id) && seen.insert($0.id).inserted }
    }

    /// The words for moving a group, by the rules of the one-service question
    /// (`prompt(for:)`): its services by name; a web service keeps its sign-in
    /// and its cookies come with it; a Mac app opens the same app from there;
    /// and services staying behind that share a sign-in with it are named.
    nonisolated static func groupMovePrompt(
        name: String?,
        members: [(label: String, isMacApp: Bool)],
        sharingSignIn partners: [String],
        spaceName: String
    ) -> RailMovePrompt {
        let title = name.map { "Move \($0) to \(spaceName)?" } ?? "Move these services to \(spaceName)?"
        let web = members.filter { !$0.isMacApp }.map(\.label)
        let apps = members.filter(\.isMacApp).map(\.label)
        var sentences = ["\(listed(members.map(\.label))) move together."]
        if !web.isEmpty {
            if apps.isEmpty && web.count > 1 {
                sentences.append("Each keeps its sign-in, so its cookies come with it.")
            } else if web.count == 1 {
                sentences.append("\(web[0]) keeps its sign-in, so its cookies come with it.")
            } else {
                sentences.append("\(listed(web)) keep their sign-ins, so their cookies come with them.")
            }
        }
        if !apps.isEmpty {
            if web.isEmpty && apps.count > 1 {
                sentences.append("Each opens the same app from there.")
            } else if apps.count == 1 {
                sentences.append("\(apps[0]) opens the same app from there.")
            } else {
                sentences.append("\(listed(apps)) open the same apps from there.")
            }
        }
        if !partners.isEmpty, !web.isEmpty {
            sentences.append(
                partners.count == 1
                    ? "\(partners[0]) stays where it is and still uses the same cookies."
                    : "\(listed(partners)) stay where they are and still use the same cookies."
            )
        }
        return RailMovePrompt(title: title, message: sentences.joined(separator: " "), confirm: "Move")
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
