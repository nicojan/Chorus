import Foundation

/// One thing the rail draws: a row on its own, or a box round a service group.
enum RailRun: Identifiable {
    case row(RailItem)
    case group(id: UUID, name: String?, items: [RailItem], holdsDragged: Bool)

    var id: UUID {
        switch self {
        case .row(let item): return item.id
        case .group(let id, _, _, _): return id
        }
    }
}

/// Turns a rail list into the rows and group boxes the rail draws. Pure: the
/// caller says which group a link is in and what the group is called.
enum RailRuns {
    /// Consecutive members of one group make a box when there are two or more.
    /// A group that is split by anything else, or has one member, draws as rows,
    /// so a group never draws as two boxes. The `dragged` row sits in the list
    /// during a live drag; between two members of a box it draws inside the box
    /// and does not split it.
    static func runs(
        _ items: [RailItem],
        groupOf: (UUID) -> UUID?,
        nameOf: (UUID) -> String?,
        dragged: UUID? = nil
    ) -> [RailRun] {
        // A dragged member counts in its group only while it touches the
        // group's run: within it or at either end. Dragged further away it
        // has left for now, so the box stays round the rest rather than
        // breaking into rows.
        var draggedLeftItsRun = false
        if let dragged, let at = items.firstIndex(where: { $0.id == dragged }),
           case .member(let link, _) = items[at], let own = groupOf(link.id) {
            let others = items.indices.filter { index in
                guard index != at, case .member(let other, _) = items[index] else { return false }
                return groupOf(other.id) == own
            }
            if let first = others.min(), let last = others.max() {
                draggedLeftItsRun = at < first - 1 || at > last + 1
            }
        }
        func group(_ item: RailItem) -> UUID? {
            guard case .member(let link, _) = item else { return nil }
            if draggedLeftItsRun, link.id == dragged { return nil }
            return groupOf(link.id)
        }
        func isMember(_ item: RailItem) -> Bool {
            if case .member = item { return true }
            return false
        }
        // First pass: the span of each group, with the dragged row allowed inside.
        var spans: [(group: UUID, range: Range<Int>)] = []
        var index = 0
        while index < items.count {
            guard let g = group(items[index]) else { index += 1; continue }
            var end = index + 1
            var lastMember = index
            var cursor = index + 1
            while cursor < items.count {
                if group(items[cursor]) == g {
                    lastMember = cursor
                    end = cursor + 1
                } else if let dragged, items[cursor].id == dragged, isMember(items[cursor]) {
                    // A dragged service row, in no group or another one, may sit
                    // inside; the span still ends at its last member. A dragged
                    // divider or other non-member splits the run as usual.
                } else {
                    break
                }
                cursor += 1
            }
            spans.append((g, index..<(lastMember + 1)))
            index = max(end, lastMember + 1)
        }
        // A group that appears as more than one span is split: draw rows.
        var counts: [UUID: Int] = [:]
        for span in spans { counts[span.group, default: 0] += 1 }
        var boxes: [Int: (UUID, Int)] = [:]
        for span in spans where counts[span.group] == 1 {
            let members = items[span.range].filter { group($0) == span.group }
            if members.count >= 2 { boxes[span.range.lowerBound] = (span.group, span.range.upperBound) }
        }
        var result: [RailRun] = []
        index = 0
        while index < items.count {
            if let (g, end) = boxes[index] {
                let slice = Array(items[index..<end])
                // Lit whenever the dragged row is drawn in the box, its own
                // member included: letting go there keeps it in the group.
                let holds = slice.contains { $0.id == dragged }
                result.append(.group(id: g, name: nameOf(g), items: slice, holdsDragged: holds))
                index = end
            } else {
                result.append(.row(items[index]))
                index += 1
            }
        }
        return result
    }

    /// The group whose box holds the dragged row, if one does: the box a drop
    /// would join or stay in.
    static func litGroup(in runs: [RailRun]) -> UUID? {
        for run in runs {
            if case .group(let id, _, _, true) = run { return id }
        }
        return nil
    }
}
