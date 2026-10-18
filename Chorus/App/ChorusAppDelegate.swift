import AppKit

/// Holds a quit back for about a second so every live page can save first. See
/// `AppState.releasePagesForQuit`.
@MainActor
final class ChorusAppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the main window appears. Until then there are no pages to
    /// release, and a quit goes straight through.
    weak var appState: AppState?

    /// The handoff runs once. The second `terminate` it triggers, and any quit
    /// asked for while it runs, must not start it again.
    private var isReleasingPages = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !isReleasingPages { appState?.saveSelection() }
        guard let appState, !isReleasingPages, appState.webViewPool.loadedCount > 0 else {
            return .terminateNow
        }
        isReleasingPages = true
        Task { @MainActor in
            await appState.releasePagesForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
