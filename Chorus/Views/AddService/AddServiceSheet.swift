import SwiftUI
import SwiftData

struct AddServiceSheet: View {
    let spaceID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var selectedTab: AddServiceTab = .catalog
    @State private var customURL = ""
    @State private var customLabel = ""
    @State private var urlError: String?
    @State private var macAppError: String?
    /// Show the new service in every space instead of this one.
    @State private var showInEverySpace = false
    /// Give the new service its own sign-in instead of the shared one.
    @State private var keepSignInSeparate = false
    /// A service waiting on the "already here" question, and the name of the
    /// one it would share an account with.
    @State private var pendingAdd: PendingAdd?
    @State private var duplicateLabel = ""

    enum AddServiceTab: String, CaseIterable {
        case catalog = "Browse"
        case custom = "Custom URL"
        case macApp = "Mac App"
    }

    enum CustomServiceInputValidation: Equatable {
        case valid(label: String, url: String)
        case invalid(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Picker("", selection: $selectedTab) {
                ForEach(AddServiceTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Add service by")
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if !AppCapabilities.passkeysSupported {
                passkeyNotice
            }

            switch selectedTab {
            case .catalog:
                catalogContent
            case .custom:
                customURLContent
            case .macApp:
                macAppContent
            }

            Divider()
            placementOptions
        }
        .frame(width: 520, height: 520)
        .alert(
            "\(duplicateLabel) is already \(showInEverySpace ? "in every space" : "here")",
            isPresented: Binding(
                get: { pendingAdd != nil },
                set: { if !$0 { pendingAdd = nil } }
            ),
            presenting: pendingAdd
        ) { add in
            Button("Keep Separate") { make(add, separate: true) }
            Button("Share Sign-In") { make(add, separate: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Services \(showInEverySpace ? "in every space" : "in a space") share one sign-in, so a second \(duplicateLabel) would open the same account. To use another account, keep this one's sign-in separate.")
        }
        .onAppear {
            if let tab = appState.pendingAddServiceTab {
                selectedTab = tab
                appState.pendingAddServiceTab = nil
            }
        }
    }

    /// Calm, non-blocking heads-up that passkey sign-in won't work in-app yet.
    /// Shown for both catalog and custom adds. Gated by AppCapabilities so it
    /// disappears in one edit once the WebAuthn browser entitlement is granted.
    private var passkeyNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(AppCapabilities.passkeyUnavailableNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: ChorusRadius.control))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppCapabilities.passkeyUnavailableNotice)
    }

    /// Where the new service goes, and whether it shares the sign-in there.
    private var placementOptions: some View {
        HStack(spacing: 20) {
            Toggle("Show in every space", isOn: $showInEverySpace)
                .help("Adds it above the spaces, where it shows whichever space you are in.")
            Toggle("Keep its sign-in separate", isOn: $keepSignInSeparate)
                .help("Services in a space share one sign-in, so signing in once signs in the rest. Keep it separate to use another account.")
                // A Mac app has no sign-in to share.
                .disabled(selectedTab == .macApp)
            Spacer(minLength: 0)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack {
            Text("Add a service")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var catalogContent: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search services...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: ChorusRadius.control))
            .overlay(
                RoundedRectangle(cornerRadius: ChorusRadius.control)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            CatalogGridView(searchText: searchText) { entry in
                request(.catalog(entry))
            }
        }
    }

    private var customURLContent: some View {
        Form {
            TextField("Label", text: $customLabel, prompt: Text("My Service"))
                .textFieldStyle(.roundedBorder)

            TextField("URL", text: $customURL, prompt: Text("https://example.com"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: customURL) { urlError = nil }

            if let error = urlError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Add Service") {
                addCustomService()
            }
            .disabled(customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var macAppContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an app that has no web version. Chorus can't show its window inside a tab, so clicking it opens the app, and its unread count appears in the sidebar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose App…") { chooseMacApp() }
                .buttonStyle(.borderedProminent)
            if let macAppError {
                Text(macAppError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chooseMacApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let appURL = panel.url,
              let bundleID = Bundle(url: appURL)?.bundleIdentifier
        else { return }
        // Docking Chorus would move and hide its own window. Any build counts.
        guard !NativeApp.isChorus(bundleID: bundleID) else {
            macAppError = "Chorus can't hold itself in a tab."
            return
        }
        addMacApp(at: appURL, bundleID: bundleID)
        FeatureTips.markUsed(.addMacApp)
        appState.explainAccessibility(for: NativeApp.displayName(of: appURL))
    }

    private func addMacApp(at appURL: URL, bundleID: String) {
        let service = ServiceInstance(
            label: NativeApp.displayName(of: appURL),
            url: NativeApp.serviceURL(forBundleID: bundleID),
            customIconData: NativeApp.iconPNG(of: appURL),
            // A launcher has no page, so there is no passkey sign-in to warn about.
            hasSeenPasskeyNotice: true
        )
        // A Mac app has no cookies, so it keeps the store it was made with.
        insert(service, at: destination)
    }

    private func addCustomService() {
        switch Self.validatedCustomServiceInput(label: customLabel, url: customURL) {
        case .invalid(let error):
            urlError = error
            return
        case .valid(let label, let url):
            request(.custom(label: label, url: url))
        }
    }

    // MARK: - Adding

    /// A service the person has picked, before it is made.
    enum PendingAdd: Equatable {
        case catalog(ServiceCatalogEntry)
        case custom(label: String, url: String)

        var catalogEntryID: String? {
            if case .catalog(let entry) = self { return entry.id }
            return nil
        }

        var url: String {
            switch self {
            case .catalog(let entry): return entry.url
            case .custom(_, let url): return url
            }
        }
    }

    /// Where the checkboxes say the new service goes.
    private var destination: ServiceAdding.Destination {
        ServiceAdding.Destination(spaceID: spaceID, global: showInEverySpace, separate: keepSignInSeparate)
    }

    /// Adds the picked service, or first asks when the place it goes already
    /// has the same site on the sign-in it would share: the two would open
    /// the same account, which is rarely what a second copy is for.
    private func request(_ add: PendingAdd) {
        if let existing = ServiceAdding.sameSiteOnSharedStore(
            catalogEntryID: add.catalogEntryID,
            url: add.url,
            destination: destination,
            context: modelContext
        ) {
            duplicateLabel = existing.label
            pendingAdd = add
            return
        }
        make(add, separate: keepSignInSeparate)
    }

    private func make(_ add: PendingAdd, separate: Bool) {
        var place = destination
        place.separate = separate
        let service: ServiceInstance
        switch add {
        case .catalog(let entry):
            service = ServiceInstance(
                label: entry.name,
                url: entry.url,
                catalogEntryID: entry.id,
                userAgent: entry.userAgent,
                dataStoreIdentifier: ServiceAdding.store(for: place)
            )
        case .custom(let label, let url):
            service = ServiceInstance(label: label, url: url, dataStoreIdentifier: ServiceAdding.store(for: place))
        }
        guard insert(service, at: place) else { return }

        if case .catalog(let entry) = add {
            // Offer "always appear active" for presence services (Teams) so
            // backgrounding Chorus doesn't flip the user to away. Set before the
            // sheet dismisses; ContentView hosts the alert and shows it after.
            appState.offerPresenceActivationIfNeeded(serviceID: service.id, catalogEntryID: entry.id)
        }
        fetchFavicon(for: service.id, url: add.url)
    }

    /// Saves a new service in its place and switches to it. False when the
    /// save failed and nothing was added.
    @discardableResult
    private func insert(_ service: ServiceInstance, at place: ServiceAdding.Destination) -> Bool {
        modelContext.insert(service)
        guard ServiceAdding.place(service, at: place, context: modelContext),
              modelContext.saveOrRollBack("add service")
        else { return false }

        // Switch to the service just added. A global one shows in every space,
        // so the space stays as it is.
        if !place.global { appState.selectedSpaceID = spaceID }
        appState.selectedServiceID = service.id
        dismiss()
        return true
    }

    /// Fetches the favicon in the background. The service may be deleted in
    /// the meantime, so it is looked up again by id after the await.
    private func fetchFavicon(for serviceID: UUID, url serviceURL: String) {
        Task {
            let data = await FaviconFetcher.shared.fetchFavicon(for: serviceURL)
            guard let data else { return }
            let desc = FetchDescriptor<ServiceInstance>(predicate: #Predicate { $0.id == serviceID })
            guard let svc = try? modelContext.fetch(desc).first else { return }
            svc.fetchedIconData = data
            svc.faviconFetchedAt = Date()
            do {
                try modelContext.save()
            } catch {
                AppLogger.dataStore.error("Failed to save fetched favicon: \(error.localizedDescription)")
            }
        }
    }

    static func validatedCustomServiceInput(
        label rawLabel: String,
        url rawURL: String
    ) -> CustomServiceInputValidation {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            return .invalid("Label can't be empty")
        }

        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            return .invalid("URL must start with https:// or http://")
        }

        guard let host = components.host, !host.isEmpty else {
            return .invalid("URL must include a host")
        }

        var normalizedComponents = components
        normalizedComponents.scheme = scheme

        guard let url = normalizedComponents.url else {
            return .invalid("That doesn't look like a valid URL")
        }

        return .valid(label: label, url: url.absoluteString)
    }
}
