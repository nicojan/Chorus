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

    @Relationship(deleteRule: .cascade)
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
