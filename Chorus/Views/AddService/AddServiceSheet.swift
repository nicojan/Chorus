import SwiftUI
import SwiftData

struct AddServiceSheet: View {
    let spaceID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var selectedTab: AddServiceTab = .catalog
    @State private var customURL = ""
    @State private var customLabel = ""
    @State private var urlError: String?

    enum AddServiceTab: String, CaseIterable {
        case catalog = "Browse"
        case custom = "Custom URL"
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
            }
        }
        .frame(width: 520, height: 480)
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppCapabilities.passkeyUnavailableNotice)
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
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            CatalogGridView(
                searchText: searchText,
                spaceID: spaceID,
                onAdd: { dismiss() }
            )
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

    private func addCustomService() {
        switch Self.validatedCustomServiceInput(label: customLabel, url: customURL) {
        case .invalid(let error):
            urlError = error
            return
        case .valid(let label, let url):
            addCustomService(label: label, url: url)
        }
    }

    private func addCustomService(label: String, url: String) {
        guard let space = fetchSpace(id: spaceID) else { return }
        let existingCount = space.serviceLinks.count

        let service = ServiceInstance(
            label: label,
            url: url
        )
        modelContext.insert(service)

        let link = SpaceServiceLink(
            sortOrder: existingCount,
            space: space,
            service: service
        )
        modelContext.insert(link)

        do {
            try modelContext.save()
        } catch {
            AppLogger.dataStore.error("Failed to save custom service: \(error.localizedDescription)")
        }

        // Fetch favicon in background — capture ID before the await
        let serviceID = service.id
        let serviceURL = url
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

        dismiss()
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

    private func fetchSpace(id: UUID) -> Space? {
        let descriptor = FetchDescriptor<Space>(predicate: #Predicate { $0.id == id })
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            AppLogger.dataStore.error("Failed to fetch space: \(error.localizedDescription)")
            return nil
        }
    }
}
