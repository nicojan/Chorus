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

    /// Takes over the quit Apple Event that the Dock's Quit, a logout, Sparkle's
    /// installer and AppleScript send, so an open sheet is closed first (see
    /// `SheetQuit`). AppKit's own handler hands the quit to `terminate`, which a
    /// sheet blocks.
    func applicationDidFinishLaunching(_ notification: Notification) {
        SheetQuit.beforeClosingSheets = { [weak self] in
            self?.appState?.clearPromptsForQuit()
        }
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    /// With no sheet open, quits at once, as AppKit's handler does. With one,
    /// holds the event open while the sheets close, as AppKit holds it during
    /// a delayed quit, so a logout hears a refusal rather than waiting out its
    /// timeout on an app that said yes.
    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard SheetQuit.hasSheet else {
            SheetQuit.quitWithNoSheet()
            return
        }
        let manager = NSAppleEventManager.shared()
        guard let suspension = manager.suspendCurrentAppleEvent() else {
            SheetQuit.quit()
            return
        }
        SheetQuit.quit { quitting in
            if !quitting {
                reply.setParam(NSAppleEventDescriptor(int32: Int32(userCanceledErr)), forKeyword: keyErrorNumber)
            }
            manager.resume(withSuspensionID: suspension)
        }
    }

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
