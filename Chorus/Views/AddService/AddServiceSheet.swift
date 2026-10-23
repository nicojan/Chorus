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
    /// The service picked on the first page, now being placed on the second.
    /// Nil while still picking. See `AddServicePlacementPage`.
    @State private var configuring: PendingAdd?
    /// Why the last add failed, shown on the second page.
    @State private var addError: String?

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

            if let add = configuring {
                placementPage(for: add)
            } else {
                pickingPage
            }
        }
        .frame(width: 520, height: 480)
        .onAppear {
            if let tab = appState.pendingAddServiceTab {
                selectedTab = tab
                appState.pendingAddServiceTab = nil
            }
        }
    }

    /// The first page: find the service, in the catalog, by address, or as a
    /// Mac app.
    @ViewBuilder
    private var pickingPage: some View {
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
    }

    /// The second page: where the picked service goes and whose sign-in it
    /// uses, worked out from the store it would join.
    private func placementPage(for add: PendingAdd) -> some View {
        let store = ServiceAdding.store(for: ServiceAdding.Destination(spaceID: spaceID, global: showInEverySpace))
        let sharers = ServiceAdding.services(on: store, context: modelContext).map(\.label).sorted()
        let sameSite = add.isMacApp ? nil : ServiceAdding.sameSiteOnSharedStore(
            catalogEntryID: add.catalogEntryID,
            url: add.url,
            destination: ServiceAdding.Destination(spaceID: spaceID, global: showInEverySpace),
            context: modelContext
        )?.label
        return AddServicePlacementPage(
            serviceName: add.name,
            spaceName: spaceName,
            isMacApp: add.isMacApp,
            showInEverySpace: $showInEverySpace,
            keepSeparate: $keepSignInSeparate,
            sharers: sharers,
            sameSite: sameSite,
            isChat: ServiceAdding.isChat(catalogEntryID: add.catalogEntryID, url: add.url),
            error: addError,
            onBack: {
                configuring = nil
                addError = nil
            },
            onAdd: { commit(add) }
        )
    }

    private var spaceName: String {
        let id = spaceID
        let spaces = (try? modelContext.fetch(FetchDescriptor<Space>(predicate: #Predicate { $0.id == id }))) ?? []
        return spaces.first?.name ?? "this space"
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

    private var header: some View {
        HStack {
            Text(configuring == nil ? "Add a service" : "Where it goes")
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
        request(.macApp(appURL: appURL, bundleID: bundleID))
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
        guard insert(service, at: destination) else { return }
        FeatureTips.markUsed(.addMacApp)
        appState.explainAccessibility(for: NativeApp.displayName(of: appURL))
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
        case macApp(appURL: URL, bundleID: String)

        var catalogEntryID: String? {
            if case .catalog(let entry) = self { return entry.id }
            return nil
        }

        var url: String {
            switch self {
            case .catalog(let entry): return entry.url
            case .custom(_, let url): return url
            case .macApp(_, let bundleID): return NativeApp.serviceURL(forBundleID: bundleID)
            }
        }

        var name: String {
            switch self {
            case .catalog(let entry): return entry.name
            case .custom(let label, _): return label
            case .macApp(let appURL, _): return NativeApp.displayName(of: appURL)
            }
        }

        var isMacApp: Bool {
            if case .macApp = self { return true }
            return false
        }
    }

    /// Where the checkboxes say the new service goes.
    private var destination: ServiceAdding.Destination {
        ServiceAdding.Destination(spaceID: spaceID, global: showInEverySpace, separate: keepSignInSeparate)
    }

    /// Moves to the second page with the picked service. It starts in this
    /// space, on the shared sign-in, unless the same site is already on that
    /// sign-in: then a second copy is most likely a second account, so it
    /// starts on its own.
    private func request(_ add: PendingAdd) {
        showInEverySpace = false
        addError = nil
        keepSignInSeparate = !add.isMacApp && ServiceAdding.sameSiteOnSharedStore(
            catalogEntryID: add.catalogEntryID,
            url: add.url,
            destination: ServiceAdding.Destination(spaceID: spaceID),
            context: modelContext
        ) != nil
        configuring = add
    }

    /// Adds the service as the second page has it.
    private func commit(_ add: PendingAdd) {
        if case .macApp(let appURL, let bundleID) = add {
            addMacApp(at: appURL, bundleID: bundleID)
            return
        }
        make(add, separate: keepSignInSeparate)
    }

    private func make(_ add: PendingAdd, separate: Bool) {
        var place = destination
        place.separate = separate
        let store = ServiceAdding.store(for: place)
        Task {
            // A space's shared store, or the global one, may be waiting to be
            // removed since its last service went; ready it first. Nothing
            // awaits between this and the save, so the removal sees the claim.
            await appState.prepareStore(store)
            finishMaking(add, at: place, store: store)
        }
    }

    private func finishMaking(_ add: PendingAdd, at place: ServiceAdding.Destination, store: UUID) {
        let service: ServiceInstance
        switch add {
        case .catalog(let entry):
            service = ServiceInstance(
                label: entry.name,
                url: entry.url,
                catalogEntryID: entry.id,
                userAgent: entry.userAgent,
                dataStoreIdentifier: store
            )
        case .custom(let label, let url):
            service = ServiceInstance(label: label, url: url, dataStoreIdentifier: store)
        case .macApp:
            // Mac apps are added by `addMacApp`; nothing to make here.
            return
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
        guard ServiceAdding.place(service, at: place, context: modelContext) else {
            // The space went while the sheet was open. Take the unsaved
            // service back out, or the next save would keep it with no place.
            modelContext.rollback()
            addError = "Chorus couldn't add it: the space is gone."
            return false
        }
        guard modelContext.saveOrRollBack("add service") else {
            addError = "Chorus couldn't save the new service."
            return false
        }

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
