import Foundation
import AppKit

@MainActor
@Observable
final class BadgeManager {
    /// The true, unmasked unread count per service. Always reflects what the
    /// page actually reported — muting and the per-service show-badge toggle
    /// are applied as a *display mask* (see `maskedIDs`), never by zeroing the
    /// stored count. This keeps `rawCount` meaningful for adaptive polling and
    /// lets un-muting restore the badge instantly without waiting for a poll.
    private(set) var counts: [UUID: Int] = [:]

    /// Services whose badge is hidden because they are muted or have the
    /// show-badge toggle off. Their real count still lives in `counts`.
    private var maskedIDs: Set<UUID> = []

    var doNotDisturb: Bool = false {
        // Mirror into a thread-safe snapshot so the UNUserNotificationCenter
        // delegate can read Do Not Disturb from its callback without asserting
        // main-actor isolation (that callback isn't contractually main-thread;
        // an off-main read via MainActor.assumeIsolated would hard-crash).
        didSet { doNotDisturbSnapshot.value = doNotDisturb }
    }

    /// Off-main-safe mirror of `doNotDisturb`. See the property's didSet.
    nonisolated let doNotDisturbSnapshot = AtomicBool(false)

    var showBadgeCountInDock: Bool = true {
        didSet { updateDockBadge() }
    }

    var totalCount: Int {
        guard !doNotDisturb else { return 0 }
        return counts.reduce(0) { $0 + (maskedIDs.contains($1.key) ? 0 : $1.value) }
    }

    /// Returns the raw stored count regardless of DND or masking. Used by
    /// adaptive polling to compare deltas without any mask zeroing both sides.
    func rawCount(for instanceID: UUID) -> Int {
        counts[instanceID] ?? 0
    }

    func badgeCount(for instanceID: UUID) -> Int {
        guard !doNotDisturb, !maskedIDs.contains(instanceID) else { return 0 }
        return counts[instanceID] ?? 0
    }

    func aggregateCount(for serviceIDs: [UUID]) -> Int {
        guard !doNotDisturb else { return 0 }
        return serviceIDs.reduce(0) { sum, id in
            sum + (maskedIDs.contains(id) ? 0 : (counts[id] ?? 0))
        }
    }

    func updateBadge(for instanceID: UUID, count: Int, isMuted: Bool, showBadge: Bool = true) {
        // Clamp to a sane badge range. The DOM-badge path (catalog badgeJS) is
        // otherwise unbounded, so a page whose expression yields a negative or
        // garbage-large value would corrupt totalCount/aggregateCount — one
        // negative can zero out or hide the dock badge for every other service.
        let clamped = max(0, min(count, 999))
        // Always store the (clamped) true count; muting / show-badge only
        // toggles the display mask. Storing the real value (rather than 0) keeps
        // adaptive polling's delta detection correct for muted services and
        // makes un-muting instantaneous.
        counts[instanceID] = clamped
        if isMuted || !showBadge {
            maskedIDs.insert(instanceID)
        } else {
            maskedIDs.remove(instanceID)
        }
        updateDockBadge()
    }

    func removeBadge(for instanceID: UUID) {
        counts.removeValue(forKey: instanceID)
        maskedIDs.remove(instanceID)
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
            let total = totalCount
            dockTile.badgeLabel = total > 0 ? "\(total)" : nil
        }
    }
}

/// A minimal thread-safe boolean, so a value owned by a `@MainActor` type can
/// be read safely from a non-isolated context (e.g. a system delegate callback
/// that isn't guaranteed to run on the main thread).
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    init(_ value: Bool) { self._value = value }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
