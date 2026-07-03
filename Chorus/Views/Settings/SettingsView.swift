import SwiftUI
import SwiftData
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Sparkle)
import Sparkle
#endif

struct SettingsView: View {
    #if canImport(Sparkle)
    let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
    }
    #else
    init() {}
    #endif

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            NotificationSettingsView()
                .tabItem {
                    Label("Notifications", systemImage: "bell")
                }

            PrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "lock")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 460)
    }

    @ViewBuilder
    private var aboutTab: some View {
        #if canImport(Sparkle)
        AboutSettingsView(updater: updater)
        #else
        AboutSettingsView()
        #endif
    }
}

struct GeneralSettingsView: View {
    @Query private var preferences: [AppPreferences]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    private let presenceManager = AppPresenceManager()

    private var prefs: AppPreferences {
        preferences.first ?? AppPreferences()
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Show Chorus in", selection: Binding(
                    get: { prefs.appPresenceMode },
                    set: { mode in
                        ensurePrefs().appPresenceMode = mode
                        presenceManager.apply(mode: mode)
                        save("app presence mode")
                    }
                )) {
                    Text("Dock only").tag(AppPresenceMode.dock)
                    Text("Menu bar only").tag(AppPresenceMode.menuBar)
                    Text("Both").tag(AppPresenceMode.both)
                }

                Toggle("Show badge count on Dock icon", isOn: Binding(
                    get: { prefs.showBadgeCountInDock },
                    set: { value in
                        ensurePrefs().showBadgeCountInDock = value
                        appState.badgeManager.showBadgeCountInDock = value
                        save("badge count in dock")
                    }
                ))
            }

            Section("Web Content") {
                Toggle("Automatically dismiss cookie banners", isOn: Binding(
                    get: { prefs.autoDismissCookieBanners },
                    set: { value in
                        ensurePrefs().autoDismissCookieBanners = value
                        appState.userScriptManager.autoDismissCookieBanners = value
                        save("cookie banner preference")
                    }
                ))
            }

            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { presenceManager.isLaunchAtLoginEnabled },
                    set: { presenceManager.setLaunchAtLogin($0) }
                ))
            }

            Section("Accessibility") {
                Picker("Default zoom", selection: Binding(
                    get: { prefs.defaultZoomEffective },
                    set: { value in
                        ensurePrefs().defaultZoom = value
                        appState.applyDefaultZoom(value)
                        save("default zoom")
                    }
                )) {
                    ForEach(Self.zoomLevels, id: \.self) { level in
                        Text("\(Int((level * 100).rounded()))%").tag(level)
                    }
                }
                Text("Applies to every service. Zoom a single service with ⌘- / ⌘+ to override this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static let zoomLevels: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5]

    private func save(_ context: String) {
        do {
            try modelContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save setting (\(context)): \(error.localizedDescription)")
        }
    }

    private func ensurePrefs() -> AppPreferences {
        if let existing = preferences.first { return existing }
        let newPrefs = AppPreferences()
        modelContext.insert(newPrefs)
        return newPrefs
    }
}

struct NotificationSettingsView: View {
    @Query private var services: [ServiceInstance]
    @Query private var preferences: [AppPreferences]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    private var prefs: AppPreferences {
        preferences.first ?? AppPreferences()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Do Not Disturb", isOn: Binding(
                    get: { appState.doNotDisturb },
                    set: { value in
                        appState.doNotDisturb = value
                        appState.refreshEffectiveDoNotDisturb()
                    }
                ))
                Text("Silences all badge counts and notification banners.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            scheduledDNDSection

            Section("Per-Service") {
                if services.isEmpty {
                    Text("No services added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    serviceTable
                    Text("Turning a service off silences its banners and badge — mute is the master switch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var serviceTable: some View {
        Grid(alignment: .center, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Service")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridColumnAlignment(.leading)
                Text("On").frame(width: 44)
                Text("macOS").frame(width: 52)
                Text("Badge").frame(width: 52)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            ForEach(services) { service in
                GridRow {
                    Text(service.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Toggle("", isOn: enabledBinding(service))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Notifications for \(service.label)")

                    Toggle("", isOn: macOSBinding(service))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(service.isMuted)
                        .accessibilityLabel("macOS notifications for \(service.label)")

                    Toggle("", isOn: badgeBinding(service))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(service.isMuted)
                        .accessibilityLabel("Badge count for \(service.label)")
                }
            }
        }
    }

    /// Master switch: on means not muted. Muting silences banners and badge.
    private func enabledBinding(_ service: ServiceInstance) -> Binding<Bool> {
        Binding(
            get: { !service.isMuted },
            set: { enabled in
                service.isMuted = !enabled
                save("toggle mute for \(service.label)")
                appState.refreshBadgeState(for: service.id)
            }
        )
    }

    private func macOSBinding(_ service: ServiceInstance) -> Binding<Bool> {
        Binding(
            get: { service.notifiesOSEffective },
            set: { enabled in
                service.osNotificationsEnabled = enabled
                save("toggle macOS notifications for \(service.label)")
            }
        )
    }

    private func badgeBinding(_ service: ServiceInstance) -> Binding<Bool> {
        Binding(
            get: { service.showBadge },
            set: { enabled in
                service.showBadge = enabled
                save("toggle badge for \(service.label)")
                appState.refreshBadgeState(for: service.id)
            }
        )
    }

    @ViewBuilder
    private var scheduledDNDSection: some View {
        Section("Quiet Hours") {
            Toggle("Do Not Disturb on a schedule", isOn: Binding(
                get: { appState.scheduledDNDEnabled },
                set: { value in
                    appState.scheduledDNDEnabled = value
                    let p = ensurePrefs()
                    p.scheduledDNDEnabled = value
                    if value {
                        // Seed the stored window from the current defaults so the
                        // pickers below have values to show.
                        if p.dndStartMinutes == nil { p.dndStartMinutes = appState.dndStartMinutes }
                        if p.dndEndMinutes == nil { p.dndEndMinutes = appState.dndEndMinutes }
                    }
                    appState.refreshEffectiveDoNotDisturb()
                    save("scheduled DND")
                }
            ))

            if appState.scheduledDNDEnabled {
                DatePicker("From", selection: timeBinding(
                    get: { appState.dndStartMinutes },
                    set: { appState.dndStartMinutes = $0; ensurePrefs().dndStartMinutes = $0 }
                ), displayedComponents: .hourAndMinute)

                DatePicker("To", selection: timeBinding(
                    get: { appState.dndEndMinutes },
                    set: { appState.dndEndMinutes = $0; ensurePrefs().dndEndMinutes = $0 }
                ), displayedComponents: .hourAndMinute)
            }

            Text("Silences badges and notification banners during these hours.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Bridges a minutes-since-midnight value to the Date a time-only DatePicker
    /// expects. Re-evaluates effective DND and saves on every change.
    private func timeBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: {
                var comps = DateComponents()
                comps.hour = get() / 60
                comps.minute = get() % 60
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                set((c.hour ?? 0) * 60 + (c.minute ?? 0))
                appState.refreshEffectiveDoNotDisturb()
                save("quiet hours time")
            }
        )
    }

    private func ensurePrefs() -> AppPreferences {
        if let existing = preferences.first { return existing }
        let newPrefs = AppPreferences()
        modelContext.insert(newPrefs)
        return newPrefs
    }

    private func save(_ context: String) {
        do {
            try modelContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save setting (\(context)): \(error.localizedDescription)")
        }
    }
}

struct PrivacySettingsView: View {
    @Query private var preferences: [AppPreferences]
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("App Lock") {
                Toggle("Require Touch ID or password", isOn: Binding(
                    get: { appState.appLockEnabled },
                    set: { value in
                        appState.appLockEnabled = value
                        ensurePrefs().appLockEnabled = value
                        save("app lock enabled")
                    }
                ))

                if appState.appLockEnabled {
                    Toggle("Lock on launch", isOn: Binding(
                        get: { appState.lockOnLaunch },
                        set: { value in
                            appState.lockOnLaunch = value
                            ensurePrefs().lockOnLaunch = value
                            save("lock on launch")
                        }
                    ))
                    Toggle("Lock when the Mac sleeps or the screen locks", isOn: Binding(
                        get: { appState.lockOnSleep },
                        set: { value in
                            appState.lockOnSleep = value
                            ensurePrefs().lockOnSleep = value
                            save("lock on sleep")
                        }
                    ))
                }

                Text("Uses Touch ID, with your login password as a fallback. Lock immediately from the File menu (⇧⌘L).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func ensurePrefs() -> AppPreferences {
        if let existing = preferences.first { return existing }
        let newPrefs = AppPreferences()
        modelContext.insert(newPrefs)
        return newPrefs
    }

    private func save(_ context: String) {
        do {
            try modelContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save setting (\(context)): \(error.localizedDescription)")
        }
    }
}

struct AboutSettingsView: View {
    #if canImport(Sparkle)
    let updater: SPUUpdater
    #endif

    private let repoURL = URL(string: "https://github.com/nicojan/Chorus")!
    private let licenseURL = URL(string: "https://github.com/nicojan/Chorus/blob/main/LICENSE")!
    private let authorURL = URL(string: "https://nicojan.com/")!

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    appIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chorus")
                            .font(.title2)
                            .bold()
                        Text(AppVersion.current)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                #if canImport(Sparkle)
                CheckForUpdatesView(updater: updater)
                #endif
            }

            Section {
                Link("GitHub Repository", destination: repoURL)
                Link("MIT License", destination: licenseURL)
            }

            Section {
                HStack(spacing: 4) {
                    Text("Built with")
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                    Text("by")
                    Link("Nico Jan", destination: authorURL)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var appIcon: some View {
        #if canImport(AppKit)
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 64, height: 64)
        }
        #endif
    }
}

/// Formats the app version for display. Kept as a pure helper (fed a bundle's
/// info dictionary) so it can be unit-tested without a running app.
enum AppVersion {
    static func string(from info: [String: Any]?) -> String {
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    static var current: String {
        string(from: Bundle.main.infoDictionary)
    }
}
