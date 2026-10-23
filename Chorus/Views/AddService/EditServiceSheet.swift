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
    /// Every service, for the sign-in picker's choices.
    @Query(sort: \ServiceInstance.label) private var allServices: [ServiceInstance]
    /// Spaces and memberships, for the shared sign-ins of the spaces this
    /// service is in.
    @Query(sort: \Space.sortOrder) private var spaces: [Space]
    @Query private var allLinks: [SpaceServiceLink]

    @State private var label: String = ""
    @State private var url: String = ""
    @State private var hibernationPolicy: HibernationPolicy = .followGlobal
    @State private var hibernateAfterMinutes: Int = 10
    @State private var mobileView: Bool = false
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
    /// The store this service's sign-in should use, a space's shared one or
    /// another service's, or nil for one of its own. See `SignInSharing`.
    @State private var signInTarget: UUID?
    @State private var initialSignInTarget: UUID?

    /// A Mac-app service has no page, so it gets only the settings that apply
    /// to a launcher: name, mute and badge.
    private var nativeBundleID: String? { service.nativeAppBundleID }

    /// How tall the settings may grow before they scroll: room for a short
    /// sheet to show whole, while a long one fits a 13-inch screen.
    static let settingsMaxHeight: CGFloat = 460

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

            // The settings scroll; the title row and Save stay put. A web
            // service's settings ran past the bottom of a laptop screen, and the
            // whole sheet was one long column with Save under the fold.
            ScrollView {
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
            }
            .frame(maxHeight: Self.settingsMaxHeight)

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
            Text(clearSessionMessage)
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
                // A service added by typing its address is only known when
                // its host matches a catalog entry, so a self-hosted
                // Mattermost hibernates like any other page and goes quiet.
                // Nothing said so before this.
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

        Toggle("Always appear active", isOn: $stayActive)
            .help("Keeps this service from showing you as away or idle while Chorus is in the background, so your status stays active even when you work in other apps. Useful for Microsoft Teams. May hold back some of this service's notifications, since it now thinks you're looking at it.")

        Picker("Dark theme for this service", selection: $darkMode) {
            Text("On").tag(ServiceDarkMode.on)
            Text("Off").tag(ServiceDarkMode.off)
        }
        .pickerStyle(.segmented)
        .help("On applies a dark theme to this service while the app is dark. Off never does.")

        signInSection

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

    /// One choice in the Sign-in picker.
    private struct SignInOption: Identifiable {
        /// The store it puts the service on; nil for one of its own.
        let store: UUID?
        let title: String
        /// How the note under the picker names it.
        let phrase: String
        var id: String { store?.uuidString ?? "own" }
    }

    /// The services that share this one's sign-in as saved now.
    private var currentPartners: [ServiceInstance] {
        SignInSharing.partners(of: service, among: allServices)
    }

    /// The shared sign-ins this service can join: those of the spaces it is
    /// in, the global one when it is global, and the one it is on now.
    private var sharedOptions: [SignInOption] {
        let memberSpaceIDs = Set(allLinks.compactMap(\.liveEnds).filter { $0.service.id == service.id }.map(\.space.id))
        var options = spaces
            .filter { $0.modelContext != nil && (memberSpaceIDs.contains($0.id) || $0.id == service.dataStoreIdentifier) }
            .map { space in
                SignInOption(
                    store: ServiceAdding.sharedStore(forSpace: space.id),
                    title: "Shared in \(space.name)",
                    phrase: "the sign-in \(space.name) shares"
                )
            }
        if service.isGlobalEffective || service.dataStoreIdentifier == ServiceAdding.globalStore {
            options.append(SignInOption(
                store: ServiceAdding.globalStore,
                title: "Shared by every-space services",
                phrase: "the sign-in every-space services share"
            ))
        }
        return options
    }

    /// Every choice: its own, the shared ones, then each other store some web
    /// service uses, named after the services on it. A Mac app has no cookies.
    private var signInOptions: [SignInOption] {
        let shared = sharedOptions
        let listed = Set(shared.compactMap(\.store))
        let others = allServices.filter {
            $0.id != service.id && $0.modelContext != nil && $0.nativeAppBundleID == nil && !listed.contains($0.dataStoreIdentifier)
        }
        let byStore = Dictionary(grouping: others, by: \.dataStoreIdentifier)
        let storeOptions = byStore
            .map { store, members -> SignInOption in
                let names = AppState.listed(members.map(\.label).sorted())
                return SignInOption(store: store, title: "Same as \(names)", phrase: "\(names)'s sign-in")
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let own = SignInOption(store: nil, title: "Its own", phrase: "a new sign-in of its own, signed out")
        return [own] + shared + storeOptions
    }

    /// Where the picker starts: the store it is on, when that is shared with
    /// anything or is a space's or the global one; otherwise its own.
    private var savedSignInTarget: UUID? {
        let current = service.dataStoreIdentifier
        let spaceIDs = Set(spaces.map(\.id))
        let shared = !currentPartners.isEmpty || SignInSharing.isSharedStore(current, spaceIDs: spaceIDs)
        return shared ? current : nil
    }

    @ViewBuilder
    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Sign-in", selection: $signInTarget) {
                ForEach(signInOptions) { option in
                    Text(option.title).tag(option.store)
                }
            }
            .help("Services on the same sign-in share cookies and storage, so signing in to one signs in the others. A service added to a space goes on that space's shared sign-in unless it is kept separate.")

            if let signInNote {
                Text(signInNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What saving the picker's choice will do, in the words that matter:
    /// which sign-in this service ends up on, and whether the one it has now
    /// is deleted. Nil when saving changes nothing and nothing needs saying.
    private var signInNote: String? {
        let partners = currentPartners.map(\.label)
        let partnerNames = AppState.listed(partners)
        let keep = partners.count == 1 ? "keeps" : "keep"
        let current = service.dataStoreIdentifier
        guard signInTarget != initialSignInTarget else {
            if !partners.isEmpty { return "Shares its sign-in with \(partnerNames)." }
            if let option = sharedOptions.first(where: { $0.store == current }) {
                return "Uses \(option.phrase). Services added there join it."
            }
            return nil
        }
        let phrase = signInOptions.first { $0.store == signInTarget }?.phrase ?? "another sign-in"
        if partners.isEmpty {
            return "Saving deletes this service's saved sign-in on this Mac and moves it to \(phrase)."
        }
        return "Saving moves this service to \(phrase). \(partnerNames) \(keep) the current one."
    }

    private var clearSessionMessage: String {
        let partners = currentPartners.map(\.label)
        guard !partners.isEmpty else {
            return "This clears this service's cookies and storage on this Mac. You'll need to sign in again."
        }
        return "This clears the cookies and storage this service shares with \(partners.joined(separator: ", ")), so all of them sign out on this Mac."
    }

    private func loadFields() {
        signInTarget = savedSignInTarget
        initialSignInTarget = signInTarget
        label = service.label
        url = service.url
        hibernationPolicy = service.hibernationPolicyEffective
        hibernateAfterMinutes = service.hibernateAfterMinutesEffective
        mobileView = service.userAgent == UserAgentProvider.mobileSafari
        initialUserAgent = service.userAgent
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
            guard signInTarget != initialSignInTarget else {
                dismiss()
                return
            }
            let target = signInTarget
            Task {
                if await appState.changeSignIn(for: service.id, toStore: target) {
                    dismiss()
                } else {
                    // The other changes are saved by now; only the sign-in failed.
                    errorMessage = "Chorus couldn't change the sign-in. Your other changes are saved."
                }
            }
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
