import Foundation
import AppKit

@MainActor
@Observable
final class BadgeManager {
    private(set) var counts: [UUID: Int] = [:]
    var doNotDisturb: Bool = false

    var totalCount: Int {
        guard !doNotDisturb else { return 0 }
        return counts.values.reduce(0, +)
    }

    func badgeCount(for instanceID: UUID) -> Int {
        guard !doNotDisturb else { return 0 }
        return counts[instanceID] ?? 0
    }

    func aggregateCount(for serviceIDs: [UUID]) -> Int {
        guard !doNotDisturb else { return 0 }
        return serviceIDs.reduce(0) { $0 + (counts[$1] ?? 0) }
    }

    func updateBadge(for instanceID: UUID, count: Int, isMuted: Bool) {
        counts[instanceID] = isMuted ? 0 : count
        updateDockBadge()
    }

    func removeBadge(for instanceID: UUID) {
        counts.removeValue(forKey: instanceID)
        updateDockBadge()
    }

    func updateDockBadge() {
        if doNotDisturb {
            NSApp.dockTile.badgeLabel = nil
        } else {
            let total = counts.values.reduce(0, +)
            NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
        }
    }
}
