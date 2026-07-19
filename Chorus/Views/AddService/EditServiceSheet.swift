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
    @State private var darkMode: ServiceDarkMode = .auto
    @State private var notify: Bool = true
    @State private var osNotify: Bool = true
    @State private var badge: Bool = true
    @State private var customCSS: String = ""
    @State private var cameraPolicy: MediaPermissionPolicy = .ask
    @State private var microphonePolicy: MediaPermissionPolicy = .ask
    // The effective values the pickers opened at, so save only pins a policy the
    // user actually changed — editing an unrelated field must not silently pin
    // (and thus stop inheriting) the global default.
    @State private var initialCameraPolicy: MediaPermissionPolicy = .ask
    @State private var initialMicrophonePolicy: MediaPermissionPolicy = .ask
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

                Picker("Dark theme for this service", selection: $darkMode) {
                    Text("Auto").tag(ServiceDarkMode.auto)
                    Text("On").tag(ServiceDarkMode.on)
                    Text("Off").tag(ServiceDarkMode.off)
                }
                .pickerStyle(.segmented)
                .help("Auto follows the app-wide setting and skips services that already have a dark theme. On always applies one while the app is dark; Off never does.")

                if darkMode == .auto {
                    Button("Re-detect dark theme") {
                        appState.redetectDarkTheme(for: service.id)
                    }
                    .help("Check this service's own theme again and reload it. Use this after switching the service to its own dark theme, so Chorus stops applying Dark Reader on top.")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(errorMessage)")
                }

                Divider()

                notificationsSection

                Divider()

                cameraMicrophoneSection

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
            darkMode = service.darkMode
            notify = !service.isMuted
            osNotify = service.notifiesOSEffective
            badge = service.showBadge
            // Prefill with the instance's own CSS, or the baked-in default so
            // the user can see and tweak what's already applied.
            customCSS = service.customCSS ?? defaultCSS
            // Start the pickers at the EFFECTIVE policy (the service's own value,
            // else the global default), so what's shown is what applies. Saving
            // pins it on the service (consistent with the dark-theme picker).
            cameraPolicy = MediaPermissionResolver.effectivePolicy(
                serviceRaw: service.cameraPolicyRaw, globalRaw: appState.defaultCameraPolicy.rawValue)
            microphonePolicy = MediaPermissionResolver.effectivePolicy(
                serviceRaw: service.microphonePolicyRaw, globalRaw: appState.defaultMicrophonePolicy.rawValue)
            initialCameraPolicy = cameraPolicy
            initialMicrophonePolicy = microphonePolicy
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
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("Allow notifications", isOn: $notify)
                .help("The master switch for this service. Off silences its banners and badge.")

            Toggle("macOS notification banners", isOn: $osNotify)
                .disabled(!notify)
                .padding(.leading, 16)
                .help("Forward this service's alerts to macOS Notification Center.")

            Toggle("Badge count", isOn: $badge)
                .disabled(!notify)
                .padding(.leading, 16)
                .help("Show this service's unread count on its icon and in the Dock.")
        }
    }

    @ViewBuilder
    private var cameraMicrophoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera & microphone")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Camera", selection: $cameraPolicy) {
                ForEach(MediaPermissionPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            .help("Ask the first time this service wants your camera and remember the choice, always allow, or always deny.")

            Picker("Microphone", selection: $microphonePolicy) {
                ForEach(MediaPermissionPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            .help("Ask the first time this service wants your microphone and remember the choice, always allow, or always deny.")

            Text("Screen sharing is handled by macOS and isn't controlled here.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            // Dark theming applies live without a rebuild, so it's tracked
            // separately from CSS changes.
            let darkModeChanged = service.darkMode != darkMode
            let cssChanged = (service.customCSS ?? "") != (newCSS ?? "")

            let newUserAgent: String? = mobileView ? UserAgentProvider.mobileSafari : nil
            let userAgentChanged = (service.userAgent ?? "") != (newUserAgent ?? "")

            // Notification changes: mute and badge affect the dock/rail badge, so
            // they need an explicit refresh below — applyServiceEdits doesn't.
            let muted = !notify
            let muteChanged = service.isMuted != muted
            let badgeChanged = service.showBadge != badge

            service.label = validLabel
            service.url = validURL
            service.neverHibernate = keepLoaded
            service.customCSS = newCSS
            service.darkModeRaw = darkMode.rawValue
            service.forceDarkMode = nil          // retire the legacy flag
            // A different site may theme differently — drop the stale verdict.
            if urlChanged { service.detectedLacksDarkTheme = nil }
            service.userAgent = newUserAgent
            service.isMuted = muted
            service.osNotificationsEnabled = osNotify
            service.showBadge = badge
            // Pin a camera/mic policy only if the user actually changed it, so
            // opening the sheet to edit something else doesn't stop the service
            // from inheriting the global default. No rebuild needed — the value is
            // read at the next getUserMedia; applyServiceEdits saves the context.
            if cameraPolicy != initialCameraPolicy { service.cameraPolicy = cameraPolicy }
            if microphonePolicy != initialMicrophonePolicy { service.microphonePolicy = microphonePolicy }

            appState.applyServiceEdits(
                serviceID: service.id,
                urlChanged: urlChanged,
                cssChanged: cssChanged,
                userAgentChanged: userAgentChanged,
                darkModeChanged: darkModeChanged
            )
            if muteChanged || badgeChanged {
                appState.refreshBadgeState(for: service.id)
            }
            dismiss()
        }
    }
}
