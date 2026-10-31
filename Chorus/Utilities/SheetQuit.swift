import AppKit
import ChorusEngine

/// The one way Chorus quits. AppKit drops a quit while any window has a sheet
/// attached, before `applicationShouldTerminate` is asked, so ⌘Q, Quit from the
/// Dock or the menu bar, a logout, Sparkle's install-and-relaunch and the
/// restore relaunch all did nothing while Edit Service or the What's New sheet
/// was up.
///
/// SwiftUI runs its own `NSApplication` subclass and ignores `NSPrincipalClass`,
/// so `terminate` can't be overridden. Instead each way in calls this: the Quit
/// menu item, the menu bar extra, the quit Apple Event (`ChorusAppDelegate`),
/// Sparkle's relaunch (`UpdaterQuitDelegate`) and `AppState`'s restarts.
///
/// A SwiftUI sheet is closed the way a person closes it, with Escape. Ending it
/// through AppKit (`endSheet`) does not hold: SwiftUI still thinks it is showing
/// and attaches the same sheet again a moment later. AppKit's own sheets (a
/// page's `alert()`, the file picker) are ended directly if Escape fails, since
/// an alert with only an OK button ignores it.
enum SheetQuit {
    /// What the closing loop does next.
    enum Step: Equatable {
        /// No sheet left: quit.
        case quit
        /// Press Escape in every sheet and look again.
        case pressEscape
        /// Escape has not worked; also end the sheets AppKit owns.
        case pressEscapeAndEndAppKitSheets
        /// A sheet outlasted every try. Quitting now would be dropped.
        case giveUp
    }

    /// Tries, 100 ms apart. A field holding text takes the first Escape to
    /// clear itself; the bound keeps a sheet that ignores everything from
    /// holding the quit forever.
    static let maxTries = 20
    /// Tries with Escape alone before AppKit's own sheets are ended as well.
    static let escapeOnlyTries = 5
    private static let retryInterval: Duration = .milliseconds(100)
    /// How long to wait once the last sheet has gone. AppKit still drops a quit
    /// asked for while the sheet is animating away, and drops it silently.
    private static let settleTime: Duration = .milliseconds(400)

    /// Pure, so the rule can be tested without windows.
    static func step(sheetAttached: Bool, tries: Int) -> Step {
        guard sheetAttached else { return .quit }
        guard tries < maxTries else { return .giveUp }
        return tries < escapeOnlyTries ? .pressEscape : .pressEscapeAndEndAppKitSheets
    }

    /// Whether a quit asked for now starts one. Only one runs at a time: a
    /// second `terminate` while the first is saving pages would make
    /// `applicationShouldTerminate` answer `.terminateNow` and cut the save
    /// short. A second ⌘Q, or ⌘Q and then a logout, joins the first instead.
    static func startsQuit(alreadyQuitting: Bool) -> Bool {
        !alreadyQuitting
    }

    @MainActor private static var isQuitting = false

    /// What asked for the quit under way, for `QuitRecord`. Nil when nothing
    /// came through here, which leaves Sparkle's install.
    @MainActor private(set) static var reason: QuitRecord.Reason?

    /// Runs before any sheet is closed. Set by `ChorusAppDelegate` to clear the
    /// app's own prompts as unanswered: Escape on the camera question is
    /// Don't Allow, and that answer is remembered.
    @MainActor static var beforeClosingSheets: (() -> Void)?

    @MainActor
    static var hasSheet: Bool {
        NSApp.windows.contains { $0.attachedSheet != nil }
    }

    /// Closes every open sheet, then quits. What a sheet held unsaved is
    /// dropped, as a quit drops it. `finish` hears whether the quit went ahead,
    /// right before it does; a quit already under way counts as going ahead.
    @MainActor
    static func quit(reason: QuitRecord.Reason, finish: (@MainActor (_ quitting: Bool) -> Void)? = nil) {
        guard startsQuit(alreadyQuitting: isQuitting) else {
            finish?(true)
            return
        }
        isQuitting = true
        self.reason = reason
        beforeClosingSheets?()
        closeSheets { closed in
            finish?(closed)
            guard closed else {
                isQuitting = false
                self.reason = nil
                NSSound.beep()
                return
            }
            NSApp.terminate(nil)
        }
    }

    /// Quits at once, for a caller that knows no sheet is open and is not
    /// running inside a main-queue job (the quit Apple Event handler).
    @MainActor
    static func quitWithNoSheet(reason: QuitRecord.Reason) {
        guard startsQuit(alreadyQuitting: isQuitting) else { return }
        isQuitting = true
        self.reason = reason
        NSApp.terminate(nil)
    }

    /// Closes every open sheet, then runs `action` with whether they all went.
    /// Always on a later turn, never from inside the menu action or event that
    /// asked, where AppKit holds a quit back.
    ///
    /// `action` runs from the run loop rather than from this task. A quit
    /// waits in a nested run loop for the page-save handoff, which is itself a
    /// main-actor task, and a task already running on the main queue would
    /// keep that one from ever starting, so the app would hang.
    @MainActor
    static func closeSheets(then action: @escaping @MainActor (_ closed: Bool) -> Void) {
        Task { @MainActor in
            var tries = 0
            loop: while true {
                switch step(sheetAttached: hasSheet, tries: tries) {
                case .quit, .giveUp:
                    break loop
                case .pressEscape:
                    pressEscapeInSheets()
                case .pressEscapeAndEndAppKitSheets:
                    pressEscapeInSheets()
                    endAppKitSheets()
                }
                tries += 1
                try? await Task.sleep(for: retryInterval)
            }
            let closed = !hasSheet
            if !closed {
                AppLogger.general.error("A sheet stayed open through Escape; not quitting")
            } else if tries > 0 {
                try? await Task.sleep(for: settleTime)
            }
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { action(closed) }
            }
        }
    }

    /// The sheets stacked on `window`, outermost first.
    @MainActor
    static func sheetChain(of window: NSWindow) -> [NSWindow] {
        guard let sheet = window.attachedSheet else { return [] }
        return [sheet] + sheetChain(of: sheet)
    }

    /// Every open sheet, a sheet's own sheet before the sheet.
    @MainActor
    private static var sheetsInnermostFirst: [NSWindow] {
        NSApp.windows
            .filter { $0.sheetParent == nil }
            .flatMap { sheetChain(of: $0).reversed() }
    }

    @MainActor
    private static func pressEscapeInSheets() {
        for sheet in sheetsInnermostFirst {
            pressEscape(in: sheet)
        }
    }

    /// Ends the sheets AppKit runs itself: a page's alert, confirm or prompt
    /// (`NSAlert`) and the upload picker (`NSOpenPanel`). Their completion
    /// handlers see Cancel and answer the page. SwiftUI's own are left to
    /// Escape, since it puts them back.
    @MainActor
    private static func endAppKitSheets() {
        for sheet in sheetsInnermostFirst where isAppKitOwned(sheet) {
            sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
        }
    }

    @MainActor
    private static func isAppKitOwned(_ sheet: NSWindow) -> Bool {
        sheet is NSSavePanel || NSStringFromClass(type(of: sheet)).contains("Alert")
    }

    /// Escape as a key equivalent first, the way a real key press arrives, so a
    /// Cancel button takes it even while a text view holds focus; then as a key
    /// press, for a sheet whose Escape is handled by its first responder.
    @MainActor
    private static func pressEscape(in sheet: NSWindow) {
        let escape = "\u{1b}"
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber,
            context: nil,
            characters: escape,
            charactersIgnoringModifiers: escape,
            isARepeat: false,
            keyCode: 53
        ) else { return }
        if !sheet.performKeyEquivalent(with: event) {
            sheet.sendEvent(event)
        }
    }
}
