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
        func group(_ item: RailItem) -> UUID? {
            guard case .member(let link, _) = item else { return nil }
            return groupOf(link.id)
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
                } else if let dragged, items[cursor].id == dragged, group(items[cursor]) == nil {
                    // may sit inside; kept only if a member follows
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
                let holds = slice.contains { $0.id == dragged && group($0) != g }
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
    /// would join.
    static func litGroup(in runs: [RailRun]) -> UUID? {
        for run in runs {
            if case .group(let id, _, _, true) = run { return id }
        }
        return nil
    }
}
