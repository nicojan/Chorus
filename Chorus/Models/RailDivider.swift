import Foundation
import SwiftData

/// What a divider sits between.
enum RailDividerKind: String, CaseIterable {
    /// Between services, inside one space or inside the global group.
    case services
    /// Between spaces, in the lists that show every space.
    case spaces
}

/// A line the user puts in a rail list to split it into groups.
///
/// A divider has no relationship to anything. `spaceID` is a plain attribute,
/// not a link to `Space`: a relationship would change `Space`'s stored shape
/// and bring in the cascade differences between macOS 14, 15 and 26 that
/// `SpaceServiceLink` already had to be reshaped for. Deleting a space deletes
/// its dividers by hand, in the same save (`AppState.deleteSpace`).
///
/// It shares its neighbours' numbering: a services divider shares
/// `SpaceServiceLink.sortOrder` in its space, or `globalSortOrder` in the
/// global group; a spaces divider shares `Space.sortOrder`. See `RailOrder`.
@Model
final class RailDivider {
    @Attribute(.unique) var id: UUID
    /// A `RailDividerKind` raw value. Read via `kind`.
    var kindRaw: String
    /// For a services divider, the space it sits in; nil means the global
    /// group. Always nil for a spaces divider.
    var spaceID: UUID?
    var sortOrder: Int
    var createdAt: Date

    /// The divider's kind. An unknown stored value reads as `.services`, the
    /// kind that can only ever show inside one list.
    var kind: RailDividerKind {
        RailDividerKind(rawValue: kindRaw) ?? .services
    }

    init(
        id: UUID = UUID(),
        kind: RailDividerKind,
        spaceID: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.spaceID = kind == .spaces ? nil : spaceID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
