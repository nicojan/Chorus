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
        .frame(width: 450, height: 350)
    }
}

struct GeneralSettingsView: View {
    @Query private var preferences: [AppPreferences]
    @Environment(\.modelContext) private var modelContext

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
                        try? modelContext.save()
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
                        try? modelContext.save()
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

    var body: some View {
        Form {
            Section("Mute notifications per service") {
                if services.isEmpty {
                    Text("No services added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(services) { service in
                        Toggle(service.label, isOn: Binding(
                            get: { !service.isMuted },
                            set: { enabled in
                                service.isMuted = !enabled
                                try? modelContext.save()
                            }
                        ))
                    }
                }
            }
        }
        .padding()
    }
}
