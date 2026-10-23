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
        for link in allLinks where link.modelContext != nil && link.liveService?.id == serviceID {
            context.delete(link)
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
        if let beforeID {
            applyOrder(
                placing(link.id, before: beforeID, in: list.map(\.id)),
                in: .space(spaceID),
                context: context,
                extra: (link.id, { link.sortOrder = $0 })
            )
        }
        return context.saveOrRollBack("move global service into space")
    }

    // MARK: - Dividers

    /// Adds a divider to a list, right after `afterID` (a row or divider of
    /// that list) or at the end. Returns its id, or nil when the save failed.
    @discardableResult
    static func addDivider(in scope: RailScope, after afterID: UUID?, context: ModelContext) -> UUID? {
        let key = scope.dividerKey
        let list = entries(in: scope, context: context)
        let divider = RailDivider(
            kind: key.kind,
            spaceID: key.spaceID,
            sortOrder: RailOrder.nextOrder(after: list.map(\.sortOrder))
        )
        context.insert(divider)
        applyOrder(
            RailOrder.inserting(divider.id, after: afterID, in: list.map(\.id)),
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
