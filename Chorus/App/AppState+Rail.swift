import Foundation
import SwiftData

/// Global services and dividers, with the side effects the store edits in
/// `RailEdits` leave to their caller: selection, badges, web views.
extension AppState {
    /// Makes a service global, before `beforeID` in the global group or at its
    /// end. The selection stays on it if it was showing: a global service is
    /// visible in every space, so there is nowhere it has gone.
    @discardableResult
    func makeServiceGlobal(_ serviceID: UUID, before beforeID: UUID? = nil) -> Bool {
        guard RailEdits.makeGlobal(serviceID, before: beforeID, context: modelContainer.mainContext) else {
            return false
        }
        // Its space may have been muted; it no longer inherits that.
        refreshBadgeState(for: serviceID)
        return true
    }

    /// Moves a global service into a space. With `follow`, the view switches
    /// to that space and keeps the service selected, which the new-space path
    /// wants. Without it the view stays put, and if the service was showing and
    /// the space is not the current one, the selection is cleared, the same as
    /// moving a service between spaces from the context menu.
    @discardableResult
    func moveGlobalService(
        _ serviceID: UUID,
        toSpace spaceID: UUID,
        before beforeID: UUID? = nil,
        follow: Bool = false
    ) -> Bool {
        let wasSelected = selectedServiceID == serviceID
        guard RailEdits.moveIntoSpace(serviceID, spaceID: spaceID, before: beforeID, context: modelContainer.mainContext) else {
            return false
        }
        refreshBadgeState(for: serviceID)
        if follow {
            selectedSpaceID = spaceID
            selectedServiceID = serviceID
        } else if wasSelected, selectedSpaceID != spaceID {
            selectedServiceID = nil
        }
        return true
    }

    /// Deletes a service from every space and the global group, then tears
    /// down its web view and schedules its data store for removal. The
    /// teardown waits for a committed save: a failed save rolls back, and
    /// wiping the sign-in of a service whose row survived is the data loss
    /// `deleteSpace` is written to avoid.
    func deleteServiceEntirely(_ serviceID: UUID) {
        let context = modelContainer.mainContext
        guard let service = try? context.fetch(FetchDescriptor<ServiceInstance>(
            predicate: #Predicate { $0.id == serviceID }
        )).first else { return }
        let dataStoreIdentifier = service.dataStoreIdentifier

        if selectedServiceID == serviceID {
            selectedServiceID = nil
        }

        // Links first, read from a fetch rather than the inverse, which can be
        // stale; leaving them to the cascade can put dangling rows in front of
        // a @Query during the re-render.
        let links = (try? context.fetch(FetchDescriptor<SpaceServiceLink>())) ?? []
        for link in links where link.modelContext != nil && link.liveService?.id == serviceID {
            context.delete(link)
        }
        context.delete(service)

        guard context.saveOrRollBack("delete service") else { return }

        webViewPool.removeWebView(for: serviceID)
        markDataStoreOrphaned(dataStoreIdentifier)
        cleanUpOrphanedDataStores()
    }

    /// Adds a divider to a list, right after `afterID`, or at the end.
    @discardableResult
    func addDivider(in scope: RailScope, after afterID: UUID?) -> UUID? {
        RailEdits.addDivider(in: scope, after: afterID, context: modelContainer.mainContext)
    }

    /// Deletes a divider.
    @discardableResult
    func removeDivider(_ dividerID: UUID) -> Bool {
        RailEdits.removeDivider(dividerID, context: modelContainer.mainContext)
    }

    /// Renumbers a list after a reorder. See `RailOrder`.
    @discardableResult
    func reorderRail(_ orderedIDs: [UUID], in scope: RailScope) -> Bool {
        RailEdits.reorder(orderedIDs, in: scope, context: modelContainer.mainContext)
    }
}
