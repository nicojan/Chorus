import Foundation
import SwiftData

/// One ordered rail list: the services of a space, the global group, or the
/// list of spaces. Each mixes its rows with the dividers that belong to it.
enum RailScope: Hashable {
    case space(UUID)
    case global
    case spaces

    /// The divider kind and space id that put a divider in this list.
    var dividerKey: (kind: RailDividerKind, spaceID: UUID?) {
        switch self {
        case .space(let id): return (.services, id)
        case .global: return (.services, nil)
        case .spaces: return (.spaces, nil)
        }
    }
}

/// The store edits behind global services and dividers, written against a
/// `ModelContext` so tests can run them on an in-memory store. Selection,
/// badges and web views are the caller's (see the `AppState` wrappers); these
/// only change rows, and each one either saves everything it changed or rolls
/// all of it back.
///
/// Membership is read by fetching links and checking both ends with
/// `liveEnds`, never through `Space.serviceLinks` or
/// `ServiceInstance.spaceLinks`: those inverses can be stale, and a link whose
/// other end was deleted holds a freed model that traps when read.
@MainActor
enum RailEdits {
    // MARK: - Reading

    /// Global services in rail order.
    static func globalServices(in context: ModelContext) -> [ServiceInstance] {
        let services = (try? context.fetch(FetchDescriptor<ServiceInstance>(
            predicate: #Predicate { $0.isGlobal == true }
        ))) ?? []
        return RailItems.orderedGlobals(services)
    }

    /// The dividers that belong to one list, in no particular order.
    static func dividers(in scope: RailScope, context: ModelContext) -> [RailDivider] {
        let key = scope.dividerKey
        let kindRaw = key.kind.rawValue
        let all = (try? context.fetch(FetchDescriptor<RailDivider>(
            predicate: #Predicate { $0.kindRaw == kindRaw }
        ))) ?? []
        return all.filter { $0.spaceID == key.spaceID }
    }

    /// Live links of one space, in no particular order.
    static func links(inSpace spaceID: UUID, context: ModelContext) -> [SpaceServiceLink] {
        let all = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        return all.filter { $0.liveEnds?.space.id == spaceID }
    }

    /// The list's rows and dividers as ordering entries, merged and sorted.
    /// A row's id is the link's id in a space, the service's id in the global
    /// group, and the space's id in the list of spaces.
    static func entries(in scope: RailScope, context: ModelContext) -> [RailOrderEntry] {
        let rows: [RailOrderEntry]
        switch scope {
        case .space(let spaceID):
            rows = links(inSpace: spaceID, context: context).map {
                RailOrderEntry(id: $0.id, sortOrder: $0.sortOrder, isDivider: false)
            }
        case .global:
            rows = globalServices(in: context).map {
                RailOrderEntry(id: $0.id, sortOrder: $0.globalSortOrder ?? 0, isDivider: false)
            }
        case .spaces:
            let spaces = (try? context.fetch(FetchDescriptor<Space>())) ?? []
            rows = spaces.map { RailOrderEntry(id: $0.id, sortOrder: $0.sortOrder, isDivider: false) }
        }
        let dividers = dividers(in: scope, context: context).map {
            RailOrderEntry(id: $0.id, sortOrder: $0.sortOrder, isDivider: true, createdAt: $0.createdAt)
        }
        return RailOrder.sorted(rows + dividers)
    }

    /// The number for an entry appended to the list.
    static func nextOrder(in scope: RailScope, context: ModelContext) -> Int {
        RailOrder.nextOrder(after: entries(in: scope, context: context).map(\.sortOrder))
    }

    // MARK: - Ordering

    /// Numbers the list's rows and dividers by their place in `orderedIDs`.
    /// Ids that are not in the list are ignored, and anything in the list
    /// that `orderedIDs` leaves out keeps its number. Does not save.
    ///
    /// `extra` numbers a row that is joining the list in this same unsaved
    /// edit. It is set directly rather than found by a fetch, so the result
    /// does not hang on whether a fetch sees a change not yet saved.
    static func applyOrder(
        _ orderedIDs: [UUID],
        in scope: RailScope,
        context: ModelContext,
        extra: (id: UUID, set: (Int) -> Void)? = nil
    ) {
        let numbering = RailOrder.numbering(orderedIDs)
        if let extra, let order = numbering[extra.id] { extra.set(order) }
        for divider in dividers(in: scope, context: context) {
            if let order = numbering[divider.id] { divider.sortOrder = order }
        }
        switch scope {
        case .space(let spaceID):
            for link in links(inSpace: spaceID, context: context) {
                if let order = numbering[link.id] { link.sortOrder = order }
            }
        case .global:
            for service in globalServices(in: context) {
                if let order = numbering[service.id] { service.globalSortOrder = order }
            }
        case .spaces:
            for space in (try? context.fetch(FetchDescriptor<Space>())) ?? [] {
                if let order = numbering[space.id] { space.sortOrder = order }
            }
        }
    }

    /// Renumbers the list and saves. False when the save failed and was
    /// rolled back.
    @discardableResult
    static func reorder(_ orderedIDs: [UUID], in scope: RailScope, context: ModelContext) -> Bool {
        applyOrder(orderedIDs, in: scope, context: context)
        return context.saveOrRollBack("reorder rail")
    }

    // MARK: - Global services

    /// Makes a service global: removes it from every space and puts it in the
    /// global group, before `beforeID` (a row or divider of the global group)
    /// or at the end. Its settings, sign-in and web view are untouched.
    @discardableResult
    static func makeGlobal(_ serviceID: UUID, before beforeID: UUID? = nil, context: ModelContext) -> Bool {
        guard let service = service(serviceID, context: context), !service.isGlobalEffective else { return false }

        // Read the group before anything changes, so no fetch below has to
        // see an unsaved edit to get the numbers right.
        var group = entries(in: .global, context: context)
        // Dividers left from a group that emptied some other way would show
        // above nothing now, so a group starting over starts clean.
        if !group.contains(where: { !$0.isDivider }) {
            for divider in dividers(in: .global, context: context) { context.delete(divider) }
            group = []
        }
        let allLinks = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        var left: [UUID: Set<UUID>] = [:]
        for link in allLinks where link.modelContext != nil && link.liveService?.id == serviceID {
            if let spaceID = link.liveSpace?.id { left[spaceID, default: []].insert(link.id) }
            context.delete(link)
        }
        // A group it was in may be down to one member now.
        for (spaceID, removed) in left {
            tidyGroups(inSpace: spaceID, context: context, removedLinks: removed)
        }
        service.isGlobal = true
        service.globalSortOrder = RailOrder.nextOrder(after: group.map(\.sortOrder))
        if let beforeID {
            applyOrder(
                placing(serviceID, before: beforeID, in: group.map(\.id)),
                in: .global,
                context: context,
                extra: (serviceID, { service.globalSortOrder = $0 })
            )
        }
        return context.saveOrRollBack("make service global")
    }

    /// Puts a new service, not yet linked anywhere, at the end of the global
    /// group. A group starting over drops any dividers left behind, as
    /// `makeGlobal` does. Does not save.
    static func appendGlobal(_ service: ServiceInstance, context: ModelContext) {
        var group = entries(in: .global, context: context).filter { $0.id != service.id }
        if !group.contains(where: { !$0.isDivider }) {
            for divider in dividers(in: .global, context: context) { context.delete(divider) }
            group = []
        }
        service.isGlobal = true
        service.globalSortOrder = RailOrder.nextOrder(after: group.map(\.sortOrder))
    }

    /// Moves a global service into a space, before `beforeID` (a link or
    /// divider of that space) or at the end. It stops being global.
    @discardableResult
    static func moveIntoSpace(
        _ serviceID: UUID,
        spaceID: UUID,
        before beforeID: UUID? = nil,
        context: ModelContext
    ) -> Bool {
        guard let service = service(serviceID, context: context), service.isGlobalEffective,
              let space = try? context.fetch(FetchDescriptor<Space>(predicate: #Predicate { $0.id == spaceID })).first
        else { return false }

        let list = entries(in: .space(spaceID), context: context)
        // Read before the insert, so no fetch has to see it.
        let anchor = GroupRules.landingAnchor(before: beforeID, in: groupEntries(inSpace: spaceID, context: context))
        let link = SpaceServiceLink(
            sortOrder: RailOrder.nextOrder(after: list.map(\.sortOrder)),
            space: space,
            service: service
        )
        // Building the link wires the inverses, which registers it when both
        // ends are in the context. A second insert is fatal on macOS 14.
        if link.modelContext == nil { context.insert(link) }
        service.isGlobal = nil
        service.globalSortOrder = nil
        // The group is not drawn without services, so its dividers would sit
        // there unseen and come back above nothing when a service next goes
        // global. They go with the last service.
        // Whether or not the fetch already sees this one as no longer global,
        // "no other global service" is the test.
        if globalServices(in: context).allSatisfy({ $0.id == serviceID }) {
            for divider in dividers(in: .global, context: context) { context.delete(divider) }
        }
        if let anchor {
            applyOrder(
                placing(link.id, before: anchor, in: list.map(\.id)),
                in: .space(spaceID),
                context: context,
                extra: (link.id, { link.sortOrder = $0 })
            )
        }
        tidyGroups(inSpace: spaceID, context: context)
        return context.saveOrRollBack("move global service into space")
    }

    /// Moves a membership into another space, before `beforeID` (a link or
    /// divider there) or at the end. The service and its store are kept; only
    /// the link is repointed, so it never drops to zero links and is never
    /// reaped. Refused when the service is already in that space, since two
    /// links to one service in a space are invalid.
    ///
    /// A group belongs to one space, so the link leaves its group and lands
    /// outside any run there (see `GroupRules.landingAnchor`). Both spaces are
    /// tidied: the one it left may have a group down to one member.
    @discardableResult
    static func moveMembership(
        _ linkID: UUID,
        toSpace spaceID: UUID,
        before beforeID: UUID? = nil,
        context: ModelContext
    ) -> Bool {
        let allLinks = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        guard let link = allLinks.first(where: { $0.id == linkID }),
              let ends = link.liveEnds, ends.space.id != spaceID,
              let target = try? context.fetch(FetchDescriptor<Space>(predicate: #Predicate { $0.id == spaceID })).first
        else { return false }
        guard !allLinks.contains(where: { $0.liveEnds?.space.id == spaceID && $0.liveEnds?.service.id == ends.service.id }) else {
            return false
        }

        let sourceID = ends.space.id
        let list = entries(in: .space(spaceID), context: context)
        let anchor = GroupRules.landingAnchor(before: beforeID, in: groupEntries(inSpace: spaceID, context: context))
        let order = RailOrder.nextOrder(after: list.map(\.sortOrder))
        link.space = target
        link.sortOrder = order
        link.groupID = nil
        if let anchor {
            applyOrder(
                placing(linkID, before: anchor, in: list.map(\.id)),
                in: .space(spaceID),
                context: context,
                extra: (linkID, { link.sortOrder = $0 })
            )
        }
        tidyGroups(inSpace: sourceID, context: context, removedLinks: [linkID])
        tidyGroups(inSpace: spaceID, context: context)
        return context.saveOrRollBack("move service to space")
    }

    // MARK: - Dividers

    /// Adds a divider to a list, right after `afterID` (a row or divider of
    /// that list) or at the end. Returns its id, or nil when the save failed.
    /// In a space, a spot inside a group's run moves to just after the run.
    @discardableResult
    static func addDivider(in scope: RailScope, after afterID: UUID?, context: ModelContext) -> UUID? {
        let key = scope.dividerKey
        let list = entries(in: scope, context: context)
        let groups: [GroupEntry]?
        if case .space(let spaceID) = scope {
            groups = groupEntries(inSpace: spaceID, context: context)
        } else {
            groups = nil
        }
        let divider = RailDivider(
            kind: key.kind,
            spaceID: key.spaceID,
            sortOrder: RailOrder.nextOrder(after: list.map(\.sortOrder))
        )
        context.insert(divider)
        let ids = list.map(\.id)
        let ordered: [UUID]
        if let groups, let afterID, let index = groups.firstIndex(where: { $0.id == afterID }) {
            let next = groups.indices.contains(index + 1) ? groups[index + 1].id : nil
            if let anchor = GroupRules.landingAnchor(before: next, in: groups) {
                ordered = placing(divider.id, before: anchor, in: ids)
            } else {
                ordered = ids + [divider.id]
            }
        } else {
            ordered = RailOrder.inserting(divider.id, after: afterID, in: ids)
        }
        applyOrder(
            ordered,
            in: scope,
            context: context,
            extra: (divider.id, { divider.sortOrder = $0 })
        )
        guard context.saveOrRollBack("add divider") else { return nil }
        return divider.id
    }

    /// Deletes a divider. True when it is gone.
    @discardableResult
    static func removeDivider(_ dividerID: UUID, context: ModelContext) -> Bool {
        guard let divider = try? context.fetch(FetchDescriptor<RailDivider>(
            predicate: #Predicate { $0.id == dividerID }
        )).first else { return true }
        context.delete(divider)
        return context.saveOrRollBack("remove divider")
    }

    /// Deletes the dividers of a space being deleted. Does not save: the
    /// caller deletes the space in the same save.
    static func deleteDividers(ofSpace spaceID: UUID, context: ModelContext) {
        for divider in dividers(in: .space(spaceID), context: context) {
            context.delete(divider)
        }
    }

    // MARK: - Groups

    /// The space's rows and dividers in order, each row with its group.
    ///
    /// `knownGroups` maps group id to space id for groups inserted in this
    /// unsaved edit, and `removedLinks` are links deleted in it, so the answer
    /// does not hang on whether a fetch sees either. A link's `groupID` with no
    /// row, or with a row of another space, reads as no group.
    static func groupEntries(
        inSpace spaceID: UUID,
        context: ModelContext,
        knownGroups: [UUID: UUID] = [:],
        removedLinks: Set<UUID> = []
    ) -> [GroupEntry] {
        var groupSpaces = knownGroups
        for group in (try? context.fetch(FetchDescriptor<ServiceGroup>())) ?? [] where !group.isDeleted {
            groupSpaces[group.id] = group.spaceID
        }
        // A group moved or inserted in this unsaved edit: the caller's word
        // beats whatever the fetch shows.
        for (group, space) in knownGroups { groupSpaces[group] = space }
        let groupOf = Dictionary(
            links(inSpace: spaceID, context: context).map { ($0.id, $0.groupID) },
            uniquingKeysWith: { first, _ in first }
        )
        return entries(in: .space(spaceID), context: context)
            .filter { !removedLinks.contains($0.id) }
            .map { entry in
                guard !entry.isDivider, let group = groupOf[entry.id] ?? nil, groupSpaces[group] == spaceID else {
                    return GroupEntry(id: entry.id, groupID: nil, isDivider: entry.isDivider)
                }
                return GroupEntry(id: entry.id, groupID: group, isDivider: false)
            }
    }

    /// Makes the space's groups legal again with `GroupRules.repaired`: each
    /// one run, none of one member, and no link pointing at a group that is
    /// missing or another space's. Deletes this space's group rows that have no
    /// member left. Returns whether it changed anything. Does not save.
    @discardableResult
    static func tidyGroups(
        inSpace spaceID: UUID,
        context: ModelContext,
        knownGroups: [UUID: UUID] = [:],
        removedLinks: Set<UUID> = []
    ) -> Bool {
        let list = groupEntries(inSpace: spaceID, context: context, knownGroups: knownGroups, removedLinks: removedLinks)
        let repaired = GroupRules.repaired(list)
        var changed = false
        if repaired.map(\.id) != list.map(\.id) {
            applyOrder(repaired.map(\.id), in: .space(spaceID), context: context)
            changed = true
        }
        if setMembership(repaired, inSpace: spaceID, context: context, skipping: removedLinks) { changed = true }
        let used = Set(repaired.compactMap(\.groupID))
        for group in groups(inSpace: spaceID, context: context) where !used.contains(group.id) {
            context.delete(group)
            changed = true
        }
        return changed
    }

    /// The launch repair: `tidyGroups` on every space, and the deletion of
    /// group rows whose space is gone. Saves only when something changed.
    /// Returns whether it did. It touches no sign-in, so it runs on damaged,
    /// restored and in-memory stores too.
    @discardableResult
    static func repairGroups(context: ModelContext) -> Bool {
        let spaces = (try? context.fetch(FetchDescriptor<Space>())) ?? []
        var changed = false
        var fixed = 0
        for space in spaces where tidyGroups(inSpace: space.id, context: context) {
            changed = true
            fixed += 1
        }
        let spaceIDs = Set(spaces.map(\.id))
        for group in (try? context.fetch(FetchDescriptor<ServiceGroup>())) ?? [] where !group.isDeleted && !spaceIDs.contains(group.spaceID) {
            context.delete(group)
            changed = true
            fixed += 1
        }
        guard changed else { return false }
        do {
            try context.save()
            AppLogger.dataStore.info("Repaired service groups at launch (\(fixed) change(s))")
            return true
        } catch {
            context.rollback()
            AppLogger.dataStore.error("Failed to repair service groups; rolled back: \(error.localizedDescription)")
            return false
        }
    }

    /// `draggedLinkID` dropped onto `targetLinkID`: it joins the target's
    /// group, or a new one the target joins too. Refused, with nothing
    /// changed, when either link is gone or they are in different spaces.
    @discardableResult
    static func groupLink(_ draggedLinkID: UUID, onto targetLinkID: UUID, context: ModelContext) -> Bool {
        guard draggedLinkID != targetLinkID else { return false }
        let allLinks = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        guard let dragged = allLinks.first(where: { $0.id == draggedLinkID })?.liveEnds,
              let target = allLinks.first(where: { $0.id == targetLinkID })?.liveEnds,
              dragged.space.id == target.space.id
        else { return false }
        let spaceID = target.space.id
        let list = groupEntries(inSpace: spaceID, context: context)
        guard let targetEntry = list.first(where: { $0.id == targetLinkID }),
              list.contains(where: { $0.id == draggedLinkID })
        else { return false }

        let newGroupID = UUID()
        var known: [UUID: UUID] = [:]
        if targetEntry.groupID == nil {
            context.insert(ServiceGroup(id: newGroupID, spaceID: spaceID))
            known[newGroupID] = spaceID
        }
        let joined = GroupRules.joining(draggedLinkID, onto: targetLinkID, in: list, newGroupID: newGroupID)
        writeGroups(joined, inSpace: spaceID, context: context)
        tidyGroups(inSpace: spaceID, context: context, knownGroups: known)
        return context.saveOrRollBack("group services")
    }

    /// The write that ends a drag within a space. The order comes from the
    /// store, where the live moves already put it, never from the view.
    /// `litGroup` is the group whose box was lit at the drop.
    @discardableResult
    static func finishDrag(_ draggedLinkID: UUID, inSpace spaceID: UUID, litGroup: UUID?, context: ModelContext) -> Bool {
        let list = groupEntries(inSpace: spaceID, context: context)
        guard list.contains(where: { $0.id == draggedLinkID }) else { return false }
        writeGroups(GroupRules.placing(draggedLinkID, in: list, litGroup: litGroup), inSpace: spaceID, context: context)
        tidyGroups(inSpace: spaceID, context: context)
        return context.saveOrRollBack("finish rail drag")
    }

    /// Takes one link out of its group. It steps out to just below the run,
    /// wherever in the run it was. A group left with one member dissolves.
    @discardableResult
    static func removeFromGroup(_ linkID: UUID, context: ModelContext) -> Bool {
        guard let spaceID = liveLink(linkID, context: context)?.liveEnds?.space.id else { return false }
        let list = groupEntries(inSpace: spaceID, context: context)
        guard let index = list.firstIndex(where: { $0.id == linkID }) else { return false }
        guard let group = list[index].groupID else { return true }
        var rest = list
        rest.remove(at: index)
        let landing = rest.lastIndex(where: { $0.groupID == group }).map { $0 + 1 } ?? index
        rest.insert(GroupEntry(id: linkID, groupID: nil, isDivider: false), at: landing)
        writeGroups(rest, inSpace: spaceID, context: context)
        tidyGroups(inSpace: spaceID, context: context)
        return context.saveOrRollBack("remove service from group")
    }

    /// Names a group. The name is trimmed, empty means no name, and it is cut
    /// to `SetupArchive.Limit.textLength` characters. False when the group is
    /// gone or the save failed.
    @discardableResult
    static func nameGroup(_ groupID: UUID, _ name: String?, context: ModelContext) -> Bool {
        guard let group = group(groupID, context: context) else { return false }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        group.name = trimmed.isEmpty ? nil : String(trimmed.prefix(SetupArchive.Limit.textLength))
        return context.saveOrRollBack("name group")
    }

    /// Dissolves a group: its members stay where they are, in no group.
    @discardableResult
    static func ungroup(_ groupID: UUID, context: ModelContext) -> Bool {
        let row = group(groupID, context: context)
        let allLinks = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        let members = allLinks.filter { $0.modelContext != nil && $0.groupID == groupID }
        guard row != nil || !members.isEmpty else { return false }
        for member in members { member.groupID = nil }
        if let row { context.delete(row) }
        return context.saveOrRollBack("ungroup")
    }

    /// Deletes a link from its space and tidies the space's groups, since the
    /// link's group may be down to one member. Does not save.
    static func leaveSpace(_ linkID: UUID, context: ModelContext) {
        guard let link = liveLink(linkID, context: context) else { return }
        let spaceID = link.liveSpace?.id
        context.delete(link)
        if let spaceID {
            tidyGroups(inSpace: spaceID, context: context, removedLinks: [linkID])
        }
    }

    /// Tidies every space a service being deleted is in, as if its links were
    /// already gone. Call it before deleting them. Does not save.
    static func forgetService(_ serviceID: UUID, context: ModelContext) {
        let allLinks = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        var bySpace: [UUID: Set<UUID>] = [:]
        for link in allLinks where link.modelContext != nil && link.liveService?.id == serviceID {
            if let spaceID = link.liveSpace?.id { bySpace[spaceID, default: []].insert(link.id) }
        }
        for (spaceID, removed) in bySpace {
            tidyGroups(inSpace: spaceID, context: context, removedLinks: removed)
        }
    }

    /// Deletes the groups of a space being deleted. Does not save: the caller
    /// deletes the space in the same save.
    static func deleteGroups(ofSpace spaceID: UUID, context: ModelContext) {
        for group in groups(inSpace: spaceID, context: context) {
            context.delete(group)
        }
    }

    /// A group's member links in rail order, read by fetch.
    static func groupMembers(_ groupID: UUID, context: ModelContext) -> [SpaceServiceLink] {
        let all = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        return all
            .filter { $0.modelContext != nil && !$0.isDeleted && $0.groupID == groupID && $0.liveEnds != nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The new order of a space that moves one group's run. Membership is
    /// untouched; `order` is the whole list as the caller wants it, and a run
    /// that comes out broken is repaired. False when the group is not in that
    /// space or the save failed.
    @discardableResult
    static func reorderGroup(_ groupID: UUID, order: [UUID], inSpace spaceID: UUID, context: ModelContext) -> Bool {
        guard let row = group(groupID, context: context), row.spaceID == spaceID,
              groupMembers(groupID, context: context).contains(where: { $0.liveEnds?.space.id == spaceID })
        else { return false }
        applyOrder(order, in: .space(spaceID), context: context)
        tidyGroups(inSpace: spaceID, context: context)
        return context.saveOrRollBack("reorder group")
    }

    /// Spaces a group can move to, in rail order: every space but its own that
    /// holds none of its members' services.
    static func eligibleSpaces(forGroup groupID: UUID, context: ModelContext) -> [UUID] {
        let members = groupMembers(groupID, context: context)
        let ownSpaces = Set(members.compactMap { $0.liveEnds?.space.id })
        let serviceIDs = Set(members.compactMap { $0.liveEnds?.service.id })
        let all = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        let taken = Set(all.compactMap { link -> UUID? in
            guard let ends = link.liveEnds, serviceIDs.contains(ends.service.id) else { return nil }
            return ends.space.id
        })
        let spaces = (try? context.fetch(FetchDescriptor<Space>())) ?? []
        return spaces
            .filter { !ownSpaces.contains($0.id) && !taken.contains($0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.id)
    }

    /// Moves a group and all its members into another space, before `beforeID`
    /// (a link or divider there) or at the end, as one run in the same order.
    /// The members keep their group and the group row follows them. Refused,
    /// with nothing changed, when any member's service is already in that space.
    @discardableResult
    static func moveGroup(
        _ groupID: UUID,
        toSpace spaceID: UUID,
        before beforeID: UUID? = nil,
        context: ModelContext
    ) -> Bool {
        guard let row = group(groupID, context: context),
              let target = try? context.fetch(FetchDescriptor<Space>(predicate: #Predicate { $0.id == spaceID })).first
        else { return false }
        let members = groupMembers(groupID, context: context)
        let sources = Set(members.compactMap { $0.liveEnds?.space.id })
        guard !members.isEmpty, sources.count == 1, let sourceID = sources.first, sourceID != spaceID else { return false }
        let all = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        let serviceIDs = Set(members.compactMap { $0.liveEnds?.service.id })
        guard !all.contains(where: {
            guard let ends = $0.liveEnds else { return false }
            return ends.space.id == spaceID && serviceIDs.contains(ends.service.id)
        }) else { return false }

        let memberIDs = members.map(\.id)
        let list = entries(in: .space(spaceID), context: context).map(\.id)
        let anchor = GroupRules.landingAnchor(before: beforeID, in: groupEntries(inSpace: spaceID, context: context))
        var ordered = list
        if let anchor, let index = ordered.firstIndex(of: anchor) {
            ordered.insert(contentsOf: memberIDs, at: index)
        } else {
            ordered.append(contentsOf: memberIDs)
        }
        let numbering = RailOrder.numbering(ordered)
        for member in members {
            member.space = target
            member.sortOrder = numbering[member.id] ?? member.sortOrder
        }
        row.spaceID = spaceID
        applyOrder(ordered, in: .space(spaceID), context: context)
        let known = [groupID: spaceID]
        tidyGroups(inSpace: sourceID, context: context, knownGroups: known, removedLinks: Set(memberIDs))
        tidyGroups(inSpace: spaceID, context: context, knownGroups: known)
        return context.saveOrRollBack("move group to space")
    }

    // MARK: - Putting a drag back

    /// Each list as it stands, with each row's group, for `restore`. Lists
    /// other than a space's carry no groups.
    static func snapshot(_ scopes: [RailScope], context: ModelContext) -> [RailScope: [GroupEntry]] {
        var lists: [RailScope: [GroupEntry]] = [:]
        for scope in scopes {
            if case .space(let spaceID) = scope {
                lists[scope] = groupEntries(inSpace: spaceID, context: context)
            } else {
                lists[scope] = entries(in: scope, context: context).map {
                    GroupEntry(id: $0.id, groupID: nil, isDivider: $0.isDivider)
                }
            }
        }
        return lists
    }

    /// Puts every list in `snapshot` back the way it was: its order and, in a
    /// space, each link's group. A group row that went in the meantime comes
    /// back with the same id and no name, and one that moved to another space
    /// comes back to this one. Anything that has left a list since is left
    /// where it is. False when the save failed and was rolled back.
    @discardableResult
    static func restore(_ snapshot: [RailScope: [GroupEntry]], context: ModelContext) -> Bool {
        for (scope, list) in snapshot {
            applyOrder(list.map(\.id), in: scope, context: context)
            guard case .space(let spaceID) = scope else { continue }
            var known: [UUID: UUID] = [:]
            for groupID in Set(list.compactMap(\.groupID)) {
                if let row = group(groupID, context: context) {
                    if row.spaceID != spaceID { row.spaceID = spaceID }
                } else {
                    context.insert(ServiceGroup(id: groupID, spaceID: spaceID))
                }
                known[groupID] = spaceID
            }
            setMembership(list, inSpace: spaceID, context: context, skipping: [])
            tidyGroups(inSpace: spaceID, context: context, knownGroups: known)
        }
        return context.saveOrRollBack("put back a cancelled drag")
    }

    /// Writes a list's order and each of its links' groups. Does not save.
    private static func writeGroups(_ list: [GroupEntry], inSpace spaceID: UUID, context: ModelContext) {
        applyOrder(list.map(\.id), in: .space(spaceID), context: context)
        setMembership(list, inSpace: spaceID, context: context, skipping: [])
    }

    /// Points each link of the space at its group in `list`. Links not in the
    /// list are left alone. Returns whether any changed.
    @discardableResult
    private static func setMembership(
        _ list: [GroupEntry],
        inSpace spaceID: UUID,
        context: ModelContext,
        skipping removedLinks: Set<UUID>
    ) -> Bool {
        let groupOf = Dictionary(list.map { ($0.id, $0.groupID) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for link in links(inSpace: spaceID, context: context) where !removedLinks.contains(link.id) {
            if let group = groupOf[link.id], link.groupID != group {
                link.groupID = group
                changed = true
            }
        }
        return changed
    }

    /// This space's group rows, in no particular order.
    private static func groups(inSpace spaceID: UUID, context: ModelContext) -> [ServiceGroup] {
        let all = (try? context.fetch(FetchDescriptor<ServiceGroup>(
            predicate: #Predicate { $0.spaceID == spaceID }
        ))) ?? []
        return all.filter { !$0.isDeleted }
    }

    private static func group(_ id: UUID, context: ModelContext) -> ServiceGroup? {
        let all = (try? context.fetch(FetchDescriptor<ServiceGroup>(predicate: #Predicate { $0.id == id }))) ?? []
        return all.first { !$0.isDeleted }
    }

    private static func liveLink(_ id: UUID, context: ModelContext) -> SpaceServiceLink? {
        let all = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        return all.first { $0.id == id && $0.modelContext != nil && !$0.isDeleted }
    }

    // MARK: - Helpers

    private static func service(_ id: UUID, context: ModelContext) -> ServiceInstance? {
        try? context.fetch(FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == id })).first
    }

    /// `ids` with `movingID` placed before `beforeID`, or at the end when
    /// `beforeID` is not in the list.
    static func placing(_ movingID: UUID, before beforeID: UUID, in ids: [UUID]) -> [UUID] {
        let without = ids.filter { $0 != movingID }
        guard let index = without.firstIndex(of: beforeID) else { return without + [movingID] }
        return Array(without[..<index]) + [movingID] + Array(without[index...])
    }
}
