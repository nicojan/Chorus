import Foundation
import SwiftData

@Model
final class Space {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String
    var sortOrder: Int
    var isMuted: Bool

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
}
