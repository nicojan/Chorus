import Foundation
import SwiftData

/// Where a new service goes and whose sign-in it uses.
///
/// From 1.5.29 the services in a space share one sign-in by default, and the
/// global services share another, so signing in to Google once signs in every
/// Google app beside it. A service can still keep its own, which a second
/// account of the same site needs. The shared stores need no schema: a space's
/// store is the space's own id, and the global store is a fixed id. A service
/// still only points at a store, so deleting, exporting and the store cleanup
/// treat a shared store as they treat any other (see `SignInSharing`).
///
/// Services that existed before keep their own stores. Moving them onto a
/// shared one would sign people out of everything on update, so it is left to
/// them, per service, in Edit Service.
enum ServiceAdding {
    struct Destination: Equatable {
        let spaceID: UUID
        /// Shown in every space rather than in `spaceID`.
        var global: Bool = false
        /// Its own sign-in rather than the shared one.
        var separate: Bool = false
    }

    /// The store the global services added from now on share.
    static let globalStore = UUID(uuidString: "6C0BA15E-0000-4000-8000-0000C40205E5")!

    /// The store a space's services share: the space's own id.
    static func sharedStore(forSpace spaceID: UUID) -> UUID { spaceID }

    /// The store a new service starts on.
    static func store(for destination: Destination) -> UUID {
        if destination.separate { return UUID() }
        return destination.global ? globalStore : sharedStore(forSpace: destination.spaceID)
    }

    /// The site a service is, for spotting a second copy: its catalog entry
    /// when it has one, else its host without a leading "www.".
    static func siteKey(catalogEntryID: String?, url: String) -> String? {
        if let catalogEntryID, !catalogEntryID.isEmpty { return "catalog:\(catalogEntryID)" }
        guard var host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return "host:\(host)"
    }

    /// A service already on the store the new one would share, and of the
    /// same site, so the two would open the same account. Nil when the new
    /// one keeps its own sign-in, or nothing matches.
    @MainActor
    static func sameSiteOnSharedStore(
        catalogEntryID: String?,
        url: String,
        destination: Destination,
        context: ModelContext
    ) -> ServiceInstance? {
        guard !destination.separate,
              let key = siteKey(catalogEntryID: catalogEntryID, url: url)
        else { return nil }
        let store = store(for: destination)
        let services = (try? context.fetch(FetchDescriptor<ServiceInstance>())) ?? []
        return services.first { service in
            service.modelContext != nil
                && service.nativeAppBundleID == nil
                && service.dataStoreIdentifier == store
                && siteKey(catalogEntryID: service.catalogEntryID, url: service.url) == key
        }
    }

    /// The web services on a store, for saying who a new service would share
    /// a sign-in with.
    @MainActor
    static func services(on store: UUID, context: ModelContext) -> [ServiceInstance] {
        let services = (try? context.fetch(FetchDescriptor<ServiceInstance>())) ?? []
        return services.filter { $0.modelContext != nil && $0.nativeAppBundleID == nil && $0.dataStoreIdentifier == store }
    }

    /// Whether a site is a chat service. Two copies of one on a single
    /// sign-in compete for the session, so a second copy is only offered a
    /// sign-in of its own.
    static func isChat(catalogEntryID: String?, url: String) -> Bool {
        let entry = catalogEntryID.flatMap { ServiceCatalog.shared.entry(for: $0) }
            ?? URL(string: url)?.host.flatMap { ServiceCatalog.shared.entry(forHost: $0) }
        guard let entry else { return false }
        return ServiceInstance.notificationCriticalCategories.contains(entry.category)
    }

    /// Puts a new service in its place: a link at the end of the space, or
    /// the end of the global group. The caller has inserted the service and
    /// set its store; this does not save.
    @MainActor
    static func place(_ service: ServiceInstance, at destination: Destination, context: ModelContext) -> Bool {
        if destination.global {
            RailEdits.appendGlobal(service, context: context)
            return true
        }
        let spaceID = destination.spaceID
        guard let space = try? context.fetch(FetchDescriptor<Space>(
            predicate: #Predicate { $0.id == spaceID }
        )).first else { return false }
        let link = SpaceServiceLink(
            sortOrder: RailEdits.nextOrder(in: .space(destination.spaceID), context: context),
            space: space,
            service: service
        )
        // Wiring the inverses already registers the row on macOS 14; a second
        // insert there is fatal.
        if link.modelContext == nil { context.insert(link) }
        return true
    }
}
