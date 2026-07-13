import Foundation
import SwiftData

@Model
final class Space {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String
    var sortOrder: Int
    /// Optional in storage so SwiftData lightweight migration can add this
    /// column to existing Space rows without a `mandatory destination attribute`
    /// failure. Read sites should use the `isMutedEffective` helper which
    /// treats `nil` as `false`.
    var isMuted: Bool?

    /// The inverse must be declared explicitly. `SpaceServiceLink` has two
    /// relationships to different models (`space` and `service`), and the
    /// service side already claims its own inverse
    /// (`ServiceInstance.spaceLinks -> inverse: \.service`). With the space
    /// side left implicit, SwiftData does not wire this pair — `serviceLinks`
    /// then reads empty and the `.cascade` rule never fires, so deleting a
    /// Space leaks its links (dangling `space`) and never reclaims services.
    @Relationship(deleteRule: .cascade, inverse: \SpaceServiceLink.space)
    var serviceLinks: [SpaceServiceLink]

    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String,
        sortOrder: Int = 0,
        isMuted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.sortOrder = sortOrder
        self.isMuted = isMuted
        self.serviceLinks = []
        self.createdAt = Date()
    }

    /// Materialises the storage-optional `isMuted` flag into a plain Bool
    /// (nil → false). Use this everywhere except direct writes.
    var isMutedEffective: Bool { isMuted ?? false }
}
