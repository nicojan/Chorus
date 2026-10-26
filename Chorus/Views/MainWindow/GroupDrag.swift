import Foundation

/// How a service drag over a row decides between moving past it and grouping
/// with it. This task only names the parts of a row; the rules that use them
/// come with pause-to-group.
enum GroupDrag {
    /// The part of a row the pointer is over, along the list.
    enum Zone: Equatable {
        case before, middle, after
    }
}
