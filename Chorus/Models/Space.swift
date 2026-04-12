import Foundation
import SwiftData

@Model
final class Space {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String
    var sortOrder: Int

    @Relationship(deleteRule: .cascade)
    var serviceLinks: [SpaceServiceLink]

    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.sortOrder = sortOrder
        self.serviceLinks = []
        self.createdAt = Date()
    }
}
