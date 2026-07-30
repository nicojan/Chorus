import AppKit

/// Restarts Chorus. Used after the user picks a store to restore, because the
/// swap can only happen at launch, before the container opens.
enum AppRelauncher {
    /// How often the detached poller checks whether this process has exited.
    private static let pollIntervalSeconds = 0.2
    /// Total time to give this process to exit before giving up without
    /// relaunching. A hung shutdown is not hypothetical: the file-upload path
    /// (`WebViewCoordinator`) can show a modal `NSOpenPanel`, and a session
    /// pending in a nested run loop is a concrete way for termination to take
    /// longer than an ordinary quit.
    private static let totalWaitSeconds = 30.0
    /// The poller's iteration bound, derived from the two durations above
    /// rather than a bare number.
    private static var maxPolls: Int { Int((totalWaitSeconds / pollIntervalSeconds).rounded()) }

    /// Set once a relaunch has actually been spawned, so a second call —
    /// e.g. a second click on the picker's restore action before shutdown
    /// completes, since `NSApp.terminate` is asynchronous — cannot spawn a
    /// second poller. Two pollers would each independently see this process's
    /// PID gone and each `open` the bundle, putting two instances on the store
    /// the restore just put in place. Plain static state is safe here only
    /// because every access is `@MainActor`.
    @MainActor
    private static var scheduled = false

    /// Waits for this process to exit and then reopens the app bundle.
    ///
    /// The wait is the point. Reopening first would put a second Chorus on the
    /// same store, and both instances doing file-level work on one SQLite file
    /// is how stores get corrupted. A detached `sh` polls this PID and reopens
    /// ONLY on the branch where the PID is confirmed gone: giving up on the
    /// bound above runs no `open` at all. That's deliberate, not a missed
    /// case — the pending restore is durable in `UserDefaults`
    /// (`StoreRepair.applyPendingRestore` re-checks it on every launch), so
    /// declining to reopen costs at most one manual relaunch, while `open -n`
    /// bypasses LaunchServices' single-instance check and so would otherwise
    /// guarantee a second live instance rather than degrade to "activate the
    /// running app".
    ///
    /// `@MainActor` because it reads the main-actor-isolated `NSApp` global;
    /// the sole caller (`AppState.chooseStoreRestore`) is already `@MainActor`,
    /// so this adds no new constraint at the call site.
    ///
    /// Returns whether the poller was actually spawned. `false` means
    /// `Process.run()` itself failed (logged) and nothing was scheduled; the
    /// caller decides what that means for anything it already wrote.
    @MainActor
    @discardableResult
    static func relaunchAfterExit() -> Bool {
        guard !scheduled else { return true }
        scheduled = true

        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            // `exec` replaces the shell with `open` on the branch where the
            // PID is confirmed gone, ending the script there. Exhausting the
            // loop while the PID is still alive falls through to the end of
            // the script instead, opening nothing.
            "for i in $(seq 1 \(maxPolls)); do kill -0 \(pid) 2>/dev/null || { exec open -n -- \"$1\"; }; sleep \(pollIntervalSeconds); done",
            "sh",
            bundlePath,
        ]
        do {
            try task.run()
        } catch {
            AppLogger.dataStore.error("Could not schedule a relaunch: \(error.localizedDescription)")
            // Nothing was actually spawned, so a later retry must be able to
            // try again rather than being permanently blocked by this guard.
            scheduled = false
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}
