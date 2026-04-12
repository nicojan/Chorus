import Foundation
import AppKit

@MainActor
@Observable
final class BadgeManager {
    private var counts: [UUID: Int] = [:]

    var totalCount: Int {
        counts.values.reduce(0, +)
    }

    func updateBadge(for instanceID: UUID, count: Int, isMuted: Bool) {
        counts[instanceID] = isMuted ? 0 : count
        updateDockBadge()
    }

    func removeBadge(for instanceID: UUID) {
        counts.removeValue(forKey: instanceID)
        updateDockBadge()
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = totalCount > 0 ? "\(totalCount)" : nil
    }
}
