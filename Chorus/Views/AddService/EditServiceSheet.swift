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
    @State private var mobileView: Bool = false
    @State private var forceDark: Bool = false
    @State private var blockAds: Bool = true
    @State private var customCSS: String = ""
    @State private var errorMessage: String?
    @State private var confirmingClearSession = false

    private var defaultCSS: String {
        ServiceCSSDefaults.css(forCatalogID: service.catalogEntryID) ?? ""
    }

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

                Toggle("Mobile view", isOn: $mobileView)
                    .help("Loads this service as if on an iPhone, so it serves its mobile web layout. Applied on save.")

                Toggle("Force dark mode", isOn: $forceDark)
                    .help("Inverts the page to force a dark appearance — for services with no dark theme of their own. Leave it off for services that already follow your Mac's light/dark setting.")

                if appState.contentBlockingEnabled {
                    Toggle("Block ads and trackers", isOn: $blockAds)
                        .help("Blocks known ad and tracking domains on this service. Turn it off if the service misbehaves with blocking on. Applied on save.")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(errorMessage)")
                }

                Divider()

                customCSSSection

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
            mobileView = service.userAgent == UserAgentProvider.mobileSafari
            forceDark = service.isForceDarkModeEnabled
            blockAds = !service.isContentBlockingDisabled
            // Prefill with the instance's own CSS, or the baked-in default so
            // the user can see and tweak what's already applied.
            customCSS = service.customCSS ?? defaultCSS
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

    @ViewBuilder
    private var customCSSSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Custom CSS")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $customCSS)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )
                .accessibilityLabel("Custom CSS")

            HStack {
                Spacer()

                Button("Reset to default") {
                    customCSS = defaultCSS
                }
                .disabled(customCSS == defaultCSS)
            }

            Text("Injected into the page. Leave blank to use the built-in default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveEdits() {
        switch AddServiceSheet.validatedCustomServiceInput(label: label, url: url) {
        case .invalid(let message):
            errorMessage = message
        case .valid(let validLabel, let validURL):
            let urlChanged = service.url != validURL

            // Collapse "blank" or "same as the default" to nil so the service
            // keeps tracking the built-in default instead of pinning a copy.
            let trimmed = customCSS.trimmingCharacters(in: .whitespacesAndNewlines)
            let newCSS: String?
            if trimmed.isEmpty || trimmed == defaultCSS.trimmingCharacters(in: .whitespacesAndNewlines) {
                newCSS = nil
            } else {
                newCSS = customCSS
            }
            // Force-dark is injected as part of the page CSS at web-view build
            // time, so a change to it needs the same rebuild as a CSS change.
            let darkChanged = service.isForceDarkModeEnabled != forceDark
            let cssChanged = (service.customCSS ?? "") != (newCSS ?? "") || darkChanged

            let newUserAgent: String? = mobileView ? UserAgentProvider.mobileSafari : nil
            let userAgentChanged = (service.userAgent ?? "") != (newUserAgent ?? "")

            // Content blocking is applied at web-view build time (like CSS), so a
            // change to the per-service opt-out needs a rebuild.
            let blockingDisabled = !blockAds
            let contentBlockingChanged = service.isContentBlockingDisabled != blockingDisabled

            service.label = validLabel
            service.url = validURL
            service.neverHibernate = keepLoaded
            service.customCSS = newCSS
            service.forceDarkMode = forceDark ? true : nil
            service.contentBlockingDisabled = blockingDisabled ? true : nil
            service.userAgent = newUserAgent

            appState.applyServiceEdits(
                serviceID: service.id,
                urlChanged: urlChanged,
                cssChanged: cssChanged,
                userAgentChanged: userAgentChanged,
                contentBlockingChanged: contentBlockingChanged
            )
            dismiss()
        }
    }
}
