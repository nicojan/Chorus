import AppKit

/// Records input so destroying or detaching a page can give recent work time
/// to run. Hide waits in a background task after the app is already hidden;
/// switching waits behind the newly displayed page.
@MainActor
final class InputSettle {
    static let shared = InputSettle()

    /// Existing upper budget for recently started page work. This is a grace
    /// period, not confirmation that a site's server has saved a change.
    static let settleWindow: TimeInterval = 2.2

    private var lastInputAt = Date.distantPast
    private var lastDepartureAt = Date.distantPast
    private var monitor: Any?

    private init() {}

    /// Installs the monitor. Called at launch so a click is counted even when
    /// the first leave comes before anything has asked for a shared instance.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                // A shortcut such as Cmd-H or Cmd-R is the leave itself, not
                // the work being left; counting it would make every reload and
                // hide wait the full window.
                let isShortcut = event.modifierFlags.contains(.command)
                    || event.modifierFlags.contains(.control)
                if !isShortcut {
                    self?.lastInputAt = Date()
                }
            }
            return event
        }
    }

    /// Keep the cue's timestamp across transitions: quit just after hide or
    /// switch still owes time to work the earlier hover exit started.
    func recordDeparture() {
        lastDepartureAt = Date()
    }

    func waitForSettle() async {
        let remaining = Self.remainingWait(
            since: max(lastInputAt, lastDepartureAt),
            now: Date(),
            window: Self.settleWindow
        )
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
    }

    /// The wait the settle window calls for. Pure, so the arithmetic is
    /// testable without a clock or a page.
    nonisolated static func remainingWait(
        since lastInput: Date,
        now: Date,
        window: TimeInterval
    ) -> TimeInterval {
        max(0, window - now.timeIntervalSince(lastInput))
    }
}
