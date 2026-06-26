import SwiftUI
import SwiftData

/// Edits an existing service: rename, change its URL, toggle keep-loaded
/// (never hibernate), and clear its session (log out). Validation is shared
/// with AddServiceSheet so the same rules apply to created and edited services.
struct EditServiceSheet: View {
    let service: ServiceInstance

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @State private var label: String = ""
    @State private var url: String = ""
    @State private var keepLoaded: Bool = false
    @State private var errorMessage: String?
    @State private var confirmingClearSession = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit service")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Service name", text: $label)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Service name")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Address")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("https://example.com", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Service address")
                }

                Toggle("Keep loaded in the background", isOn: $keepLoaded)
                    .help("Never hibernate this service, so its notifications and calls keep working even when you're viewing something else. Uses more memory.")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(errorMessage)")
                }

                Divider()

                Button(role: .destructive) {
                    confirmingClearSession = true
                } label: {
                    Label("Clear session (log out)", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .help("Signs you out by clearing this service's cookies and storage. Its place in your spaces is kept.")
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Save") {
                    saveEdits()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 420)
        .onAppear {
            label = service.label
            url = service.url
            keepLoaded = service.neverHibernate
        }
        .confirmationDialog(
            "Log out of \(service.label)?",
            isPresented: $confirmingClearSession,
            titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) {
                appState.clearSession(for: service.id)
                dismiss()
            }
        } message: {
            Text("This clears this service's cookies and storage on this Mac. You'll need to sign in again.")
        }
    }

    private func saveEdits() {
        switch AddServiceSheet.validatedCustomServiceInput(label: label, url: url) {
        case .invalid(let message):
            errorMessage = message
        case .valid(let validLabel, let validURL):
            let urlChanged = service.url != validURL
            service.label = validLabel
            service.url = validURL
            service.neverHibernate = keepLoaded
            appState.applyServiceEdits(serviceID: service.id, urlChanged: urlChanged)
            dismiss()
        }
    }
}
