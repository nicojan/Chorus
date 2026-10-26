import Foundation

/// One entry in a space's list, in display order: a service row or a divider.
/// `groupID` is nil for dividers and for rows that are in no group.
struct GroupEntry: Equatable {
    let id: UUID
    let groupID: UUID?
    let isDivider: Bool
}

/// The rules that keep a service group one unbroken run in the list. Pure, like
/// `RailOrder`, so tests pin them and the store and the views only apply the
/// result.
///
/// A group is not a container in the list. It is a set of rows that happen to
/// sit side by side, so every move that could split the run goes through
/// `repaired(_:)`, which is the one place that says what a legal list is. The
/// other rules decide what a move means, then hand the list to it.
enum GroupRules {
    /// Every group one unbroken run at the place of its first member. Anything
    /// that sits inside a run (a row of no group, a divider, another group's
    /// row) moves to just after it, in its order. A group left with fewer than
    /// two members dissolves, because a group of one is only a label.
    nonisolated static func repaired(_ entries: [GroupEntry]) -> [GroupEntry] {
        var counts: [UUID: Int] = [:]
        for entry in entries where !entry.isDivider {
            if let group = entry.groupID { counts[group, default: 0] += 1 }
        }
        let cleaned = entries.map { entry -> GroupEntry in
            guard let group = entry.groupID, entry.isDivider || (counts[group] ?? 0) < 2 else { return entry }
            return GroupEntry(id: entry.id, groupID: nil, isDivider: entry.isDivider)
        }
        var emitted = Set<UUID>()
        var result: [GroupEntry] = []
        for entry in cleaned {
            guard let group = entry.groupID else {
                result.append(entry)
                continue
            }
            if emitted.insert(group).inserted {
                result.append(contentsOf: cleaned.filter { $0.groupID == group })
            }
        }
        return result
    }

    /// `dragged` dropped onto `target`: it takes the target's group, or a new
    /// one (which the target joins too) when the target has none. It lands next
    /// to the target on the side it came from, so the drop reads as a small
    /// step and the rows around it do not jump: from below it lands right after
    /// the target, from above right before it.
    nonisolated static func joining(
        _ dragged: UUID, onto target: UUID, in entries: [GroupEntry], newGroupID: UUID
    ) -> [GroupEntry] {
        guard dragged != target,
              let from = entries.firstIndex(where: { $0.id == dragged }),
              let to = entries.firstIndex(where: { $0.id == target }),
              !entries[from].isDivider, !entries[to].isDivider
        else { return entries }
        let group = entries[to].groupID ?? newGroupID
        var rest = entries.filter { $0.id != dragged }
        let targetIndex = rest.firstIndex(where: { $0.id == target }) ?? 0
        rest.insert(GroupEntry(id: dragged, groupID: group, isDivider: false), at: from > to ? targetIndex + 1 : targetIndex)
        let joined = rest.map { entry in
            entry.id == target ? GroupEntry(id: target, groupID: group, isDivider: false) : entry
        }
        return repaired(joined)
    }

    /// The list after a drag ends. `entries` already holds `dragged` where the
    /// live moves left it. It takes `litGroup` (the group whose box was lit when
    /// it dropped) only if it sits inside that run or touches either end, so a
    /// box that lit earlier and went stale cannot pull in a row that has since
    /// moved away. With no lit group it leaves its own, and a group that is
    /// down to one dissolves.
    nonisolated static func placing(_ dragged: UUID, in entries: [GroupEntry], litGroup: UUID?) -> [GroupEntry] {
        guard let index = entries.firstIndex(where: { $0.id == dragged }) else { return entries }
        let group = litGroup.flatMap { touchesRun(dragged, of: $0, in: entries) ? $0 : nil }
        var result = entries
        result[index] = GroupEntry(id: dragged, groupID: group, isDivider: entries[index].isDivider)
        return repaired(result)
    }

    /// Whether `dragged` sits inside `group`'s run, or right next to either
    /// end of it, counting the group's other members only. That is where a drop
    /// can join the group.
    nonisolated static func touchesRun(_ dragged: UUID, of group: UUID, in entries: [GroupEntry]) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == dragged }) else { return false }
        let others = entries.indices.filter { entries[$0].groupID == group && entries[$0].id != dragged }
        guard let first = others.min(), let last = others.max() else { return false }
        return index >= first - 1 && index <= last + 1
    }

    /// Where something arriving from outside the list (a divider being added, a
    /// service from another space, a global service) goes, as the id of the
    /// entry it lands before. When `beforeID` is a member that is not first in
    /// its run, that spot is inside the run, so it is the entry after the run
    /// instead. Nil means the end of the list.
    nonisolated static func landingAnchor(before beforeID: UUID?, in entries: [GroupEntry]) -> UUID? {
        guard let beforeID, let index = entries.firstIndex(where: { $0.id == beforeID }),
              let group = entries[index].groupID, index > 0, entries[index - 1].groupID == group
        else { return beforeID }
        var end = index
        while end < entries.count, entries[end].groupID == group { end += 1 }
        return end < entries.count ? entries[end].id : nil
    }

    /// Move Up / Move Down for one entry. A member moves one place inside its
    /// run and never out of it, so the keyboard cannot leave a group (dragging
    /// does that). At the edge of the run it does nothing. A row or divider
    /// outside a run steps over a whole run in one step. Membership is never
    /// touched.
    nonisolated static func stepping(_ id: UUID, forward: Bool, in entries: [GroupEntry]) -> [UUID] {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return entries.map(\.id) }
        var ids = entries.map(\.id)
        if let group = entries[index].groupID {
            let target = forward ? index + 1 : index - 1
            if entries.indices.contains(target), entries[target].groupID == group {
                ids.swapAt(index, target)
            }
            return ids
        }
        var units = units(of: entries)
        guard let at = units.firstIndex(where: { $0.contains { $0.id == id } }) else { return ids }
        let other = forward ? at + 1 : at - 1
        guard units.indices.contains(other) else { return ids }
        units.swapAt(at, other)
        return units.flatMap { $0.map(\.id) }
    }

    /// Move Group Up / Down: the whole run passes its neighbour, which is a
    /// row, a divider, or another whole run.
    nonisolated static func steppingGroup(_ groupID: UUID, forward: Bool, in entries: [GroupEntry]) -> [UUID] {
        var units = units(of: entries)
        guard let at = units.firstIndex(where: { $0.first?.groupID == groupID }) else { return entries.map(\.id) }
        let other = forward ? at + 1 : at - 1
        guard units.indices.contains(other) else { return entries.map(\.id) }
        units.swapAt(at, other)
        return units.flatMap { $0.map(\.id) }
    }

    /// The rows directly above and below `id` that are not dividers and not in
    /// its group: the ones "Group With..." can offer.
    nonisolated static func groupWithCandidates(for id: UUID, in entries: [GroupEntry]) -> [UUID] {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return [] }
        let own = entries[index].groupID
        return [index - 1, index + 1]
            .filter { entries.indices.contains($0) }
            .map { entries[$0] }
            .filter { !$0.isDivider && (own == nil || $0.groupID != own) }
            .map(\.id)
    }

    /// The list as units that move whole: each run is one unit, every other
    /// entry its own.
    private nonisolated static func units(of entries: [GroupEntry]) -> [[GroupEntry]] {
        var units: [[GroupEntry]] = []
        for entry in entries {
            if let group = entry.groupID, let last = units.last?.last, last.groupID == group {
                units[units.count - 1].append(entry)
            } else {
                units.append([entry])
            }
        }
        return units
    }
}
