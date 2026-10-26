import Foundation
import SwiftData

/// A named or unnamed bracket the user puts around some services in one space.
///
/// A group has no relationship to anything, for the reasons `RailDivider` has
/// none. `spaceID` is a plain attribute, not a link to `Space`: a relationship
/// would change `Space`'s stored shape and bring in the cascade differences
/// between macOS 14, 15 and 26 that `SpaceServiceLink` already had to be
/// reshaped for. Members point the other way: `SpaceServiceLink.groupID` holds
/// this group's `id`. Deleting a space deletes its groups by hand, in the same
/// save.
@Model
final class ServiceGroup {
    @Attribute(.unique) var id: UUID
    /// The space this group sits in.
    var spaceID: UUID
    /// The label the user gave it, or nil for a group with no name.
    var name: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        spaceID: UUID,
        name: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.name = name
        self.createdAt = createdAt
    }
}
