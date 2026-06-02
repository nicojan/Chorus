import Foundation
import AppKit

@MainActor
@Observable
final class BadgeManager {
    private(set) var counts: [UUID: Int] = [:]
    var doNotDisturb: Bool = false
    var showBadgeCountInDock: Bool = true {
        didSet { updateDockBadge() }
    }

    var totalCount: Int {
        guard !doNotDisturb else { return 0 }
        return counts.values.reduce(0, +)
    }

    /// Returns the raw stored count regardless of DND. Used by adaptive
    /// polling to compare deltas without the DND mask zeroing both sides.
    func rawCount(for instanceID: UUID) -> Int {
        counts[instanceID] ?? 0
    }

    func badgeCount(for instanceID: UUID) -> Int {
        guard !doNotDisturb else { return 0 }
        return counts[instanceID] ?? 0
    }

    func aggregateCount(for serviceIDs: [UUID]) -> Int {
        guard !doNotDisturb else { return 0 }
        return serviceIDs.reduce(0) { $0 + (counts[$1] ?? 0) }
    }

    func updateBadge(for instanceID: UUID, count: Int, isMuted: Bool, showBadge: Bool = true) {
        // A muted or badge-disabled service contributes nothing to the
        // sidebar or dock totals, but we still store 0 (rather than removing
        // the entry) so adaptive polling can detect deltas correctly.
        counts[instanceID] = (isMuted || !showBadge) ? 0 : count
        updateDockBadge()
    }

    func removeBadge(for instanceID: UUID) {
        counts.removeValue(forKey: instanceID)
        updateDockBadge()
    }

    func updateDockBadge() {
        // Use NSApplication.shared rather than the NSApp global — the
        // global is an implicitly-unwrapped optional that can still be
        // nil during early AppState init (and in test hosts), and reading
        // .dockTile through it then traps. NSApplication.shared is lazy
        // and safe even before the run loop is up.
        let dockTile = NSApplication.shared.dockTile
        if doNotDisturb || !showBadgeCountInDock {
            dockTile.badgeLabel = nil
        } else {
            let total = counts.values.reduce(0, +)
            dockTile.badgeLabel = total > 0 ? "\(total)" : nil
        }
    }
}
