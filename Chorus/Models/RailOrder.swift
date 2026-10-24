import Foundation

/// One entry in a rail list: a row (a service membership, a global service or
/// a space) or a divider between rows. Only what ordering needs.
struct RailOrderEntry: Equatable {
    let id: UUID
    let sortOrder: Int
    let isDivider: Bool
    /// Breaks a tie between two dividers on the same number.
    var createdAt: Date = .distantPast
}

/// The ordering rules for a rail list that mixes rows and dividers. Pure, so
/// the rules are pinned by tests rather than by whichever view last wrote a
/// number.
///
/// A divider shares its neighbours' numbering, so the list on screen is rows
/// and dividers merged and sorted by `sortOrder`. That only stays true if every
/// write that reorders renumbers the merged list, not the rows alone: renumber
/// just the rows 0…n and one lands on a divider's number, and the divider
/// jumps. So reorders go through `numbering(_:)` over merged ids, and appends
/// take `nextOrder(after:)` over the merged numbers.
///
/// Anchoring a divider to a neighbour ("after service X") was the other way to
/// do it, and it was turned down: drag X across the divider and the divider
/// goes along with it, which is not what a line between groups should do.
enum RailOrder {
    /// The merged display order. By `sortOrder`; on a tie a row comes before a
    /// divider, two dividers go oldest first, and the id settles anything
    /// left, so the order never depends on fetch order.
    static func sorted(_ entries: [RailOrderEntry]) -> [RailOrderEntry] {
        entries.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            if lhs.isDivider != rhs.isDivider { return !lhs.isDivider }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The number for an entry added at the end: one past the highest in use,
    /// or 0 for an empty list.
    static func nextOrder(after orders: [Int]) -> Int {
        (orders.max() ?? -1) + 1
    }

    /// The number each id takes when the list is in the given order: its index.
    static func numbering(_ orderedIDs: [UUID]) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
    }

    /// The merged ids with `newID` placed right after `anchorID`, or at the end
    /// when the anchor is nil or not in the list.
    static func inserting(_ newID: UUID, after anchorID: UUID?, in orderedIDs: [UUID]) -> [UUID] {
        let without = orderedIDs.filter { $0 != newID }
        guard let anchorID, let index = without.firstIndex(of: anchorID) else {
            return without + [newID]
        }
        var result = without
        result.insert(newID, at: index + 1)
        return result
    }
}
