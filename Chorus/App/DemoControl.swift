#if DEBUG
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

    /// UserDefaults key naming a setup file. The next launch empties the
    /// Debug store and loads that file in its place, so a recording holds the
    /// demo's own services and nothing of the developer's:
    /// `defaults write com.nicojan.Chorus.debug debugDemoSetupPath /path/setup.json`.
    /// The launch clears the key before it reads the file, so a bad file
    /// costs one launch, not every launch.
    static let setupPathKey = "debugDemoSetupPath"

    /// Deletes every space, link and service, then imports `archive`. Links go
    /// first and explicitly: on macOS 14 a space's cascade leaves its links
    /// behind with `space` nulled.
    @MainActor
    static func replaceContents(of context: ModelContext, with archive: SetupArchive) throws -> SetupArchive.ImportSummary {
        try context.fetch(FetchDescriptor<SpaceServiceLink>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<Space>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<ServiceInstance>()).forEach(context.delete)
        try context.save()
        return try archive.apply(to: context)
    }

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

    /// Loads the setup file `DemoControl.setupPathKey` names, if one is set,
    /// in place of everything in the store. Runs before seeding, so a store
    /// it empties is not then filled with the default services.
    func loadDemoSetupIfAsked(defaults: UserDefaults = .standard) {
        guard let path = defaults.string(forKey: DemoControl.setupPathKey) else { return }
        defaults.removeObject(forKey: DemoControl.setupPathKey)
        do {
            let archive = try SetupArchive.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            let summary = try DemoControl.replaceContents(of: modelContainer.mainContext, with: archive)
            defaults.set(true, forKey: Self.hasEverHadDataKey)
            AppLogger.dataStore.notice("Demo setup loaded from \(path, privacy: .public): \(summary.servicesAdded) services")
        } catch {
            AppLogger.dataStore.error("Demo setup at \(path, privacy: .public) not loaded: \(error.localizedDescription, privacy: .public)")
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
