import XCTest
import SwiftData
@testable import Chorus

@MainActor
final class ChorusTests: XCTestCase {
    func testServiceInstanceCreation() {
        let service = ServiceInstance(
            label: "Test Gmail",
            url: "https://mail.google.com",
            catalogEntryID: "gmail"
        )
        XCTAssertEqual(service.label, "Test Gmail")
        XCTAssertEqual(service.url, "https://mail.google.com")
        XCTAssertFalse(service.isMuted)
        XCTAssertNotNil(service.dataStoreIdentifier)
    }

    func testSpaceCreation() {
        let space = Space(name: "Work", emoji: "🏢", sortOrder: 0)
        XCTAssertEqual(space.name, "Work")
        XCTAssertEqual(space.emoji, "🏢")
        XCTAssertEqual(space.sortOrder, 0)
        XCTAssertTrue(space.serviceLinks.isEmpty)
    }

    func testServiceCatalogParsing() {
        let json = """
        [{"id":"gmail","name":"Gmail","url":"https://mail.google.com","icon":"gmail-icon","category":"Email","badgeJS":null,"userAgent":null,"description":"Google email"}]
        """.data(using: .utf8)!

        let entries = try! JSONDecoder().decode([ServiceCatalogEntry].self, from: json)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "gmail")
        XCTAssertEqual(entries[0].category, "Email")
    }

    @MainActor
    func testBadgeCountExtraction() {
        XCTAssertEqual(NotificationManager.extractBadgeCount(from: "Inbox (5) - Gmail"), 5)
        XCTAssertEqual(NotificationManager.extractBadgeCount(from: "(12) Slack"), 12)
        XCTAssertEqual(NotificationManager.extractBadgeCount(from: "No badges here"), 0)
    }

    func testCustomServiceInputValidation() {
        XCTAssertEqual(
            AddServiceSheet.validatedCustomServiceInput(label: "  Docs  ", url: " HTTPS://example.com/app "),
            .valid(label: "Docs", url: "https://example.com/app")
        )
        XCTAssertEqual(
            AddServiceSheet.validatedCustomServiceInput(label: "   ", url: "https://example.com"),
            .invalid("Label can't be empty")
        )
        XCTAssertEqual(
            AddServiceSheet.validatedCustomServiceInput(label: "Broken", url: "https://"),
            .invalid("URL must include a host")
        )
        XCTAssertEqual(
            AddServiceSheet.validatedCustomServiceInput(label: "FTP", url: "ftp://example.com"),
            .invalid("URL must start with https:// or http://")
        )
    }

    func testFaviconParserHandlesAttributeOrderAndRelativeURLs() {
        let html = """
        <html><head>
            <link href="icons/favicon-32.png" rel="icon" sizes="16x16 32x32">
            <link sizes="180x180" rel="apple-touch-icon" href="/apple-touch-icon.png">
            <link rel="stylesheet" href="/site.css">
        </head></html>
        """
        let links = FaviconFetcher.parseIconLinks(
            from: html,
            baseURL: URL(string: "https://example.com/app/page")!
        )

        XCTAssertEqual(
            links,
            [
                .init(url: "https://example.com/app/icons/favicon-32.png", size: 32),
                .init(url: "https://example.com/apple-touch-icon.png", size: 180),
            ]
        )
    }

    func testIsFetchableIconURLRejectsPrivateAndNonWebTargets() {
        // Public https host is fetchable.
        XCTAssertTrue(FaviconFetcher.isFetchableIconURL(URL(string: "https://example.com/i.png")!))
        // Non-web schemes never fetch.
        XCTAssertFalse(FaviconFetcher.isFetchableIconURL(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(FaviconFetcher.isFetchableIconURL(URL(string: "data:image/png;base64,AAAA")!))
        // Literal private / loopback / link-local IPs are blocked (SSRF).
        XCTAssertFalse(FaviconFetcher.isFetchableIconURL(URL(string: "http://127.0.0.1/i.png")!))
        XCTAssertFalse(FaviconFetcher.isFetchableIconURL(URL(string: "http://10.0.0.5/i.png")!))
        XCTAssertFalse(FaviconFetcher.isFetchableIconURL(URL(string: "http://169.254.169.254/latest")!))
    }

    func testIsLikelyPrivateHostHeuristic() {
        // Public FQDNs pass through (may go to Google, may be fetched).
        XCTAssertFalse(FaviconFetcher.isLikelyPrivateHost("example.com"))
        XCTAssertFalse(FaviconFetcher.isLikelyPrivateHost("mail.google.com"))
        // Intranet shapes are treated as private without a DNS lookup.
        XCTAssertTrue(FaviconFetcher.isLikelyPrivateHost("localhost"))
        XCTAssertTrue(FaviconFetcher.isLikelyPrivateHost("intranet"))          // single label
        XCTAssertTrue(FaviconFetcher.isLikelyPrivateHost("mail.corp"))         // private TLD
        XCTAssertTrue(FaviconFetcher.isLikelyPrivateHost("nas.local"))
        XCTAssertTrue(FaviconFetcher.isLikelyPrivateHost("192.168.1.10"))      // literal private IP
    }

    func testServiceReorderPlacement() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let ids = [first, second, third, fourth]

        XCTAssertEqual(
            ServiceReorder.reorderedIDs(ids, moving: first, relativeTo: second, placement: .after),
            [second, first, third, fourth]
        )
        XCTAssertEqual(
            ServiceReorder.reorderedIDs(ids, moving: fourth, relativeTo: first, placement: .before),
            [fourth, first, second, third]
        )
        XCTAssertEqual(
            ServiceReorder.reorderedIDs(ids, moving: second, relativeTo: fourth, placement: .after),
            [first, third, fourth, second]
        )
    }

    func testServiceReorderNoOpsAndInvalidDrops() {
        let first = UUID()
        let second = UUID()
        let missing = UUID()
        let ids = [first, second]

        XCTAssertNil(ServiceReorder.reorderedIDs(ids, moving: first, relativeTo: first, placement: .after))
        XCTAssertNil(ServiceReorder.reorderedIDs(ids, moving: first, relativeTo: second, placement: .before))
        XCTAssertNil(ServiceReorder.reorderedIDs(ids, moving: second, relativeTo: first, placement: .after))
        XCTAssertNil(ServiceReorder.reorderedIDs(ids, moving: missing, relativeTo: first, placement: .before))
        XCTAssertNil(ServiceReorder.reorderedIDs(ids, moving: first, relativeTo: missing, placement: .before))
    }

    // MARK: - BadgeManager

    @MainActor
    func testMutingPreservesRawCountAndRestoresOnUnmute() {
        let manager = BadgeManager()
        let id = UUID()

        // A live poll reports 5 unread.
        manager.updateBadge(for: id, count: 5, isMuted: false, showBadge: true)
        XCTAssertEqual(manager.badgeCount(for: id), 5)
        XCTAssertEqual(manager.rawCount(for: id), 5)

        // Muting hides the badge but must NOT destroy the real count — the
        // adaptive poller relies on rawCount to detect deltas, and un-muting
        // must restore the badge instantly without waiting for a poll tick.
        manager.updateBadge(for: id, count: 5, isMuted: true, showBadge: true)
        XCTAssertEqual(manager.badgeCount(for: id), 0, "muted badge is hidden")
        XCTAssertEqual(manager.rawCount(for: id), 5, "real count survives muting")

        // Un-mute by re-applying with the preserved rawCount (mirrors
        // AppState.refreshBadgeState reading rawCount).
        manager.updateBadge(for: id, count: manager.rawCount(for: id), isMuted: false, showBadge: true)
        XCTAssertEqual(manager.badgeCount(for: id), 5, "un-mute restores the badge immediately")
    }

    @MainActor
    func testAggregateAndTotalExcludeMaskedServices() {
        let manager = BadgeManager()
        let visible = UUID()
        let muted = UUID()
        let hidden = UUID()

        manager.updateBadge(for: visible, count: 3, isMuted: false, showBadge: true)
        manager.updateBadge(for: muted, count: 7, isMuted: true, showBadge: true)
        manager.updateBadge(for: hidden, count: 4, isMuted: false, showBadge: false)

        XCTAssertEqual(manager.aggregateCount(for: [visible, muted, hidden]), 3)
        XCTAssertEqual(manager.totalCount, 3)
        // Raw counts are all preserved regardless of masking.
        XCTAssertEqual(manager.rawCount(for: muted), 7)
        XCTAssertEqual(manager.rawCount(for: hidden), 4)
    }

    @MainActor
    func testDoNotDisturbZerosVisibleCountsButKeepsRaw() {
        let manager = BadgeManager()
        let id = UUID()
        manager.updateBadge(for: id, count: 9, isMuted: false, showBadge: true)

        manager.doNotDisturb = true
        XCTAssertEqual(manager.badgeCount(for: id), 0)
        XCTAssertEqual(manager.aggregateCount(for: [id]), 0)
        XCTAssertEqual(manager.totalCount, 0)
        XCTAssertEqual(manager.rawCount(for: id), 9, "DND does not destroy the real count")

        manager.doNotDisturb = false
        XCTAssertEqual(manager.badgeCount(for: id), 9)
    }

    @MainActor
    func testUpdateBadgeClampsOutOfRangeCounts() {
        let manager = BadgeManager()
        let negative = UUID()
        let huge = UUID()
        let ok = UUID()

        // A misbehaving DOM badge (catalog badgeJS) could yield a negative or a
        // garbage-large value; a stored negative would subtract from the sum and
        // hide the dock badge for every other service.
        manager.updateBadge(for: negative, count: -5, isMuted: false, showBadge: true)
        manager.updateBadge(for: huge, count: 100_000, isMuted: false, showBadge: true)
        manager.updateBadge(for: ok, count: 3, isMuted: false, showBadge: true)

        XCTAssertEqual(manager.rawCount(for: negative), 0, "negative clamps to 0")
        XCTAssertEqual(manager.rawCount(for: huge), 999, "huge clamps to 999")
        // The total is the clamped sum, never dragged below the other services.
        XCTAssertEqual(manager.totalCount, 0 + 999 + 3)
    }

    @MainActor
    func testDoNotDisturbSnapshotMirrorsValue() {
        let manager = BadgeManager()
        XCTAssertFalse(manager.doNotDisturbSnapshot.value)
        manager.doNotDisturb = true
        XCTAssertTrue(manager.doNotDisturbSnapshot.value, "snapshot follows the property for off-main reads")
        manager.doNotDisturb = false
        XCTAssertFalse(manager.doNotDisturbSnapshot.value)
    }

    @MainActor
    func testRemoveBadgeClearsMaskState() {
        let manager = BadgeManager()
        let id = UUID()
        manager.updateBadge(for: id, count: 2, isMuted: true, showBadge: true)
        manager.removeBadge(for: id)
        // Re-adding an un-muted badge after removal must not stay masked.
        manager.updateBadge(for: id, count: 6, isMuted: false, showBadge: true)
        XCTAssertEqual(manager.badgeCount(for: id), 6)
    }

    // MARK: - Orphaned-service detection (space deletion)

    func testServicesOrphanedByDeletingSpace() {
        let space = UUID()
        let otherSpace = UUID()
        let onlyHere = UUID()      // belongs only to `space` → orphaned
        let alsoElsewhere = UUID() // belongs to `space` and `otherSpace` → kept
        let elsewhere = UUID()     // not in `space` at all → untouched

        let memberships: [UUID: Set<UUID>] = [
            onlyHere: [space],
            alsoElsewhere: [space, otherSpace],
            elsewhere: [otherSpace],
        ]

        XCTAssertEqual(
            AppState.servicesOrphaned(byDeletingSpace: space, memberships: memberships),
            [onlyHere]
        )
    }

    func testServicesOrphanedHandlesEmptyAndAbsentSpace() {
        let space = UUID()
        let svc = UUID()
        // Deleting a space no service belongs to orphans nothing.
        XCTAssertEqual(
            AppState.servicesOrphaned(byDeletingSpace: space, memberships: [svc: [UUID()]]),
            []
        )
        XCTAssertEqual(
            AppState.servicesOrphaned(byDeletingSpace: space, memberships: [:]),
            []
        )
    }

    // MARK: - Store integrity after deleting a space (repro: "delete second workspace and quit, won't start")

    /// Reproduces the reported sequence against a real on-disk store: seed two
    /// spaces with linked services, delete the second (reclaiming its orphaned
    /// services exactly as `AppState.deleteSpace` does at the SwiftData layer),
    /// close the container, then reopen it and run the launch-time queries.
    /// A dangling `SpaceServiceLink` or corrupt store would trap here.
    func testDeleteSecondSpaceThenReopenStoreIsClean() throws {
        let schema = Schema([
            ServiceInstance.self,
            Space.self,
            SpaceServiceLink.self,
            AppPreferences.self,
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-repro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // --- Session 1: seed two spaces, then delete the second ---
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = container.mainContext

            let personal = Space(name: "Personal", emoji: "🏠", sortOrder: 0)
            let work = Space(name: "Work", emoji: "💼", sortOrder: 1)
            context.insert(personal)
            context.insert(work)

            func link(_ label: String, to space: Space, order: Int) {
                let svc = ServiceInstance(label: label, url: "https://\(label).example", catalogEntryID: label)
                context.insert(svc)
                context.insert(SpaceServiceLink(sortOrder: order, space: space, service: svc))
            }
            link("gmail-personal", to: personal, order: 0)
            link("claude", to: personal, order: 1)
            link("gmail-work", to: work, order: 0)
            link("slack", to: work, order: 1)
            try context.save()

            // Replicate AppState.deleteSpace's SwiftData operations for `work`.
            let workID = work.id
            let doomed = try context.fetch(
                FetchDescriptor<Space>(predicate: #Predicate { $0.id == workID })
            ).first!
            let linkedServices = doomed.serviceLinks.map(\.service)
            var memberships: [UUID: Set<UUID>] = [:]
            for service in linkedServices {
                memberships[service.id] = Set(service.spaceLinks.map { $0.space.id })
            }
            // The inverse must be wired for this to be non-empty — the bug was
            // that it read 0, so nothing was reclaimed and the space's links
            // were left dangling after the space was deleted.
            XCTAssertEqual(doomed.serviceLinks.count, 2, "Space.serviceLinks inverse must be populated")
            let orphaned = AppState.servicesOrphaned(byDeletingSpace: workID, memberships: memberships)
            XCTAssertEqual(orphaned.count, 2, "Both of Work's services should be reclaimed")
            for service in linkedServices where orphaned.contains(service.id) {
                context.delete(service)
            }
            context.delete(doomed)
            try context.save()
        }

        // --- Session 2: reopen the SAME store and run launch-time queries ---
        let config = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        // reapOrphanedServices(): fetch all services, find any with no spaceLinks.
        let services = try context.fetch(FetchDescriptor<ServiceInstance>())
        XCTAssertEqual(services.count, 2, "Only Personal's two services should remain")
        let orphans = services.filter { $0.spaceLinks.isEmpty }
        XCTAssertTrue(orphans.isEmpty, "No orphaned services should survive the delete")

        // servicesForSpace guard path: materialize each link's relationships.
        let links = try context.fetch(FetchDescriptor<SpaceServiceLink>())
        XCTAssertEqual(links.count, 2, "Only Personal's two links should remain")
        for l in links {
            XCTAssertNotNil(l.modelContext)
            XCTAssertNotNil(l.space.modelContext, "Link's space must not dangle")
            XCTAssertNotNil(l.service.modelContext, "Link's service must not dangle")
        }

        let spaces = try context.fetch(FetchDescriptor<Space>())
        XCTAssertEqual(spaces.count, 1)
        XCTAssertEqual(spaces.first?.name, "Personal")
    }

    // MARK: - Repair of a store ALREADY corrupted by a pre-1.5.1 build

    /// The 1.5.1 fix has two halves: the inverse declaration (prevents NEW
    /// corruption — covered by the test above) and `reapDanglingLinks` (repairs
    /// a store a pre-fix build already corrupted). The reporter is in the second
    /// case: they deleted a space on 1.4.0/1.5.0, so their store holds a
    /// `SpaceServiceLink` whose `space` points at a deleted row. This test
    /// reproduces exactly that on-disk state — by deleting the space's row
    /// directly, the way the pre-fix build effectively did when its cascade
    /// never fired — then runs the shipped repair sequence and the launch badge
    /// read that used to trap. If deleting a dangling link faults its dead space,
    /// or the read still traps, this test crashes (SIGTRAP), matching the report.
    func testReapRepairsPreFixDanglingLinkWithoutCrashing() throws {
        let schema = Schema([
            ServiceInstance.self,
            Space.self,
            SpaceServiceLink.self,
            AppPreferences.self,
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-danglerepair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // --- Session 1: seed two spaces with linked services, clean ---
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = container.mainContext
            let personal = Space(name: "Personal", emoji: "🏠", sortOrder: 0)
            let work = Space(name: "Work", emoji: "💼", sortOrder: 1)
            context.insert(personal)
            context.insert(work)
            func link(_ label: String, to space: Space, order: Int) {
                let svc = ServiceInstance(label: label, url: "https://\(label).example", catalogEntryID: label)
                context.insert(svc)
                context.insert(SpaceServiceLink(sortOrder: order, space: space, service: svc))
            }
            link("gmail-personal", to: personal, order: 0)
            link("claude", to: personal, order: 1)
            link("gmail-work", to: work, order: 0)
            link("slack", to: work, order: 1)
            try context.save()
        }

        // --- Corrupt like a pre-fix build: delete the Work space ROW,
        //     leaving its two links with a dangling ZSPACE foreign key. ---
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE WHERE ZNAME='Work';")
        func danglingRows() throws -> Int {
            Int(try Self.runSQLite(
                storeURL,
                "SELECT count(*) FROM ZSPACESERVICELINK WHERE ZSPACE NOT IN (SELECT Z_PK FROM ZSPACE);"
            ).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        }
        XCTAssertEqual(try danglingRows(), 2, "repro must leave two dangling links")

        // --- Run the SHIPPED pre-open repair against the raw file. ---
        StoreRepair.repairDanglingLinks(at: storeURL)
        XCTAssertEqual(try danglingRows(), 0, "repair must remove the dangling links")

        // Idempotency: a second pass is a no-op.
        StoreRepair.repairDanglingLinks(at: storeURL)
        XCTAssertEqual(try danglingRows(), 0, "second repair pass must stay clean")

        // A backup of the corrupted store must have been written.
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") }
        XCTAssertFalse(backups.isEmpty, "repair must back up the store before mutating")

        // --- Session 2: open the repaired store and run the launch queries
        //     that used to trap, then confirm good data survived. ---
        let config = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let links = try context.fetch(FetchDescriptor<SpaceServiceLink>())
        XCTAssertEqual(links.count, 2, "only Personal's two links should survive")
        for l in links {
            _ = l.space.id     // the badge-sweep read that crashed pre-fix
            _ = l.service.id
        }
        let spaces = try context.fetch(FetchDescriptor<Space>())
        XCTAssertEqual(spaces.map(\.name), ["Personal"], "the live space must be intact")
        let services = try context.fetch(FetchDescriptor<ServiceInstance>())
        XCTAssertEqual(services.count, 4, "no service rows should be lost by the repair")

        // The store must remain writable (bookkeeping/history survived): create
        // and remove a link, then save with no error.
        let probeSpace = spaces[0]
        let probeSvc = ServiceInstance(label: "probe", url: "https://probe.example", catalogEntryID: "probe")
        context.insert(probeSvc)
        let probeLink = SpaceServiceLink(sortOrder: 9, space: probeSpace, service: probeSvc)
        context.insert(probeLink)
        try context.save()
        context.delete(probeLink)
        context.delete(probeSvc)
        try context.save()
    }

    /// The launch gate's detector must flag a store that still holds a dangling
    /// link (true) and clear a repaired one (false). This is what makes `init`
    /// fall back to in-memory instead of running on a store that would trap on a
    /// later `.space`/`.service` read.
    func testStoreHasDanglingLinksDetectsAndClears() throws {
        let schema = Schema([
            ServiceInstance.self,
            Space.self,
            SpaceServiceLink.self,
            AppPreferences.self,
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = container.mainContext
            let work = Space(name: "Work", emoji: "💼", sortOrder: 0)
            let personal = Space(name: "Personal", emoji: "🏠", sortOrder: 1)
            context.insert(work)
            context.insert(personal)
            let svc = ServiceInstance(label: "slack", url: "https://slack.example", catalogEntryID: "slack")
            context.insert(svc)
            context.insert(SpaceServiceLink(sortOrder: 0, space: work, service: svc))
            let keep = ServiceInstance(label: "gmail", url: "https://gmail.example", catalogEntryID: "gmail")
            context.insert(keep)
            context.insert(SpaceServiceLink(sortOrder: 0, space: personal, service: keep))
            try context.save()
        }

        // Corrupt: delete Work's row, leaving its link dangling.
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE WHERE ZNAME='Work';")

        // Detector must flag the corrupted store.
        let corruptConfig = ModelConfiguration(schema: schema, url: storeURL)
        let corrupt = try ModelContainer(for: schema, configurations: [corruptConfig])
        XCTAssertTrue(AppState.storeHasDanglingLinks(corrupt), "must detect the dangling link")

        // After repair, the same detector must pass the store.
        StoreRepair.repairDanglingLinks(at: storeURL)
        let repairedConfig = ModelConfiguration(schema: schema, url: storeURL)
        let repaired = try ModelContainer(for: schema, configurations: [repairedConfig])
        XCTAssertFalse(AppState.storeHasDanglingLinks(repaired), "repaired store must be clean")
    }

    /// `StoreRepair.spaceCount` is what lets `init` tell a fresh install from a
    /// store that had spaces but came up empty (a silent migration failure).
    /// It must return nil when there's no file, nil when the schema has no
    /// ZSPACE table, and the exact row count otherwise — so a genuine empty
    /// store reads as 0, never nil, and a populated one reads as its count.
    func testSpaceCountDistinguishesMissingUnknownAndPopulated() throws {
        let schema = Schema([
            ServiceInstance.self,
            Space.self,
            SpaceServiceLink.self,
            AppPreferences.self,
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-spacecount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // No file yet → unknown, not zero.
        XCTAssertNil(StoreRepair.spaceCount(at: storeURL), "missing store must read as nil (unknown)")

        // A store with two spaces → exact count.
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = container.mainContext
            context.insert(Space(name: "Personal", emoji: "🏠", sortOrder: 0))
            context.insert(Space(name: "Work", emoji: "💼", sortOrder: 1))
            try context.save()
        }
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 2, "populated store must read its space count")

        // Emptied on disk → 0, NOT nil: the table still exists, so the count is
        // known to be zero. This is the case that must NOT look like a fresh
        // install to init (nil), or the seed would overwrite the store.
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 0, "emptied store must read as 0, not nil")

        // A file with no ZSPACE table → unknown (nil), never guessed as zero.
        let alienURL = dir.appendingPathComponent("alien.sqlite")
        try Self.runSQLite(alienURL, "CREATE TABLE ZOTHER (x INTEGER);")
        XCTAssertNil(StoreRepair.spaceCount(at: alienURL), "unrecognized schema must read as nil")
    }

    // MARK: - Auto-restore of an emptied store

    /// The store schema, shared by the restore tests.
    private static var storeSchema: Schema {
        Schema([ServiceInstance.self, Space.self, SpaceServiceLink.self, AppPreferences.self])
    }

    /// Creates a store at `url` with `spaces` populated spaces, then releases the
    /// container (so the SQLite file is free for raw ops). Spaces-only keeps the
    /// store free of links, so no dangling-link machinery is involved.
    private func makePopulatedStore(at url: URL, spaces: Int) throws {
        let config = ModelConfiguration(schema: Self.storeSchema, url: url)
        let container = try ModelContainer(for: Self.storeSchema, configurations: [config])
        let ctx = container.mainContext
        for i in 0..<spaces {
            ctx.insert(Space(name: "S\(i)", emoji: "🏠", sortOrder: i))
        }
        try ctx.save()
    }

    /// `newestRestorableSnapshot` must skip empty and corrupt snapshots and
    /// return the newest one that actually holds data.
    func testNewestRestorableSnapshotSkipsEmptyAndCorruptPicksNewestGood() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-newest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Good store → snapshot it as the OLDEST.
        try makePopulatedStore(at: storeURL, spaces: 2)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.0.0")

        // Empty the store → snapshot it as a NEWER but empty snapshot.
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        StoreRepair.snapshot(at: storeURL, stamp: "1700000500-1.1.0")

        // A NEWEST but corrupt snapshot file (not a database).
        let corrupt = dir.appendingPathComponent("store.sqlite.snapshot-1700000999-1.2.0.bak")
        try "not a database".write(to: corrupt, atomically: true, encoding: .utf8)

        let candidate = StoreRepair.newestRestorableSnapshot(for: storeURL)
        XCTAssertEqual(candidate?.version, "1.0.0", "must skip the newer empty and corrupt snapshots for the good one")
        XCTAssertEqual(candidate?.takenAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// `restoreFromSnapshot` must copy the snapshot's data back and keep exactly
    /// one prerestore backup of the bad store across repeated calls.
    func testRestoreFromSnapshotBacksUpOnceAndCopiesData() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePopulatedStore(at: storeURL, spaces: 3)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.0.0")
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 0, "precondition: store emptied")

        let candidate = try XCTUnwrap(StoreRepair.newestRestorableSnapshot(for: storeURL))
        XCTAssertTrue(StoreRepair.restoreFromSnapshot(candidate, to: storeURL))
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 3, "restore must bring the data back")

        func prerestoreStamps() throws -> Set<String> {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.contains(".prerestore-") }
            // Collapse the triple (…, -wal, -shm) to distinct stamps.
            return Set(names.map { $0.replacingOccurrences(of: "-wal", with: "").replacingOccurrences(of: "-shm", with: "") })
        }
        let after1 = try prerestoreStamps()
        XCTAssertEqual(after1.count, 1, "exactly one prerestore backup after first restore")

        // Second restore must NOT stack another backup.
        _ = StoreRepair.restoreFromSnapshot(candidate, to: storeURL)
        XCTAssertEqual(try prerestoreStamps(), after1, "second restore must not add another prerestore backup")
    }

    /// End-to-end: a store that had data but comes up empty, with a good snapshot
    /// present, must auto-restore — the exact recovery the field bug needed.
    func testLoadContainerRestoresEmptiedStoreWithHistory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-load-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 4)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.0.0")
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        defaults.set(true, forKey: AppState.hasEverHadDataKey)   // user has had data

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let (container, outcome) = AppState.loadContainer(schema: Self.storeSchema, config: config, defaults: defaults)

        guard case .restoredFromSnapshot = outcome else {
            return XCTFail("expected .restoredFromSnapshot, got \(outcome)")
        }
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Space>()), 4, "restored store must hold the snapshot's spaces")
    }

    /// A genuine fresh install (no file, no history) opens clean and does NOT
    /// restore or record data yet.
    func testLoadContainerFreshInstallOpensCleanWithoutRestore() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-load-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let (container, outcome) = AppState.loadContainer(schema: Self.storeSchema, config: config, defaults: defaults)

        XCTAssertEqual(outcome, .openedClean)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Space>()), 0)
        XCTAssertFalse(defaults.bool(forKey: AppState.hasEverHadDataKey), "an empty fresh install hasn't recorded data yet")
    }

    /// Emptied store + history but NO usable snapshot → in-memory fallback, and
    /// the on-disk store is left untouched (not seeded, not deleted).
    func testLoadContainerFallsBackToInMemoryWhenNoSnapshot() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-load-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 2)
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")   // emptied, but no snapshot taken
        defaults.set(true, forKey: AppState.hasEverHadDataKey)

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let (_, outcome) = AppState.loadContainer(schema: Self.storeSchema, config: config, defaults: defaults)

        guard case .inMemoryFallback = outcome else {
            return XCTFail("expected .inMemoryFallback, got \(outcome)")
        }
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 0, "on-disk store must be left untouched (not seeded)")
    }

    /// Opening a store that already holds data must record `hasEverHadData`, so
    /// an existing user is protected from a future empty-store reseed.
    func testLoadContainerWithExistingDataRecordsHasEverHadData() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-existing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 2)
        XCTAssertFalse(defaults.bool(forKey: AppState.hasEverHadDataKey), "precondition: flag not yet set")

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let (container, outcome) = AppState.loadContainer(schema: Self.storeSchema, config: config, defaults: defaults)

        XCTAssertEqual(outcome, .openedClean)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Space>()), 2)
        XCTAssertTrue(defaults.bool(forKey: AppState.hasEverHadDataKey), "opening a populated store must record that data exists")
    }

    /// The pure recovery-decision truth table — the heart of the data-safety
    /// guarantees, testable without provoking a real SwiftData failure.
    func testRecoveryPlanNeverOverwritesLiveDataAndFreshStartsOnlyWhenNoFile() {
        // Emptied-with-history: the on-disk file was rewritten empty, so restore.
        let emptiedWithFile = AppState.recoveryPlan(kind: .emptiedWithHistory, before: 4, fileExisted: true)
        XCTAssertTrue(emptiedWithFile.attemptRestore)
        XCTAssertEqual(emptiedWithFile.ifNoRestore, .preserveInMemory, "a file that existed must be preserved, never reseeded")

        // Stale flag but no file at all → a fresh start is correct, not a brick.
        XCTAssertEqual(
            AppState.recoveryPlan(kind: .emptiedWithHistory, before: nil, fileExisted: false).ifNoRestore,
            .freshStart
        )

        // Open FAILED while data is on disk → never touch it (the HIGH-severity
        // regression: a transient open failure must not roll back to an older
        // snapshot and lose the newest data).
        let failedWithData = AppState.recoveryPlan(kind: .openFailed, before: 5, fileExisted: true)
        XCTAssertFalse(failedWithData.attemptRestore, "must not overwrite a store that still has rows on disk")
        XCTAssertEqual(failedWithData.ifNoRestore, .preserveInMemory)

        // Open failed on an empty file → safe to restore, preserve if it existed.
        let failedEmpty = AppState.recoveryPlan(kind: .openFailed, before: 0, fileExisted: true)
        XCTAssertTrue(failedEmpty.attemptRestore)
        XCTAssertEqual(failedEmpty.ifNoRestore, .preserveInMemory)

        // Open failed with no file → fresh start allowed.
        XCTAssertEqual(
            AppState.recoveryPlan(kind: .openFailed, before: nil, fileExisted: false).ifNoRestore,
            .freshStart
        )
    }

    /// Prune must never delete the newest USABLE snapshot, even when a run of
    /// newer empty snapshots pushes it past the keep window — otherwise the only
    /// copy of real data is destroyed after a few post-loss version bumps.
    func testPruneRetainsNewestUsableSnapshotBeyondKeepWindow() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // One good snapshot (oldest), then several newer EMPTY snapshots.
        try makePopulatedStore(at: storeURL, spaces: 2)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.0.0")
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        for stamp in ["1700000100-1.1.0", "1700000200-1.2.0", "1700000300-1.3.0", "1700000400-1.4.0"] {
            StoreRepair.snapshot(at: storeURL, stamp: stamp)
        }

        StoreRepair.pruneSnapshots(at: storeURL, keeping: 3)

        let good = dir.appendingPathComponent("store.sqlite.snapshot-1700000000-1.0.0.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.path), "the newest usable snapshot must survive prune")
        XCTAssertEqual(StoreRepair.newestRestorableSnapshot(for: storeURL)?.version, "1.0.0")
    }

    /// A stale `hasEverHadData` flag with NO store file and no snapshot (e.g. a
    /// support step deleted the store but not the preferences) must start fresh
    /// and clear the flag — not brick the app into a permanent empty state.
    func testLoadContainerStaleFlagWithNoFileStartsFresh() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")   // deliberately not created
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppState.hasEverHadDataKey)   // stale

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let (container, outcome) = AppState.loadContainer(schema: Self.storeSchema, config: config, defaults: defaults)

        XCTAssertEqual(outcome, .openedClean, "no file + nothing to restore must start fresh, not fall to a permanent empty state")
        XCTAssertFalse(defaults.bool(forKey: AppState.hasEverHadDataKey), "the stale flag must be cleared so the seed can run")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Space>()), 0)
    }

    /// Runs one SQL statement against a SwiftData store via the sqlite3 CLI and
    /// returns stdout. Used to manufacture on-disk corruption a fixed schema
    /// can't produce through the normal delete path.
    private static func runSQLite(_ url: URL, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - WebContent crash backoff

    func testCrashBackoffStopsAfterRepeatedCrashes() {
        let now = Date()
        // First two crashes within the window still auto-reload.
        XCTAssertTrue(WebViewCoordinator.shouldAutoReload(
            crashTimestamps: [now], now: now, maxCrashes: 3, window: 30))
        XCTAssertTrue(WebViewCoordinator.shouldAutoReload(
            crashTimestamps: [now.addingTimeInterval(-5), now], now: now, maxCrashes: 3, window: 30))
        // Third crash in the window stops the loop (show error page instead).
        XCTAssertFalse(WebViewCoordinator.shouldAutoReload(
            crashTimestamps: [now.addingTimeInterval(-10), now.addingTimeInterval(-5), now],
            now: now, maxCrashes: 3, window: 30))
    }

    func testCrashBackoffIgnoresStaleCrashesOutsideWindow() {
        let now = Date()
        // Two crashes long ago + one now: the old ones fall outside the window,
        // so we still auto-reload.
        XCTAssertTrue(WebViewCoordinator.shouldAutoReload(
            crashTimestamps: [now.addingTimeInterval(-300), now.addingTimeInterval(-120), now],
            now: now, maxCrashes: 3, window: 30))
    }

    func testErrorPageEmbedsEscapedRetryURL() {
        let html = WebViewCoordinator.errorPageHTML(
            title: "Unable to connect",
            message: "The network connection was lost.",
            retryURLString: "https://example.com/a'b\"c"
        )
        XCTAssertTrue(html.contains("The network connection was lost."))
        // Retry target is JSON-encoded so quotes can't break out of the JS string.
        XCTAssertTrue(html.contains(#"https://example.com/a'b\"c"#),
                      "retry URL should be JSON-escaped into the script")
        XCTAssertFalse(html.contains("location.reload()"),
                       "retry must navigate to the real URL, not reload about:blank")
    }

    // MARK: - External-open scheme policy

    func testExternalOpenAllowsWebAndCuratedSchemes() {
        for allowed in [
            "https://example.com/a",
            "http://example.com",
            "HTTPS://example.com",  // scheme comparison is case-insensitive
            "mailto:someone@example.com",
            "tel:+15551234",
            "maps://?q=test",
        ] {
            let url = URL(string: allowed)!
            XCTAssertTrue(WebViewCoordinator.isSafeForExternalOpen(url),
                          "\(allowed) should be handed to the system handler")
        }
    }

    func testExternalOpenBlocksCredentialAndFileSchemes() {
        // smb/afp reach a remote share and leak NTLM credentials on click; file
        // and custom schemes hand a page control over local content and other
        // apps. A page can offer any of these as a plain link.
        for blocked in [
            "smb://attacker.example/share",
            "afp://attacker.example/vol",
            "ftp://attacker.example/f",
            "vnc://attacker.example",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "someapp://do-something",
        ] {
            let url = URL(string: blocked)!
            XCTAssertFalse(WebViewCoordinator.isSafeForExternalOpen(url),
                           "\(blocked) must not reach NSWorkspace.open")
        }
    }

    func testErrorPageWithoutRetryURLHasNoButton() {
        let html = WebViewCoordinator.errorPageHTML(
            title: "Page unavailable", message: "Keeps crashing.", retryURLString: nil)
        XCTAssertFalse(html.contains("<button"))
    }

    // MARK: - Open-external-links-in-app routing

    func testInAppBrowserNeedsOptInAndWebScheme() {
        let web = URL(string: "https://news.example/article")!
        // Opted in, web scheme → in-app window.
        XCTAssertTrue(WebViewCoordinator.shouldOpenInAppBrowser(sourceOptedIn: true, url: web))
        XCTAssertTrue(WebViewCoordinator.shouldOpenInAppBrowser(
            sourceOptedIn: true, url: URL(string: "http://news.example")!))
        XCTAssertTrue(WebViewCoordinator.shouldOpenInAppBrowser(
            sourceOptedIn: true, url: URL(string: "HTTPS://news.example")!))
        // Not opted in → browser, even for a web link.
        XCTAssertFalse(WebViewCoordinator.shouldOpenInAppBrowser(sourceOptedIn: false, url: web))
    }

    func testInAppBrowserNeverTakesNonWebSchemes() {
        // Even opted in, a non-web scheme must not load in an in-app web view: it
        // stays on the openExternally path (mailto reaches Mail, smb/file are
        // dropped by the vetted-scheme gate).
        for other in [
            "mailto:a@example.com",
            "tel:+15551234",
            "smb://attacker.example/share",
            "file:///etc/passwd",
            "someapp://do-something",
        ] {
            XCTAssertFalse(
                WebViewCoordinator.shouldOpenInAppBrowser(sourceOptedIn: true, url: URL(string: other)!),
                "\(other) must not open in an in-app web view")
        }
    }

    func testOpensExternalLinksInAppDefaultsToOff() {
        // A legacy row (nil) keeps opening external links in the system browser.
        XCTAssertFalse(ServiceInstance(label: "S", url: "https://s.example")
            .opensExternalLinksInAppEffective)
        XCTAssertTrue(ServiceInstance(label: "S", url: "https://s.example", openExternalLinksInApp: true)
            .opensExternalLinksInAppEffective)
        XCTAssertFalse(ServiceInstance(label: "S", url: "https://s.example", openExternalLinksInApp: false)
            .opensExternalLinksInAppEffective)
    }

    // MARK: - OS-notification gate + per-service notify flag

    func testOSNotificationGateFiresOnlyWhenEnabledUnmutedAndNotDND() {
        // Fires only when not muted, notifyOS on, and DND off.
        XCTAssertTrue(NotificationManager.shouldPostOSNotification(
            isMuted: false, notifyOS: true, doNotDisturb: false))
        // Each condition independently vetoes.
        XCTAssertFalse(NotificationManager.shouldPostOSNotification(
            isMuted: true, notifyOS: true, doNotDisturb: false), "mute vetoes")
        XCTAssertFalse(NotificationManager.shouldPostOSNotification(
            isMuted: false, notifyOS: false, doNotDisturb: false), "notifyOS off vetoes")
        XCTAssertFalse(NotificationManager.shouldPostOSNotification(
            isMuted: false, notifyOS: true, doNotDisturb: true), "DND vetoes")
    }

    func testShouldStopOutgoingPollReconcilesAgainstPoolActiveID() {
        let outgoing = UUID()
        let incoming = UUID()
        // Normal sidebar switch: the pool still regards the outgoing service as
        // active, so the view layer stops its active poll before the pool
        // downgrades it to background.
        XCTAssertTrue(NotificationManager.shouldStopOutgoingPoll(
            previousID: outgoing, poolActiveID: outgoing))
        // Deep-link switch: AppState already made the incoming service active
        // and moved the outgoing one onto a background poll, so the view layer
        // must NOT stop it (that was the OPEN-ITEMS item 1 race).
        XCTAssertFalse(NotificationManager.shouldStopOutgoingPoll(
            previousID: outgoing, poolActiveID: incoming))
        // No previously displayed service: nothing to stop.
        XCTAssertFalse(NotificationManager.shouldStopOutgoingPoll(
            previousID: nil, poolActiveID: incoming))
    }

    func testNotifiesOSEffectiveDefaultsToEnabledForLegacyRows() {
        let service = ServiceInstance(label: "X", url: "https://x.test")
        // nil (new row, or a row created before the flag existed) → enabled,
        // preserving the prior always-notify behavior.
        XCTAssertNil(service.osNotificationsEnabled)
        XCTAssertTrue(service.notifiesOSEffective)
        // Explicit values are honored.
        service.osNotificationsEnabled = false
        XCTAssertFalse(service.notifiesOSEffective)
        service.osNotificationsEnabled = true
        XCTAssertTrue(service.notifiesOSEffective)
    }

    // MARK: - EmojiPickerView.emojiToPromote

    func testEmojiToPromotePromotesEmojiFromSearchField() {
        // A single emoji picked from the system Character Viewer lands as the
        // selection rather than a search query.
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "🎉"), "🎉")
        // Skin-tone modifiers, ZWJ sequences, VS16, and flags stay intact.
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "👍🏽"), "👍🏽")
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "👩‍💻"), "👩‍💻")
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "❤️"), "❤️")
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "🇺🇸"), "🇺🇸")
        // Surrounding whitespace is ignored.
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "  🚀 "), "🚀")
        // When several emoji are present, the most recent pick wins.
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "😀😃"), "😃")
    }

    func testEmojiToPromoteLeavesKeywordSearchesAlone() {
        // Ordinary text must keep filtering the grid, not get promoted.
        XCTAssertNil(EmojiPickerView.emojiToPromote(from: "smile"))
        XCTAssertNil(EmojiPickerView.emojiToPromote(from: ""))
        XCTAssertNil(EmojiPickerView.emojiToPromote(from: "   "))
        // Bare digits report isEmoji == true but aren't real emoji.
        XCTAssertNil(EmojiPickerView.emojiToPromote(from: "123"))
        // Mixed text + emoji is treated as a search.
        XCTAssertNil(EmojiPickerView.emojiToPromote(from: "cat 🐱"))
    }

    // MARK: - About: version string

    func testAppVersionStringFormatsShortAndBuild() {
        XCTAssertEqual(
            AppVersion.string(from: ["CFBundleShortVersionString": "1.0.2", "CFBundleVersion": "3"]),
            "Version 1.0.2 (3)"
        )
    }

    func testAppVersionStringFallsBackWhenKeysMissing() {
        XCTAssertEqual(AppVersion.string(from: nil), "Version — (—)")
        XCTAssertEqual(
            AppVersion.string(from: ["CFBundleShortVersionString": "2.0"]),
            "Version 2.0 (—)"
        )
    }

    // MARK: - Custom CSS injection + resolution

    func testCSSInjectionScriptEscapesCSSAndTagsStyle() {
        let css = ".x { content: \"a\"; }\n.y { color: red; }"
        let script = UserScriptManager.makeCSSInjectionScript(css: css)
        // The <style> gets a stable id so re-injection is idempotent.
        XCTAssertTrue(script.contains("chorus-custom-css"))
        // CSS is embedded as a JSON string literal, so the inner quotes are
        // escaped rather than able to break out of the script.
        XCTAssertTrue(script.contains("\\\"a\\\""), "quotes should be JSON-escaped")
        // The raw newline is encoded, so the second rule can't sit on its own
        // line inside the JS source.
        XCTAssertFalse(script.contains("\n.y { color: red; }"), "raw newline must be encoded")
    }

    func testEffectiveCSSPrefersInstanceThenDefaultThenNothing() {
        // No instance CSS → the baked-in default for a known service.
        XCTAssertEqual(
            ServiceCSSDefaults.effectiveCSS(instanceCSS: nil, catalogID: "linkedin"),
            ServiceCSSDefaults.linkedInMessaging
        )
        // An instance override wins over the default.
        XCTAssertEqual(
            ServiceCSSDefaults.effectiveCSS(instanceCSS: "body{}", catalogID: "linkedin"),
            "body{}"
        )
        // A blank override injects nothing — an explicit "no CSS".
        XCTAssertNil(ServiceCSSDefaults.effectiveCSS(instanceCSS: "   ", catalogID: "linkedin"))
        // A service with neither an override nor a default gets nothing.
        XCTAssertNil(ServiceCSSDefaults.effectiveCSS(instanceCSS: nil, catalogID: "slack"))
        XCTAssertNil(ServiceCSSDefaults.effectiveCSS(instanceCSS: nil, catalogID: nil))
    }

    func testLinkedInShipsBakedInMessagingCSS() {
        let css = ServiceCSSDefaults.css(forCatalogID: "linkedin")
        XCTAssertNotNil(css)
        XCTAssertTrue(css?.contains("#global-nav") == true)
        XCTAssertTrue(css?.contains(".scaffold-layout__aside") == true)
    }

    func testServiceInstanceCustomCSSDefaultsNil() {
        let service = ServiceInstance(label: "X", url: "https://x.test", catalogEntryID: "linkedin")
        // A fresh instance carries no override, so it tracks the baked-in default.
        XCTAssertNil(service.customCSS)
    }

    // MARK: - Stay-active / presence

    func testStayActiveDefaultsOff() {
        let service = ServiceInstance(label: "X", url: "https://x.test")
        // Opt-in only: a fresh service never fakes focus.
        XCTAssertFalse(service.staysActiveInBackgroundEffective)
        XCTAssertNil(service.stayActiveInBackground)
    }

    func testStayActiveEffectiveMaterialisesStoredValue() {
        let on = ServiceInstance(label: "X", url: "https://x.test", stayActiveInBackground: true)
        XCTAssertTrue(on.staysActiveInBackgroundEffective)
        let off = ServiceInstance(label: "Y", url: "https://y.test", stayActiveInBackground: false)
        XCTAssertFalse(off.staysActiveInBackgroundEffective)
    }

    func testFocusOverrideScriptFakesFocusAndSwallowsBlur() {
        let script = UserScriptManager.makeFocusOverrideScript()
        // hasFocus() must report true so a presence check reads active. It's
        // installed by redefining the property, so the name is a quoted literal.
        XCTAssertTrue(script.contains("'hasFocus'"))
        XCTAssertTrue(script.contains("return true"))
        // Blur is swallowed on both window and document, capture phase, so the
        // page's own idle timer never starts.
        XCTAssertTrue(script.contains("stopImmediatePropagation"))
        XCTAssertTrue(script.contains("window.addEventListener('blur'"))
        XCTAssertTrue(script.contains("document.addEventListener('blur'"))
        // Only the top-level window/document blur is swallowed — a form field's
        // own blur (which captures through the same listener) must still reach
        // the page, or dropdowns and draft-saving break.
        XCTAssertTrue(script.contains("e.target === window"))
        XCTAssertTrue(script.contains("e.target === document"))
    }

    func testTeamsIsPresenceSensitiveInCatalog() {
        let catalog = ServiceCatalog.shared
        // Teams broadcasts a status that goes away on blur, so it carries the flag
        // that drives the add-time "always appear active" offer.
        XCTAssertEqual(catalog.entry(for: "teams")?.presenceSensitive, true)
        // A service with no presence status must not carry it (nil, not false).
        XCTAssertNil(catalog.entry(for: "gmail")?.presenceSensitive)
    }

    func testCatalogEntryDecodesWithoutPresenceKey() {
        // Entries predating the key must still decode, with presenceSensitive nil.
        let json = """
        [{"id":"x","name":"X","url":"https://x.test","icon":"x","category":"Other","badgeJS":null,"userAgent":null,"description":"d"}]
        """.data(using: .utf8)!
        let entries = try! JSONDecoder().decode([ServiceCatalogEntry].self, from: json)
        XCTAssertNil(entries[0].presenceSensitive)
    }

    // MARK: - Zoom resolution

    @MainActor
    func testEffectiveZoomPrefersPerServiceThenGlobalDefault() {
        // An explicit per-service zoom wins over the global default.
        XCTAssertEqual(AppState.effectiveZoom(pageZoom: 1.25, defaultZoom: 0.9), 1.25)
        // With no per-service zoom, the global default applies.
        XCTAssertEqual(AppState.effectiveZoom(pageZoom: nil, defaultZoom: 0.9), 0.9)
        XCTAssertEqual(AppState.effectiveZoom(pageZoom: nil, defaultZoom: 1.0), 1.0)
    }

    func testAppPreferencesDefaultZoomEffectiveFallsBackToOne() {
        XCTAssertEqual(AppPreferences().defaultZoomEffective, 1.0)
        XCTAssertEqual(AppPreferences(defaultZoom: 0.8).defaultZoomEffective, 0.8)
    }

    func testGoogleFaviconFallbackIsOffUnlessOptedIn() {
        // A legacy row (nil) must resolve to off: the fallback discloses the
        // service hostname to a third party, so an upgrade shouldn't start
        // doing that without the user asking.
        XCTAssertFalse(AppPreferences().googleFaviconFallbackEnabledEffective)
        XCTAssertTrue(AppPreferences(googleFaviconFallbackEnabled: true)
            .googleFaviconFallbackEnabledEffective)
        XCTAssertFalse(AppPreferences(googleFaviconFallbackEnabled: false)
            .googleFaviconFallbackEnabledEffective)
    }

    func testAutoHibernateDefaultsToOffAndTenMinutes() {
        // Off on a legacy row — an upgrade must not start hibernating services
        // without the user opting in.
        XCTAssertFalse(AppPreferences().autoHibernateIdleEnabledEffective)
        XCTAssertTrue(AppPreferences(autoHibernateIdleEnabled: true)
            .autoHibernateIdleEnabledEffective)
        XCTAssertEqual(AppPreferences().autoHibernateIdleMinutesEffective, 10)
    }

    func testAutoHibernateMinutesClampToSaneRange() {
        // A stored value outside 1...120 is clamped rather than trusted, so a
        // corrupt or hostile row can't set a zero/negative sweep interval.
        XCTAssertEqual(AppPreferences(autoHibernateIdleMinutes: 0).autoHibernateIdleMinutesEffective, 1)
        XCTAssertEqual(AppPreferences(autoHibernateIdleMinutes: -5).autoHibernateIdleMinutesEffective, 1)
        XCTAssertEqual(AppPreferences(autoHibernateIdleMinutes: 5).autoHibernateIdleMinutesEffective, 5)
        XCTAssertEqual(AppPreferences(autoHibernateIdleMinutes: 9999).autoHibernateIdleMinutesEffective, 120)
    }

    func testMessagingServicesAreNotificationCriticalInCatalog() {
        // The auto-hibernation exemption keys off the catalog category, so guard
        // that the messaging apps the user relies on carry it and a heavy
        // non-chat service does not.
        let catalog = ServiceCatalog.shared
        for id in ["slack", "teams", "whatsapp", "discord"] {
            XCTAssertEqual(catalog.entry(for: id)?.category, "Messaging",
                           "\(id) must stay in the Messaging category")
        }
        XCTAssertNotEqual(catalog.entry(for: "spotify")?.category, "Messaging")
    }

    // MARK: - Per-service hibernation policy

    func testHibernationPolicyMigratesLegacyKeepLoaded() {
        // A pre-existing row has no raw policy, only the legacy neverHibernate
        // flag — it must keep behaving as "Keep Loaded" (.never), and an ordinary
        // legacy row must default to following the global setting.
        let kept = ServiceInstance(label: "K", url: "https://k.example", neverHibernate: true)
        XCTAssertEqual(kept.hibernationPolicyEffective, .never)

        let ordinary = ServiceInstance(label: "O", url: "https://o.example", neverHibernate: false)
        XCTAssertEqual(ordinary.hibernationPolicyEffective, .followGlobal)
    }

    func testHibernationPolicyRawWinsOverLegacyFlag() {
        // Once a raw policy is stored it is authoritative, even if the legacy flag
        // disagrees (as it does for .never, which we keep synced to true).
        let immediate = ServiceInstance(
            label: "I", url: "https://i.example",
            neverHibernate: true, hibernationPolicyRaw: HibernationPolicy.immediate.rawValue)
        XCTAssertEqual(immediate.hibernationPolicyEffective, .immediate)

        let after = ServiceInstance(
            label: "A", url: "https://a.example",
            hibernationPolicyRaw: HibernationPolicy.after.rawValue)
        XCTAssertEqual(after.hibernationPolicyEffective, .after)
    }

    func testHibernationPolicyUnknownRawFallsBackToFollowGlobal() {
        // A corrupt or future-written raw value must not crash or silently pin an
        // unexpected behavior — it falls back to following the global setting.
        let svc = ServiceInstance(
            label: "X", url: "https://x.example",
            hibernationPolicyRaw: "nonsense")
        XCTAssertEqual(svc.hibernationPolicyEffective, .followGlobal)
    }

    func testHibernateAfterMinutesClampToSaneRange() {
        // Same guard as the global interval: an out-of-range stored value is
        // clamped, and an unset one defaults to ten minutes.
        XCTAssertEqual(ServiceInstance(label: "S", url: "https://s.example").hibernateAfterMinutesEffective, 10)
        XCTAssertEqual(ServiceInstance(label: "S", url: "https://s.example", hibernateAfterMinutes: 0).hibernateAfterMinutesEffective, 1)
        XCTAssertEqual(ServiceInstance(label: "S", url: "https://s.example", hibernateAfterMinutes: -5).hibernateAfterMinutesEffective, 1)
        XCTAssertEqual(ServiceInstance(label: "S", url: "https://s.example", hibernateAfterMinutes: 45).hibernateAfterMinutesEffective, 45)
        XCTAssertEqual(ServiceInstance(label: "S", url: "https://s.example", hibernateAfterMinutes: 9999).hibernateAfterMinutesEffective, 120)
    }

    func testIsNotificationCriticalByCatalogCategory() {
        // The edit sheet caption and the sweep exemption both read this, so a chat
        // app must report true, a heavy non-chat catalog app false, and a custom
        // (non-catalog) service false — those must use .never instead.
        XCTAssertTrue(ServiceInstance(label: "Slack", url: "https://slack.example", catalogEntryID: "slack").isNotificationCritical)
        XCTAssertFalse(ServiceInstance(label: "Gmail", url: "https://gmail.example", catalogEntryID: "gmail").isNotificationCritical)
        XCTAssertFalse(ServiceInstance(label: "Custom", url: "https://custom.example").isNotificationCritical)
    }

    func testHibernationResolverThresholdPerPolicy() {
        // .never never fires, regardless of the global toggle.
        XCTAssertNil(HibernationResolver.idleThreshold(
            policy: .never, globalEnabled: true, globalIdleMinutes: 30, afterMinutes: 10))
        XCTAssertNil(HibernationResolver.idleThreshold(
            policy: .never, globalEnabled: false, globalIdleMinutes: 30, afterMinutes: 10))

        // .followGlobal uses the global interval only while the global toggle is
        // on; with it off the service must not hibernate on the sweep at all.
        XCTAssertEqual(HibernationResolver.idleThreshold(
            policy: .followGlobal, globalEnabled: true, globalIdleMinutes: 30, afterMinutes: 10), 1800)
        XCTAssertNil(HibernationResolver.idleThreshold(
            policy: .followGlobal, globalEnabled: false, globalIdleMinutes: 30, afterMinutes: 10))

        // .after uses the service's own minutes, independent of the global toggle.
        XCTAssertEqual(HibernationResolver.idleThreshold(
            policy: .after, globalEnabled: false, globalIdleMinutes: 30, afterMinutes: 5), 300)
        XCTAssertEqual(HibernationResolver.idleThreshold(
            policy: .after, globalEnabled: true, globalIdleMinutes: 30, afterMinutes: 45), 2700)

        // .immediate uses the short backstop, whether or not the global toggle is on.
        XCTAssertEqual(HibernationResolver.idleThreshold(
            policy: .immediate, globalEnabled: false, globalIdleMinutes: 30, afterMinutes: 10),
            HibernationResolver.immediateBackstopSeconds)
        XCTAssertEqual(HibernationResolver.idleThreshold(
            policy: .immediate, globalEnabled: true, globalIdleMinutes: 30, afterMinutes: 10),
            HibernationResolver.immediateBackstopSeconds)
    }

    // MARK: - Scheduled DND (quiet hours)

    @MainActor
    func testQuietHoursSameDayWindow() {
        // 09:00–17:00.
        let start = 9 * 60, end = 17 * 60
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: 10 * 60, start: start, end: end))
        XCTAssertFalse(AppState.isWithinQuietHours(nowMinutes: 8 * 60, start: start, end: end))
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: end - 1, start: start, end: end))
        XCTAssertFalse(AppState.isWithinQuietHours(nowMinutes: end, start: start, end: end), "end is exclusive")
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: start, start: start, end: end), "start is inclusive")
    }

    @MainActor
    func testQuietHoursWrapsMidnight() {
        // 22:00–07:00.
        let start = 22 * 60, end = 7 * 60
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: 23 * 60, start: start, end: end))
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: 5 * 60, start: start, end: end))
        XCTAssertFalse(AppState.isWithinQuietHours(nowMinutes: end, start: start, end: end), "end is exclusive")
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: end - 1, start: start, end: end))
        XCTAssertFalse(AppState.isWithinQuietHours(nowMinutes: 20 * 60, start: start, end: end))
    }

    @MainActor
    func testQuietHoursZeroLengthWindowIsNeverActive() {
        XCTAssertFalse(AppState.isWithinQuietHours(nowMinutes: 12 * 60, start: 9 * 60, end: 9 * 60))
    }

    // MARK: - Dark mode

    func testForceDarkModeDefaultsOff() {
        XCTAssertFalse(ServiceInstance(label: "X", url: "https://x.test").isForceDarkModeEnabled)
        XCTAssertTrue(ServiceInstance(label: "X", url: "https://x.test", forceDarkMode: true).isForceDarkModeEnabled)
        XCTAssertFalse(ServiceInstance(label: "X", url: "https://x.test", forceDarkMode: false).isForceDarkModeEnabled)
    }

    // MARK: - Link routing (belongsToService)

    func testBelongsToServiceKeepsSlackWorkspacesInApp() {
        // Same registrable domain, subdomain differs — Slack switching
        // workspaces must stay in-app rather than spawning a new window.
        XCTAssertTrue(WebViewCoordinator.belongsToService("app.slack.com", serviceHost: "app.slack.com"))
        XCTAssertTrue(WebViewCoordinator.belongsToService("myteam.slack.com", serviceHost: "app.slack.com"))
        XCTAssertTrue(WebViewCoordinator.belongsToService("app.slack.com", serviceHost: "myteam.slack.com"))
    }

    func testBelongsToServiceSeparatesGoogleProducts() {
        // Shared-umbrella domain: a Docs/Drive link must NOT be treated as part
        // of the Gmail service (the reported "Google Docs opened in Gmail" bug).
        XCTAssertFalse(WebViewCoordinator.belongsToService("docs.google.com", serviceHost: "mail.google.com"))
        XCTAssertFalse(WebViewCoordinator.belongsToService("drive.google.com", serviceHost: "mail.google.com"))
        // The exact same host is still the same service.
        XCTAssertTrue(WebViewCoordinator.belongsToService("mail.google.com", serviceHost: "mail.google.com"))
        XCTAssertTrue(WebViewCoordinator.belongsToService("docs.google.com", serviceHost: "docs.google.com"))
    }

    func testBelongsToServiceRejectsUnrelatedDomains() {
        XCTAssertFalse(WebViewCoordinator.belongsToService("example.com", serviceHost: "slack.com"))
        XCTAssertFalse(WebViewCoordinator.belongsToService("notion.so", serviceHost: "mail.google.com"))
    }

    func testBelongsToServiceIgnoresWWWAndCase() {
        XCTAssertTrue(WebViewCoordinator.belongsToService("www.notion.so", serviceHost: "notion.so"))
        XCTAssertTrue(WebViewCoordinator.belongsToService("APP.SLACK.COM", serviceHost: "app.slack.com"))
    }

    func testBelongsToServiceSeparatesSharedHostingTenants() {
        // Multi-tenant hosting suffixes: each label under the suffix is a
        // DIFFERENT owner, so an attacker sibling must NOT be treated as part of
        // a user's service (which would load its page in the service's
        // authenticated web view). The naive registrable-domain reduction
        // collapsed both to the bare suffix (e.g. "vercel.app") and returned true.
        XCTAssertFalse(WebViewCoordinator.belongsToService("evil.vercel.app", serviceHost: "team.vercel.app"))
        XCTAssertFalse(WebViewCoordinator.belongsToService("attacker.github.io", serviceHost: "myproject.github.io"))
        XCTAssertFalse(WebViewCoordinator.belongsToService("evil.pages.dev", serviceHost: "app.pages.dev"))
        XCTAssertFalse(WebViewCoordinator.belongsToService("evil.workers.dev", serviceHost: "api.workers.dev"))
        // A window.open target on the same tenant is still the same service.
        XCTAssertTrue(WebViewCoordinator.belongsToService("team.vercel.app", serviceHost: "team.vercel.app"))
        XCTAssertTrue(WebViewCoordinator.belongsToService("app.team.vercel.app", serviceHost: "team.vercel.app"))
    }

    func testAuthHostsAreRecognized() {
        // Identity gateways stay in-app so sign-in completes (the reported
        // "Gmail login kicked to the default browser" bug).
        XCTAssertTrue(WebViewCoordinator.isAuthHost("accounts.google.com"))
        XCTAssertTrue(WebViewCoordinator.isAuthHost("login.microsoftonline.com"))
        XCTAssertTrue(WebViewCoordinator.isAuthHost("appleid.apple.com"))
        // Case- and www-insensitive, and subdomains of a gateway still match.
        XCTAssertTrue(WebViewCoordinator.isAuthHost("ACCOUNTS.GOOGLE.COM"))
        XCTAssertTrue(WebViewCoordinator.isAuthHost("eu.login.microsoftonline.com"))
        // Ordinary product hosts are not auth gateways.
        XCTAssertFalse(WebViewCoordinator.isAuthHost("mail.google.com"))
        XCTAssertFalse(WebViewCoordinator.isAuthHost("docs.google.com"))
        XCTAssertFalse(WebViewCoordinator.isAuthHost("example.com"))
    }

    func testAuthHostExemptionLeavesUmbrellaSeparationIntact() {
        // The exemption is layered on top of belongsToService, not baked into
        // it: Google products stay separate for ordinary link routing.
        XCTAssertFalse(WebViewCoordinator.belongsToService("accounts.google.com", serviceHost: "mail.google.com"))
        XCTAssertFalse(WebViewCoordinator.belongsToService("docs.google.com", serviceHost: "mail.google.com"))
    }

    // MARK: - Download destination

    func testSanitizedDownloadFilenameStripsPathParts() {
        // A crafted name must not be able to escape the Downloads folder.
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename("../../etc/passwd"), "passwd")
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename("report.pdf"), "report.pdf")
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename("a/b/c.txt"), "c.txt")
    }

    func testSanitizedDownloadFilenameFallsBackWhenEmpty() {
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename(""), "download")
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename("   "), "download")
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename("/"), "download")
    }

    func testNonCollidingURLReturnsBaseWhenFree() {
        let dir = URL(fileURLWithPath: "/Users/x/Downloads")
        let url = WebViewCoordinator.nonCollidingURL(in: dir, filename: "a.txt", fileExists: { _ in false })
        XCTAssertEqual(url.lastPathComponent, "a.txt")
    }

    func testNonCollidingURLAppendsIndexOnCollision() {
        let dir = URL(fileURLWithPath: "/Users/x/Downloads")
        // "a.txt" and "a (1).txt" are taken; the next free name is "a (2).txt".
        let taken: Set<String> = ["a.txt", "a (1).txt"]
        let url = WebViewCoordinator.nonCollidingURL(
            in: dir,
            filename: "a.txt",
            fileExists: { taken.contains($0.lastPathComponent) }
        )
        XCTAssertEqual(url.lastPathComponent, "a (2).txt")
    }

    func testNonCollidingURLHandlesExtensionlessNames() {
        let dir = URL(fileURLWithPath: "/Users/x/Downloads")
        let taken: Set<String> = ["README"]
        let url = WebViewCoordinator.nonCollidingURL(
            in: dir,
            filename: "README",
            fileExists: { taken.contains($0.lastPathComponent) }
        )
        XCTAssertEqual(url.lastPathComponent, "README (1)")
    }

    private func httpResponse(headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/file")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    func testIsAttachmentDetectsDisposition() {
        XCTAssertTrue(WebViewCoordinator.isAttachment(
            httpResponse(headers: ["Content-Disposition": "attachment; filename=\"report.pdf\""])
        ))
        // Case-insensitive on the header value.
        XCTAssertTrue(WebViewCoordinator.isAttachment(
            httpResponse(headers: ["Content-Disposition": "ATTACHMENT"])
        ))
    }

    func testIsAttachmentFalseForInlineOrMissing() {
        XCTAssertFalse(WebViewCoordinator.isAttachment(
            httpResponse(headers: ["Content-Disposition": "inline"])
        ))
        XCTAssertFalse(WebViewCoordinator.isAttachment(httpResponse(headers: [:])))
        // A non-HTTP response has no headers to inspect.
        let url = URL(string: "https://example.com")!
        XCTAssertFalse(WebViewCoordinator.isAttachment(
            URLResponse(url: url, mimeType: "application/pdf", expectedContentLength: 1, textEncodingName: nil)
        ))
    }

    // MARK: - Passkey notice

    func testNeedsPasskeyNoticeDefaultsTrueForNewService() {
        // A freshly created service has never seen the notice.
        let service = ServiceInstance(label: "Test", url: "https://example.com")
        XCTAssertTrue(service.needsPasskeyNotice)
    }

    func testNeedsPasskeyNoticeFalseOnceSeen() {
        let service = ServiceInstance(label: "Test", url: "https://example.com", hasSeenPasskeyNotice: true)
        XCTAssertFalse(service.needsPasskeyNotice)
    }

    // MARK: - Content blocker

    // MARK: - Dark Reader

    func testDarkInjectionTruthTable() {
        typealias I = DarkReaderSupport.DarkInjection
        // `.themed` only when the mode is On AND the app is dark; every other
        // combination of mode × appDark is `.none`.
        XCTAssertEqual(DarkReaderSupport.injection(mode: .on, appDark: true), I.themed)
        XCTAssertEqual(DarkReaderSupport.injection(mode: .on, appDark: false), I.none)
        XCTAssertEqual(DarkReaderSupport.injection(mode: .off, appDark: true), I.none)
        XCTAssertEqual(DarkReaderSupport.injection(mode: .off, appDark: false), I.none)
    }

    func testGmailBadgeCountsUnreadRowsNotInboxAriaLabel() {
        // The badge counts unread conversation rows in the current inbox view
        // (Gmail marks them tr.zA.zE), matching what the user sees. It must no
        // longer read the "Inbox N unread" aria-label, which sums unread across
        // every inbox category/section and showed 99+ over a visibly empty view.
        let js = ServiceCatalog.shared.entry(for: "gmail")?.badgeJS ?? ""
        XCTAssertTrue(js.contains("tr.zA.zE"), "Gmail badge should count unread conversation rows")
        XCTAssertFalse(js.contains("unread"), "Gmail badge should not parse the Inbox aria-label unread total")
        XCTAssertFalse(js.contains("aria-label"), "Gmail badge should not read an aria-label")
    }

    func testDarkModeMigrationFromLegacyFlag() {
        // Explicit mode wins.
        XCTAssertEqual(ServiceInstance(label: "x", url: "https://e.com", darkModeRaw: "off").darkMode, .off)
        XCTAssertEqual(ServiceInstance(label: "x", url: "https://e.com", darkModeRaw: "on").darkMode, .on)
        // Legacy force-dark maps to On.
        XCTAssertEqual(ServiceInstance(label: "x", url: "https://e.com", forceDarkMode: true).darkMode, .on)
        // A stored "auto" (from before manual-only) and nothing set both resolve
        // to Off — manual theming is opt-in, so a service that rode the old auto
        // mode stops theming until the user turns it back on.
        XCTAssertEqual(ServiceInstance(label: "x", url: "https://e.com", darkModeRaw: "auto").darkMode, .off)
        XCTAssertEqual(ServiceInstance(label: "x", url: "https://e.com").darkMode, .off)
    }

    func testAnnoyanceBlockingDefaultsFalse() {
        XCTAssertFalse(AppPreferences().annoyanceBlockingEnabledEffective)
        XCTAssertTrue(AppPreferences(annoyanceBlockingEnabled: true).annoyanceBlockingEnabledEffective)
    }

    func testDarkReaderBootstrapEnablesOnlyWhenDark() {
        let dark = DarkReaderSupport.bootstrapScript(enable: true)
        XCTAssertTrue(dark.contains("DarkReader.enable"))
        XCTAssertTrue(dark.contains("setFetchMethod(window.fetch)"))

        let light = DarkReaderSupport.bootstrapScript(enable: false)
        XCTAssertFalse(light.contains("DarkReader.enable("))
        XCTAssertTrue(light.contains("setFetchMethod(window.fetch)"))
    }

    func testDarkReaderAntiFlashSetsDarkBackground() {
        let s = DarkReaderSupport.antiFlashScript()
        XCTAssertTrue(s.contains("chorus-dr-antiflash"))
        XCTAssertTrue(s.contains("#1a1a1a"))
    }

    func testDarkReaderLoadCoverRevealsAndSelfRemoves() {
        let s = DarkReaderSupport.antiFlashScript()
        // The cover is an opaque overlay on top of everything, not a background
        // style, so it hides Dark Reader's washed intermediate pass, not just a
        // white flash.
        XCTAssertTrue(s.contains("z-index:2147483647"))
        // It reveals once the page stops mutating and removes itself afterward.
        XCTAssertTrue(s.contains("MutationObserver"))
        XCTAssertTrue(s.contains("removeChild"))
        // An absolute failsafe guarantees it can never trap the view.
        XCTAssertTrue(s.contains("setTimeout(reveal, FAILSAFE_MS)"))
        // Interaction is restored the instant the fade begins.
        XCTAssertTrue(s.contains("pointerEvents = 'none'"))
        // The cover is visual only, never modal: it's click-through from creation
        // so a page that settles before it reveals stays usable underneath
        // instead of having its input swallowed by the overlay.
        XCTAssertTrue(s.contains("pointer-events:none"))
        // Theming is always baked at document-start now (no detection verdict to
        // wait for), so the cover begins settling immediately.
        XCTAssertTrue(s.contains("beginSettle();"))
    }

    func testDarkReaderLoadCoverSettleCapIsConfigurable() {
        XCTAssertTrue(DarkReaderSupport.antiFlashScript(settleCapMs: 6000).contains("SETTLE_CAP_MS = 6000"))
    }

    func testDarkReaderCoverHooksAreWired() {
        let cover = DarkReaderSupport.antiFlashScript()
        // The cover exposes the dismiss hook its live caller reaches across the
        // shared isolated-world globals; disabling theming tears it down.
        XCTAssertTrue(cover.contains("window.__chorusCoverDismiss"))
        XCTAssertTrue(DarkReaderSupport.disableJS.contains("__chorusCoverDismiss"))
    }

    func testContentBlockingEnabledDefaultsTrue() {
        // nil (existing installs / fresh) resolves to enabled.
        XCTAssertTrue(AppPreferences().contentBlockingEnabledEffective)
        XCTAssertFalse(AppPreferences(contentBlockingEnabled: false).contentBlockingEnabledEffective)
    }

    func testBlocklistIdentifierIsStableAndContentAddressed() {
        let a = BlocklistSupport.identifier(prefix: "hz", forJSON: "[1,2,3]")
        let b = BlocklistSupport.identifier(prefix: "hz", forJSON: "[1,2,3]")
        let c = BlocklistSupport.identifier(prefix: "hz", forJSON: "[1,2,4]")
        XCTAssertEqual(a, b)                 // same JSON → same id (cache hit)
        XCTAssertNotEqual(a, c)              // changed JSON → new id (recompile)
        XCTAssertTrue(a.hasPrefix("hz-"))
    }

    func testBlocklistRuleCountAndChunkingGuard() throws {
        let json = "[{\"x\":1},{\"x\":2},{\"x\":3}]"
        XCTAssertEqual(try BlocklistSupport.ruleCount(inJSON: json), 3)
        XCTAssertFalse(BlocklistSupport.needsChunking(count: 3, cap: 5))
        XCTAssertTrue(BlocklistSupport.needsChunking(count: 6, cap: 5))
    }

    func testBlocklistChunkUnderCapReturnsSingle() throws {
        let json = "[{\"x\":1},{\"x\":2}]"
        let chunks = try BlocklistSupport.chunk(json: json, cap: 10)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, json)
    }

    func testBlocklistChunkSplitsOverCapPreservingTotal() throws {
        let rules = (0..<7).map { "{\"x\":\($0)}" }.joined(separator: ",")
        let json = "[\(rules)]"
        let chunks = try BlocklistSupport.chunk(json: json, cap: 3)
        XCTAssertEqual(chunks.count, 3)  // 3 + 3 + 1
        let total = try chunks.reduce(0) { $0 + (try BlocklistSupport.ruleCount(inJSON: $1)) }
        XCTAssertEqual(total, 7)
    }

    func testBlocklistChunkRejectsNonArray() {
        XCTAssertThrowsError(try BlocklistSupport.chunk(json: "{\"not\":\"an array\"}"))
    }

    // MARK: - Rail layout preference

    func testRailLayoutParsesFromStoredValueWithSidebarFallback() {
        XCTAssertEqual(AppPreferences(railLayoutRaw: nil).railLayout, .sidebar)
        XCTAssertEqual(AppPreferences(railLayoutRaw: "sidebar").railLayout, .sidebar)
        XCTAssertEqual(AppPreferences(railLayoutRaw: "topBars").railLayout, .topBars)
        XCTAssertEqual(AppPreferences(railLayoutRaw: "hybrid").railLayout, .hybrid)
        XCTAssertEqual(AppPreferences(railLayoutRaw: "garbage").railLayout, .sidebar)
    }

    func testAppearanceModeParsesFromStoredValueWithSystemFallback() {
        XCTAssertEqual(AppPreferences(appearanceModeRaw: nil).appearanceMode, .system)
        XCTAssertEqual(AppPreferences(appearanceModeRaw: "system").appearanceMode, .system)
        XCTAssertEqual(AppPreferences(appearanceModeRaw: "light").appearanceMode, .light)
        XCTAssertEqual(AppPreferences(appearanceModeRaw: "dark").appearanceMode, .dark)
        XCTAssertEqual(AppPreferences(appearanceModeRaw: "garbage").appearanceMode, .system)
    }

    // MARK: - Notification grouping by space

    /// A fresh in-memory store. `NotificationGrouping.grouped` now skips links
    /// whose service has no `modelContext` (a dangling or never-inserted model),
    /// so these tests must use live, inserted models rather than detached ones.
    /// Returns the container — the caller must hold it for the test's duration;
    /// using only its `mainContext` after the container deallocates crashes.
    private func makeGroupingContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Space.self, ServiceInstance.self, SpaceServiceLink.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Links an already-inserted service to an already-inserted space by
    /// inserting a join row; SwiftData maintains both relationship sides.
    @discardableResult
    private func link(_ service: ServiceInstance, to space: Space, sortOrder: Int, in ctx: ModelContext) -> SpaceServiceLink {
        let link = SpaceServiceLink(sortOrder: sortOrder, space: space, service: service)
        ctx.insert(link)
        return link
    }

    func testNotificationGroupingIsFlatAndHeaderlessWhenNoSpacesHaveMembers() throws {
        let container = try makeGroupingContainer()
        let ctx = container.mainContext
        let a = ServiceInstance(label: "Zulip", url: "https://z.example")
        let b = ServiceInstance(label: "Asana", url: "https://a.example")
        let empty = Space(name: "Empty", emoji: "📭", sortOrder: 0)
        [a, b].forEach(ctx.insert)
        ctx.insert(empty)
        try ctx.save()

        let result = NotificationGrouping.grouped(spaces: [empty], services: [a, b])

        XCTAssertFalse(result.showsHeaders)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertNil(result.groups[0].space)
        // Flat bucket is sorted by label.
        XCTAssertEqual(result.groups[0].services.map(\.label), ["Asana", "Zulip"])
    }

    func testNotificationGroupingFollowsSpaceOrderThenLinkOrder() throws {
        let container = try makeGroupingContainer()
        let ctx = container.mainContext
        let work = Space(name: "Work", emoji: "🏢", sortOrder: 0)
        let play = Space(name: "Play", emoji: "🎮", sortOrder: 1)
        let slack = ServiceInstance(label: "Slack", url: "https://s.example")
        let gmail = ServiceInstance(label: "Gmail", url: "https://g.example")
        let discord = ServiceInstance(label: "Discord", url: "https://d.example")
        [work, play].forEach(ctx.insert)
        [slack, gmail, discord].forEach(ctx.insert)
        // Add gmail first but at a higher sortOrder to prove link order wins.
        link(gmail, to: work, sortOrder: 1, in: ctx)
        link(slack, to: work, sortOrder: 0, in: ctx)
        link(discord, to: play, sortOrder: 0, in: ctx)
        try ctx.save()

        let result = NotificationGrouping.grouped(spaces: [work, play], services: [slack, gmail, discord])

        XCTAssertTrue(result.showsHeaders)
        XCTAssertEqual(result.groups.map { $0.space?.name }, ["Work", "Play"])
        XCTAssertEqual(result.groups[0].services.map(\.label), ["Slack", "Gmail"])
        XCTAssertEqual(result.groups[1].services.map(\.label), ["Discord"])
    }

    func testNotificationGroupingPutsUngroupedServicesInTrailingBucket() throws {
        let container = try makeGroupingContainer()
        let ctx = container.mainContext
        let work = Space(name: "Work", emoji: "🏢", sortOrder: 0)
        let slack = ServiceInstance(label: "Slack", url: "https://s.example")
        let loose2 = ServiceInstance(label: "Notion", url: "https://n.example")
        let loose1 = ServiceInstance(label: "Figma", url: "https://f.example")
        ctx.insert(work)
        [slack, loose2, loose1].forEach(ctx.insert)
        link(slack, to: work, sortOrder: 0, in: ctx)
        try ctx.save()

        let result = NotificationGrouping.grouped(spaces: [work], services: [slack, loose2, loose1])

        XCTAssertTrue(result.showsHeaders)
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.groups[0].space?.name, "Work")
        XCTAssertNil(result.groups[1].space)  // the ungrouped bucket, last
        XCTAssertEqual(result.groups[1].services.map(\.label), ["Figma", "Notion"])
    }

    func testNotificationGroupingSkipsSpacesWithNoServices() throws {
        let container = try makeGroupingContainer()
        let ctx = container.mainContext
        let full = Space(name: "Full", emoji: "📥", sortOrder: 0)
        let empty = Space(name: "Empty", emoji: "📭", sortOrder: 1)
        let slack = ServiceInstance(label: "Slack", url: "https://s.example")
        [full, empty].forEach(ctx.insert)
        ctx.insert(slack)
        link(slack, to: full, sortOrder: 0, in: ctx)
        try ctx.save()

        let result = NotificationGrouping.grouped(spaces: [full, empty], services: [slack])

        XCTAssertEqual(result.groups.map { $0.space?.name }, ["Full"])
    }

    func testNotificationGroupingRepeatsServiceInEachSpace() throws {
        let container = try makeGroupingContainer()
        let ctx = container.mainContext
        let home = Space(name: "Home", emoji: "🏠", sortOrder: 0)
        let design = Space(name: "Design", emoji: "🎨", sortOrder: 1)
        let slack = ServiceInstance(label: "Slack", url: "https://s.example")
        [home, design].forEach(ctx.insert)
        ctx.insert(slack)
        link(slack, to: home, sortOrder: 0, in: ctx)
        link(slack, to: design, sortOrder: 0, in: ctx)
        try ctx.save()

        let result = NotificationGrouping.grouped(spaces: [home, design], services: [slack])

        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.groups[0].services.map(\.label), ["Slack"])
        XCTAssertEqual(result.groups[1].services.map(\.label), ["Slack"])
        // Same underlying object under both headers, so toggles stay in sync.
        XCTAssertTrue(result.groups[0].services[0] === result.groups[1].services[0])
        // No ungrouped bucket when every service belongs to a space.
        XCTAssertFalse(result.groups.contains { $0.space == nil })
    }

    /// Exercises the dangling-link guard: a link whose service has no
    /// `modelContext` (a deleted or never-inserted model — the crash class the
    /// guard exists for) must be skipped, not grouped or trapped on.
    func testNotificationGroupingSkipsLinkWhoseServiceIsDetached() throws {
        // A live space with a real, inserted, linked service.
        let container = try makeGroupingContainer()
        let ctx = container.mainContext
        let live = Space(name: "Live", emoji: "✅", sortOrder: 0)
        let alpha = ServiceInstance(label: "Alpha", url: "https://a.example")
        ctx.insert(live)
        ctx.insert(alpha)
        link(alpha, to: live, sortOrder: 0, in: ctx)
        try ctx.save()

        // A detached space whose link points at a never-inserted service — the
        // stand-in for a dangling link. Its service has a nil modelContext, so
        // the guard must skip it rather than group it.
        let ghost = Space(name: "Ghost", emoji: "👻", sortOrder: 1)
        let beta = ServiceInstance(label: "Beta", url: "https://b.example")
        let danglingLink = SpaceServiceLink(sortOrder: 0, space: ghost, service: beta)
        ghost.serviceLinks.append(danglingLink)
        beta.spaceLinks.append(danglingLink)

        let result = NotificationGrouping.grouped(spaces: [live, ghost], services: [alpha, beta])

        // Only the live space is grouped; the ghost's dangling link is skipped
        // and Beta appears nowhere. Without the guard, Ghost/Beta would show.
        XCTAssertEqual(result.groups.map { $0.space?.name }, ["Live"])
        XCTAssertEqual(result.groups.first?.services.map(\.label), ["Alpha"])
        XCTAssertFalse(result.groups.contains { group in
            group.services.contains { $0.label == "Beta" }
        })
    }

    // MARK: - Move service to space

    func testEligibleSpaceIDsExcludesCurrentMemberships() {
        let a = UUID(), b = UUID(), c = UUID()
        // A service that lives in `a` can be moved to `b` and `c`, not `a`.
        XCTAssertEqual(
            SpaceMove.eligibleSpaceIDs(allSpaceIDs: [a, b, c], memberSpaceIDs: [a]),
            [b, c]
        )
        // Order follows `allSpaceIDs` (the sorted space rail).
        XCTAssertEqual(
            SpaceMove.eligibleSpaceIDs(allSpaceIDs: [c, a, b], memberSpaceIDs: [a]),
            [c, b]
        )
    }

    func testEligibleSpaceIDsEmptyWhenServiceIsEverywhere() {
        let a = UUID(), b = UUID()
        // Already a member of every space → nothing to move into (menu falls
        // back to "New Space…" only).
        XCTAssertEqual(
            SpaceMove.eligibleSpaceIDs(allSpaceIDs: [a, b], memberSpaceIDs: [a, b]),
            []
        )
        // No spaces at all → nothing eligible.
        XCTAssertEqual(
            SpaceMove.eligibleSpaceIDs(allSpaceIDs: [], memberSpaceIDs: [a]),
            []
        )
    }

    /// Exercises the SwiftData reassignment behind `ServiceSidebarView.moveService`
    /// against a real in-memory store: repointing a link's `space` relocates the
    /// service between spaces (the source space loses it, the target gains it at
    /// the tail) and never leaves the service with zero or duplicate links.
    func testMoveServiceRelocatesLinkBetweenSpacesAtTail() throws {
        let container = try ModelContainer(
            for: Space.self, ServiceInstance.self, SpaceServiceLink.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        let spaceA = Space(name: "A", emoji: "🅰️", sortOrder: 0)
        let spaceB = Space(name: "B", emoji: "🅱️", sortOrder: 1)
        let moving = ServiceInstance(label: "Slack", url: "https://s.example")
        let residentOfB = ServiceInstance(label: "Gmail", url: "https://g.example")
        [spaceA, spaceB].forEach(ctx.insert)
        [moving, residentOfB].forEach(ctx.insert)

        let movingLink = SpaceServiceLink(sortOrder: 0, space: spaceA, service: moving)
        let bLink = SpaceServiceLink(sortOrder: 0, space: spaceB, service: residentOfB)
        [movingLink, bLink].forEach(ctx.insert)
        try ctx.save()

        // Replicate moveService: compute the target's tail order *before*
        // repointing, then reassign the link's space.
        let before = try ctx.fetch(FetchDescriptor<SpaceServiceLink>())
        let targetOrders = before.filter { $0.space.id == spaceB.id }.map(\.sortOrder)
        movingLink.sortOrder = (targetOrders.max() ?? -1) + 1
        movingLink.space = spaceB
        try ctx.save()

        let after = try ctx.fetch(FetchDescriptor<SpaceServiceLink>())
        let inA = after.filter { $0.space.id == spaceA.id }
        let inB = after.filter { $0.space.id == spaceB.id }.sorted { $0.sortOrder < $1.sortOrder }

        XCTAssertTrue(inA.isEmpty, "source space should hold no links after the move")
        XCTAssertEqual(inB.map { $0.service.label }, ["Gmail", "Slack"], "moved service lands at the tail of the target")
        XCTAssertEqual(inB.last?.sortOrder, 1)
        // The service keeps exactly one link: no orphan, no double-link.
        XCTAssertEqual(after.filter { $0.service.id == moving.id }.count, 1)
    }

    // MARK: - Media permission resolution

    func testMediaEffectivePolicyPrefersServiceThenGlobalThenAsk() {
        // Explicit service value wins over the global default.
        XCTAssertEqual(MediaPermissionResolver.effectivePolicy(serviceRaw: "allow", globalRaw: "deny"), .allow)
        // Falls back to the global default when the service has no value.
        XCTAssertEqual(MediaPermissionResolver.effectivePolicy(serviceRaw: nil, globalRaw: "deny"), .deny)
        // Falls back to .ask when neither is set, or either is unparseable.
        XCTAssertEqual(MediaPermissionResolver.effectivePolicy(serviceRaw: nil, globalRaw: nil), .ask)
        XCTAssertEqual(MediaPermissionResolver.effectivePolicy(serviceRaw: "garbage", globalRaw: nil), .ask)
    }

    func testMediaResolveSingleTypeReadsTheMatchingField() {
        // .camera reads only the camera field.
        XCTAssertEqual(MediaPermissionResolver.resolve(.camera, camera: .allow, microphone: .deny), .grant)
        XCTAssertEqual(MediaPermissionResolver.resolve(.camera, camera: .deny, microphone: .allow), .deny)
        XCTAssertEqual(MediaPermissionResolver.resolve(.camera, camera: .ask, microphone: .allow), .ask)
        // .microphone reads only the microphone field.
        XCTAssertEqual(MediaPermissionResolver.resolve(.microphone, camera: .allow, microphone: .deny), .deny)
        XCTAssertEqual(MediaPermissionResolver.resolve(.microphone, camera: .deny, microphone: .allow), .grant)
        XCTAssertEqual(MediaPermissionResolver.resolve(.microphone, camera: .allow, microphone: .ask), .ask)
    }

    func testMediaResolveCameraAndMicrophoneIsMostRestrictive() {
        // Grant only when BOTH allow.
        XCTAssertEqual(MediaPermissionResolver.resolve(.cameraAndMicrophone, camera: .allow, microphone: .allow), .grant)
        // Deny if EITHER denies (deny beats ask and allow).
        XCTAssertEqual(MediaPermissionResolver.resolve(.cameraAndMicrophone, camera: .deny, microphone: .allow), .deny)
        XCTAssertEqual(MediaPermissionResolver.resolve(.cameraAndMicrophone, camera: .ask, microphone: .deny), .deny)
        // Ask if EITHER asks and neither denies.
        XCTAssertEqual(MediaPermissionResolver.resolve(.cameraAndMicrophone, camera: .ask, microphone: .allow), .ask)
        XCTAssertEqual(MediaPermissionResolver.resolve(.cameraAndMicrophone, camera: .allow, microphone: .ask), .ask)
    }

    func testMediaPolicyAccessorsDefaultToAskAndRoundTrip() {
        let service = ServiceInstance(label: "S", url: "https://s.example")
        // Unset → .ask, and the raw stays nil so resolution can fall back to global.
        XCTAssertEqual(service.cameraPolicy, .ask)
        XCTAssertEqual(service.microphonePolicy, .ask)
        XCTAssertNil(service.cameraPolicyRaw)
        XCTAssertNil(service.microphonePolicyRaw)
        // Setting pins the raw string.
        service.cameraPolicy = .allow
        service.microphonePolicy = .deny
        XCTAssertEqual(service.cameraPolicyRaw, "allow")
        XCTAssertEqual(service.microphonePolicyRaw, "deny")
        XCTAssertEqual(service.cameraPolicy, .allow)
        XCTAssertEqual(service.microphonePolicy, .deny)
    }

    func testMediaAskedFieldsGatesByRequestKind() {
        // A mic-only request with BOTH fields unset (.ask) marks ONLY the mic as
        // asked — so answering the prompt can never silently pin the camera to
        // Allow (the cross-device over-grant this guards).
        var asked = MediaPermissionResolver.askedFields(.microphone, camera: .ask, microphone: .ask)
        XCTAssertFalse(asked.camera)
        XCTAssertTrue(asked.microphone)
        // Camera-only request → only the camera.
        asked = MediaPermissionResolver.askedFields(.camera, camera: .ask, microphone: .ask)
        XCTAssertTrue(asked.camera)
        XCTAssertFalse(asked.microphone)
        // Combined request marks a field only when it's actually .ask; an
        // already-explicit field is left out so it isn't overwritten.
        asked = MediaPermissionResolver.askedFields(.cameraAndMicrophone, camera: .ask, microphone: .allow)
        XCTAssertTrue(asked.camera)
        XCTAssertFalse(asked.microphone)
        asked = MediaPermissionResolver.askedFields(.cameraAndMicrophone, camera: .ask, microphone: .ask)
        XCTAssertTrue(asked.camera)
        XCTAssertTrue(asked.microphone)
    }

    func testCaptureOriginTrustSeparatesSharedHostingSuffixes() {
        typealias C = WebViewCoordinator
        // Exact host, and same registrable domain for a normal domain — trusted
        // (e.g. Slack workspace subdomains).
        XCTAssertTrue(C.captureOriginBelongsToService("app.slack.com", serviceHost: "app.slack.com"))
        XCTAssertTrue(C.captureOriginBelongsToService("huddle.slack.com", serviceHost: "app.slack.com"))
        // Different owners sharing a multi-tenant hosting suffix — NOT trusted
        // (this is the grant-leak the fix closes).
        XCTAssertFalse(C.captureOriginBelongsToService("attacker.web.app", serviceHost: "alice.web.app"))
        XCTAssertFalse(C.captureOriginBelongsToService("evil.github.io", serviceHost: "myapp.github.io"))
        // Same tenant under a shared suffix (its own subdomain) — trusted.
        XCTAssertTrue(C.captureOriginBelongsToService("sub.alice.web.app", serviceHost: "alice.web.app"))
        // Cross registrable domain — not trusted (fails safe; pre-existing).
        XCTAssertFalse(C.captureOriginBelongsToService("messenger.com", serviceHost: "facebook.com"))
        // Shared-umbrella domains keep the exact-host rule.
        XCTAssertFalse(C.captureOriginBelongsToService("docs.google.com", serviceHost: "mail.google.com"))
        XCTAssertTrue(C.captureOriginBelongsToService("mail.google.com", serviceHost: "mail.google.com"))
        // Empty host — not trusted.
        XCTAssertFalse(C.captureOriginBelongsToService("", serviceHost: "alice.web.app"))
    }

    func testMediaPromptCopyNamesTheRealRequester() {
        // The service's own origin — the prompt names the service.
        let own = AppState.MediaPermissionRequest(
            id: UUID(), serviceLabel: "Slack", originHost: nil, camAsked: false, micAsked: true)
        XCTAssertEqual(own.title, "Allow Slack to use your microphone?")
        XCTAssertTrue(own.message.hasPrefix("Slack wants to use your microphone"))
        // A cross-domain origin — the prompt names the ORIGIN (not the service),
        // and the body says which service opened it, so it can't spoof the service.
        let foreign = AppState.MediaPermissionRequest(
            id: UUID(), serviceLabel: "Messenger", originHost: "messenger.com", camAsked: true, micAsked: true)
        XCTAssertEqual(foreign.title, "Allow messenger.com to use your camera and microphone?")
        XCTAssertTrue(foreign.message.hasPrefix("messenger.com, opened by Messenger"))
    }

    func testForeignCaptureOutcomeGrantsSilentlyOnlyForFirstPartyAllow() {
        // A first-party vendor pinned to Allow, calling from a foreign MAIN-frame
        // origin (Messenger: facebook.com → messenger.com): silent grant, the
        // seamless-call case the flag exists for.
        XCTAssertEqual(
            AppState.foreignCaptureOutcome(
                isMainFrame: true, originHost: "messenger.com", isFirstParty: true, resolution: .grant),
            .grantSilently)

        // A first-party vendor still on Ask does NOT silently grant a foreign
        // origin — it prompts, and the prompt names the real origin.
        XCTAssertEqual(
            AppState.foreignCaptureOutcome(
                isMainFrame: true, originHost: "messenger.com", isFirstParty: true, resolution: .ask),
            .promptNamingOrigin)

        // A non-first-party service, even pinned Allow, never silently grants a
        // foreign origin (this was the shared-suffix leak) — it prompts.
        XCTAssertEqual(
            AppState.foreignCaptureOutcome(
                isMainFrame: true, originHost: "evil.example.com", isFirstParty: false, resolution: .grant),
            .promptNamingOrigin)

        // A third-party SUBFRAME fails closed even for a first-party Allow vendor.
        XCTAssertEqual(
            AppState.foreignCaptureOutcome(
                isMainFrame: false, originHost: "messenger.com", isFirstParty: true, resolution: .grant),
            .deny)

        // An empty origin fails closed.
        XCTAssertEqual(
            AppState.foreignCaptureOutcome(
                isMainFrame: true, originHost: "", isFirstParty: true, resolution: .grant),
            .deny)
    }

    func testCatalogFlagsFirstPartyCallVendors() {
        let entries = ServiceCatalog.shared.entries
        func firstParty(_ id: String) -> Bool? { entries.first { $0.id == id }?.firstParty }
        // The curated cross-domain / named call vendors are flagged.
        for id in ["messenger", "teams", "facebook", "whatsapp", "google-meet", "google-chat"] {
            XCTAssertEqual(firstParty(id), true, "\(id) should be flagged firstParty")
        }
        // Single-domain services are not (no benefit, keep the trust surface small).
        XCTAssertNotEqual(firstParty("discord"), true)
        XCTAssertNotEqual(firstParty("slack"), true)
    }

    func testShouldBustCachesOnlyAfterAVersionChange() {
        // Fresh install (no previous version) — nothing stale to bust.
        XCTAssertFalse(AppState.shouldBustCachesOnLaunch(previousVersion: nil, currentVersion: "1.5.3"))
        // Normal relaunch on the same version — no bust.
        XCTAssertFalse(AppState.shouldBustCachesOnLaunch(previousVersion: "1.5.3", currentVersion: "1.5.3"))
        // Updated to a new version — bust the icon caches.
        XCTAssertTrue(AppState.shouldBustCachesOnLaunch(previousVersion: "1.5.2", currentVersion: "1.5.3"))
        // Unknown current version (missing Info key) — don't bust spuriously.
        XCTAssertFalse(AppState.shouldBustCachesOnLaunch(previousVersion: "1.5.2", currentVersion: ""))
    }

    // MARK: - Store pre-migration snapshots

    /// Makes a throwaway directory holding a fake `default.store` triple and
    /// returns the store URL. The caller removes the directory when done.
    private func makeFakeStore() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chorus-snapshot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appending(path: "default.store")
        for suffix in ["", "-wal", "-shm"] {
            try Data("db\(suffix)".utf8).write(to: URL(fileURLWithPath: store.path + suffix))
        }
        return store
    }

    private func snapshotFiles(besides store: URL) -> [String] {
        let dir = store.deletingLastPathComponent()
        let prefix = store.lastPathComponent + StoreRepair.snapshotInfix
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return all.filter { $0.hasPrefix(prefix) }.sorted()
    }

    func testSnapshotCopiesTheWholeStoreTriple() throws {
        let store = try makeFakeStore()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        StoreRepair.snapshot(at: store, stamp: "1000000000")

        let made = snapshotFiles(besides: store)
        XCTAssertEqual(made, [
            "default.store.snapshot-1000000000.bak",
            "default.store.snapshot-1000000000.bak-shm",
            "default.store.snapshot-1000000000.bak-wal",
        ])
    }

    func testPruneKeepsOnlyTheMostRecentSnapshots() throws {
        let store = try makeFakeStore()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        // Five snapshots, oldest to newest by their fixed-width stamp.
        for stamp in ["1000000001", "1000000002", "1000000003", "1000000004", "1000000005"] {
            StoreRepair.snapshot(at: store, stamp: stamp)
        }
        StoreRepair.pruneSnapshots(at: store, keeping: 2)

        // Only the two newest triples survive (3 files each).
        let survivors = snapshotFiles(besides: store)
        XCTAssertEqual(survivors.count, 6)
        XCTAssertTrue(survivors.allSatisfy { $0.contains("1000000004") || $0.contains("1000000005") })
    }

    func testBackupOnlyRunsWhenTheVersionChanges() throws {
        let store = try makeFakeStore()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let suite = "chorus-snapshot-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // First launch on 1.5.7 — snapshot taken.
        StoreRepair.backupBeforeMigrationIfNeeded(at: store, version: "1.5.7", defaults: defaults, keeping: 3)
        XCTAssertEqual(snapshotFiles(besides: store).count, 3)

        // Relaunch, same version — no new snapshot.
        StoreRepair.backupBeforeMigrationIfNeeded(at: store, version: "1.5.7", defaults: defaults, keeping: 3)
        XCTAssertEqual(snapshotFiles(besides: store).count, 3)

        // New version installed — snapshot the pre-migration state again.
        StoreRepair.backupBeforeMigrationIfNeeded(at: store, version: "1.5.8", defaults: defaults, keeping: 3)
        XCTAssertEqual(snapshotFiles(besides: store).count, 6)
    }

    func testBackupIsANoOpWhenNoStoreExistsYet() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chorus-snapshot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "default.store")  // never created
        let suite = "chorus-snapshot-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        StoreRepair.backupBeforeMigrationIfNeeded(at: store, version: "1.5.7", defaults: defaults, keeping: 3)
        XCTAssertEqual(snapshotFiles(besides: store).count, 0)
    }

}
