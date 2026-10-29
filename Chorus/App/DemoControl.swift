#if DEBUG
import ChorusEngine
import Foundation
import SwiftData

/// A Debug-only remote for scripted demo recordings. A script posts a
/// distributed notification named `notificationName` whose object is a command
/// line, and the running Debug build acts on it:
///
/// - `bumpBadge <service label>` raises that service's made-up count by one,
///   so the flash and the attention pulse happen on cue.
/// - `setRailLayout <sidebar|topBars|hybrid|allServices>` switches the layout
///   the way the Settings picker does.
///
/// None of this exists in a Release build.
enum DemoControl {
    static let notificationName = Notification.Name("com.nicojan.Chorus.debug.demoControl")

    /// UserDefaults switch that stops the six-second made-up count ticker, so
    /// a recording sees only the counts it asked for:
    /// `defaults write com.nicojan.Chorus.debug debugMockTickerOff -bool true`.
    static let tickerOffKey = "debugMockTickerOff"

    enum Command: Equatable {
        case bumpBadge(label: String)
        case setRailLayout(RailLayout)
    }

    /// Reads a command line: the verb, a space, and the rest as its argument.
    /// A label may itself hold spaces. Returns nil for anything it does not know.
    static func parse(_ line: String) -> Command? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let argument = parts[1].trimmingCharacters(in: .whitespaces)
        switch parts[0] {
        case "bumpBadge":
            return argument.isEmpty ? nil : .bumpBadge(label: argument)
        case "setRailLayout":
            return RailLayout(rawValue: argument).map(Command.setRailLayout)
        default:
            return nil
        }
    }
}

extension AppState {
    private static var demoControlToken: NSObjectProtocol?

    /// Starts listening for `DemoControl` commands. Safe to call each time the
    /// window's launch task runs: the second call finds the observer in place.
    func startDemoControl() {
        guard Self.demoControlToken == nil else { return }
        Self.demoControlToken = DistributedNotificationCenter.default().addObserver(
            forName: DemoControl.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let line = note.object as? String
            MainActor.assumeIsolated {
                guard let line, let command = DemoControl.parse(line) else {
                    AppLogger.general.notice("Demo control: ignored \(line ?? "<none>", privacy: .public)")
                    return
                }
                self?.perform(command)
            }
        }
    }

    private func perform(_ command: DemoControl.Command) {
        switch command {
        case .bumpBadge(let label):
            let services = (try? modelContainer.mainContext.fetch(FetchDescriptor<ServiceInstance>())) ?? []
            guard let service = services.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else {
                AppLogger.general.notice("Demo control: no service called \(label, privacy: .public)")
                return
            }
            badgeManager.bumpMockCount(for: service.id)
        case .setRailLayout(let layout):
            ensurePreferences().railLayoutRaw = layout.rawValue
            railLayout = layout
            modelContainer.mainContext.saveOrRollBack("demo control: rail layout")
        }
    }
}
#endif
