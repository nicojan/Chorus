import AppKit

/// Gives live pages a bounded save period before quit. See
/// `AppState.releasePagesForQuit`.
@MainActor
final class ChorusAppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the main window appears. Until then there are no pages to
    /// release, and a quit goes straight through.
    weak var appState: AppState?

    /// The handoff runs once. The second `terminate` it triggers, and any quit
    /// asked for while it runs, must not start it again.
    private var isReleasingPages = false

    /// Routes Cmd-H through the same departure policy as the app menu.
    private var hideKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Watching from launch means a click is counted even when the leave
        // that follows is the first thing to ask for a settle window.
        InputSettle.shared.start()
        patchHideMenuItem()
        Task { @MainActor [weak self] in
            // SwiftUI may build the app menu after launch; look once more.
            try? await Task.sleep(for: .milliseconds(500))
            self?.patchHideMenuItem()
        }
        hideKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let shortcutFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard shortcutFlags == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "h"
            else { return event }
            MainActor.assumeIsolated { self?.hideWithDeparture(nil) }
            return nil
        }
    }

    /// Points a standard Hide item at `hideWithDeparture` when SwiftUI left it as
    /// the system `hide:` action.
    private func patchHideMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        for item in appMenu.items where item.action == #selector(NSApplication.hide(_:)) {
            item.target = self
            item.action = #selector(hideWithDeparture(_:))
        }
    }

    @objc private func hideWithDeparture(_ sender: Any?) {
        WebViewDeparture.hideApplication()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
