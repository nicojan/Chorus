import Foundation
import SwiftData

/// Shared sign-ins (issue #39): two services that point at one
/// `dataStoreIdentifier` use the same cookies and storage, so signing in to
/// Google once signs in Gmail, Calendar and Drive alike.
///
/// The store layer already allowed it: a service's sign-in lives under
/// `dataStoreIdentifier`, separate from its `id`. What sharing needs is care
/// at the edges. A deleted service must not take a store others still use
/// (`markDataStoreOrphaned` refuses a claimed store), and clearing one
/// service's session signs out every service that shares it, which the
/// confirmation has to say.
enum SignInSharing {
    /// The services that share `service`'s sign-in, not counting itself.
    static func partners(of service: ServiceInstance, among services: [ServiceInstance]) -> [ServiceInstance] {
        // A Mac app has no cookies, so it is never anyone's partner.
        services.filter {
            $0.id != service.id
                && $0.modelContext != nil
                && $0.nativeAppBundleID == nil
                && $0.dataStoreIdentifier == service.dataStoreIdentifier
        }
    }

    /// The store a service should use after the change: a fresh one for
    /// "its own" (nil), or the chosen service's. Nil when nothing would
    /// change, so the caller leaves the service and its web view alone.
    static func newIdentifier(
        current: UUID,
        sharingWith partner: ServiceInstance?,
        isSharedNow: Bool
    ) -> UUID? {
        if let partner {
            return partner.dataStoreIdentifier == current ? nil : partner.dataStoreIdentifier
        }
        // Already its own: keep it, and keep the sign-in it has.
        return isSharedNow ? UUID() : nil
    }
}

extension AppState {
    /// Every service whose sign-in `serviceID` shares, not counting itself.
    func signInPartners(of serviceID: UUID) -> [ServiceInstance] {
        let context = modelContainer.mainContext
        let services = (try? context.fetch(FetchDescriptor<ServiceInstance>())) ?? []
        guard let service = services.first(where: { $0.id == serviceID }) else { return [] }
        return SignInSharing.partners(of: service, among: services)
    }

    /// Points a service at another service's sign-in, or back at one of its
    /// own (`partnerID` nil). Either way the service starts on a store it has
    /// not used, so it is signed out of the session it had, and its web view
    /// is rebuilt on the new store.
    ///
    /// The store it leaves is removed only when no other service still uses
    /// it; `markDataStoreOrphaned` checks that after the save.
    @discardableResult
    func changeSignIn(for serviceID: UUID, sharingWith partnerID: UUID?) -> Bool {
        let context = modelContainer.mainContext
        let services = (try? context.fetch(FetchDescriptor<ServiceInstance>())) ?? []
        guard let service = services.first(where: { $0.id == serviceID }),
              service.nativeAppBundleID == nil
        else { return false }
        let partner = partnerID.flatMap { id in
            services.first { $0.id == id && $0.modelContext != nil && $0.nativeAppBundleID == nil }
        }
        if partnerID != nil && partner == nil { return false }

        let previous = service.dataStoreIdentifier
        let isShared = !SignInSharing.partners(of: service, among: services).isEmpty
        guard let next = SignInSharing.newIdentifier(current: previous, sharingWith: partner, isSharedNow: isShared) else {
            return true
        }

        service.dataStoreIdentifier = next
        guard context.saveOrRollBack("change sign-in") else { return false }

        // The data store is fixed when a web view is built, so the view has
        // to go and be built again on the new one, at the home page: a page
        // kept from the old session, by this rebuild or an earlier one in the
        // same Save, means nothing to the new one.
        webViewPool.recreateWebView(for: serviceID, preserveURL: false)
        webViewPool.forgetSuspendedURL(for: serviceID)
        webViewRebuildToken &+= 1
        markDataStoreOrphaned(previous)
        cleanUpOrphanedDataStores()
        return true
    }
}
