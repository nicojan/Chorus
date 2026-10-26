import Foundation

/// How a service drag over a row decides between moving past it and grouping
/// with it: the iOS feel. The row's two ends move the dragged service past it,
/// and resting on its middle for `pauseBeforeGrouping` groups the two. Moving
/// past services never groups; only a pause does.
enum GroupDrag {
    /// How long the pointer has to rest on a row's middle before letting go
    /// groups with it. iOS's own pause is not published; this is a guess, kept
    /// in one place so it is easy to tune.
    static let pauseBeforeGrouping: Duration = .milliseconds(500)

    /// The part of a row the pointer is over, along the list.
    enum Zone: Equatable {
        case before, middle, after
    }

    /// The middle starts this far into the row and ends this far in, as a
    /// fraction of its length, for a pointer coming from either end.
    nonisolated static let middleEntry: ClosedRange<CGFloat> = 0.30...0.70
    /// Once in the middle, the pointer has to leave this wider band to leave
    /// it, so a hand that wavers at the edge does not flicker between moving
    /// and pausing.
    nonisolated static let middleExit: ClosedRange<CGFloat> = 0.25...0.75

    /// Which part of a row `offset` points at, `offset` and `length` measured
    /// along the list. `current` is the part the pointer was last over in this
    /// row, which decides which band the middle has.
    nonisolated static func zone(at offset: CGFloat, length: CGFloat, current: Zone?) -> Zone {
        guard length > 0 else { return .middle }
        let fraction = offset / length
        let middle = current == .middle ? middleExit : middleEntry
        if middle.contains(fraction) { return .middle }
        return fraction < middle.lowerBound ? .before : .after
    }

    /// The order with `dragged` put directly before (`.before`) or after
    /// (`.after`) `target`. Nil when it is already there, for the middle, or
    /// when either is missing. So the near edge of a neighbour `dragged`
    /// already touches does nothing, and the row the pointer reaches stays
    /// under it rather than swapping away.
    nonisolated static func reordered(_ dragged: UUID, over target: UUID, zone: Zone, in ids: [UUID]) -> [UUID]? {
        guard zone != .middle, dragged != target, ids.contains(dragged), ids.contains(target) else { return nil }
        var rest = ids.filter { $0 != dragged }
        guard let targetIndex = rest.firstIndex(of: target) else { return nil }
        rest.insert(dragged, at: zone == .before ? targetIndex : targetIndex + 1)
        return rest == ids ? nil : rest
    }
}
