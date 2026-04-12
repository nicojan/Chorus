import SwiftUI
import SwiftData
import WebKit
import os

@Observable
final class AppState {
    let modelContainer: ModelContainer
    let webViewPool: WebViewPool
    let dataStoreManager: DataStoreManager
    let processPoolManager: ProcessPoolManager
    let userScriptManager: UserScriptManager

    var selectedSpaceID: UUID?
    var selectedServiceID: UUID?
    var showAddService = false

    private static let logger = Logger(subsystem: "com.nicojan.Chorus", category: "AppState")

    init() {
        let schema = Schema([
            ServiceInstance.self,
            Space.self,
            SpaceServiceLink.self,
            AppPreferences.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        self.dataStoreManager = DataStoreManager()
        self.processPoolManager = ProcessPoolManager()
        self.userScriptManager = UserScriptManager()
        self.webViewPool = WebViewPool(
            dataStoreManager: dataStoreManager,
            processPoolManager: processPoolManager,
            userScriptManager: userScriptManager
        )

        seedDefaultDataIfNeeded()
    }

    @MainActor
    private func seedDefaultDataIfNeeded() {
        let context = modelContainer.mainContext

        let descriptor = FetchDescriptor<Space>()
        let existingSpaces = (try? context.fetch(descriptor)) ?? []

        guard existingSpaces.isEmpty else {
            selectedSpaceID = existingSpaces.first?.id
            return
        }

        let space = Space(name: "General", emoji: "🌐", sortOrder: 0)
        context.insert(space)

        let defaultServices: [(String, String, String)] = [
            ("Gmail", "https://mail.google.com", "gmail"),
            ("Slack", "https://app.slack.com", "slack"),
            ("Discord", "https://discord.com/app", "discord"),
            ("ChatGPT", "https://chatgpt.com", "chatgpt"),
            ("Claude", "https://claude.ai", "claude"),
        ]

        for (index, (label, url, catalogID)) in defaultServices.enumerated() {
            let service = ServiceInstance(
                label: label,
                url: url,
                catalogEntryID: catalogID
            )
            context.insert(service)

            let link = SpaceServiceLink(
                sortOrder: index,
                space: space,
                service: service
            )
            context.insert(link)
        }

        do {
            try context.save()
            selectedSpaceID = space.id
            Self.logger.info("Seeded default space with \(defaultServices.count) services")
        } catch {
            Self.logger.error("Failed to seed default data: \(error.localizedDescription)")
        }
    }
}
