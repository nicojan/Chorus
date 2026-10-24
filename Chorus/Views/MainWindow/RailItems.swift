import Foundation

/// One entry in a rail list as drawn: a row, or a divider between rows.
enum RailItem: Identifiable {
    /// A service in a space, through its membership.
    case member(SpaceServiceLink, ServiceInstance)
    /// A global service, which has no membership.
    case global(ServiceInstance)
    case space(Space)
    case divider(RailDivider)

    /// The id `RailOrder` numbers it by: the link's for a member, the
    /// service's for a global service, the space's, or the divider's.
    var id: UUID {
        switch self {
        case .member(let link, _): return link.id
        case .global(let service): return service.id
        case .space(let space): return space.id
        case .divider(let divider): return divider.id
        }
    }

    /// The service a row shows, if it shows one.
    var service: ServiceInstance? {
        switch self {
        case .member(_, let service), .global(let service): return service
        case .space, .divider: return nil
        }
    }
}

/// Builds the lists the rail draws from what its queries returned. The order
/// is `RailOrder`'s, the same one `RailEdits` writes, so a list on screen and
/// the numbers in the store never disagree about where a divider is.
@MainActor
enum RailItems {
    /// The dividers that belong to one list, skipping any already deleted.
    static func dividers(_ all: [RailDivider], in scope: RailScope) -> [RailDivider] {
        let key = scope.dividerKey
        return all.filter { $0.modelContext != nil && $0.kind == key.kind && $0.spaceID == key.spaceID }
    }

    /// A space's members, given its live links, with its dividers.
    static func members(_ links: [SpaceServiceLink], dividers: [RailDivider]) -> [RailItem] {
        merge(
            rows: links.compactMap { link in
                link.liveService.map { (RailItem.member(link, $0), link.sortOrder) }
            },
            dividers: dividers
        )
    }

    /// The global group, given its live services, with its dividers.
    static func globals(_ services: [ServiceInstance], dividers: [RailDivider]) -> [RailItem] {
        merge(rows: services.map { (RailItem.global($0), $0.globalSortOrder ?? 0) }, dividers: dividers)
    }

    /// The list of spaces, with the dividers between them.
    static func spaces(_ spaces: [Space], dividers: [RailDivider]) -> [RailItem] {
        merge(rows: spaces.map { (RailItem.space($0), $0.sortOrder) }, dividers: dividers)
    }

    /// Global services in rail order, skipping any already deleted.
    static func liveGlobals(_ services: [ServiceInstance]) -> [ServiceInstance] {
        orderedGlobals(services.filter { $0.modelContext != nil && $0.isGlobalEffective })
    }

    /// Global services in the order the rail draws them: `RailOrder`'s rule,
    /// with a missing `globalSortOrder` read as 0, the same as `globals` and
    /// `RailEdits.entries` read it. One rule, so ⌘1–9, the arrow keys, the
    /// quick switcher and the menu bar all agree with the rail.
    nonisolated static func orderedGlobals(_ services: [ServiceInstance]) -> [ServiceInstance] {
        let byID = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = services.map { RailOrderEntry(id: $0.id, sortOrder: $0.globalSortOrder ?? 0, isDivider: false) }
        return RailOrder.sorted(entries).compactMap { byID[$0.id] }
    }

    private static func merge(rows: [(item: RailItem, order: Int)], dividers: [RailDivider]) -> [RailItem] {
        var byID: [UUID: RailItem] = [:]
        var entries: [RailOrderEntry] = []
        for row in rows {
            byID[row.item.id] = row.item
            entries.append(RailOrderEntry(id: row.item.id, sortOrder: row.order, isDivider: false))
        }
        for divider in dividers {
            byID[divider.id] = .divider(divider)
            entries.append(RailOrderEntry(
                id: divider.id, sortOrder: divider.sortOrder, isDivider: true, createdAt: divider.createdAt
            ))
        }
        return RailOrder.sorted(entries).compactMap { byID[$0.id] }
    }
}
