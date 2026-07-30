import AppKit

/// Restarts Chorus. Used after the user picks a store to restore, because the
/// swap can only happen at launch, before the container opens.
enum AppRelauncher {
    /// Waits for this process to exit and then reopens the app bundle.
    ///
    /// The wait is the point. Reopening first would put a second Chorus on the
    /// same store, and both instances doing file-level work on one SQLite file
    /// is how stores get corrupted. A detached `sh` polls this PID, so the
    /// reopen cannot start until this process is gone.
    ///
    /// `@MainActor` because it ends in `NSApp.terminate(nil)`, which AppKit
    /// requires to run on the main thread; the sole caller
    /// (`AppState.chooseStoreRestore`) is already `@MainActor`, so this adds no
    /// new constraint at the call site — it only removes the concurrency
    /// warning that a nonisolated function touching `NSApp` would otherwise get.
    @MainActor
    static func relaunchAfterExit() {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            // Bounded so a hung shutdown cannot leave this polling forever.
            "for i in $(seq 1 150); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done; " +
            "open -n \"$1\"",
            "sh",
            bundlePath,
        ]
        do {
            try task.run()
        } catch {
            AppLogger.general.error("Could not schedule a relaunch: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }
}
