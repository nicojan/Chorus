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
    @State private var hibernationPolicy: HibernationPolicy = .followGlobal
    @State private var hibernateAfterMinutes: Int = 10
    @State private var mobileView: Bool = false
    @State private var handlesMailLinks: Bool = true
    /// The service's own outside-link choice; nil follows the Settings default.
    @State private var openLinksInApp: Bool? = nil
    @AppStorage(OutsideLinkDefault.defaultsKey) private var linksOpenInChorusByDefault = false
    @State private var stayActive: Bool = false
    @State private var darkMode: ServiceDarkMode = .off
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
    @State private var initialUserAgent: String?
    @State private var errorMessage: String?
    @State private var confirmingClearSession = false

    /// A Mac-app service has no page, so it gets only the settings that apply
    /// to a launcher: name, mute and badge.
    private var nativeBundleID: String? { service.nativeAppBundleID }

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

                if let nativeBundleID {
                    nativeAppRow(bundleID: nativeBundleID)
                    Divider()
                    notificationsSection
                } else {
                    webSettings
                }
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
            loadFields()
            FeatureTips.markUsed(.editSelectedService)
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

    /// Which app the service opens, read-only.
    private func nativeAppRow(bundleID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("App")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let appURL = NativeApp.appURL(bundleID: bundleID) {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text(appURL.path)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            } else {
                Text("Chorus can't find this app on this Mac (\(bundleID)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var webSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("https://example.com", text: $url)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Service address")
        }

        VStack(alignment: .leading, spacing: 6) {
            Picker("Hibernate", selection: $hibernationPolicy) {
                Text("Follow global setting").tag(HibernationPolicy.followGlobal)
                Text("When I switch to another service").tag(HibernationPolicy.immediate)
                Text("After a set idle time").tag(HibernationPolicy.after)
                Text("Never (keep loaded)").tag(HibernationPolicy.never)
            }
            .help("Chorus frees a service's memory and CPU while it runs in the background. The one you're viewing always stays loaded. \"Never\" also keeps calls and notifications working in the background, at the cost of more memory.")
            .disabled(service.isNotificationCritical)

            if hibernationPolicy == .after && !service.isNotificationCritical {
                Stepper(value: $hibernateAfterMinutes, in: 1...120) {
                    Text("Idle for \(hibernateAfterMinutes) minute\(hibernateAfterMinutes == 1 ? "" : "s")")
                }
                .accessibilityLabel("Hibernate after \(hibernateAfterMinutes) minutes idle")
            }

            if service.isNotificationCritical {
                Text("Chat apps stay loaded so their messages reach you the instant they arrive. This setting won't hibernate this one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if service.catalogEntryID == nil && hibernationPolicy != .never {
                // A service added by typing its address has no catalog
                // category, so `isNotificationCritical` is false for it
                // whatever it actually is — a self-hosted Mattermost or
                // a second Slack hibernates like any other page and goes
                // quiet. Nothing said so before this.
                Text("Chorus does not know what this service is, so it cannot keep it loaded the way it does a chat app from its list. While this one sleeps its notifications do not arrive, only its unread count. Pick Never if you need to hear from it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Toggle("Mobile view", isOn: $mobileView)
            .help("Loads this service as if on an iPhone, so it serves its mobile web layout. Applied on save.")

        Picker("Open outside links in", selection: $openLinksInApp) {
            Text(linksOpenInChorusByDefault ? "Follow global setting (Chorus window)" : "Follow global setting (browser)").tag(Bool?.none)
            Text("Chorus window").tag(Bool?.some(true))
            Text("Browser").tag(Bool?.some(false))
        }
        .help("Where a link opens when it points somewhere no Chorus service covers. A link that another service covers still switches to that service.")

        if service.mailtoHandler != nil {
            Toggle("Use for mail links", isOn: $handlesMailLinks)
                .help("Offer this signed-in service when Chorus opens a mail link. Chorus keeps its declaration when this is off, so you can enable it again later.")
        }

        Toggle("Always appear active", isOn: $stayActive)
            .help("Keeps this service from showing you as away or idle while Chorus is in the background, so your status stays active even when you work in other apps. Useful for Microsoft Teams. May hold back some of this service's notifications, since it now thinks you're looking at it.")

        Picker("Dark theme for this service", selection: $darkMode) {
            Text("On").tag(ServiceDarkMode.on)
            Text("Off").tag(ServiceDarkMode.off)
        }
        .pickerStyle(.segmented)
        .help("On applies a dark theme to this service while the app is dark. Off never does.")

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

    private func loadFields() {
        label = service.label
        url = service.url
        hibernationPolicy = service.hibernationPolicyEffective
        hibernateAfterMinutes = service.hibernateAfterMinutesEffective
        mobileView = service.userAgent == UserAgentProvider.mobileSafari
        initialUserAgent = service.userAgent
        handlesMailLinks = service.mailtoHandlerEnabledEffective
        openLinksInApp = service.openExternalLinksInApp
        stayActive = service.staysActiveInBackgroundEffective
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

    @ViewBuilder
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("Allow notifications", isOn: $notify)
                .help("The master switch for this service. Off silences its banners and badge.")

            // A Mac app posts its own banners; Chorus has none to forward.
            if nativeBundleID == nil {
                Toggle("macOS notification banners", isOn: $osNotify)
                    .disabled(!notify)
                    .padding(.leading, 16)
                    .help("Forward this service's alerts to macOS Notification Center.")
            }

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
                    RoundedRectangle(cornerRadius: ChorusRadius.control)
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
        if nativeBundleID != nil {
            saveNativeAppEdits()
            return
        }
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

            // Only the Mobile-view toggle drives the UA here. Rewrite it only when
            // that toggle actually changed, so a custom (non-mobile) user-agent set
            // elsewhere — e.g. a future catalog default — isn't wiped by an
            // unrelated edit. Mirrors the camera/mic initial-value guards below.
            let wasMobile = initialUserAgent == UserAgentProvider.mobileSafari
            let userAgentChanged = mobileView != wasMobile

            // Notification changes: mute and badge affect the dock/rail badge, so
            // they need an explicit refresh below — applyServiceEdits doesn't.
            let muted = !notify
            let muteChanged = service.isMuted != muted
            let badgeChanged = service.showBadge != badge

            // The focus override is baked at web-view build time, so a change
            // needs a rebuild — tracked like the CSS change.
            let presenceChanged = service.staysActiveInBackgroundEffective != stayActive

            service.label = validLabel
            service.url = validURL
            service.hibernationPolicyRaw = hibernationPolicy.rawValue
            service.hibernateAfterMinutes = hibernateAfterMinutes
            // Keep the legacy flag in sync so the pool's never-hibernate fast path
            // and any older build reading the store still honor "keep loaded".
            service.neverHibernate = (hibernationPolicy == .never)
            service.customCSS = newCSS
            service.darkModeRaw = darkMode.rawValue
            service.forceDarkMode = nil          // retire the legacy flag
            if userAgentChanged {
                service.userAgent = mobileView ? UserAgentProvider.mobileSafari : nil
            }
            service.isMuted = muted
            service.osNotificationsEnabled = osNotify
            service.showBadge = badge
            // Read fresh at each link click, so no rebuild is needed.
            service.openExternalLinksInApp = openLinksInApp
            if service.mailtoHandler != nil {
                service.mailtoHandlerEnabled = handlesMailLinks
            }
            service.stayActiveInBackground = stayActive
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
                darkModeChanged: darkModeChanged,
                presenceChanged: presenceChanged
            )
            if muteChanged || badgeChanged {
                appState.refreshBadgeState(for: service.id)
            }
            dismiss()
        }
    }

    /// A Mac-app service keeps its `chorus-app://` address, which the web URL
    /// check would reject, so it saves only the fields its sheet shows.
    private func saveNativeAppEdits() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            errorMessage = "Label can't be empty"
            return
        }
        service.label = trimmedLabel
        service.isMuted = !notify
        service.showBadge = badge
        do {
            try modelContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save Mac app service: \(error.localizedDescription)")
        }
        appState.refreshBadgeState(for: service.id)
        dismiss()
    }
}
