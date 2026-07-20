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
            Section("Dock & Menu Bar") {
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

            Section("Appearance") {
                Picker("Appearance", selection: Binding(
                    get: { prefs.appearanceMode },
                    set: { mode in
                        ensurePrefs().appearanceModeRaw = mode.rawValue
                        appState.appearanceMode = mode
                        save("appearance mode")
                        // Re-theme dark-opted-in services for the new appearance.
                        appState.applyEffectiveAppearanceChange()
                    }
                )) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker("Layout", selection: Binding(
                    get: { prefs.railLayout },
                    set: { layout in
                        ensurePrefs().railLayoutRaw = layout.rawValue
                        appState.railLayout = layout
                        save("rail layout")
                    }
                )) {
                    ForEach(RailLayout.allCases, id: \.self) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }

                Picker("Navigation buttons", selection: Binding(
                    get: { prefs.toolbarPosition },
                    set: { position in
                        appState.setToolbarPosition(position)
                    }
                )) {
                    ForEach(ToolbarPosition.allCases, id: \.self) { position in
                        Text(position.displayName).tag(position)
                    }
                }

                Toggle("Hide the spaces bar", isOn: Binding(
                    get: { prefs.hideSpacesUIEffective },
                    set: { value in
                        appState.setHideSpacesUI(value)
                    }
                ))

                Text("Hiding the bar only affects what you see. Switch spaces with ⌘K or Ctrl-Tab, or from the menu bar. Services in a space you aren't viewing stay out of the sidebar, so reach them with ⌘K.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Web Content") {
                Toggle("Accept cookie banners automatically", isOn: Binding(
                    get: { prefs.autoDismissCookieBanners },
                    set: { value in
                        ensurePrefs().autoDismissCookieBanners = value
                        appState.userScriptManager.autoDismissCookieBanners = value
                        save("cookie banner preference")
                    }
                ))
                Text("This accepts consent pop-ups for you. That includes advertising and tracking cookies, so turn it off to answer each site's banner yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Performance") {
                Toggle("Hibernate idle background services", isOn: Binding(
                    get: { prefs.autoHibernateIdleEnabledEffective },
                    set: { value in
                        appState.setAutoHibernateIdleEnabled(value)
                    }
                ))

                if prefs.autoHibernateIdleEnabledEffective {
                    Picker("After", selection: Binding(
                        get: { prefs.autoHibernateIdleMinutesEffective },
                        set: { value in
                            ensurePrefs().autoHibernateIdleMinutes = value
                            appState.autoHibernateIdleMinutes = value
                            save("auto-hibernate interval")
                        }
                    )) {
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                    }
                }

                Text("Frees the memory and CPU of a service you haven't opened in a while, releasing its process until you return. Chat apps (Slack, Teams, WhatsApp, and the like) stay live so their notifications still arrive the instant a message lands, even when many services are open. A hibernated service still refreshes its unread badge every few minutes, though that count only climbs until you open it again. Mark any service \"Keep Loaded\" to exempt it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        // Route creation through the single accessor so two first-time setters
        // (rapid toggles, or toggles across two Settings tabs) can't each insert
        // a duplicate row — a fresh fetch there sees pending inserts, unlike this
        // view's @Query, which refreshes a tick later.
        appState.ensurePreferences()
    }
}

struct NotificationSettingsView: View {
    @Query private var services: [ServiceInstance]
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
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
        let grouped = NotificationGrouping.grouped(spaces: spaces, services: services)
        return Grid(alignment: .center, horizontalSpacing: 12, verticalSpacing: 10) {
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

            ForEach(grouped.groups) { group in
                if grouped.showsHeaders {
                    GridRow {
                        Text(headerTitle(group))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                            .gridCellColumns(4)
                    }
                }

                ForEach(group.services) { service in
                    serviceRow(service)
                }
            }
        }
    }

    /// A space's "emoji  name", or "Ungrouped" for services in no space. The
    /// same service can appear under several space headers; every row binds to
    /// the same model object, so their toggles stay in sync.
    private func headerTitle(_ group: NotificationGrouping.Group) -> String {
        guard let space = group.space else { return "Ungrouped" }
        return "\(space.emoji)  \(space.name)"
    }

    @ViewBuilder
    private func serviceRow(_ service: ServiceInstance) -> some View {
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
        // Route creation through the single accessor so two first-time setters
        // (rapid toggles, or toggles across two Settings tabs) can't each insert
        // a duplicate row — a fresh fetch there sees pending inserts, unlike this
        // view's @Query, which refreshes a tick later.
        appState.ensurePreferences()
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

    private var prefs: AppPreferences {
        preferences.first ?? AppPreferences()
    }

    var body: some View {
        Form {
            Section("Service Icons") {
                Toggle("Ask Google for icons Chorus can't find", isOn: Binding(
                    get: { prefs.googleFaviconFallbackEnabledEffective },
                    set: { value in
                        appState.setGoogleFaviconFallbackEnabled(value)
                    }
                ))

                Text("Chorus fetches each service's icon from that service's own site. When a site serves none, this asks Google for one, which tells Google the hostname — including a private or self-hosted one. Off by default; services without an icon show their initial instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            Section("Content Blocking") {
                Toggle("Block ads and trackers", isOn: Binding(
                    get: { appState.contentBlockingEnabled },
                    set: { appState.setContentBlockingEnabled($0) }
                ))

                Text("Blocks known ad and tracking domains across your services. It won't remove ads a site serves from its own domain, so YouTube and Facebook ads still get through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Hide annoyances", isOn: Binding(
                    get: { appState.annoyanceBlockingEnabled },
                    set: { appState.setAnnoyanceBlockingEnabled($0) }
                ))

                Text("Hides cookie notices, newsletter pop-ups, floating share bars, and similar clutter. It's more aggressive than ad blocking and can occasionally hide something you wanted, so it's off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Camera & Microphone") {
                Picker("Camera", selection: Binding(
                    get: { appState.defaultCameraPolicy },
                    set: { appState.setDefaultCameraPolicy($0) }
                )) {
                    ForEach(MediaPermissionPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Microphone", selection: Binding(
                    get: { appState.defaultMicrophonePolicy },
                    set: { appState.setDefaultMicrophonePolicy($0) }
                )) {
                    ForEach(MediaPermissionPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.segmented)

                Text("The default for new services. \"Ask\" prompts the first time a service wants your camera or microphone and remembers the answer. Set a single service's own rule in its Edit sheet. Mute every live microphone at once with ⇧⌘M.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func ensurePrefs() -> AppPreferences {
        // Route creation through the single accessor so two first-time setters
        // (rapid toggles, or toggles across two Settings tabs) can't each insert
        // a duplicate row — a fresh fetch there sees pending inserts, unlike this
        // view's @Query, which refreshes a tick later.
        appState.ensurePreferences()
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
    private let blocklistURL = URL(string: "https://github.com/hagezi/dns-blocklists")!
    private let annoyanceListURL = URL(string: "https://easylist.to/")!
    private let darkReaderURL = URL(string: "https://github.com/darkreader/darkreader")!

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

            Section("Content blocking") {
                Text("Ad and tracker blocking uses the HaGezi DNS blocklist. Annoyance hiding uses Fanboy's Annoyance List from EasyList.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("HaGezi blocklists (GPL-3.0)", destination: blocklistURL)
                Link("EasyList / Fanboy Annoyance List", destination: annoyanceListURL)
            }

            Section("Dark theme") {
                Text("Per-service dark theming uses Dark Reader.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Dark Reader (MIT)", destination: darkReaderURL)
            }

            Section {
                HStack(spacing: 4) {
                    Text("Built with")
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .accessibilityHidden(true)
                    Text("by")
                    Link("Nico Jan", destination: authorURL)
                }
                .accessibilityElement(children: .combine)
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
                .accessibilityHidden(true)
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

/// Groups services by space for the per-service notifications list. Pure (fed
/// plain arrays) so the ordering and bucketing rules can be unit-tested without
/// a running app or a model container.
///
/// Rules: spaces appear in the caller's order (the view sorts by `sortOrder`);
/// within a space, services follow their link `sortOrder`; a service in several
/// spaces appears under each; services in no space fall into a trailing
/// "Ungrouped" bucket (`space == nil`), sorted by label. Spaces with no
/// services are skipped. When nothing is grouped — no spaces have members —
/// `showsHeaders` is false and a single flat, headerless bucket holds every
/// service, matching the pre-grouping layout.
enum NotificationGrouping {
    struct Group: Identifiable {
        /// The space, or `nil` for the ungrouped / flat bucket.
        let space: Space?
        let services: [ServiceInstance]

        var id: String { space?.id.uuidString ?? "ungrouped" }
    }

    struct Result {
        let groups: [Group]
        /// False only when no space has members, so the view renders a plain
        /// flat list with no space headers.
        let showsHeaders: Bool
    }

    static func grouped(spaces: [Space], services: [ServiceInstance]) -> Result {
        var spaceGroups: [Group] = []
        for space in spaces {
            let members = space.serviceLinks
                // Skip dangling links (a link whose Space or ServiceInstance was
                // deleted): materializing `.service` on a faulted model traps.
                // `.modelContext` is nil once deleted and safe to read.
                .filter { $0.modelContext != nil && $0.service.modelContext != nil }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.service)
            if !members.isEmpty {
                spaceGroups.append(Group(space: space, services: members))
            }
        }

        // No space has members → flat, headerless list of everything.
        guard !spaceGroups.isEmpty else {
            let flat = services.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            return Result(groups: [Group(space: nil, services: flat)], showsHeaders: false)
        }

        let ungrouped = services
            .filter { $0.spaceLinks.isEmpty }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        var groups = spaceGroups
        if !ungrouped.isEmpty {
            groups.append(Group(space: nil, services: ungrouped))
        }
        return Result(groups: groups, showsHeaders: true)
    }
}
