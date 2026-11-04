import AppKit

/// Holds a quit back for about a second so every live page can save first. See
/// `AppState.releasePagesForQuit`.
@MainActor
final class ChorusAppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the main window appears. Until then there are no pages to
    /// release, and a quit goes straight through.
    weak var appState: AppState?

    /// Opens the main window, from SwiftUI's `openWindow`. The main window
    /// sets it when it first appears.
    var openMainWindow: (() -> Void)?

    /// A click on the Dock icon. AppKit only reopens a window when none is
    /// visible, and the parking lot's window (`WebViewParking`) always is, so
    /// Chorus brings the main window back itself.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let main = NSApp.windows.first { $0.identifier?.rawValue == "main" }
        if let main, main.isVisible { return true }
        if let main, main.isMiniaturized {
            main.deminiaturize(nil)
        } else {
            openMainWindow?()
        }
        return false
    }

    /// The handoff runs once. The second `terminate` it triggers, and any quit
    /// asked for while it runs, must not start it again.
    private var isReleasingPages = false

    /// Takes over the quit Apple Event that the Dock's Quit, a logout, Sparkle's
    /// installer and AppleScript send, so an open sheet is closed first (see
    /// `SheetQuit`). AppKit's own handler hands the quit to `terminate`, which a
    /// sheet blocks.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A test run is killed rather than quit, so it would read as a run
        // that never quit.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            QuitRecord.noteLaunch()
            PageStorageLog.trim()
        }
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
        let why = event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)).map(\.enumCodeValue)
        let reason = QuitRecord.Reason(quitEventReason: why)
        guard SheetQuit.hasSheet else {
            SheetQuit.quitWithNoSheet(reason: reason)
            return
        }
        let manager = NSAppleEventManager.shared()
        guard let suspension = manager.suspendCurrentAppleEvent() else {
            SheetQuit.quit(reason: reason)
            return
        }
        SheetQuit.quit(reason: reason) { quitting in
            if !quitting {
                reply.setParam(NSAppleEventDescriptor(int32: Int32(userCanceledErr)), forKeyword: keyErrorNumber)
            }
            manager.resume(withSuspensionID: suspension)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let start = ContinuousClock.now
        let reason = SheetQuit.reason ?? .other
        let pages = appState?.webViewPool.loadedCount ?? 0
        if !isReleasingPages { appState?.saveSelection() }
        guard let appState, !isReleasingPages, pages > 0 else {
            // A second quit during the wait lands here too, and its line
            // shows the wait was cut short.
            QuitRecord.noteQuit(reason: reason, pages: pages, wait: nil, since: start)
            return .terminateNow
        }
        isReleasingPages = true
        Task { @MainActor in
            let wait = await appState.releasePagesForQuit()
            QuitRecord.noteQuit(reason: reason, pages: pages, wait: wait, since: start)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
