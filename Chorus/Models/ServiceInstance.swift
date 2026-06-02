import Foundation
import SwiftData

@Model
final class ServiceInstance {
    @Attribute(.unique) var id: UUID
    var label: String
    var url: String
    var customIconData: Data?
    var fetchedIconData: Data?
    var faviconFetchedAt: Date?
    var catalogEntryID: String?
    var isMuted: Bool
    var showBadge: Bool
    var neverHibernate: Bool
    var userAgent: String?
    var dataStoreIdentifier: UUID

    @Relationship(deleteRule: .cascade, inverse: \SpaceServiceLink.service)
    var spaceLinks: [SpaceServiceLink]

    var createdAt: Date
    var lastAccessedAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        url: String,
        customIconData: Data? = nil,
        fetchedIconData: Data? = nil,
        faviconFetchedAt: Date? = nil,
        catalogEntryID: String? = nil,
        isMuted: Bool = false,
        showBadge: Bool = true,
        neverHibernate: Bool = false,
        userAgent: String? = nil,
        dataStoreIdentifier: UUID = UUID()
    ) {
        self.id = id
        self.label = label
        self.url = url
        self.customIconData = customIconData
        self.fetchedIconData = fetchedIconData
        self.faviconFetchedAt = faviconFetchedAt
        self.catalogEntryID = catalogEntryID
        self.isMuted = isMuted
        self.showBadge = showBadge
        self.neverHibernate = neverHibernate
        self.userAgent = userAgent
        self.dataStoreIdentifier = dataStoreIdentifier
        self.spaceLinks = []
        self.createdAt = Date()
        self.lastAccessedAt = Date()
    }
}
