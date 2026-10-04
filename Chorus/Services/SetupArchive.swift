import Foundation
import SwiftData

/// A file that carries a Chorus setup — its spaces, its services, which service
/// sits in which space, and each service's own settings — to another Mac, or
/// keeps it safe on this one.
///
/// It carries no sign-ins. A service's cookies and storage live in its WebKit
/// data store, which can't be moved, so every imported service gets a fresh
/// store and signs in again. App-wide settings stay out too: they belong to the
/// Mac, and a restore should not silently change them.
///
/// Import only ever adds. Spaces merge by name; every service comes in as a new
/// service, so importing a file twice gives two copies rather than touching
/// anything already here.
struct SetupArchive: Codable, Equatable {
    static let format = "chorus-setup"
    static let currentVersion = 1
    /// Plain JSON, so a person can read what the file holds before sharing it.
    static let suggestedFilename = "Chorus Setup.json"

    var format: String
    var version: Int
    var exportedAt: Date
    var appVersion: String?
    var spaces: [SpaceRecord]
    var services: [ServiceRecord]

    struct SpaceRecord: Codable, Equatable {
        var name: String
        var emoji: String
        var sortOrder: Int
        var isMuted: Bool?
        var members: [Member]
    }

    /// A service's place in a space: its index in `services`, and its order.
    struct Member: Codable, Equatable {
        var service: Int
        var sortOrder: Int
    }

    /// The `ServiceInstance` fields that travel. Everything stored on a service
    /// is either here or in `excludedServiceFields`, and a test holds the two
    /// to the schema, so a new stored field can't be left out by accident.
    struct ServiceRecord: Codable, Equatable {
        var label: String
        var url: String
        var catalogEntryID: String?
        var customIconData: Data?
        var isMuted: Bool
        var showBadge: Bool
        var neverHibernate: Bool
        var userAgent: String?
        var pageZoom: Double?
        var osNotificationsEnabled: Bool?
        var customCSS: String?
        var darkModeRaw: String?
        var openExternalLinksInApp: Bool?
        var stayActiveInBackground: Bool?
        var hibernationPolicyRaw: String?
        var hibernateAfterMinutes: Int?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case label, url, catalogEntryID, customIconData, isMuted, showBadge, neverHibernate
            case userAgent, pageZoom, osNotificationsEnabled, customCSS, darkModeRaw
            case openExternalLinksInApp
            case stayActiveInBackground, hibernationPolicyRaw, hibernateAfterMinutes
        }
    }

    /// Stored on a service but not exported, each for a reason:
    /// - `id`, `dataStoreIdentifier`: an import is a new service with its own
    ///   store; reusing either would collide with, or point at, another one.
    /// - `fetchedIconData`, `faviconFetchedAt`: a cache, fetched again.
    /// - `forceDarkMode`: the retired flag; `darkModeRaw` carries its meaning.
    /// - `hasSeenPasskeyNotice`: about this Mac's copy, not the service.
    /// - `createdAt`, `lastAccessedAt`: set fresh by the import.
    /// - `cameraPolicyRaw`, `microphonePolicyRaw`: a permission is granted by a
    ///   person on a Mac, not carried in a file. A file that could grant camera
    ///   access to an address of its choosing, under a familiar name and icon,
    ///   would be a way in. An imported service asks, as a new one does.
    /// - `mailtoHandlerTemplate`, `mailtoHandlerOrigin`, `mailtoHandlerEnabled`:
    ///   declarations belong to the signed-in instance, not a portable setup.
    ///   A new instance must discover its own handler.
    static let excludedServiceFields: Set<String> = [
        "id", "dataStoreIdentifier", "fetchedIconData", "faviconFetchedAt",
        "forceDarkMode", "hasSeenPasskeyNotice", "createdAt", "lastAccessedAt",
        "cameraPolicyRaw", "microphonePolicyRaw",
        "mailtoHandlerTemplate", "mailtoHandlerOrigin", "mailtoHandlerEnabled",
    ]

    // MARK: - Limits

    /// A setup file is small; one past these is not one Chorus wrote, and is
    /// refused before any of it reaches the store.
    enum Limit {
        static let fileBytes = 20 * 1024 * 1024
        static let spaces = 200
        static let services = 1000
        static let iconBytes = 1024 * 1024
        static let cssBytes = 256 * 1024
        static let textLength = 8192
        static let zoom: ClosedRange<Double> = 0.5...3.0
    }

    enum ReadError: LocalizedError, Equatable {
        case tooLarge
        case notASetupFile
        case newerVersion(Int)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return "The file is too large to be a Chorus setup."
            case .notASetupFile:
                return "Chorus doesn't recognize this as a setup file."
            case .newerVersion:
                return "A newer version of Chorus made this file. Update Chorus, then try again."
            case .invalid(let reason):
                return "The setup file is damaged: \(reason)."
            }
        }
    }

    // MARK: - What an import would add

    /// The services that will actually be added: those at least one space
    /// lists. A service no space lists would have nowhere to show.
    var listedServiceIndices: [Int] {
        Set(spaces.flatMap { $0.members.map(\.service) }).sorted()
    }

    /// The sites the import would open, so the person can see them before
    /// saying yes. A file can name a service "Slack" and point it anywhere.
    var hosts: [String] {
        var seen = Set<String>()
        return listedServiceIndices
            // A Mac app's address names an app on this Mac, not a site.
            .filter { NativeApp.bundleID(fromServiceURL: services[$0].url) == nil }
            .compactMap { URL(string: services[$0].url)?.host }
            .filter { seen.insert($0).inserted }
    }

    /// Whether any service brings its own CSS, which runs inside that site's
    /// pages and can change what they show.
    var hasCustomCSS: Bool {
        listedServiceIndices.contains { !(services[$0].customCSS ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Reading and writing

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Decodes and checks a file. Nothing in it is trusted: every count, size,
    /// index and address is checked here, so the import below can assume a
    /// well-formed archive.
    static func decode(_ data: Data) throws -> SetupArchive {
        guard data.count <= Limit.fileBytes else { throw ReadError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive: SetupArchive
        do {
            archive = try decoder.decode(SetupArchive.self, from: data)
        } catch {
            throw ReadError.notASetupFile
        }
        guard archive.format == format else { throw ReadError.notASetupFile }
        guard archive.version <= currentVersion else { throw ReadError.newerVersion(archive.version) }
        try archive.validate()
        return archive
    }

    private func validate() throws {
        guard spaces.count <= Limit.spaces else { throw ReadError.invalid("too many spaces") }
        guard services.count <= Limit.services else { throw ReadError.invalid("too many services") }
        for service in services {
            guard Self.isWebURL(service.url) || NativeApp.bundleID(fromServiceURL: service.url) != nil else { throw ReadError.invalid("a service has an address that isn't a web page") }
            guard service.label.count <= Limit.textLength, service.url.count <= Limit.textLength,
                  (service.userAgent?.count ?? 0) <= Limit.textLength
            else { throw ReadError.invalid("a service has a name or address longer than Chorus allows") }
            guard (service.customIconData?.count ?? 0) <= Limit.iconBytes else { throw ReadError.invalid("a service icon is too large") }
            guard (service.customCSS?.utf8.count ?? 0) <= Limit.cssBytes else { throw ReadError.invalid("a service's CSS is too large") }
        }
        for space in spaces {
            guard space.name.count <= Limit.textLength, space.emoji.count <= Limit.textLength
            else { throw ReadError.invalid("a space has a name longer than Chorus allows") }
            for member in space.members where !services.indices.contains(member.service) {
                throw ReadError.invalid("a space lists a service that isn't in the file")
            }
        }
    }

    /// http or https with a host, and no credentials in the address. A setup
    /// file is something people send each other; an address that signs in as
    /// someone, or opens a local file, has no business in one.
    static func isWebURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil
        else { return false }
        return true
    }

    // MARK: - From and into the store

    /// Captures the setup in `context`. Services in no space are left out,
    /// since there would be nowhere to show them after an import.
    @MainActor
    static func capture(from context: ModelContext, appVersion: String?, now: Date = Date()) throws -> SetupArchive {
        let spaces = try context.fetch(FetchDescriptor<Space>(sortBy: [SortDescriptor(\.sortOrder)]))
        let linksBySpace = try liveLinksBySpace(in: context)
        var records: [ServiceRecord] = []
        var indexByID: [UUID: Int] = [:]
        var spaceRecords: [SpaceRecord] = []

        for space in spaces {
            var members: [Member] = []
            for (sortOrder, service) in linksBySpace[space.id] ?? [] {
                let index: Int
                if let known = indexByID[service.id] {
                    index = known
                } else {
                    // A service whose address can't go in a file (not a web
                    // page) is left out rather than making the file unreadable.
                    guard let record = ServiceRecord(exporting: service) else { continue }
                    index = records.count
                    indexByID[service.id] = index
                    records.append(record)
                }
                members.append(Member(service: index, sortOrder: sortOrder))
            }
            spaceRecords.append(SpaceRecord(
                name: space.name, emoji: space.emoji, sortOrder: space.sortOrder,
                isMuted: space.isMuted, members: members
            ))
        }
        return SetupArchive(
            format: format, version: currentVersion, exportedAt: now,
            appVersion: appVersion, spaces: spaceRecords, services: records
        )
    }

    /// Every link whose two ends are still there, grouped by space and in
    /// order. Fetched rather than read through `Space.serviceLinks`, the
    /// inverse that can go stale (see `AppState.servicesForSpace`), and read
    /// through `liveEnds`, since a link left by a crash mid-delete can still
    /// hold a freed model.
    @MainActor
    private static func liveLinksBySpace(in context: ModelContext) throws -> [UUID: [(Int, ServiceInstance)]] {
        var grouped: [UUID: [(Int, ServiceInstance)]] = [:]
        for link in try context.fetch(FetchDescriptor<SpaceServiceLink>()) {
            guard let ends = link.liveEnds else { continue }
            grouped[ends.space.id, default: []].append((link.sortOrder, ends.service))
        }
        return grouped.mapValues { $0.sorted { $0.0 < $1.0 } }
    }

    struct ImportSummary: Equatable {
        var spacesAdded: Int
        var spacesMerged: Int
        var servicesAdded: Int
    }

    /// Adds the archive to `context`. Two saves, on purpose: the spaces and
    /// services commit first, and only then are the links between them built.
    /// A link made while either end is still pending is what trips macOS 14,
    /// and a link whose ends are both in the context is already registered, so
    /// it is inserted only when it isn't.
    ///
    /// If the second save fails, the first has already committed, and a
    /// rollback can't reach it. So the catch deletes what the import created
    /// and saves that, rather than leave empty spaces and services in no space
    /// that a retry would then add to a second time.
    @MainActor
    func apply(to context: ModelContext) throws -> ImportSummary {
        // Oldest first, so a store that already holds two spaces of one name
        // merges into the same one every time.
        let existing = try context.fetch(FetchDescriptor<Space>(sortBy: [SortDescriptor(\.sortOrder)]))
        var nextSpaceOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        var byName: [String: Space] = [:]
        for space in existing where byName[space.name] == nil {
            byName[space.name] = space
        }

        var summary = ImportSummary(spacesAdded: 0, spacesMerged: 0, servicesAdded: 0)
        var newSpaces: [Space] = []
        var targets: [Space] = []
        let orderedSpaces = spaces.sorted { $0.sortOrder < $1.sortOrder }
        for record in orderedSpaces {
            if let match = byName[record.name] {
                targets.append(match)
                if !newSpaces.contains(where: { $0 === match }) { summary.spacesMerged += 1 }
            } else {
                let space = Space(
                    name: record.name, emoji: record.emoji,
                    sortOrder: nextSpaceOrder, isMuted: record.isMuted ?? false
                )
                nextSpaceOrder += 1
                context.insert(space)
                byName[record.name] = space
                newSpaces.append(space)
                targets.append(space)
                summary.spacesAdded += 1
            }
        }
        var created: [Int: ServiceInstance] = [:]
        for index in listedServiceIndices {
            let service = services[index].makeService()
            context.insert(service)
            created[index] = service
        }
        summary.servicesAdded = created.count

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        do {
            let linksBySpace = try Self.liveLinksBySpace(in: context)
            var nextOrder: [UUID: Int] = [:]
            var linked: [UUID: Set<Int>] = [:]
            for (record, space) in zip(orderedSpaces, targets) {
                // Two records can merge into one space; each continues the order.
                var order = nextOrder[space.id] ?? ((linksBySpace[space.id]?.last?.0 ?? -1) + 1)
                for member in record.members.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    // A service listed twice in one space gets one link.
                    guard linked[space.id, default: []].insert(member.service).inserted,
                          let service = created[member.service] else { continue }
                    let link = SpaceServiceLink(sortOrder: order, space: space, service: service)
                    if link.modelContext == nil { context.insert(link) }
                    order += 1
                }
                nextOrder[space.id] = order
            }
            try context.save()
        } catch {
            context.rollback()
            created.values.forEach(context.delete)
            newSpaces.forEach(context.delete)
            try? context.save()
            throw error
        }
        return summary
    }
}

private extension SetupArchive.ServiceRecord {
    /// The record for one service, or nil when its address is not a web page.
    /// A login written into the address (`https://me:secret@nas.local`) is
    /// taken out: the file is something people share, and a password in it
    /// would travel with it. An import then refuses nothing Chorus wrote.
    init?(exporting service: ServiceInstance) {
        guard var components = URLComponents(string: service.url) else { return nil }
        components.user = nil
        components.password = nil
        guard let url = components.string,
              SetupArchive.isWebURL(url) || NativeApp.bundleID(fromServiceURL: url) != nil
        else { return nil }
        self.init(
            label: service.label,
            url: url,
            catalogEntryID: service.catalogEntryID,
            customIconData: service.customIconData,
            isMuted: service.isMuted,
            showBadge: service.showBadge,
            neverHibernate: service.neverHibernate,
            userAgent: service.userAgent,
            pageZoom: service.pageZoom,
            osNotificationsEnabled: service.osNotificationsEnabled,
            customCSS: service.customCSS,
            darkModeRaw: service.darkMode.rawValue,
            openExternalLinksInApp: service.openExternalLinksInApp,
            stayActiveInBackground: service.stayActiveInBackground,
            hibernationPolicyRaw: service.hibernationPolicyRaw,
            hibernateAfterMinutes: service.hibernateAfterMinutes
        )
    }

    /// A new service from the record, with its own id and data store.
    func makeService() -> ServiceInstance {
        ServiceInstance(
            label: label,
            url: url,
            customIconData: customIconData,
            catalogEntryID: catalogEntryID,
            isMuted: isMuted,
            showBadge: showBadge,
            neverHibernate: neverHibernate,
            userAgent: userAgent,
            pageZoom: pageZoom.map { min(max($0, SetupArchive.Limit.zoom.lowerBound), SetupArchive.Limit.zoom.upperBound) },
            osNotificationsEnabled: osNotificationsEnabled,
            customCSS: customCSS,
            darkModeRaw: darkModeRaw,
            openExternalLinksInApp: openExternalLinksInApp,
            stayActiveInBackground: stayActiveInBackground,
            hibernationPolicyRaw: hibernationPolicyRaw,
            hibernateAfterMinutes: hibernateAfterMinutes
        )
    }
}
