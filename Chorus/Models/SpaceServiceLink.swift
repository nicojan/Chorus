import Foundation
import SwiftData

@Model
final class SpaceServiceLink {
    @Attribute(.unique) var id: UUID
    var sortOrder: Int

    @Relationship var space: Space
    @Relationship var service: ServiceInstance

    init(
        id: UUID = UUID(),
        sortOrder: Int = 0,
        space: Space,
        service: ServiceInstance
    ) {
        self.id = id
        self.sortOrder = sortOrder
        self.space = space
        self.service = service
    }
}
