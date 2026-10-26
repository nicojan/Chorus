import Foundation
import SwiftData

/// A file that carries a Chorus setup — its spaces, its services, which service
/// sits in which space or is global, and each service's own settings — to
/// another Mac, or keeps it safe on this one.
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
    /// Indexes into `services` of the global services, in rail order. Optional
    /// and not a version bump: an older Chorus ignores the key it does not know,
    /// and a file without it (every file before this) reads as no globals.
    var globalServices: [Int]?
    /// Groups of indexes into `services` that share one sign-in (issue #39),
    /// each group two or more. Optional for the same reason as
    /// `globalServices`. The sign-in itself never travels; an import gives
    /// each group one fresh store, so signing in once on the new Mac signs
    /// in the whole group.
    var sharedSignIns: [[Int]]?

    struct SpaceRecord: Codable, Equatable {
        var name: String
        var emoji: String
        var sortOrder: Int
        var isMuted: Bool?
        var members: [Member]
        /// The space's service groups, each two or more of its members.
        /// Optional, so a file from before groups reads as none.
        var groups: [GroupRecord]?
    }

    /// A group of services in one space: its name (nil for none) and the
    /// indexes into `services` of its members, in rail order.
    struct GroupRecord: Codable, Equatable {
        var name: String?
        var members: [Int]
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
    /// - `isGlobal`, `globalSortOrder`: a global service is carried by the
    ///   file's `globalServices` list, whose order sets `globalSortOrder` again
    ///   on import, after the globals already here.
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
    static let excludedServiceFields: Set<String> = [
        "isGlobal", "globalSortOrder",
        "id", "dataStoreIdentifier", "fetchedIconData", "faviconFetchedAt",
        "forceDarkMode", "hasSeenPasskeyNotice", "createdAt", "lastAccessedAt",
        "cameraPolicyRaw", "microphonePolicyRaw",
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
    /// lists, and the global ones. A service that is neither would have nowhere
    /// to show.
    var listedServiceIndices: [Int] {
        Set(spaces.flatMap { $0.members.map(\.service) } + (globalServices ?? [])).sorted()
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

    /// The Mac apps the import would dock, by bundle id. They are left out of
    /// `hosts`, so they are named on their own.
    var macApps: [String] {
        var seen = Set<String>()
        return listedServiceIndices
            .compactMap { NativeApp.bundleID(fromServiceURL: services[$0].url) }
            .filter { seen.insert($0).inserted }
    }

    /// Whether any service brings CSS that the import will keep, which runs
    /// inside that site's pages and can change what they show.
    var hasCustomCSS: Bool {
        listedServiceIndices.contains { Self.importableCSS(services[$0].customCSS) != nil }
    }

    /// Imported CSS, or nil when there is none or it could reach outside the
    /// page. A setup file can come from anyone and can point a service at a site
    /// the user trusts, so its CSS runs on their signed-in session. CSS that
    /// loads a resource can send what the page holds elsewhere
    /// (`input[value^="a"] { background: url(https://…/a) }`), so any CSS that
    /// loads something is dropped. A backslash goes too: CSS escapes
    /// (`\75 rl(`) would hide the same calls from the check.
    static func importableCSS(_ css: String?) -> String? {
        guard let css, !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lowered = css.lowercased()
        let loads = ["url(", "src(", "image(", "image-set(", "cross-fade(", "@import", "\\"]
        return loads.contains { lowered.contains($0) } ? nil : css
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
            // Docking Chorus inside itself resizes its own window in a loop and
            // hides it on every switch. Adding by hand refuses it too.
            if let bundleID = NativeApp.bundleID(fromServiceURL: service.url), NativeApp.isChorus(bundleID: bundleID) {
                throw ReadError.invalid("a service is Chorus itself")
            }
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
            let spaceMembers = Set(space.members.map(\.service))
            let globals = Set(globalServices ?? [])
            var grouped = Set<Int>()
            for group in space.groups ?? [] {
                guard group.members.count >= 2 else { throw ReadError.invalid("a group has fewer than two services") }
                guard (group.name?.count ?? 0) <= Limit.textLength else { throw ReadError.invalid("a group has a name longer than Chorus allows") }
                for index in group.members {
                    guard services.indices.contains(index) else { throw ReadError.invalid("a group lists a service that isn't in the file") }
                    guard spaceMembers.contains(index) else { throw ReadError.invalid("a group lists a service that isn't in its space") }
                    guard !globals.contains(index) else { throw ReadError.invalid("a group lists a global service") }
                    guard grouped.insert(index).inserted else { throw ReadError.invalid("a service is in more than one group") }
                }
            }
        }
        for index in globalServices ?? [] where !services.indices.contains(index) {
            throw ReadError.invalid("the global list names a service that isn't in the file")
        }
        let sharedIndices = Array((sharedSignIns ?? []).joined())
        for index in sharedIndices where !services.indices.contains(index) {
            throw ReadError.invalid("a shared sign-in names a service that isn't in the file")
        }
        // A service sits in one group at most; two groups naming it would
        // leave it in whichever came last and quietly split the first.
        guard Set(sharedIndices).count == sharedIndices.count else {
            throw ReadError.invalid("a service is in more than one shared sign-in")
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

    /// Captures the setup in `context`. Services that are in no space and not
    /// global are left out, since there would be nowhere to show them after an
    /// import.
    @MainActor
    static func capture(from context: ModelContext, appVersion: String?, now: Date = Date()) throws -> SetupArchive {
        let spaces = try context.fetch(FetchDescriptor<Space>(sortBy: [SortDescriptor(\.sortOrder)]))
        let linksBySpace = try liveLinksBySpace(in: context)
        // A link's group counts only when its row exists and sits in the
        // same space.
        var groupInfo: [UUID: (spaceID: UUID, name: String?)] = [:]
        for group in try context.fetch(FetchDescriptor<ServiceGroup>()) where !group.isDeleted {
            groupInfo[group.id] = (group.spaceID, group.name)
        }
        var records: [ServiceRecord] = []
        var indexByID: [UUID: Int] = [:]
        var spaceRecords: [SpaceRecord] = []
        var storeByIndex: [Int: UUID] = [:]

        for space in spaces {
            var members: [Member] = []
            var groupMembers: [UUID: [Int]] = [:]
            var groupOrder: [UUID] = []
            for (sortOrder, service, group) in linksBySpace[space.id] ?? [] {
                let index: Int
                if let known = indexByID[service.id] {
                    index = known
                } else {
                    // A service whose address can't go in a file (not a web
                    // page) is left out rather than making the file unreadable.
                    guard let record = ServiceRecord(exporting: service) else { continue }
                    index = records.count
                    indexByID[service.id] = index
                    storeByIndex[index] = service.dataStoreIdentifier
                    records.append(record)
                }
                members.append(Member(service: index, sortOrder: sortOrder))
                if let group, groupInfo[group]?.spaceID == space.id {
                    if groupMembers[group] == nil { groupOrder.append(group) }
                    groupMembers[group, default: []].append(index)
                }
            }
            // Whole groups only: one left with fewer than two exported
            // members is not a group.
            let groupRecords = groupOrder.compactMap { id -> GroupRecord? in
                guard let list = groupMembers[id], list.count >= 2 else { return nil }
                return GroupRecord(name: groupInfo[id]?.name, members: list)
            }
            spaceRecords.append(SpaceRecord(
                name: space.name, emoji: space.emoji, sortOrder: space.sortOrder,
                isMuted: space.isMuted, members: members,
                groups: groupRecords.isEmpty ? nil : groupRecords
            ))
        }
        var globalIndices: [Int] = []
        for service in RailEdits.globalServices(in: context) {
            guard let record = ServiceRecord(exporting: service) else { continue }
            globalIndices.append(records.count)
            storeByIndex[records.count] = service.dataStoreIdentifier
            records.append(record)
        }
        let shared = sharedSignInGroups(storeByIndex: storeByIndex)
        return SetupArchive(
            format: format, version: currentVersion, exportedAt: now,
            appVersion: appVersion, spaces: spaceRecords, services: records,
            globalServices: globalIndices.isEmpty ? nil : globalIndices,
            sharedSignIns: shared.isEmpty ? nil : shared
        )
    }

    /// The exported services that share a store, as groups of two or more,
    /// each sorted and the groups in order of their first member. Pure.
    static func sharedSignInGroups(storeByIndex: [Int: UUID]) -> [[Int]] {
        Dictionary(grouping: storeByIndex.keys, by: { storeByIndex[$0]! })
            .values
            .map { $0.sorted() }
            .filter { $0.count > 1 }
            .sorted { $0[0] < $1[0] }
    }

    /// Every link whose two ends are still there, grouped by space and in
    /// order. Fetched rather than read through `Space.serviceLinks`, the
    /// inverse that can go stale (see `AppState.servicesForSpace`), and read
    /// through `liveEnds`, since a link left by a crash mid-delete can still
    /// hold a freed model.
    @MainActor
    private static func liveLinksBySpace(in context: ModelContext) throws -> [UUID: [(Int, ServiceInstance, UUID?)]] {
        var grouped: [UUID: [(Int, ServiceInstance, UUID?)]] = [:]
        for link in try context.fetch(FetchDescriptor<SpaceServiceLink>()) {
            guard let ends = link.liveEnds else { continue }
            grouped[ends.space.id, default: []].append((link.sortOrder, ends.service, link.groupID))
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
        // Past any dividers between spaces too, which share this numbering.
        var nextSpaceOrder = RailEdits.nextOrder(in: .spaces, context: context)
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
        // Globals continue the global group's numbering, in the file's order.
        let firstGlobalOrder = RailEdits.nextOrder(in: .global, context: context)
        var globalIndices: [Int] = []
        for index in globalServices ?? [] where !globalIndices.contains(index) {
            globalIndices.append(index)
        }
        var created: [Int: ServiceInstance] = [:]
        for index in listedServiceIndices {
            let service = services[index].makeService()
            if let position = globalIndices.firstIndex(of: index) {
                service.isGlobal = true
                service.globalSortOrder = firstGlobalOrder + position
            }
            context.insert(service)
            created[index] = service
        }
        // One fresh store per shared group, among the services actually added.
        for group in sharedSignIns ?? [] {
            // A Mac app has no cookies to share.
            let members = group.compactMap { created[$0] }.filter { $0.nativeAppBundleID == nil }
            guard members.count > 1 else { continue }
            let store = UUID()
            members.forEach { $0.dataStoreIdentifier = store }
        }
        summary.servicesAdded = created.count

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        var knownGroups: [UUID: UUID] = [:]
        do {
            var nextOrder: [UUID: Int] = [:]
            var linked: [UUID: Set<Int>] = [:]
            var linkFor: [UUID: [Int: SpaceServiceLink]] = [:]
            // A global service has no links; a file that also lists it in a
            // space does not get to give it one.
            let globalSet = Set(globalIndices)
            for (record, space) in zip(orderedSpaces, targets) {
                // Two records can merge into one space; each continues the order.
                // Past the space's dividers too, which share its numbering.
                var order = nextOrder[space.id] ?? RailEdits.nextOrder(in: .space(space.id), context: context)
                for member in record.members.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    // A service listed twice in one space gets one link.
                    guard !globalSet.contains(member.service),
                          linked[space.id, default: []].insert(member.service).inserted,
                          let service = created[member.service] else { continue }
                    let link = SpaceServiceLink(sortOrder: order, space: space, service: service)
                    if link.modelContext == nil { context.insert(link) }
                    linkFor[space.id, default: [:]][member.service] = link
                    order += 1
                }
                // Each group's links take a new group row and move, in rail
                // order, to the end of the space. Only links this import made
                // are named, so no service already here joins one.
                for group in record.groups ?? [] {
                    let ours = group.members
                        .compactMap { linkFor[space.id]?[$0] }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    guard ours.count >= 2 else { continue }
                    let row = ServiceGroup(spaceID: space.id, name: group.name)
                    context.insert(row)
                    knownGroups[row.id] = space.id
                    for link in ours {
                        link.groupID = row.id
                        link.sortOrder = order
                        order += 1
                    }
                }
                nextOrder[space.id] = order
            }
            for space in targets where !knownGroups.isEmpty {
                RailEdits.tidyGroups(inSpace: space.id, context: context, knownGroups: knownGroups)
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

    /// A new service from the record, with its own id and data store. The icon
    /// is shrunk, and dropped if it isn't a safe image; CSS that could reach
    /// outside the page is dropped (`SetupArchive.importableCSS`).
    func makeService() -> ServiceInstance {
        ServiceInstance(
            label: label,
            url: url,
            customIconData: customIconData.flatMap { IconThumbnail.png(from: $0) },
            catalogEntryID: catalogEntryID,
            isMuted: isMuted,
            showBadge: showBadge,
            neverHibernate: neverHibernate,
            userAgent: userAgent,
            pageZoom: pageZoom.map { min(max($0, SetupArchive.Limit.zoom.lowerBound), SetupArchive.Limit.zoom.upperBound) },
            osNotificationsEnabled: osNotificationsEnabled,
            customCSS: SetupArchive.importableCSS(customCSS),
            darkModeRaw: darkModeRaw,
            openExternalLinksInApp: openExternalLinksInApp,
            stayActiveInBackground: stayActiveInBackground,
            hibernationPolicyRaw: hibernationPolicyRaw,
            hibernateAfterMinutes: hibernateAfterMinutes
        )
    }
}
