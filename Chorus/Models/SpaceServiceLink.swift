import Foundation
import SwiftData

@Model
final class SpaceServiceLink {
    @Attribute(.unique) var id: UUID
    var sortOrder: Int

    /// Both ends are optional in storage, and that is the whole point rather
    /// than an oversight.
    ///
    /// `Space.serviceLinks` and `ServiceInstance.spaceLinks` both delete with
    /// `.cascade`, so removing either end asks SwiftData to clear this link's
    /// reference before the row goes. When these were non-optional there was
    /// nothing to clear them to, and macOS 15 trapped rather than allow it:
    ///
    ///   Cannot remove Chorus.Space from relationship space on
    ///   Chorus.SpaceServiceLink because an appropriate default value is not
    ///   configured
    ///
    /// which took the app down on the ordinary act of deleting a space. macOS 26
    /// permits the same delete, which is why this shipped from 1.5.13 to 1.5.18
    /// with nobody on a current machine able to reproduce it.
    ///
    /// The cost is that every read has to cope with `nil`. That is honest: a
    /// dangling link has always been possible here (see `reapDanglingLinks`),
    /// and the code was already guarding for it by hand with
    /// `modelContext != nil` checks. `nil` now means the same thing those
    /// guards meant — the other end is gone, skip this link.
    @Relationship var space: Space?
    @Relationship var service: ServiceInstance?

    /// The space this link points at, or nil when it is gone.
    ///
    /// Two things can make an end unusable and both mean the same thing to a
    /// caller. It can be nil, which is the cascade having cleared it. Or it can
    /// still hold a model that was deleted, which a link left dangling by an
    /// older unclean delete does — reading through that faults freed backing
    /// data and traps, so `modelContext` has to be checked as well. Callers
    /// should go through these rather than repeat the pair.
    var liveSpace: Space? {
        guard let space, space.modelContext != nil else { return nil }
        return space
    }

    /// The service this link points at, or nil when it is gone. See `liveSpace`.
    var liveService: ServiceInstance? {
        guard let service, service.modelContext != nil else { return nil }
        return service
    }

    /// Both ends, when this link and both of them are still usable. Nil if any
    /// part is missing, which is the condition every read site wants before it
    /// touches a link at all.
    var liveEnds: (space: Space, service: ServiceInstance)? {
        guard modelContext != nil, let space = liveSpace, let service = liveService else { return nil }
        return (space, service)
    }

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
