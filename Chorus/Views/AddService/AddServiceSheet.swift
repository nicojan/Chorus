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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            switch selectedTab {
            case .catalog:
                catalogContent
            case .custom:
                customURLContent
            }
        }
        .frame(width: 520, height: 480)
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
                TextField("Search services...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
            .disabled(customLabel.isEmpty || customURL.isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func addCustomService() {
        let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("https://") else {
            urlError = "URL must start with https://"
            return
        }
        guard URL(string: trimmed) != nil else {
            urlError = "That doesn't look like a valid URL"
            return
        }

        guard let space = fetchSpace(id: spaceID) else { return }
        let existingCount = space.serviceLinks.count

        let service = ServiceInstance(
            label: customLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            url: trimmed
        )
        modelContext.insert(service)

        let link = SpaceServiceLink(
            sortOrder: existingCount,
            space: space,
            service: service
        )
        modelContext.insert(link)

        try? modelContext.save()
        dismiss()
    }

    private func fetchSpace(id: UUID) -> Space? {
        let descriptor = FetchDescriptor<Space>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }
}
