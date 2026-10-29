import ChorusEngine
import SwiftUI
import TipKit

/// Where a tip's or the What's New sheet's "Show Me" button goes. AppState
/// carries it out (`AppState.perform(_:)`), so a tip and the sheet share one
/// route to each feature.
enum FeatureAction {
    case showLayouts
    case addMacApp
    case openQuickSwitcher
    case editSelectedService
}

/// Tips that point at features people miss. TipKit shows them one at a time,
/// at most one a day, and a tip goes away for good once it is closed or the
/// feature is used (`FeatureTips.markUsed`).
enum FeatureTips {
    struct Layout: Tip {
        var title: Text { Text("Try another layout") }
        var message: Text? { Text("Put your services in a bar along the top, or list every space down the left.") }
        var image: Image? { Image(systemName: "rectangle.split.3x1") }
        var actions: [Action] { [Action(id: "show", title: "Show Layouts")] }
    }

    struct MacApp: Tip {
        var title: Text { Text("Add a Mac app") }
        var message: Text? { Text("An app with no web version, like LINE, can sit here with the rest.") }
        var image: Image? { Image(systemName: "macwindow") }
        var actions: [Action] { [Action(id: "show", title: "Show Me")] }
    }

    struct QuickSwitcher: Tip {
        var title: Text { Text("Jump to any service") }
        var message: Text? { Text("Press ⌘K and type part of its name.") }
        var image: Image? { Image(systemName: "magnifyingglass") }
        var actions: [Action] { [Action(id: "show", title: "Try It")] }
    }

    struct ServiceSettings: Tip {
        var title: Text { Text("Settings for each service") }
        var message: Text? { Text("Right-click a service to mute it, or choose Edit Service to hide its badge or change its theme.") }
        var image: Image? { Image(systemName: "slider.horizontal.3") }
        var actions: [Action] { [Action(id: "show", title: "Show Me")] }
    }

    static let layout = Layout()
    static let macApp = MacApp()
    static let quickSwitcher = QuickSwitcher()
    static let serviceSettings = ServiceSettings()

    /// The tip that leads to an action, so taking the action retires it.
    static func tip(for action: FeatureAction) -> any Tip {
        switch action {
        case .showLayouts: return layout
        case .addMacApp: return macApp
        case .openQuickSwitcher: return quickSwitcher
        case .editSelectedService: return serviceSettings
        }
    }

    /// Retires the tip for a feature the user has now used.
    static func markUsed(_ action: FeatureAction) {
        tip(for: action).invalidate(reason: .actionPerformed)
    }

    #if DEBUG
    /// Debug-only switches, so the tips can be seen again without a new user.
    static let debugResetKey = "debugResetTips"
    static let debugShowAllKey = "debugShowAllTips"
    #endif

    /// Starts TipKit with its records in Chorus's own folder. The default
    /// location is shared by every app that takes it, the same trap the store
    /// fell into (see `StoreRelocation`). Debug builds keep their own.
    static func configure() {
        #if DEBUG
        let folder = URL.applicationSupportDirectory.appending(path: "Chorus-debug")
        #else
        let folder = URL.applicationSupportDirectory.appending(path: StoreRelocation.folderName)
        #endif
        let tipsFolder = folder.appending(path: "Tips")
        try? FileManager.default.createDirectory(at: tipsFolder, withIntermediateDirectories: true)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: debugResetKey) {
            try? Tips.resetDatastore()
        }
        #endif
        do {
            try Tips.configure([
                .displayFrequency(.daily),
                .datastoreLocation(.url(tipsFolder)),
            ])
        } catch {
            AppLogger.dataStore.error("TipKit failed to start: \(error.localizedDescription)")
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: debugShowAllKey) {
            Tips.showAllTipsForTesting()
        }
        #endif
    }

    /// Retires tips for what this install already shows it knows: a layout
    /// other than the default, or a Mac app already in the rail.
    static func retireKnown(railLayout: RailLayout, hasMacApps: Bool) {
        if railLayout != .sidebar { markUsed(.showLayouts) }
        if hasMacApps { markUsed(.addMacApp) }
    }
}

extension View {
    /// A feature tip as a popover on this view. "Show Me" retires the tip and
    /// carries out its action. `arrowEdge` is the side of this view the
    /// popover opens on: `.trailing` beside a side rail, `.bottom` under a bar.
    ///
    /// The popover hangs off a clear overlay the size of this view rather than
    /// the view itself. Before macOS 26 `popoverTip` takes no optional tip, and
    /// switching the modifier on and off would rebuild the view under it (a
    /// rail row, losing its focus and drag state); only the overlay comes and
    /// goes.
    func featureTip(_ action: FeatureAction, arrowEdge: Edge, isEnabled: Bool = true, appState: AppState) -> some View {
        overlay {
            if isEnabled {
                FeatureTipAnchor(action: action, arrowEdge: arrowEdge, appState: appState)
            }
        }
    }
}

/// The clear view a feature tip's popover hangs from. A switch, because
/// `popoverTip` needs the tip's concrete type to build its view. Clear is not
/// hit-tested, so clicks reach the control underneath; `allowsHitTesting(false)`
/// must not be added, because it also stops the popover from presenting.
private struct FeatureTipAnchor: View {
    let action: FeatureAction
    let arrowEdge: Edge
    let appState: AppState

    var body: some View {
        switch action {
        case .showLayouts: anchor(FeatureTips.layout)
        case .addMacApp: anchor(FeatureTips.macApp)
        case .openQuickSwitcher: anchor(FeatureTips.quickSwitcher)
        case .editSelectedService: anchor(FeatureTips.serviceSettings)
        }
    }

    private func anchor<T: Tip>(_ tip: T) -> some View {
        Color.clear
            .allowsHitTesting(false)
            .popoverTip(tip, arrowEdge: arrowEdge) { _ in
                appState.perform(action)
            }
    }
}
