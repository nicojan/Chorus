import SwiftUI
import SwiftData

struct SettingsView: View {
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
        }
        .frame(minWidth: 450, maxWidth: 450, minHeight: 350, maxHeight: 600)
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

                Toggle("Show badge count on dock icon", isOn: Binding(
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
        }
        .padding()
    }

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
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section {
                Toggle("Do Not Disturb", isOn: Binding(
                    get: { appState.doNotDisturb },
                    set: { value in
                        appState.doNotDisturb = value
                        appState.badgeManager.doNotDisturb = value
                        appState.badgeManager.updateDockBadge()
                    }
                ))
                Text("Suppresses all badge counts and notification banners.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                if services.isEmpty {
                    Text("No services added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(services) { service in
                        HStack {
                            Text(service.label)
                            Spacer()
                            Toggle("Notifications", isOn: Binding(
                                get: { !service.isMuted },
                                set: { enabled in
                                    service.isMuted = !enabled
                                    save("toggle mute for \(service.label)")
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Notifications for \(service.label)")
                        }
                    }
                }
            }

            Section("Badge Counts") {
                if services.isEmpty {
                    Text("No services added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(services) { service in
                        Toggle(service.label, isOn: Binding(
                            get: { service.showBadge },
                            set: { enabled in
                                service.showBadge = enabled
                                save("toggle badge for \(service.label)")
                            }
                        ))
                        .accessibilityLabel("Badge count for \(service.label)")
                    }
                }
            }
        }
        .padding()
    }

    private func save(_ context: String) {
        do {
            try modelContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save setting (\(context)): \(error.localizedDescription)")
        }
    }
}
