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
    var body: some View {
        Form {
            Text("More settings coming soon.")
                .foregroundStyle(.secondary)
        }
        .padding()
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
