import XCTest
import SwiftData
import SQLite3
import JavaScriptCore
import WebKit
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
            let linkedServices = doomed.serviceLinks.compactMap(\.service)
            var memberships: [UUID: Set<UUID>] = [:]
            for service in linkedServices {
                memberships[service.id] = Set(service.spaceLinks.compactMap { $0.space?.id })
            }
            // The inverse must be wired for this to be non-empty — the bug was
            // that it read 0, so nothing was reclaimed and the space's links
            // were left dangling after the space was deleted.
            XCTAssertEqual(doomed.serviceLinks.count, 2, "Space.serviceLinks inverse must be populated")
            let orphaned = AppState.servicesOrphaned(byDeletingSpace: workID, memberships: memberships)
            XCTAssertEqual(orphaned.count, 2, "Both of Work's services should be reclaimed")
            // Mirrors AppState.deleteSpace: the links go explicitly, because
            // the .cascade rule does not take them on macOS 14.
            for link in doomed.serviceLinks where link.modelContext != nil {
                context.delete(link)
            }
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
            XCTAssertNotNil(l.space?.modelContext, "Link's space must not dangle")
            XCTAssertNotNil(l.service?.modelContext, "Link's service must not dangle")
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
            _ = l.space?.id    // the badge-sweep read that crashed pre-fix
            _ = l.service?.id
        }
        let spaces = try context.fetch(FetchDescriptor<Space>())
        XCTAssertEqual(spaces.map(\.name), ["Personal"], "the live space must be intact")
        let services = try context.fetch(FetchDescriptor<ServiceInstance>())
        XCTAssertEqual(services.count, 4, "no service rows should be lost by the repair")

        // The store must remain writable (bookkeeping/history survived): create
        // and remove a link, then save with no error.
        //
        // Delete the service alone and let the cascade take the link with it.
        // Deleting both by hand is what the app never does and what SwiftData
        // will not always survive: on the Xcode 26.3 SDK, removing the link
        // first and then its service traps with "Cannot remove
        // Chorus.ServiceInstance from relationship service on
        // Chorus.SpaceServiceLink because an appropriate default value is not
        // configured", because `service` is non-optional and there is nothing
        // to put in its place. Newer SDKs let it pass, which is why this stood
        // until CI ran it.
        let probeSpace = spaces[0]
        let probeSvc = ServiceInstance(label: "probe", url: "https://probe.example", catalogEntryID: "probe")
        context.insert(probeSvc)
        let probeLink = SpaceServiceLink(sortOrder: 9, space: probeSpace, service: probeSvc)
        context.insert(probeLink)
        try context.save()
        // Delete the link explicitly, the way the app does. The .cascade rule
        // would take it on macOS 15 and 26 and leave it behind on macOS 14, so
        // relying on it here would make this a reading of the OS rather than a
        // check that the store stayed writable.
        context.delete(probeLink)
        context.delete(probeSvc)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<SpaceServiceLink>())
        XCTAssertEqual(remaining.count, 2, "only Personal's two links should be left")
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

    /// The store schema, shared by the restore tests. Uses the versioned current
    /// schema so it matches `ChorusMigrationPlan`'s latest, the same shape
    /// `loadContainer` opens in production.
    private static var storeSchema: Schema {
        Schema(versionedSchema: ChorusSchemaVCurrent.self)
    }

    /// Creates a store at `url` with `spaces` populated spaces and returns only
    /// once the file is genuinely free for raw ops. Spaces-only keeps the store
    /// free of links, so no dangling-link machinery is involved.
    ///
    /// The write and the wait are separate calls on purpose: `container` has to
    /// go out of scope before anything can wait on its connection closing, and
    /// it only does that when `writeFixture` returns.
    private func makePopulatedStore(at url: URL, spaces: Int) throws {
        try Self.writeFixture(at: url, spaces: spaces)
        try Self.settleStore(at: url)
    }

    /// Writes the fixture rows and lets its container go out of scope.
    private static func writeFixture(at url: URL, spaces: Int) throws {
        let config = ModelConfiguration(schema: storeSchema, url: url)
        let container = try ModelContainer(for: storeSchema, configurations: [config])
        let ctx = container.mainContext
        for i in 0..<spaces {
            ctx.insert(Space(name: "S\(i)", emoji: "🏠", sortOrder: i))
        }
        try ctx.save()
    }

    enum FixtureError: Error, CustomStringConvertible {
        case storeNeverSettled(String, String)

        var description: String {
            switch self {
            case let .storeNeverSettled(name, detail):
                return "fixture store \(name) never came free: \(detail)"
            }
        }
    }

    /// Blocks until nothing else holds the store at `url`, then folds its WAL
    /// into the main database file.
    ///
    /// SwiftData exposes no way to close a `ModelContainer`. Its SQLite
    /// connection goes away when the container deallocates, and ARC promises
    /// nothing about when that happens — so a fixture helper that just returns
    /// leaves every caller racing that close. Two tests here lost that race:
    /// one saw `PRAGMA journal_mode=WAL` come back `SQLITE_BUSY` because the
    /// container still held a transaction, and one copied the store while rows
    /// were still only in the `-wal`, producing a main file that read as empty
    /// and was judged an unusable snapshot.
    ///
    /// `BEGIN EXCLUSIVE` is the check because it is the one statement that can
    /// only succeed when this process holds the file alone. The checkpoint that
    /// follows is what makes a copy of the main file *alone* carry every
    /// committed row, which is the shape `StoreRepair.snapshot` produces and
    /// several tests then read back.
    ///
    /// The wait turns the run loop rather than sleeping: the container is torn
    /// down by work scheduled on this very thread, so a bare `usleep` would
    /// starve exactly what it is waiting for.
    private static func settleStore(at url: URL, timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastDetail = "not attempted"

        repeat {
            var db: OpaquePointer?
            if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db {
                sqlite3_busy_timeout(db, 250)
                let locked = sqlite3_exec(db, "BEGIN EXCLUSIVE; COMMIT;", nil, nil, nil)
                if locked == SQLITE_OK {
                    sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
                    sqlite3_close(db)
                    return
                }
                lastDetail = "BEGIN EXCLUSIVE returned \(locked)"
                sqlite3_close(db)
            } else {
                lastDetail = "could not open read-write"
                if let db { sqlite3_close(db) }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline

        throw FixtureError.storeNeverSettled(url.lastPathComponent, lastDetail)
    }

    /// Inserts `count` spaces into an existing store by raw SQL, so a fixture can
    /// be reshaped without reopening a container. `Z_PK` is assigned explicitly
    /// because Core Data's `Z_PRIMARYKEY` bookkeeping is not maintained here;
    /// these fixtures are only ever read back by raw SQLite.
    private static func insertSpaces(_ url: URL, count: Int) throws {
        let entity = try runSQLite(url, "SELECT Z_ENT FROM ZSPACE LIMIT 1;")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ent = entity.isEmpty ? "1" : entity
        for i in 0..<count {
            _ = try runSQLite(url, """
                INSERT INTO ZSPACE (Z_PK, Z_ENT, Z_OPT, ZNAME, ZEMOJI, ZSORTORDER)
                VALUES (\(1000 + i), \(ent), 1, 'S\(i)', '🏠', \(i));
                """)
        }
    }

    /// Writes the untouched default seed shape into an existing store by raw SQL:
    /// the two seeded space names and the seven seeded service labels.
    private static func insertSeedShape(_ url: URL) throws {
        let spaceEnt = try runSQLite(url, "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'Space';")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceEnt = try runSQLite(url, "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ServiceInstance';")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for (i, entry) in DefaultSeed.spaces.enumerated() {
            _ = try runSQLite(url, """
                INSERT INTO ZSPACE (Z_PK, Z_ENT, Z_OPT, ZNAME, ZEMOJI, ZSORTORDER)
                VALUES (\(2000 + i), \(spaceEnt.isEmpty ? "1" : spaceEnt), 1, '\(entry.name)', '\(entry.emoji)', \(i));
                """)
        }
        for (i, label) in DefaultSeed.allServiceLabels.enumerated() {
            _ = try runSQLite(url, """
                INSERT INTO ZSERVICEINSTANCE (Z_PK, Z_ENT, Z_OPT, ZLABEL, ZURL)
                VALUES (\(3000 + i), \(serviceEnt.isEmpty ? "2" : serviceEnt), 1, '\(label)', 'https://example.com');
                """)
        }
    }

    /// Copies the store triple — main file plus `-wal`/`-shm` when present —
    /// from `source` to `destination`, mirroring what `StoreRepair.snapshot`
    /// does in production. A prerestore/corrupt fixture built from a bare
    /// single-file copy would miss a live store's `-wal` sibling and so
    /// misrepresent what a real backup looks like.
    private static func copyStoreTriple(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: source.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: URL(fileURLWithPath: destination.path + suffix))
        }
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

    /// End-to-end proof that the shipped recovery path sees a snapshot whose
    /// `-wal` sibling is gone — exactly what `StoreRepair.snapshot` produces
    /// after a clean checkpoint, since it only copies the suffixes that exist
    /// at backup time. Before the WAL-header/no-`-wal` fallback in
    /// `StoreInventory.openReadOnly`, this snapshot would have been
    /// misjudged unusable (via either `spaceCount`'s gate or
    /// `snapshotHasUsableData`'s own integrity-check open) and skipped.
    /// Regression guard for the production bug behind this task: it fails if
    /// any of the three readers that share the opener loses the fallback.
    func testNewestRestorableSnapshotFindsAMainFileOnlySnapshot() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-newest-walonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePopulatedStore(at: storeURL, spaces: 2)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.0.0")

        // Strip the snapshot's own `-wal`/`-shm` siblings, regardless of
        // whether `StoreRepair.snapshot` copied them, so the fixture is
        // exactly the main-file-only WAL-mode shape this bug needs.
        let snapshotURL = dir.appendingPathComponent("store.sqlite.snapshot-1700000000-1.0.0.bak")
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: snapshotURL.path + suffix))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: snapshotURL.path + "-wal"),
            "precondition: the snapshot has no -wal sibling"
        )

        let candidate = StoreRepair.newestRestorableSnapshot(for: storeURL)
        XCTAssertEqual(
            candidate?.version, "1.0.0",
            "a main-file-only WAL-mode snapshot must be found, not skipped as unusable"
        )
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

    /// Emptied store + history, no snapshot, and nothing readable left in the
    /// file → start fresh, with the old file kept as a `.reset-` backup.
    ///
    /// This case used to return `.inMemoryFallback` and leave the file in place,
    /// which was the trap in issue #20: an install updated before it was ever
    /// configured comes up on temporary storage at every launch, with no backup
    /// to offer and no way out — reinstalling does not clear it, because both
    /// the durable flag and the store file outlive the app bundle.
    ///
    /// Starting fresh here is safe *because* the old file is copied aside first,
    /// so the guarantee the old assertion was protecting — the user's bytes are
    /// never destroyed — still holds. It is checked explicitly below.
    func testLoadContainerStartsFreshWhenTheEmptiedStoreHoldsNothing() throws {
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

        XCTAssertEqual(outcome, .openedClean, "nothing was left to protect, so the user gets a working store")

        // The point of the change: nothing was destroyed to get there.
        let asides = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("store.sqlite" + StoreRepair.resetAsideInfix) && $0.hasSuffix(".bak") }
        XCTAssertEqual(asides.count, 1, "the old store must be kept as a .reset- backup, not deleted")
    }

    /// The same shape, but the store still holds services → preserve it. Only a
    /// store proved empty across all three tables licenses a fresh start; rows in
    /// any of them are the user's.
    func testLoadContainerPreservesAnEmptiedStoreThatStillHoldsServices() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-load-keepsvc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 2)
        // A service with no space is exactly the shape a half-lost store takes.
        try Self.runSQLite(storeURL, "INSERT INTO ZSERVICEINSTANCE (Z_PK, Z_ENT, Z_OPT) VALUES (99, 1, 1);")
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        defaults.set(true, forKey: AppState.hasEverHadDataKey)

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let (_, outcome) = AppState.loadContainer(schema: Self.storeSchema, config: config, defaults: defaults)

        guard case .inMemoryFallback = outcome else {
            return XCTFail("a store still holding services must never be started over; got \(outcome)")
        }
    }

    /// A snapshot on disk, even one too damaged to restore from, stops the
    /// fresh start. `hasAnyPreservedCopy` is deliberately weaker than
    /// `newestRestorableSnapshot`: a file the user might salvage by hand still
    /// counts as something to protect.
    func testLoadContainerPreservesWhenAnUnusableSnapshotExists() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-load-keepsnap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 2)
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        // Not a readable store, so newestRestorableSnapshot skips it — but it is
        // still a file bearing the user's data's name.
        try Data("not a database".utf8).write(
            to: dir.appendingPathComponent("store.sqlite\(StoreRepair.snapshotInfix)1700000000_1.0.0.bak")
        )
        defaults.set(true, forKey: AppState.hasEverHadDataKey)

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let (_, outcome) = AppState.loadContainer(schema: Self.storeSchema, config: config, defaults: defaults)

        guard case .inMemoryFallback = outcome else {
            return XCTFail("a snapshot on disk must stop a fresh start; got \(outcome)")
        }
    }

    /// A `.prepick-` aside is the user's own data, set aside when they restored
    /// a backup, and it must stop the fresh start exactly as a `.snapshot-` does.
    /// The check reads every backup family but one, so pick a family that is
    /// neither the snapshot it started life matching nor the `.reset-` exception.
    func testLoadContainerPreservesWhenAnyOtherBackupFamilyExists() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-load-keepfam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 2)
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Data("not a database".utf8).write(
            to: dir.appendingPathComponent("store.sqlite\(StoreRepair.pickAsideInfix)1700000000_1.0.0.bak")
        )
        defaults.set(true, forKey: AppState.hasEverHadDataKey)

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let (_, outcome) = AppState.loadContainer(schema: Self.storeSchema, config: config, defaults: defaults)

        guard case .inMemoryFallback = outcome else {
            return XCTFail("a .prepick- aside must stop a fresh start; got \(outcome)")
        }
    }

    /// A `.reset-` aside is the one family that must NOT stop a fresh start.
    /// It is the copy an earlier fresh start already made, so counting it would
    /// let the user's own first fresh start veto the automatic fix and push
    /// every repeat of issue #20 back to the button. Nothing is lost by going
    /// again: the second fresh start sets its own copy aside beside the first,
    /// and the picker lists both.
    func testLoadContainerStartsFreshDespiteAnEarlierResetAside() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-load-resetaside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 2)
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        // What an earlier fresh start left behind.
        try Data("not a database".utf8).write(
            to: dir.appendingPathComponent("store.sqlite\(StoreRepair.resetAsideInfix)1700000000.bak")
        )
        defaults.set(true, forKey: AppState.hasEverHadDataKey)

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let (_, outcome) = AppState.loadContainer(schema: Self.storeSchema, config: config, defaults: defaults)

        XCTAssertEqual(outcome, .openedClean, "an earlier fresh start must not veto this one")

        // And this fresh start kept its own copy, beside the older one.
        let asides = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("store.sqlite" + StoreRepair.resetAsideInfix) && $0.hasSuffix(".bak") }
        XCTAssertEqual(asides.count, 2, "the earlier aside must survive and the new one must join it")
    }

    /// `storeIsProvablyEmpty` must answer no for a file it cannot read. Unknown
    /// is not empty, and this is the direction that matters: an unreadable store
    /// is the one that might still hold everything.
    func testStoreIsProvablyEmptyRefusesToGuessAboutAnUnreadableFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-provably-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let garbage = dir.appendingPathComponent("garbage.sqlite")
        try Data("not a database".utf8).write(to: garbage)
        XCTAssertFalse(StoreRepair.storeIsProvablyEmpty(at: garbage))

        // A file that isn't there at all is likewise not proof of emptiness.
        XCTAssertFalse(StoreRepair.storeIsProvablyEmpty(at: dir.appendingPathComponent("absent.sqlite")))

        let empty = dir.appendingPathComponent("empty.sqlite")
        try makePopulatedStore(at: empty, spaces: 1)
        try Self.runSQLite(empty, "DELETE FROM ZSPACE;")
        XCTAssertTrue(StoreRepair.storeIsProvablyEmpty(at: empty))
    }

    /// Setting the store aside copies it before removing it, and a caller that
    /// then opens a fresh store finds the old one still on disk under its own
    /// backup family.
    func testMoveStoreAsideKeepsTheOldBytes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-aside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("store.sqlite")
        try makePopulatedStore(at: storeURL, spaces: 3)

        XCTAssertTrue(StoreRepair.moveStoreAside(at: storeURL, stamp: "1700000000"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path), "the live store must be gone")

        let aside = dir.appendingPathComponent("store.sqlite\(StoreRepair.resetAsideInfix)1700000000.bak")
        XCTAssertEqual(StoreRepair.spaceCount(at: aside), 3, "the aside copy must still hold the data")

        // A missing store is success: the postcondition already holds.
        XCTAssertTrue(StoreRepair.moveStoreAside(at: storeURL, stamp: "1700000001"))
    }

    /// The aside a fresh start leaves must be listed in the picker — that is the
    /// promise the confirmation dialog makes, and the reason starting fresh is
    /// safe to offer at all — while never being what Chorus proposes by itself.
    ///
    /// Both halves matter. Drop it from the picker and the user cannot undo a
    /// fresh start. Let it reach `best` and the launch right after one greets
    /// them with an offer to restore the store they just chose to leave, since
    /// that launch is precisely when the live store is the untouched seed and
    /// preselection is licensed.
    func testResetAsideIsListedInThePickerButNeverProposed() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-reset-listed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Four spaces set aside by a fresh start, and a live store holding
        // nothing — the shape of the launch straight after the button is used.
        try makePopulatedStore(at: storeURL, spaces: 4)
        try Self.copyStoreTriple(
            from: storeURL,
            to: dir.appendingPathComponent("store.sqlite\(StoreRepair.resetAsideInfix)1700000000.bak")
        )
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")

        let live = try XCTUnwrap(StoreInventory.readContent(at: storeURL))
        let found = StoreInventory.candidates(for: storeURL, liveContent: live)

        let aside = try XCTUnwrap(
            found.first { $0.kind == .reset },
            "the .reset- family must be recognized as its own kind and listed in the picker"
        )
        XCTAssertEqual(aside.content?.spaces, 4, "and it must read back the data it holds")
        XCTAssertTrue(aside.isRestorable, "the user must be able to choose it")

        // But Chorus must not choose it for them.
        XCTAssertNil(StoreInventory.best(among: found), "a .reset- aside must never be proposed")
        XCTAssertNil(
            StoreInventory.preselection(among: found, liveContent: live),
            "and never preselected, least of all on the launch right after a fresh start"
        )
        XCTAssertNil(
            StoreInventory.offer(
                liveContent: live,
                best: StoreInventory.best(among: found),
                record: StoreContent(spaces: 4, services: 0, links: 0, spaceNames: [], serviceLabels: []),
                declinedKeys: []
            ),
            "so no banner offers to undo what the user just asked for"
        )
    }

    /// The pending-reset key is consumed exactly once, so a crash mid-move can't
    /// make every later launch repeat it.
    func testApplyPendingResetRunsOnceAndOnlyWhenAsked() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-pendingreset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("store.sqlite")
        try makePopulatedStore(at: storeURL, spaces: 1)
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(StoreRepair.applyPendingReset(at: storeURL, defaults: defaults), "no request, no move")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))

        defaults.set(true, forKey: StoreRepair.pendingResetKey)
        XCTAssertTrue(StoreRepair.applyPendingReset(at: storeURL, defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: StoreRepair.pendingResetKey), "the key must be cleared")
        XCTAssertFalse(StoreRepair.applyPendingReset(at: storeURL, defaults: defaults), "and not run again")
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

    /// When no store file exists but a usable backup does, Chorus must RESTORE
    /// the backup — never clear the durable flag and reseed over it. Guards the
    /// regression where `freshStart` could abandon a recoverable snapshot.
    func testLoadContainerNoFileButUsableSnapshotRestoresNotReseeds() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-nofile-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Build a usable snapshot, then remove the store file entirely so only the
        // backup remains (a store-deleted-but-snapshots-kept situation).
        try makePopulatedStore(at: storeURL, spaces: 3)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.0.0")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        defaults.set(true, forKey: AppState.hasEverHadDataKey)   // stale flag, no file

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let (container, outcome) = AppState.loadContainer(schema: Self.storeSchema, config: config, defaults: defaults)

        guard case .restoredFromSnapshot = outcome else {
            return XCTFail("a usable backup must be restored, not reseeded; got \(outcome)")
        }
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Space>()), 3)
        XCTAssertTrue(defaults.bool(forKey: AppState.hasEverHadDataKey), "the flag must NOT be cleared when a backup was restored")
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

    /// Unreadable content must not be treated as evidence of a seed. A snapshot
    /// that opens, holds real `ZSPACE` rows, and passes an integrity check —
    /// exactly what `snapshotHasUsableData` (the automatic-restore rule) already
    /// protects — must still be protected by pruning even when `readContent`
    /// itself fails, because its schema is missing a table `readContent`
    /// requires but `snapshotHasUsableData` does not. Without a fallback to the
    /// shipped rule, pruning would delete the very file the automatic-restore
    /// path would otherwise pick.
    func testPruneFallsBackToShippedRuleWhenContentIsUnreadable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-prune-unknown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Oldest snapshot: genuine data. Its own ZSPACESERVICELINK table is then
        // dropped, so `readContent` (which requires all three tables) reads it
        // as UNKNOWN — not empty, not seed-shaped, just unreadable — while
        // `snapshotHasUsableData` (ZSPACE + integrity check only) still passes it.
        try makePopulatedStore(at: storeURL, spaces: 3)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.0.0")
        let genuineSnapshot = dir.appendingPathComponent("store.sqlite.snapshot-1700000000-1.0.0.bak")
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: genuineSnapshot.path + suffix))
        }
        _ = try Self.runSQLite(genuineSnapshot, "DROP TABLE ZSPACESERVICELINK;")

        // Then several newer, genuinely EMPTY snapshots — no data at all, so
        // they must never be mistaken for something worth protecting.
        try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        for stamp in ["1700000100-1.1.0", "1700000200-1.2.0", "1700000300-1.3.0", "1700000400-1.4.0"] {
            StoreRepair.snapshot(at: storeURL, stamp: stamp)
        }

        StoreRepair.pruneSnapshots(at: storeURL, keeping: 3)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: genuineSnapshot.path),
            "a snapshot whose content merely failed to read must not be pruned as if it were a seed"
        )
    }

    /// Pruning must protect the newest snapshot holding the user's own data, not
    /// the newest one that merely has rows. A snapshot taken after the loss holds
    /// the default seed, and treating that as worth keeping let the real backup
    /// age out of the keep-3 window and be deleted.
    func testPruneProtectsTheUsersDataNotASeededSnapshot() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-prune-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Oldest snapshot: the user's own 5 spaces.
        try makePopulatedStore(at: storeURL, spaces: 5)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.5.11+20")

        // Then four newer snapshots of a seed-shaped store, as four updates
        // after the loss would produce.
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSeedShape(storeURL)
        for (i, version) in ["1.5.12+21", "1.5.13+22", "1.5.14+23", "1.5.15+24"].enumerated() {
            StoreRepair.snapshot(at: storeURL, stamp: "17000005\(i)0-\(version)")
        }

        StoreRepair.pruneSnapshots(at: storeURL, keeping: 3)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("store.sqlite.snapshot-") && $0.hasSuffix(".bak") }
        XCTAssertTrue(
            remaining.contains { $0.contains("1.5.11+20") },
            "the only snapshot holding the user's data must survive pruning, got \(remaining)"
        )
    }

    /// Each user-chosen restore writes a full store triple aside under
    /// `.prepick-`, and no existing reaper matches that family, so without this
    /// the directory grows by one copy of the whole store per restore, forever.
    /// Recency alone is not enough here, unlike `pruneSnapshots`: the OLDEST
    /// aside is the store as it stood before the user began trying candidates at
    /// all, so it must survive alongside the newest few, not be pruned away by
    /// a purely newest-first rule the way a run of several restores would.
    func testPrunePickAsidesKeepsNewestPlusOldest() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-prune-pick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makePopulatedStore(at: storeURL, spaces: 2)

        // Five asides, oldest first. Pruning is filename bookkeeping — it never
        // reads a candidate's contents — so stand-in bytes are the honest
        // fixture here, and they keep the test fast.
        let stamps = ["1700000010", "1700000020", "1700000030", "1700000040", "1700000050"]
        for stamp in stamps {
            for suffix in ["", "-wal", "-shm"] {
                let path = storeURL.path + ".prepick-\(stamp).bak" + suffix
                try Data("aside \(stamp)\(suffix)".utf8).write(to: URL(fileURLWithPath: path))
            }
        }

        StoreRepair.prunePickAsides(at: storeURL, keeping: 3)

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let primaries = left.filter { $0.hasPrefix("store.sqlite.prepick-") && $0.hasSuffix(".bak") }.sorted()
        XCTAssertEqual(
            primaries,
            ["store.sqlite.prepick-1700000010.bak",
             "store.sqlite.prepick-1700000030.bak",
             "store.sqlite.prepick-1700000040.bak",
             "store.sqlite.prepick-1700000050.bak"],
            "the newest three plus the oldest must survive, got \(primaries)"
        )
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(
                left.contains("store.sqlite.prepick-1700000020.bak" + suffix),
                "the second-oldest aside must be pruned along with its whole triple, \(suffix) survived"
            )
        }
        XCTAssertTrue(left.contains("store.sqlite"), "pruning must never touch the live store")
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
    /// Runs `sql` against the store with the sqlite3 CLI, then checkpoints.
    ///
    /// The checkpoint is not decoration. These stores are in WAL mode, and
    /// whether the CLI leaves a write sitting in the -wal or folds it into the
    /// main file before exiting differs by OS: macOS 26 lands it, macOS 14 does
    /// not. Tests that then delete the -wal sibling — several here do, to make
    /// the store readable through a read-only directory — silently lost the
    /// write on macOS 14 and read the ORIGINAL row count back. TRUNCATE forces
    /// the write into the main file first, so the sibling is safe to remove and
    /// the test measures the same thing everywhere.
    @discardableResult
    private static func runSQLite(_ url: URL, _ sql: String) throws -> String {
        let output = try sqlite3(url, sql)
        // Checkpoint separately so its own output ("0|2|2") cannot land in the
        // string callers parse.
        _ = try? sqlite3(url, "PRAGMA wal_checkpoint(TRUNCATE);")
        return output
    }

    private static func sqlite3(_ url: URL, _ sql: String) throws -> String {
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

    // MARK: - Badge sweep sign-in walls (AuthWallResolver)

    func testAuthWallResolverFlagsOffHostFetchWithNoCount() {
        // A session needing interactive sign-in gets redirected to the identity
        // provider and comes back empty. Retrying can't fix it — a transient web
        // view can't sign anyone in — but it does make the provider push another
        // approval request at the user, every sweep.
        XCTAssertTrue(AuthWallResolver.looksLikeSignInWall(
            requestedHost: "outlook.cloud.microsoft",
            landedHost: "login.microsoftonline.com",
            badge: 0))
    }

    func testAuthWallResolverLeavesHealthyFetchesAlone() {
        // Same host, no count: an authenticated inbox that is simply empty.
        XCTAssertFalse(AuthWallResolver.looksLikeSignInWall(
            requestedHost: "outlook.cloud.microsoft",
            landedHost: "outlook.cloud.microsoft",
            badge: 0))
        // Redirected but still produced a count, so the session is fine.
        XCTAssertFalse(AuthWallResolver.looksLikeSignInWall(
            requestedHost: "outlook.cloud.microsoft",
            landedHost: "outlook.office.com",
            badge: 3))
    }

    func testAuthWallResolverTreatsMissingHostAsUnknown() {
        // A load that never resolved a host tells us nothing, and parking on a
        // guess would stop that badge updating until the user opens the service.
        XCTAssertFalse(AuthWallResolver.looksLikeSignInWall(
            requestedHost: "outlook.cloud.microsoft", landedHost: nil, badge: 0))
        XCTAssertFalse(AuthWallResolver.looksLikeSignInWall(
            requestedHost: nil, landedHost: "login.microsoftonline.com", badge: 0))
    }

    // MARK: - Reloading the opener after a popup closes

    func testUserClosingALinkPopupLeavesTheServiceAlone() {
        // The regression this guards: glance at a link opened from a chat
        // service, close the window, and the service used to reload underneath
        // you — losing scroll position and anything typed but not sent.
        XCTAssertFalse(WebViewCoordinator.shouldReloadOpener(
            selfClosed: false, openedAtAuthHost: false))
    }

    func testSelfClosingPopupReloadsTheService() {
        // An OAuth popup finishes by calling window.close(). This is what
        // carries sign-in through providers we don't list by name — a company's
        // own Okta or Keycloak.
        XCTAssertTrue(WebViewCoordinator.shouldReloadOpener(
            selfClosed: true, openedAtAuthHost: false))
    }

    func testHandClosedSignInStillReloadsTheService() {
        // A service asking the user to sign in again opens straight at its
        // provider, so the opening URL is the gateway. Some providers leave the
        // last click to the user, and that flow must still reload.
        XCTAssertTrue(WebViewCoordinator.shouldReloadOpener(
            selfClosed: false, openedAtAuthHost: true))
    }

    func testLinkThatMerelyRedirectsThroughSSOLeavesTheServiceAlone() {
        // Measured on a real machine: opening an Azure portal link from Teams
        // starts at portal.azure.com and redirects through
        // login.microsoftonline.com for SSO. Judging by the navigation chain
        // counted that as a sign-in and reloaded Teams on close. Only the
        // opening URL is consulted, so a link like this stays a link.
        XCTAssertFalse(WebViewCoordinator.isAuthHost("portal.azure.com"))
        XCTAssertFalse(WebViewCoordinator.shouldReloadOpener(
            selfClosed: false, openedAtAuthHost: false))
    }

    func testKnownAuthGatewaysAreRecognisedIncludingSubdomains() {
        XCTAssertTrue(WebViewCoordinator.isAuthHost("login.microsoftonline.com"))
        XCTAssertTrue(WebViewCoordinator.isAuthHost("accounts.google.com"))
        // A subdomain of a gateway still counts.
        XCTAssertTrue(WebViewCoordinator.isAuthHost("eu.login.microsoftonline.com"))
        // An ordinary link target does not.
        XCTAssertFalse(WebViewCoordinator.isAuthHost("teams.cloud.microsoft"))
        XCTAssertFalse(WebViewCoordinator.isAuthHost("example.com"))
    }

    // MARK: - New-window requests (shouldLoadNewWindowInPlace)

    func testClickedSameServiceLinkLoadsInPlace() {
        // A target=_blank click inside Slack should reuse the service's own web
        // view rather than spawning a window.
        XCTAssertTrue(WebViewCoordinator.shouldLoadNewWindowInPlace(
            navigationType: .linkActivated,
            targetHost: "myteam.slack.com",
            openerHost: "app.slack.com"
        ))
    }

    func testProgrammaticSameServicePopupGetsItsOwnWindow() {
        // A page calling window.open() against its own host must still get a
        // handle back. Collapsing it in place returned nil, which a caller that
        // null-checks the handle reads as a blocked popup — so it gives up
        // silently, with no window and no error to show for it.
        XCTAssertFalse(WebViewCoordinator.shouldLoadNewWindowInPlace(
            navigationType: .other,
            targetHost: "teams.cloud.microsoft",
            openerHost: "teams.cloud.microsoft"
        ))
    }

    func testCrossServicePopupGetsItsOwnWindow() {
        XCTAssertFalse(WebViewCoordinator.shouldLoadNewWindowInPlace(
            navigationType: .linkActivated,
            targetHost: "login.microsoftonline.com",
            openerHost: "teams.cloud.microsoft"
        ))
    }

    func testNewWindowWithUnknownHostIsNotCollapsed() {
        XCTAssertFalse(WebViewCoordinator.shouldLoadNewWindowInPlace(
            navigationType: .linkActivated,
            targetHost: nil,
            openerHost: "app.slack.com"
        ))
        XCTAssertFalse(WebViewCoordinator.shouldLoadNewWindowInPlace(
            navigationType: .linkActivated,
            targetHost: "app.slack.com",
            openerHost: nil
        ))
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

    /// Runs the catalog's Gmail `badgeJS` against a stub Gmail DOM. `hiddenUnread`
    /// models the unread rows Gmail leaves mounted outside the visible list after
    /// you visit another label — the ones that made a document-wide row count read
    /// 99+ over a 2-unread inbox. Returns nil when the expression yields null,
    /// which `pollBadge` treats as "no reading" and never writes.
    private func evaluateGmailBadge(
        hash: String,
        ariaLabels: [String],
        visibleUnread: Int,
        hiddenUnread: Int
    ) -> Int? {
        guard let js = ServiceCatalog.shared.entry(for: "gmail")?.badgeJS else {
            XCTFail("Gmail catalog entry should define badgeJS")
            return nil
        }
        guard let context = JSContext() else {
            XCTFail("Could not create a JSContext")
            return nil
        }
        var jsError: String?
        context.exceptionHandler = { _, exception in
            jsError = exception?.toString() ?? "unknown JS exception"
        }
        let labels = (try? String(data: JSONEncoder().encode(ariaLabels), encoding: .utf8) ?? "[]") ?? "[]"
        // The hidden main is listed first on purpose: the expression has to skip a
        // stale container rather than take whichever one comes back first.
        let prelude = """
        var location = { hash: \(jsQuoted(hash)) };
        var aria = \(labels).map(function (l) { return { getAttribute: function () { return l; } }; });
        function rows(n) { var a = []; for (var i = 0; i < n; i++) { a.push({}); } return a; }
        function main(count, visible) {
            return {
                offsetParent: visible ? {} : null,
                querySelectorAll: function (sel) { return sel === 'tr.zA.zE' ? rows(count) : []; }
            };
        }
        var document = { querySelectorAll: function (sel) {
            if (sel === '[aria-label]') { return aria; }
            if (sel === 'div[role=main]') { return [main(\(hiddenUnread), false), main(\(visibleUnread), true)]; }
            if (sel === 'tr.zA.zE') { return rows(\(visibleUnread + hiddenUnread)); }
            return [];
        } };
        """
        let result = context.evaluateScript(prelude + "\n" + js)
        if let jsError { XCTFail("Gmail badgeJS threw: \(jsError)") }
        guard let result, result.isNumber else { return nil }
        return Int(result.toInt32())
    }

    private func jsQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    func testGmailBadgeReportsInboxUnreadNotCachedRowsFromOtherLabels() {
        // Gmail keeps a visited label's list mounted after you navigate away, so a
        // document-wide `tr.zA.zE` count kept adding Spam's unread to the badge —
        // measured live as all=101 / visible=2 back in a 2-unread inbox, which the
        // icon showed as 99+. The badge now reads Gmail's own Inbox nav count,
        // which stays put no matter which label is on screen.
        let aria = ["Inbox 2 unread", "Spam 161 unread", "Updates 1987 unread has menu"]

        XCTAssertEqual(
            evaluateGmailBadge(hash: "#inbox", ariaLabels: aria, visibleUnread: 2, hiddenUnread: 99), 2,
            "99 unread rows left over from Spam must not reach the badge"
        )
        XCTAssertEqual(
            evaluateGmailBadge(hash: "#spam", ariaLabels: aria, visibleUnread: 99, hiddenUnread: 2), 2,
            "browsing Spam must not make the badge report Spam's unread"
        )
        XCTAssertEqual(
            evaluateGmailBadge(hash: "#inbox", ariaLabels: ["Inbox 1,987 unread"], visibleUnread: 0, hiddenUnread: 0), 1987,
            "a grouped thousands separator must parse, not truncate to 1"
        )
        // An inbox with nothing unread drops the label's count, and reading that
        // as 0 is what authoritatively clears the badge.
        XCTAssertEqual(
            evaluateGmailBadge(hash: "#inbox", ariaLabels: ["Inbox", "Spam 161 unread"], visibleUnread: 0, hiddenUnread: 99), 0,
            "an empty inbox should clear the badge"
        )
    }

    func testGmailBadgeFallsBackToVisibleRowsAndWithholdsWhenItCannotTell() {
        // If Gmail ever stops labelling the nav item, counting unread rows inside
        // the *visible* list still gets the inbox right — the stale container is
        // excluded by offsetParent.
        XCTAssertEqual(
            evaluateGmailBadge(hash: "#inbox", ariaLabels: [], visibleUnread: 2, hiddenUnread: 99), 2,
            "the fallback must count only the visible list"
        )
        XCTAssertEqual(
            evaluateGmailBadge(hash: "", ariaLabels: [], visibleUnread: 3, hiddenUnread: 50), 3,
            "an empty hash is the inbox too"
        )
        // Outside the inbox with no label to read, the visible list belongs to some
        // other view and counting it would be wrong. Yielding null (not 0) leaves
        // the last good badge alone instead of clearing it.
        XCTAssertNil(
            evaluateGmailBadge(hash: "#spam", ariaLabels: [], visibleUnread: 99, hiddenUnread: 2),
            "with no inbox count available, the badge should go unwritten"
        )
    }

    /// A page shaped like Gmail after you visit Spam and come back: the inbox list
    /// on screen, plus the Spam list still mounted and hidden. `hiddenUnread` rows
    /// are the ones a document-wide count wrongly picked up.
    private func fakeGmailHTML(visibleUnread: Int, hiddenUnread: Int, read: Int = 10) -> String {
        func rows(_ unread: Int, read: Int = 0) -> String {
            let unreadRows = (0..<unread).map { _ in "<tr class='zA zE'><td>unread</td></tr>" }
            let readRows = (0..<read).map { _ in "<tr class='zA yO'><td>read</td></tr>" }
            return "<table>" + (unreadRows + readRows).joined() + "</table>"
        }
        return """
        <html><body>
        <div role="navigation">
          <a href="#inbox" aria-label="Inbox \(visibleUnread) unread">Inbox</a>
          <a href="#spam" aria-label="Spam \(hiddenUnread) unread">Spam</a>
        </div>
        <div role="main">\(rows(visibleUnread, read: read))</div>
        <div role="main" style="display:none">\(rows(hiddenUnread))</div>
        </body></html>
        """
    }

    /// Waits for the fixture's own markup, not `document.readyState` — the initial
    /// empty document reads "complete" before `loadHTMLString` has replaced it, so
    /// polling readyState races through and every query comes back empty.
    private func waitForFixture(_ webView: WKWebView) async throws {
        for _ in 0..<100 {
            let mains = try? await webView.evaluateJavaScript("document.querySelectorAll('div[role=main]').length") as? Int
            if let mains, mains > 0 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Fake Gmail page never finished loading")
    }

    func testGmailBadgeInRealWebViewIgnoresCachedRowsFromOtherLabels() async throws {
        // The JSC tests above check the expression's logic; this one runs it
        // through the real path — WebKit's engine, the catalog string, and
        // NotificationManager's poll — against a page shaped like the DOM that
        // produced the bug.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        webView.loadHTMLString(fakeGmailHTML(visibleUnread: 2, hiddenUnread: 99), baseURL: URL(string: "https://mail.google.com/mail/u/0/#inbox"))
        try await waitForFixture(webView)

        // The fixture reproduces the bug: the old expression still reads 101 here.
        let documentWide = try await webView.evaluateJavaScript("document.querySelectorAll('tr.zA.zE').length") as? Int
        XCTAssertEqual(documentWide, 101, "fixture should hold the 101 unread rows that made the badge read 99+")

        let badgeManager = BadgeManager()
        let notifications = NotificationManager(badgeManager: badgeManager)
        let entry = ServiceCatalog.shared.entry(for: "gmail")
        let serviceID = UUID()
        await notifications.pollNow(for: serviceID, webView: webView, isMuted: false, showBadge: true, catalogEntry: entry)

        XCTAssertEqual(badgeManager.badgeCount(for: serviceID), 2, "the badge should report the inbox's 2, not the page's 101")
    }

    func testGmailBadgeInRealWebViewWorksInAZeroFrameWebView() async throws {
        // The offscreen badge fetcher builds its web view with a .zero frame, where
        // layout-dependent reads like offsetParent can't be trusted. The nav-label
        // path doesn't touch layout, so a hibernated service still reads its inbox
        // count — worth pinning, because the row-counting fallback would not.
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(fakeGmailHTML(visibleUnread: 3, hiddenUnread: 99), baseURL: URL(string: "https://mail.google.com/mail/u/0/#inbox"))
        try await waitForFixture(webView)

        guard let js = ServiceCatalog.shared.entry(for: "gmail")?.badgeJS else {
            return XCTFail("Gmail catalog entry should define badgeJS")
        }
        let count = try await webView.evaluateJavaScript(js) as? Int
        XCTAssertEqual(count, 3, "an offscreen view should still read the inbox count from the nav label")
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
        XCTAssertEqual(AppPreferences(railLayoutRaw: "garbage").railLayout, .sidebar)
    }

    /// The retired third case maps forward, and it must not take the `.sidebar`
    /// fallback. A `hybrid` user picked their services as tabs along the top; the
    /// fallback would hand them a rail down the left, which is the layout
    /// furthest from what they chose.
    func testRetiredHybridLayoutMapsForwardToTheBarRatherThanTheFallback() {
        XCTAssertEqual(AppPreferences(railLayoutRaw: "hybrid").railLayout, .topBars)
        XCTAssertEqual(RailLayout.resolving("hybrid"), .topBars)
        XCTAssertNotEqual(RailLayout.resolving("hybrid"), .sidebar)
    }

    /// The enum is down to two cases, so the Settings picker offers two. If a
    /// third ever comes back it needs its own forward-map story.
    func testRailLayoutHasExactlyTheTwoSurvivingCases() {
        XCTAssertEqual(RailLayout.allCases.map(\.rawValue), ["sidebar", "topBars"])
        XCTAssertNil(RailLayout(rawValue: RailLayout.retiredHybridRawValue))
    }

    // MARK: - Notice shape, radius scale, selection against focus (build step 7)

    /// Eight radii down to three. The point of the scale is that there is
    /// nowhere else to go, so a fourth value is the thing the test catches.
    func testRadiusScaleHasExactlyThreeValues() {
        XCTAssertEqual(Set(ChorusRadius.allValues), [4, 8, 14])
        XCTAssertEqual(ChorusRadius.icon, 4)
        XCTAssertEqual(ChorusRadius.control, 8)
        XCTAssertEqual(ChorusRadius.surface, 14)
    }

    /// Three severities, and the tone has to carry the difference: same fill
    /// weight throughout, a different tint and a different icon per severity.
    func testNoticeSeveritiesAreDistinctInToneAndIcon() {
        let all = NoticeSeverity.allCases
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.systemImage)).count, 3)
        // One fill weight for all three: the spec's point is that the fill does
        // not carry severity, the icon and the rule do.
        XCTAssertEqual(Set(all.map(\.fillOpacity)).count, 1)
    }

    /// Selection and keyboard focus must never be drawn the same way. The audit's
    /// finding was that `focusEffectDisabled()` deleted the focus signal instead
    /// of reshaping it; a fill for one and a ring for the other is the reshape.
    func testSelectionAndFocusNeverDrawTheSameMark() {
        XCTAssertEqual(RowMark(isSelected: true, isFocused: false), RowMark(fill: .selected, ring: false))
        XCTAssertEqual(RowMark(isSelected: false, isFocused: true), RowMark(fill: .none, ring: true))
        XCTAssertEqual(RowMark(isSelected: true, isFocused: true), RowMark(fill: .selected, ring: true))
        XCTAssertEqual(RowMark(isSelected: false, isFocused: false), RowMark(fill: .none, ring: false))
    }

    /// Hover is a third, quieter thing, and selection outranks it — a selected
    /// row under the pointer should not change weight.
    func testHoverIsOutrankedBySelection() {
        XCTAssertEqual(RowMark(isSelected: false, isFocused: false, isHovering: true).fill, .hover)
        XCTAssertEqual(RowMark(isSelected: true, isFocused: false, isHovering: true).fill, .selected)
    }

    // MARK: - Service health (build step 6)

    /// A load starting always means loading, including a retry after a failure —
    /// otherwise the orange dot would sit there through a successful reload.
    func testServiceHealthStartingALoadAlwaysMeansLoading() {
        XCTAssertEqual(ServiceHealth.live.next(.startedLoading), .loading)
        XCTAssertEqual(ServiceHealth.failed.next(.startedLoading), .loading)
        XCTAssertEqual(ServiceHealth.loading.next(.startedLoading), .loading)
    }

    func testServiceHealthFinishingALoadClearsBothLoadingAndFailed() {
        XCTAssertEqual(ServiceHealth.loading.next(.finishedLoading), .live)
        XCTAssertEqual(ServiceHealth.failed.next(.finishedLoading), .live)
        XCTAssertEqual(ServiceHealth.live.next(.finishedLoading), .live)
    }

    func testServiceHealthFailureWins() {
        XCTAssertEqual(ServiceHealth.loading.next(.failed), .failed)
        XCTAssertEqual(ServiceHealth.live.next(.failed), .failed)
    }

    /// Signed-out detection is deliberately not built (there is no general signal
    /// for it — see the spec). The case exists so the rail can draw it, but no
    /// navigation event may ever produce it, and nothing should quietly start.
    func testNoNavigationEventEverProducesSignedOut() {
        for start in [ServiceHealth.live, .loading, .failed, .signedOut] {
            for event in ServiceHealth.Event.allCases {
                XCTAssertNotEqual(start.next(event), .signedOut, "\(start) + \(event) produced signedOut")
            }
        }
    }

    /// Only `live` draws nothing. The other three each need a mark, and each mark
    /// needs a shape of its own — colour alone fails a red-green colour-blind
    /// user, which is the app's own standard.
    func testOnlyLiveDrawsNoDotAndEveryOtherStateHasItsOwnShape() {
        XCTAssertFalse(ServiceHealth.live.drawsDot)
        XCTAssertTrue(ServiceHealth.loading.drawsDot)
        XCTAssertTrue(ServiceHealth.failed.drawsDot)
        XCTAssertTrue(ServiceHealth.signedOut.drawsDot)

        let shapes = [ServiceHealth.loading, .failed, .signedOut].map(\.dotShape)
        XCTAssertEqual(Set(shapes).count, 3, "two health states share a silhouette")
    }

    /// The state has to reach VoiceOver in words, not only as a coloured dot.
    func testSpokenLabelCarriesHealthInWords() {
        XCTAssertEqual(
            ServiceAccessibility.label(name: "Slack", badgeCount: 0, isHibernated: false, isMuted: false, health: .live),
            "Slack"
        )
        XCTAssertEqual(
            ServiceAccessibility.label(name: "Slack", badgeCount: 0, isHibernated: false, isMuted: false, health: .loading),
            "Slack, loading"
        )
        XCTAssertEqual(
            ServiceAccessibility.label(name: "Slack", badgeCount: 3, isHibernated: false, isMuted: false, health: .failed),
            "Slack, 3 unread, failed to load"
        )
        XCTAssertEqual(
            ServiceAccessibility.label(name: "Slack", badgeCount: 0, isHibernated: false, isMuted: true, health: .signedOut),
            "Slack, muted, signed out"
        )
    }

    // MARK: - Space header and palette (build step 4)

    /// The palette labels its rows ⌘1 upward. Only the first nine get a digit —
    /// there is no ⌘0 row, and a tenth space is reached by arrow or click.
    func testSpacePaletteAssignsCommandDigitsToTheFirstNineRowsOnly() {
        XCTAssertEqual(SpacePalette.shortcutDigit(forIndex: 0), 1)
        XCTAssertEqual(SpacePalette.shortcutDigit(forIndex: 8), 9)
        XCTAssertNil(SpacePalette.shortcutDigit(forIndex: 9))
        XCTAssertNil(SpacePalette.shortcutDigit(forIndex: 40))
    }

    /// The digits are palette-local (decided 2026-08-17): they resolve to a row
    /// only while the palette is open, and only when a row is actually there. A
    /// digit past the end is not handled, so it never swallows the keystroke.
    func testSpacePaletteResolvesADigitOnlyWithinTheRowCount() {
        XCTAssertEqual(SpacePalette.index(forDigit: 1, rowCount: 3), 0)
        XCTAssertEqual(SpacePalette.index(forDigit: 3, rowCount: 3), 2)
        XCTAssertNil(SpacePalette.index(forDigit: 4, rowCount: 3))
        XCTAssertNil(SpacePalette.index(forDigit: 0, rowCount: 3))
        XCTAssertNil(SpacePalette.index(forDigit: 10, rowCount: 12))
        XCTAssertNil(SpacePalette.index(forDigit: 1, rowCount: 0))
    }

    func testSpacePaletteSubtitleCountsServices() {
        XCTAssertEqual(SpacePalette.subtitle(serviceCount: 0), "No services")
        XCTAssertEqual(SpacePalette.subtitle(serviceCount: 1), "1 service")
        XCTAssertEqual(SpacePalette.subtitle(serviceCount: 4), "4 services")
    }

    /// VoiceOver hears everything the row shows: name, how many services, the
    /// unread count, and mute. Mirrors `ServiceAccessibility.label`.
    func testSpacePaletteRowSpokenLabelFoldsInCountBadgeAndMute() {
        XCTAssertEqual(
            SpacePalette.rowLabel(name: "Work", serviceCount: 3, badgeCount: 0, isMuted: false),
            "Work, 3 services"
        )
        XCTAssertEqual(
            SpacePalette.rowLabel(name: "Work", serviceCount: 1, badgeCount: 1, isMuted: false),
            "Work, 1 service, 1 unread"
        )
        XCTAssertEqual(
            SpacePalette.rowLabel(name: "Work", serviceCount: 2, badgeCount: 7, isMuted: true),
            "Work, 2 services, 7 unread, muted"
        )
    }

    /// The header says where you are and that it opens something. The trait is
    /// applied by the view; this pins the words.
    func testSpaceHeaderSpokenLabelFoldsInBadgeAndMute() {
        XCTAssertEqual(SpaceHeader.label(spaceName: "Work", badgeCount: 0, isMuted: false), "Work")
        XCTAssertEqual(SpaceHeader.label(spaceName: "Work", badgeCount: 1, isMuted: false), "Work, 1 unread")
        XCTAssertEqual(SpaceHeader.label(spaceName: "Work", badgeCount: 12, isMuted: true), "Work, 12 unread, muted")
    }

    /// With no space resolved the header still draws rather than collapsing the
    /// rail, and it says so.
    func testSpaceHeaderLabelWithoutASpace() {
        XCTAssertEqual(SpaceHeader.label(spaceName: nil, badgeCount: 0, isMuted: false), "No space")
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
        // Insert only if the relationships did not already pull it in. When both
        // ends are in the context, building the link wires the inverses and the
        // link is registered with them; inserting again is a second registration,
        // which macOS 26 tolerates and macOS 14 traps on. When the ends are
        // detached the link is not registered and the insert is what it needs.
        if link.modelContext == nil {
            ctx.insert(link)
        }
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
        // No appends: the initializer sets both relationships and SwiftData
        // maintains the inverses, so `ghost.serviceLinks` and `beta.spaceLinks`
        // already hold this link. Appending it again registers it twice, which
        // macOS 26 tolerates and macOS 14 kills the test process over.
        //
        // Held with withExtendedLifetime rather than left to the inverses. These
        // three models are detached, so nothing in a context retains the link,
        // and ARC is free to release it after the last direct use — leaving
        // `ghost.serviceLinks` reaching for a freed object when `grouped` walks
        // it. That is a crash on macOS 14 and survives on macOS 26 only by luck
        // of timing.
        let danglingLink = SpaceServiceLink(sortOrder: 0, space: ghost, service: beta)

        withExtendedLifetime(danglingLink) {
            let result = NotificationGrouping.grouped(spaces: [live, ghost], services: [alpha, beta])

            // Only the live space is grouped; the ghost's dangling link is
            // skipped and Beta appears nowhere. Without the guard, Ghost/Beta
            // would show.
            XCTAssertEqual(result.groups.map { $0.space?.name }, ["Live"])
            XCTAssertEqual(result.groups.first?.services.map(\.label), ["Alpha"])
            XCTAssertFalse(result.groups.contains { group in
                group.services.contains { $0.label == "Beta" }
            })
        }
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
        let targetOrders = before.filter { $0.space?.id == spaceB.id }.map(\.sortOrder)
        movingLink.sortOrder = (targetOrders.max() ?? -1) + 1
        movingLink.space = spaceB
        try ctx.save()

        let after = try ctx.fetch(FetchDescriptor<SpaceServiceLink>())
        let inA = after.filter { $0.space?.id == spaceA.id }
        let inB = after.filter { $0.space?.id == spaceB.id }.sorted { $0.sortOrder < $1.sortOrder }

        XCTAssertTrue(inA.isEmpty, "source space should hold no links after the move")
        XCTAssertEqual(inB.map { $0.service?.label }, ["Gmail", "Slack"], "moved service lands at the tail of the target")
        XCTAssertEqual(inB.last?.sortOrder, 1)
        // The service keeps exactly one link: no orphan, no double-link.
        XCTAssertEqual(after.filter { $0.service?.id == moving.id }.count, 1)
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

    // MARK: - VersionedSchema migration

    /// Go/no-go for the enum-nested layout: SwiftData must resolve each nested
    /// `@Model` to its bare class name, else a real store won't match the
    /// declared version. (Verified here on this machine's macOS; the 14.0 target
    /// still needs a real-device pass per the plan — entity naming is a
    /// compile-time behavior so this is a fair proxy, the migration race is not.)
    func testVersionedSchemaEntityNamesAreBare() {
        let schemas: [(String, Schema)] = [
            ("V1_5_11", Schema(versionedSchema: ChorusSchemaV1_5_11.self)),
            ("V1_5_12", Schema(versionedSchema: ChorusSchemaV1_5_12.self)),
            ("VCurrent", Schema(versionedSchema: ChorusSchemaVCurrent.self)),
        ]
        for (label, schema) in schemas {
            let names = Set(schema.entities.map(\.name))
            for expected in ["ServiceInstance", "Space", "SpaceServiceLink", "AppPreferences"] {
                XCTAssertTrue(names.contains(expected), "\(label) entity names not bare: \(names)")
            }
        }
    }

    /// The plan's versions strictly increase and its stages connect every
    /// consecutive pair with no gap.
    func testMigrationPlanShapeIsContiguousAndIncreasing() {
        let versions = ChorusMigrationPlan.schemas.map { $0.versionIdentifier }
        XCTAssertEqual(versions, versions.sorted(), "versionIdentifiers must be in increasing order")
        XCTAssertEqual(Set(versions).count, versions.count, "versionIdentifiers must be unique")
        XCTAssertEqual(
            ChorusMigrationPlan.stages.count,
            ChorusMigrationPlan.schemas.count - 1,
            "need exactly one stage between each consecutive version"
        )
    }

    /// Drift guard: the current stored shape is pinned here. If this fails, a
    /// stored property changed on a model — freeze the prior shape as a new
    /// `ChorusSchemaV…`, bump `ChorusSchemaVCurrent`, add a stage + fixture, then
    /// update these sets. Turns "forgot to version a schema change" into a red
    /// test. `AppPreferences` is covered because the historical versioned schemas
    /// share a FROZEN copy of it — this catches drift between that frozen copy and
    /// the live model.
    func testCurrentStoredShapeIsPinned() throws {
        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        func entity(_ name: String) throws -> Schema.Entity {
            try XCTUnwrap(schema.entities.first { $0.name == name }, "no entity \(name)")
        }

        let service = try entity("ServiceInstance")
        XCTAssertEqual(
            Set(service.attributes.map(\.name)),
            [
                "id", "label", "url", "customIconData", "fetchedIconData", "faviconFetchedAt",
                "catalogEntryID", "isMuted", "showBadge", "neverHibernate", "userAgent",
                "dataStoreIdentifier", "pageZoom", "osNotificationsEnabled", "customCSS",
                "forceDarkMode", "darkModeRaw", "cameraPolicyRaw", "microphonePolicyRaw",
                "openExternalLinksInApp", "stayActiveInBackground", "hasSeenPasskeyNotice",
                "hibernationPolicyRaw", "hibernateAfterMinutes", "createdAt", "lastAccessedAt",
            ],
            "ServiceInstance stored attributes changed without a new schema version"
        )
        XCTAssertEqual(
            Set(service.relationships.map(\.name)), ["spaceLinks"],
            "ServiceInstance relationships changed without a new schema version"
        )

        XCTAssertEqual(
            Set(try entity("Space").attributes.map(\.name)),
            ["id", "name", "emoji", "sortOrder", "isMuted", "createdAt"],
            "Space stored attributes changed without a new schema version"
        )
        let link = try entity("SpaceServiceLink")
        XCTAssertEqual(
            Set(link.attributes.map(\.name)),
            ["id", "sortOrder"],
            "SpaceServiceLink stored attributes changed without a new schema version"
        )
        // Both ends must stay optional. Non-optional is what made a cascade
        // delete trap on macOS 15 and kill the app on deleting a space, and the
        // attribute set above cannot see it because a relationship is not an
        // attribute — so assert it directly.
        for name in ["space", "service"] {
            let relationship = try XCTUnwrap(
                link.relationships.first { $0.name == name },
                "SpaceServiceLink lost its \(name) relationship"
            )
            XCTAssertTrue(
                relationship.isOptional,
                "SpaceServiceLink.\(name) must stay optional: a .cascade delete has to clear it, and SwiftData traps on macOS 15 when it cannot"
            )
        }

        // Control, so the check above cannot pass vacuously: the frozen 1.5.13
        // shape is the same relationships NOT optional, and `isOptional` has to
        // tell them apart or it is measuring nothing.
        let frozenLink = try XCTUnwrap(
            Schema(versionedSchema: ChorusSchemaV1_5_13.self).entities.first { $0.name == "SpaceServiceLink" }
        )
        for name in ["space", "service"] {
            let relationship = try XCTUnwrap(frozenLink.relationships.first { $0.name == name })
            XCTAssertFalse(
                relationship.isOptional,
                "the frozen 1.5.13 shape is meant to be the non-optional one"
            )
        }
        XCTAssertEqual(
            Set(try entity("AppPreferences").attributes.map(\.name)),
            [
                "id", "appPresenceMode", "launchAtLogin", "globalKeyboardShortcutsEnabled",
                "showBadgeCountInDock", "autoDismissCookieBanners", "selectedSpaceID",
                "selectedServiceID", "defaultZoom", "scheduledDNDEnabled", "dndStartMinutes",
                "dndEndMinutes", "appLockEnabled", "lockOnLaunch", "lockOnSleep", "railLayoutRaw",
                "appearanceModeRaw", "contentBlockingEnabled", "annoyanceBlockingEnabled",
                "defaultCameraPolicyRaw", "defaultMicrophonePolicyRaw", "googleFaviconFallbackEnabled",
                "autoHibernateIdleEnabled", "autoHibernateIdleMinutes",
            ],
            "AppPreferences stored attributes changed — freeze its historical shape before editing (see ChorusSchema.swift)"
        )
    }

    /// Guards that the shared frozen `AppPreferences` still matches the live model,
    /// the specific drift the review flagged: the historical versioned schemas
    /// reference the frozen copy, so if the live `AppPreferences` gains a field
    /// and the frozen copy isn't updated with a new version, a real old store
    /// stops matching its declared version. Compare their attribute sets directly.
    func testFrozenAppPreferencesMatchesLiveModel() {
        let frozen = Schema([ChorusSchemaV1_5_11.AppPreferences.self])
        let live = Schema([AppPreferences.self])
        let frozenAttrs = Set((frozen.entities.first?.attributes ?? []).map(\.name))
        let liveAttrs = Set((live.entities.first?.attributes ?? []).map(\.name))
        XCTAssertEqual(
            frozenAttrs, liveAttrs,
            "frozen AppPreferences drifted from live — if you added a settings field, freeze the prior shape and add a new schema version"
        )
    }

    /// The incident path. Write a store at the 1.5.11 shape, reopen it at the
    /// current shape through the plan, and assert every row and field survives —
    /// with the fields added after 1.5.11 defaulting correctly. Proves the stage
    /// mapping is lossless (not that the field race is gone — see the plan).
    func testMigratesFrom1_5_11PreservingAllData() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chorus-migr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")

        let serviceID = UUID(), spaceID = UUID(), linkID = UUID()

        // 1) Seed a store at the 1.5.11 shape (no migration plan).
        try autoreleasepool {
            let schema = Schema(versionedSchema: ChorusSchemaV1_5_11.self)
            let config = ModelConfiguration(schema: schema, url: url)
            let container = try ModelContainer(for: schema, configurations: [config])
            let ctx = container.mainContext
            let space = ChorusSchemaV1_5_11.Space(id: spaceID, name: "Work", emoji: "🏢", sortOrder: 3)
            space.isMuted = true
            let service = ChorusSchemaV1_5_11.ServiceInstance(id: serviceID, label: "Gmail", url: "https://mail.google.com")
            // Set EVERY 1.5.11 stored field to a distinct non-default value, so a
            // stage that silently dropped a pre-existing column would fail below.
            service.customIconData = Data([1, 2, 3])
            service.fetchedIconData = Data([4, 5, 6])
            service.faviconFetchedAt = Date(timeIntervalSince1970: 1_000_000)
            service.catalogEntryID = "gmail"
            service.isMuted = true
            service.showBadge = false
            service.neverHibernate = true
            service.userAgent = "CustomUA/1.0"
            service.pageZoom = 1.25
            service.osNotificationsEnabled = false
            service.customCSS = "body { color: red; }"
            service.forceDarkMode = true
            service.darkModeRaw = "on"
            service.cameraPolicyRaw = "deny"
            service.microphonePolicyRaw = "allow"
            service.openExternalLinksInApp = true
            service.hasSeenPasskeyNotice = true
            ctx.insert(space); ctx.insert(service)
            try ctx.save()
            // Link after the ends are committed; see makeDeleteFixture.
            let link = ChorusSchemaV1_5_11.SpaceServiceLink(id: linkID, sortOrder: 5, space: space, service: service)
            if link.modelContext == nil { ctx.insert(link) }
            try ctx.save()
        }

        // 2) Reopen at the current shape through the plan.
        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let config = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, migrationPlan: ChorusMigrationPlan.self, configurations: [config])
        let ctx = container.mainContext

        let services = try ctx.fetch(FetchDescriptor<ServiceInstance>())
        XCTAssertEqual(services.count, 1)
        let s = try XCTUnwrap(services.first)
        XCTAssertEqual(s.id, serviceID)
        XCTAssertEqual(s.label, "Gmail")
        XCTAssertEqual(s.url, "https://mail.google.com")
        XCTAssertEqual(s.customIconData, Data([1, 2, 3]))
        XCTAssertEqual(s.fetchedIconData, Data([4, 5, 6]))
        XCTAssertEqual(s.faviconFetchedAt, Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(s.catalogEntryID, "gmail")
        XCTAssertTrue(s.isMuted)
        XCTAssertFalse(s.showBadge)
        XCTAssertTrue(s.neverHibernate)
        XCTAssertEqual(s.userAgent, "CustomUA/1.0")
        XCTAssertEqual(s.pageZoom, 1.25)
        XCTAssertEqual(s.osNotificationsEnabled, false)
        XCTAssertEqual(s.customCSS, "body { color: red; }")
        XCTAssertEqual(s.forceDarkMode, true)
        XCTAssertEqual(s.darkModeRaw, "on")
        XCTAssertEqual(s.cameraPolicyRaw, "deny")
        XCTAssertEqual(s.microphonePolicyRaw, "allow")
        XCTAssertEqual(s.openExternalLinksInApp, true)
        XCTAssertEqual(s.hasSeenPasskeyNotice, true)
        // Added after 1.5.11 → nil on disk, resolving to their documented defaults.
        XCTAssertNil(s.stayActiveInBackground)
        XCTAssertNil(s.hibernationPolicyRaw)
        XCTAssertNil(s.hibernateAfterMinutes)
        XCTAssertFalse(s.staysActiveInBackgroundEffective)
        XCTAssertEqual(s.hibernationPolicyEffective, .never)  // legacy neverHibernate == true

        let spaces = try ctx.fetch(FetchDescriptor<Space>())
        XCTAssertEqual(spaces.count, 1)
        let sp = try XCTUnwrap(spaces.first)
        XCTAssertEqual(sp.id, spaceID)
        XCTAssertEqual(sp.name, "Work")
        XCTAssertEqual(sp.sortOrder, 3)
        XCTAssertTrue(sp.isMutedEffective)

        let links = try ctx.fetch(FetchDescriptor<SpaceServiceLink>())
        XCTAssertEqual(links.count, 1)
        let l = try XCTUnwrap(links.first)
        XCTAssertEqual(l.sortOrder, 5)
        XCTAssertEqual(l.space?.id, spaceID)
        XCTAssertEqual(l.service?.id, serviceID)
    }

    /// The second stage (1.5.12 → current). A 1.5.12 store already has
    /// `stayActiveInBackground`; it must survive, and only the hibernation fields
    /// should arrive as nil.
    func testMigratesFrom1_5_12PreservingAllData() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chorus-migr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")

        let serviceID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: ChorusSchemaV1_5_12.self)
            let config = ModelConfiguration(schema: schema, url: url)
            let container = try ModelContainer(for: schema, configurations: [config])
            let ctx = container.mainContext
            let service = ChorusSchemaV1_5_12.ServiceInstance(id: serviceID, label: "Teams", url: "https://teams.microsoft.com")
            service.stayActiveInBackground = true
            ctx.insert(service)
            try ctx.save()
        }

        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let config = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, migrationPlan: ChorusMigrationPlan.self, configurations: [config])
        let ctx = container.mainContext

        let s = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ServiceInstance>()).first)
        XCTAssertEqual(s.id, serviceID)
        XCTAssertEqual(s.label, "Teams")
        XCTAssertEqual(s.stayActiveInBackground, true)
        XCTAssertTrue(s.staysActiveInBackgroundEffective)
        XCTAssertNil(s.hibernationPolicyRaw)
        XCTAssertNil(s.hibernateAfterMinutes)
    }

    /// 1.5.13 (the shape 1.5.13 to 1.5.18 shipped) opens at the current shape
    /// with its links intact, and both ends of every link still resolve.
    ///
    /// This is the stage that relaxes `SpaceServiceLink.space` and `.service` to
    /// optional. Dropping a constraint should carry every row across untouched,
    /// and the assertions below are about the ends specifically, because a
    /// migration that quietly nulled them would leave a store full of links
    /// pointing at nothing — which reads exactly like the data loss this project
    /// has already had twice.
    func testMigratesFrom1_5_13PreservingLinkEnds() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chorus-migr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")

        let serviceID = UUID(), spaceID = UUID(), linkID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: ChorusSchemaV1_5_13.self)
            let config = ModelConfiguration(schema: schema, url: url)
            let container = try ModelContainer(for: schema, configurations: [config])
            let ctx = container.mainContext
            let space = ChorusSchemaV1_5_13.Space(id: spaceID, name: "Work", emoji: "🏢", sortOrder: 3)
            let service = ChorusSchemaV1_5_13.ServiceInstance(id: serviceID, label: "Slack", url: "https://slack.com")
            service.hibernationPolicyRaw = "never"
            service.hibernateAfterMinutes = 42
            ctx.insert(space); ctx.insert(service)
            try ctx.save()
            // Link after the ends are committed; see makeDeleteFixture.
            let link = ChorusSchemaV1_5_13.SpaceServiceLink(id: linkID, sortOrder: 7, space: space, service: service)
            if link.modelContext == nil { ctx.insert(link) }
            try ctx.save()
        }

        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let config = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, migrationPlan: ChorusMigrationPlan.self, configurations: [config])
        let ctx = container.mainContext

        let link = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SpaceServiceLink>()).first)
        XCTAssertEqual(link.id, linkID)
        XCTAssertEqual(link.sortOrder, 7)
        XCTAssertEqual(link.space?.id, spaceID, "the migration must not drop the link's space")
        XCTAssertEqual(link.service?.id, serviceID, "the migration must not drop the link's service")
        XCTAssertNotNil(link.liveEnds, "both ends must still resolve after the migration")

        let service = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ServiceInstance>()).first)
        XCTAssertEqual(service.hibernationPolicyRaw, "never")
        XCTAssertEqual(service.hibernateAfterMinutes, 42)
        XCTAssertEqual(service.spaceLinks.count, 1, "the inverse must survive too")
    }

    // MARK: - Deleting either end of a link
    //
    // Two things are pinned across the three tests below, learned in this order.
    //
    // The trap came first. `Space.serviceLinks` and `ServiceInstance.spaceLinks`
    // both cascade, so a delete has to clear the link's reference, and while
    // those references were non-optional macOS 15 trapped rather than allow it —
    //
    //   Cannot remove Chorus.Space from relationship space on
    //   Chorus.SpaceServiceLink because an appropriate default value is not
    //   configured
    //
    // — which killed the app on deleting a space. Optional ends fixed that.
    //
    // Then macOS 14 showed the second thing. With optional ends it does not
    // trap, but it does not take the link either: the row survives with its
    // `space` nulled, the dangling state `reapDanglingLinks` cleans up after. So
    // the app deletes links explicitly and does not lean on the rule, and these
    // assert the end state rather than the mechanism — the mechanism is exactly
    // what differs between 14, 15 and 26.
    //
    // One container per test, deliberately. Holding several at once collides on
    // macOS 14 with "Duplicate registration attempt for object with id ...
    // SpaceServiceLink": the pre-save temporary ids are registered process-wide
    // there, and separate store URLs do not separate them.

    private func makeDeleteFixture() throws -> (ModelContainer, Space, ServiceInstance, SpaceServiceLink) {
        let schema = Schema([ServiceInstance.self, Space.self, SpaceServiceLink.self, AppPreferences.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext
        // Insert and commit the two ends BEFORE building the link. Constructing
        // a link wires the inverse, so `space.serviceLinks` already holds it;
        // inserting the space afterwards cascades that link into the context and
        // the explicit `insert(link)` then registers it a second time. macOS 26
        // tolerates the double registration and macOS 14 traps on it —
        // "Duplicate registration attempt for object with id ... SpaceServiceLink"
        // — taking the whole suite down. This is the order the other tests here
        // already use.
        let space = Space(name: "Doomed", emoji: "📦", sortOrder: 0)
        let service = ServiceInstance(label: "only-here", url: "https://a.example", catalogEntryID: "a")
        ctx.insert(space)
        ctx.insert(service)
        try ctx.save()

        let link = SpaceServiceLink(sortOrder: 0, space: space, service: service)
        if link.modelContext == nil {
            ctx.insert(link)
        }
        try ctx.save()
        return (container, space, service, link)
    }

    /// `AppState.deleteSpace`: the links, the orphaned service, then the space.
    func testDeleteSpaceOrderingLeavesNothingBehind() throws {
        let (container, space, service, link) = try makeDeleteFixture()
        let ctx = container.mainContext
        ctx.delete(link)
        ctx.delete(service)
        ctx.delete(space)
        try ctx.save()

        XCTAssertTrue(try ctx.fetch(FetchDescriptor<SpaceServiceLink>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Space>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<ServiceInstance>()).isEmpty)
    }

    /// `UnifiedRailView.deleteService`: the service's links, then the service,
    /// with the space left standing.
    func testDeleteServiceOrderingLeavesTheSpaceStanding() throws {
        let (container, _, service, link) = try makeDeleteFixture()
        let ctx = container.mainContext
        ctx.delete(link)
        ctx.delete(service)
        try ctx.save()

        XCTAssertTrue(try ctx.fetch(FetchDescriptor<SpaceServiceLink>()).isEmpty)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Space>()).count, 1, "the space must survive its service")
    }

    /// The bare deletes, with no link cleanup, must still not trap — this is the
    /// regression guard for the macOS 15 crash itself. Whatever survives has to
    /// read as dangling rather than fault, which is what the optional ends buy.
    func testBareDeletesNeverTrapAndLeaveOnlyReadableLinks() throws {
        let (container, space, service, _) = try makeDeleteFixture()
        let ctx = container.mainContext
        ctx.delete(space)
        try ctx.save()
        ctx.delete(service)
        try ctx.save()

        for link in try ctx.fetch(FetchDescriptor<SpaceServiceLink>()) {
            XCTAssertNil(link.liveEnds, "a link that outlived both ends must read as dangling, not fault")
        }
    }

    /// The REAL production provenance. Every field store today was written by the
    /// old `AppState.init`, which used a PLAIN `Schema([...])` (no version), not a
    /// `VersionedSchema`. This seeds a store exactly that way — a plain `Schema`
    /// over the 1.5.11-shaped types — then opens it through the versioned plan,
    /// the way the upgraded app will. It must open with data intact, NOT throw
    /// (which would strand every existing user in the in-memory fallback). Locks
    /// in CI what the local real-snapshot check proved by hand. (macOS 14.0 still
    /// needs its own device pass — the migration race is OS-specific.)
    func testMigratesFromPlainSchemaProductionStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chorus-migr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")

        let serviceID = UUID(), spaceID = UUID()

        // Seed with a PLAIN Schema of the 1.5.11-shaped types — production's exact
        // write path (plain Schema, older shape), not Schema(versionedSchema:).
        try autoreleasepool {
            let schema = Schema([
                ChorusSchemaV1_5_11.ServiceInstance.self,
                ChorusSchemaV1_5_11.Space.self,
                ChorusSchemaV1_5_11.SpaceServiceLink.self,
                ChorusSchemaV1_5_11.AppPreferences.self,
            ])
            let config = ModelConfiguration(schema: schema, url: url)
            let container = try ModelContainer(for: schema, configurations: [config])
            let ctx = container.mainContext
            let space = ChorusSchemaV1_5_11.Space(id: spaceID, name: "Work", emoji: "🏢", sortOrder: 1)
            let service = ChorusSchemaV1_5_11.ServiceInstance(id: serviceID, label: "Gmail", url: "https://mail.google.com")
            let link = ChorusSchemaV1_5_11.SpaceServiceLink(id: UUID(), sortOrder: 0, space: space, service: service)
            let prefs = ChorusSchemaV1_5_11.AppPreferences(id: UUID())
            ctx.insert(space); ctx.insert(service); ctx.insert(link); ctx.insert(prefs)
            try ctx.save()
        }

        // Open through the plan, as the upgraded production app does.
        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let config = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, migrationPlan: ChorusMigrationPlan.self, configurations: [config])
        let ctx = container.mainContext

        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Space>()), 1, "plain-Schema store must not migrate to empty")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<ServiceInstance>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<SpaceServiceLink>()), 1)
        let s = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ServiceInstance>()).first)
        XCTAssertEqual(s.id, serviceID)
        XCTAssertEqual(s.label, "Gmail")
    }

    // MARK: - Store content and the default-seed fingerprint

    /// `holdsMore` ranks by services first, then spaces, and is false for equal
    /// content — the comparison both the ranking and the offer rule depend on.
    func testHoldsMoreRanksServicesThenSpaces() {
        let big = StoreContent(spaces: 4, services: 13, links: 13, spaceNames: [], serviceLabels: [])
        let fewerServices = StoreContent(spaces: 9, services: 12, links: 12, spaceNames: [], serviceLabels: [])
        let sameServicesFewerSpaces = StoreContent(spaces: 2, services: 13, links: 13, spaceNames: [], serviceLabels: [])

        XCTAssertTrue(big.holdsMore(than: fewerServices), "more services wins even with fewer spaces")
        XCTAssertTrue(big.holdsMore(than: sameServicesFewerSpaces), "equal services falls through to spaces")
        XCTAssertFalse(big.holdsMore(than: big), "equal content is not more")
        XCTAssertFalse(fewerServices.holdsMore(than: big))
    }

    /// The fingerprint must match the seed exactly and nothing else.
    func testUntouchedSeedFingerprint() {
        let seed = StoreContent(
            spaces: 2,
            services: 7,
            links: 7,
            spaceNames: DefaultSeed.spaces.map(\.name),
            serviceLabels: DefaultSeed.allServiceLabels
        )
        XCTAssertTrue(seed.looksLikeUntouchedSeed, "the exact seed shape must match")

        var labels = DefaultSeed.allServiceLabels
        labels.append("Notion")
        let plusOne = StoreContent(spaces: 2, services: 8, links: 8, spaceNames: DefaultSeed.spaces.map(\.name), serviceLabels: labels)
        XCTAssertFalse(plusOne.looksLikeUntouchedSeed, "one added service means the user has touched it")

        let renamed = StoreContent(spaces: 2, services: 7, links: 7, spaceNames: ["Personal", "Clients"], serviceLabels: DefaultSeed.allServiceLabels)
        XCTAssertFalse(renamed.looksLikeUntouchedSeed, "a renamed space means the user has touched it")

        let empty = StoreContent(spaces: 0, services: 0, links: 0, spaceNames: [], serviceLabels: [])
        XCTAssertFalse(empty.looksLikeUntouchedSeed, "an empty store is empty, not seeded")
        XCTAssertTrue(empty.isEmpty)
    }

    /// The fingerprint must recognize a store built from the seed lists the
    /// seeder uses. If someone edits one seed list and not the fingerprint, this
    /// goes red.
    func testSeededStoreIsFingerprintedAsSeed() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-seedprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let container = try ModelContainer(for: Self.storeSchema, configurations: [config])
        let ctx = container.mainContext
        let spaces = DefaultSeed.spaces.enumerated().map { index, entry in
            Space(name: entry.name, emoji: entry.emoji, sortOrder: index)
        }
        for space in spaces { ctx.insert(space) }
        for (index, entry) in DefaultSeed.personalServices.enumerated() {
            let service = ServiceInstance(label: entry.label, url: entry.url, catalogEntryID: entry.catalogID)
            ctx.insert(service)
            ctx.insert(SpaceServiceLink(sortOrder: index, space: spaces[0], service: service))
        }
        for (index, entry) in DefaultSeed.workServices.enumerated() {
            let service = ServiceInstance(label: entry.label, url: entry.url, catalogEntryID: entry.catalogID)
            ctx.insert(service)
            ctx.insert(SpaceServiceLink(sortOrder: index, space: spaces[1], service: service))
        }
        try ctx.save()

        let content = StoreContent(
            spaces: try ctx.fetchCount(FetchDescriptor<Space>()),
            services: try ctx.fetchCount(FetchDescriptor<ServiceInstance>()),
            links: try ctx.fetchCount(FetchDescriptor<SpaceServiceLink>()),
            spaceNames: try ctx.fetch(FetchDescriptor<Space>()).map(\.name),
            serviceLabels: try ctx.fetch(FetchDescriptor<ServiceInstance>()).map(\.label)
        )
        XCTAssertTrue(content.looksLikeUntouchedSeed, "a store built from DefaultSeed must fingerprint as the seed")
    }

    /// Reading a store file must report its real counts and return nil
    /// (unknown) rather than zero for anything it cannot read. WAL visibility
    /// is covered separately, by `testReadContentSeesCommittedRowsStillInTheWAL`.
    func testReadContentCountsRowsAndDistinguishesUnknown() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-readcontent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePopulatedStore(at: storeURL, spaces: 3)
        let content = try XCTUnwrap(StoreInventory.readContent(at: storeURL))
        XCTAssertEqual(content.spaces, 3)
        XCTAssertEqual(content.services, 0, "makePopulatedStore inserts spaces only")
        XCTAssertEqual(Set(content.spaceNames), ["S0", "S1", "S2"], "names come back for the fingerprint")

        // A missing file is unknown, not empty.
        XCTAssertNil(StoreInventory.readContent(at: dir.appendingPathComponent("nope.sqlite")))

        // A file that is not a database is unknown.
        let garbage = dir.appendingPathComponent("garbage.sqlite")
        try "not a database".write(to: garbage, atomically: true, encoding: .utf8)
        XCTAssertNil(StoreInventory.readContent(at: garbage))

        // A database with an unrecognized schema is unknown, never zero.
        let alien = dir.appendingPathComponent("alien.sqlite")
        _ = try Self.runSQLite(alien, "CREATE TABLE ZOTHER (x INTEGER);")
        XCTAssertNil(StoreInventory.readContent(at: alien))
    }

    /// Guards the exact regression this reader exists to avoid. See
    /// `StoreInventory.openReadOnly`'s doc for the full rule: a plain open
    /// never uses `immutable=1` when a `-wal` sibling exists, because a `.bak`
    /// can sit beside a `-wal` holding committed-but-uncheckpointed rows, and
    /// an immutable open would silently under-count it. `makePopulatedStore`
    /// alone can't prove that: its container deallocates at the end of the
    /// call, and SQLite auto-checkpoints (folds the WAL into the main file) on
    /// the last close, so by the time `readContent` runs the row is very likely
    /// already in the main file either way. This test holds a second, writable
    /// connection open for the duration — so nothing checkpoints — commits a
    /// row through it, and shows `readContent` counts that row while a control
    /// connection opened with `immutable=1` does not. This test's store keeps a
    /// real `-wal` file the whole time, so `openReadOnly`'s narrow immutable
    /// fallback (which only applies when no `-wal` sibling exists) must not
    /// engage here; if `readContent` ever used `immutable=1` while a `-wal`
    /// with real rows is present, this goes red.
    func testReadContentSeesCommittedRowsStillInTheWAL() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePopulatedStore(at: storeURL, spaces: 2)

        // A second, writable connection, held open for the rest of the test.
        // The last connection to close is what triggers SQLite's
        // checkpoint-on-close, so keeping this one open is what keeps the row
        // below in the -wal file rather than folded into the main store.
        var writer: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &writer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let writer else {
            XCTFail("could not open a writable connection to the test store")
            return
        }
        defer { sqlite3_close(writer) }

        XCTAssertEqual(Self.execSQL(writer, "PRAGMA journal_mode=WAL;"), SQLITE_OK)
        XCTAssertEqual(Self.execSQL(writer, """
            INSERT INTO ZSPACE (Z_ENT, Z_OPT, ZSORTORDER, ZEMOJI, ZNAME)
            SELECT Z_ENT, 1, 99, '🌊', 'WAL-only' FROM ZSPACE LIMIT 1;
            """), SQLITE_OK, "the insert this test depends on must commit")

        // The row above is committed but, with `writer` still open, sitting in
        // the -wal file rather than the main one.
        let content = try XCTUnwrap(StoreInventory.readContent(at: storeURL))
        XCTAssertEqual(content.spaces, 3, "readContent must see the row committed to the WAL")
        XCTAssertTrue(content.spaceNames.contains("WAL-only"))

        // Control: an immutable=1 open of the same file ignores the WAL, so it
        // must see fewer spaces than readContent did. Without this contrast, a
        // regression that added immutable=1 to readContent could pass the
        // assertion above for the wrong reason (an early, coincidental
        // checkpoint) and this test would not catch it.
        var immutableDB: OpaquePointer?
        let uri = "file:\(storeURL.path)?immutable=1"
        guard sqlite3_open_v2(uri, &immutableDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let immutableDB else {
            XCTFail("could not open an immutable connection to the test store")
            return
        }
        defer { sqlite3_close(immutableDB) }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(immutableDB, "SELECT COUNT(*) FROM ZSPACE;", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        let immutableCount = Int(sqlite3_column_int64(stmt, 0))
        XCTAssertLessThan(immutableCount, content.spaces, "an immutable=1 open must not see the WAL-only row")
    }

    /// Runs one SQL statement to completion via `sqlite3_exec`, for test setup
    /// that needs a live, writable connection rather than the one-shot CLI
    /// `runSQLite` uses. Returns the SQLite result code.
    @discardableResult
    private static func execSQL(_ db: OpaquePointer, _ sql: String) -> Int32 {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Candidate enumeration

    /// Enumeration must find all four backup families plus the live store,
    /// parse stamps, and mark an unreadable file as unknown rather than empty.
    func testCandidateEnumerationCoversAllBackupFamilies() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Live store with 1 space; a 4-space snapshot; a 2-space prerestore; a
        // 3-space corrupt-family backup; a 5-space prepick-family backup (the
        // aside `applyPendingRestore` writes); and one unreadable snapshot.
        try makePopulatedStore(at: storeURL, spaces: 4)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.5.11+20")
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 2)
        try Self.copyStoreTriple(from: storeURL, to: dir.appendingPathComponent("store.sqlite.prerestore-1700000500.bak"))
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 3)
        try Self.copyStoreTriple(from: storeURL, to: dir.appendingPathComponent("store.sqlite.corrupt-1700000600.bak"))
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 5)
        try Self.copyStoreTriple(from: storeURL, to: dir.appendingPathComponent("store.sqlite.prepick-1700000700.bak"))
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 1)
        try "not a database".write(
            to: dir.appendingPathComponent("store.sqlite.snapshot-1700000900-1.5.12+21.bak"),
            atomically: true,
            encoding: .utf8
        )

        let live = try XCTUnwrap(StoreInventory.readContent(at: storeURL))
        let found = StoreInventory.candidates(for: storeURL, liveContent: live)

        XCTAssertEqual(found.count, 6, "live + snapshot + prerestore + corrupt + prepick + unreadable snapshot")
        XCTAssertEqual(found.filter { $0.kind == .live }.count, 1)
        XCTAssertEqual(found.first { $0.kind == .live }?.content?.spaces, 1)

        let snapshot = try XCTUnwrap(found.first { $0.kind == .snapshot(version: "1.5.11+20") })
        XCTAssertEqual(snapshot.content?.spaces, 4)
        XCTAssertEqual(snapshot.takenAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(snapshot.isRestorable)

        XCTAssertEqual(found.first { $0.kind == .prerestore }?.content?.spaces, 2)
        XCTAssertEqual(found.first { $0.kind == .corrupt }?.content?.spaces, 3)
        XCTAssertEqual(found.first { $0.kind == .prepick }?.content?.spaces, 5, "the .prepick- family must be recognized as its own kind, not folded into .corrupt")
        XCTAssertTrue(try XCTUnwrap(found.first { $0.kind == .prepick }).isRestorable)

        let unreadable = try XCTUnwrap(found.first { $0.kind == .snapshot(version: "1.5.12+21") })
        XCTAssertNil(unreadable.content, "an unreadable candidate is unknown, not empty")
        XCTAssertFalse(unreadable.isRestorable, "unknown content is never restorable")
    }

    /// Review Finding 4: the displayed list must rank backups by completeness
    /// (the same rule `best(among:)` uses), not by filename. A `.corrupt-`
    /// backup — damaged by definition, so it can never be preselected — must
    /// never sort above a `.snapshot-` holding more content just because
    /// ".corrupt-" sorts before ".snapshot-" lexically.
    func testCandidatesOrdersBackupsByCompletenessNotFilename() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // A fuller snapshot (5 spaces) and a thinner corrupt-family backup (1
        // space). Alphabetically ".corrupt-" < ".snapshot-", so a filename sort
        // would put the corrupt one first; completeness must not.
        try makePopulatedStore(at: storeURL, spaces: 5)
        try Self.copyStoreTriple(from: storeURL, to: dir.appendingPathComponent("store.sqlite.snapshot-1700000000-1.5.11+20.bak"))
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 1)
        try Self.copyStoreTriple(from: storeURL, to: dir.appendingPathComponent("store.sqlite.corrupt-1700000600.bak"))

        let live = try XCTUnwrap(StoreInventory.readContent(at: storeURL))
        let found = StoreInventory.candidates(for: storeURL, liveContent: live)

        XCTAssertEqual(found.first?.kind, .live, "the live row must always lead regardless of ranking")

        let snapshotIndex = try XCTUnwrap(found.firstIndex { $0.kind == .snapshot(version: "1.5.11+20") })
        let corruptIndex = try XCTUnwrap(found.firstIndex { $0.kind == .corrupt })
        XCTAssertLessThan(
            snapshotIndex, corruptIndex,
            "a fuller snapshot must sort above a corrupt-family backup, not below it by filename"
        )
    }

    /// A backup whose file header still says WAL-mode but whose `-wal` sibling
    /// is gone (exactly what `StoreRepair.snapshot` produces when it copies a
    /// store after a clean checkpoint, since it only copies suffixes that
    /// exist) must still be readable. A bare `SQLITE_OPEN_READONLY` open of
    /// such a file fails with SQLITE_CANTOPEN on this SQLite build, because a
    /// read-only connection can't create the `-shm` it needs — the exact bug
    /// this task found, reachable in production through both readers that
    /// share `StoreInventory.openReadOnly`. Regression guard: this must fail
    /// if the fallback is removed.
    func testMainFileOnlyWALBackupIsReadableThroughBothReaders() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-walonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePopulatedStore(at: storeURL, spaces: 3)
        // Strip any `-wal`/`-shm` siblings explicitly, so the fixture is a
        // WAL-mode-headed main file with no siblings regardless of exactly
        // when SQLite's own checkpoint-on-close removed them.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeURL.path + "-wal"),
            "precondition: no -wal sibling present"
        )

        let content = try XCTUnwrap(
            StoreInventory.readContent(at: storeURL),
            "a main-file-only WAL-mode backup must still be readable"
        )
        XCTAssertEqual(content.spaces, 3)

        XCTAssertEqual(
            StoreRepair.spaceCount(at: storeURL), 3,
            "spaceCount must share the same fallback as StoreInventory.readContent"
        )
    }

    /// Ranking takes the fullest restorable backup, breaks ties on recency, and
    /// ignores the live store, damaged files, and unreadable files.
    func testBestCandidateRanksContentThenRecency() {
        let dir = URL(fileURLWithPath: "/tmp/ranking")
        func candidate(
            _ name: String,
            _ kind: StoreCandidate.Kind,
            spaces: Int,
            services: Int,
            at stamp: TimeInterval,
            damaged: Bool = false,
            unknown: Bool = false
        ) -> StoreCandidate {
            StoreCandidate(
                url: dir.appendingPathComponent(name),
                kind: kind,
                takenAt: Date(timeIntervalSince1970: stamp),
                content: unknown ? nil : StoreContent(spaces: spaces, services: services, links: services, spaceNames: [], serviceLabels: []),
                isDamaged: damaged
            )
        }

        let fullOld = candidate("a", .snapshot(version: "1.5.11+20"), spaces: 4, services: 13, at: 1_000)
        let thinNew = candidate("b", .snapshot(version: "1.5.14+23"), spaces: 2, services: 7, at: 9_000)
        let fullNewer = candidate("c", .prerestore, spaces: 4, services: 13, at: 5_000)
        let live = candidate("live", .live, spaces: 9, services: 99, at: 9_999)
        let damaged = candidate("d", .snapshot(version: nil), spaces: 8, services: 40, at: 9_500, damaged: true)
        let unknown = candidate("e", .snapshot(version: nil), spaces: 0, services: 0, at: 9_600, unknown: true)

        let best = StoreInventory.best(among: [fullOld, thinNew, fullNewer, live, damaged, unknown])
        XCTAssertEqual(best, fullNewer, "equal content must break the tie on recency, and live/damaged/unknown are excluded")

        XCTAssertEqual(
            StoreInventory.best(among: [thinNew, fullOld]),
            fullOld,
            "more content beats more recent"
        )
        XCTAssertNil(StoreInventory.best(among: [live, damaged, unknown]), "nothing restorable means no winner")
    }

    /// Two candidates tying on all four ranking keys must still have one settled
    /// order. `sorted(by:)` is not stable, and `best(among:)` takes the first of
    /// a sort, so a comparator that calls tied candidates equivalent hands the
    /// decision to whatever order `contentsOfDirectory` happened to return: the
    /// sheet's rows could shuffle between openings, and the preselected winner
    /// (and with it the decline key) could change launch to launch. The old
    /// filename sort was at least deterministic; the tiebreak below restores
    /// that without giving up ranking by completeness.
    func testRankingBreaksTiesDeterministicallyOnFilename() {
        let dir = URL(fileURLWithPath: "/tmp/ranking-ties")
        func candidate(_ name: String, _ kind: StoreCandidate.Kind) -> StoreCandidate {
            StoreCandidate(
                url: dir.appendingPathComponent(name),
                kind: kind,
                takenAt: Date(timeIntervalSince1970: 1_700_000_000),
                content: StoreContent(spaces: 2, services: 7, links: 7, spaceNames: [], serviceLabels: []),
                isDamaged: false
            )
        }
        // Same spaces, same services, same links, same instant — every ranking
        // key ties, so only the filename can separate them.
        let a = candidate("store.sqlite.prepick-1700000000.bak", .prepick)
        let b = candidate("store.sqlite.snapshot-1700000000-1.0.0.bak", .snapshot(version: "1.0.0"))

        XCTAssertNotEqual(
            StoreInventory.isRankedAbove(a, b), StoreInventory.isRankedAbove(b, a),
            "candidates tying on every key must still rank one above the other, not compare as equivalent"
        )
        XCTAssertEqual(
            StoreInventory.best(among: [a, b]), StoreInventory.best(among: [b, a]),
            "the winner must not depend on the order the directory listing happened to produce"
        )
        XCTAssertEqual(
            [a, b].sorted(by: StoreInventory.isRankedAbove).map(\.id),
            [b, a].sorted(by: StoreInventory.isRankedAbove).map(\.id),
            "the displayed order must be the same whichever way the list arrives"
        )
    }

    /// Preselection is narrower than ranking: it only fires when the live store
    /// holds nothing of the user's, and never picks a corrupt-family backup.
    func testPreselectionOnlyWhenLiveStoreHoldsNothingOfTheUsers() {
        let dir = URL(fileURLWithPath: "/tmp/preselect")
        let backup = StoreCandidate(
            url: dir.appendingPathComponent("s.bak"),
            kind: .snapshot(version: "1.5.11+20"),
            takenAt: Date(timeIntervalSince1970: 1_000),
            content: StoreContent(spaces: 4, services: 13, links: 13, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )
        let corruptBackup = StoreCandidate(
            url: dir.appendingPathComponent("c.bak"),
            kind: .corrupt,
            takenAt: Date(timeIntervalSince1970: 2_000),
            content: StoreContent(spaces: 9, services: 40, links: 40, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )
        let empty = StoreContent(spaces: 0, services: 0, links: 0, spaceNames: [], serviceLabels: [])
        let seeded = StoreContent(
            spaces: 2, services: 7, links: 7,
            spaceNames: DefaultSeed.spaces.map(\.name),
            serviceLabels: DefaultSeed.allServiceLabels
        )
        let usersOwn = StoreContent(spaces: 3, services: 10, links: 10, spaceNames: ["Home", "Work", "Side"], serviceLabels: [])

        XCTAssertEqual(StoreInventory.preselection(among: [backup], liveContent: empty), backup, "empty live store: preselect")
        XCTAssertEqual(StoreInventory.preselection(among: [backup], liveContent: seeded), backup, "seeded live store: preselect")
        XCTAssertEqual(StoreInventory.preselection(among: [backup], liveContent: nil), backup, "unreadable live store: preselect")
        XCTAssertNil(
            StoreInventory.preselection(among: [backup], liveContent: usersOwn),
            "the user's own data must never be silently preselected over"
        )
        XCTAssertNil(
            StoreInventory.preselection(among: [corruptBackup], liveContent: empty),
            "a corrupt-family backup is never preselected"
        )

        // An empty but valid backup cannot be preselected: it holds no more than
        // the live store, even when both are empty.
        let emptyBackup = StoreCandidate(
            url: dir.appendingPathComponent("empty.bak"),
            kind: .snapshot(version: "1.5.14"),
            takenAt: Date(timeIntervalSince1970: 8_000),
            content: empty,
            isDamaged: false
        )
        XCTAssertNil(
            StoreInventory.preselection(among: [emptyBackup], liveContent: empty),
            "empty backup holds no more than empty live store and is not preselected"
        )
    }

    /// Review Finding 6 (Tier 2): a `.corrupt` winner must not suppress
    /// preselection outright — the next-best non-corrupt candidate should be
    /// offered instead. Preselection only ever runs when the live store holds
    /// nothing of the user's, which is exactly when handing back "nothing
    /// selected" (a disabled button) is worst.
    func testPreselectionFallsThroughPastACorruptWinnerToTheNextBest() {
        let dir = URL(fileURLWithPath: "/tmp/preselect-fallthrough")
        // The fullest candidate overall is corrupt, so without the fallthrough
        // fix `best(among:)` would pick it and preselection would bail entirely.
        let corruptWinner = StoreCandidate(
            url: dir.appendingPathComponent("c.bak"),
            kind: .corrupt,
            takenAt: Date(timeIntervalSince1970: 5_000),
            content: StoreContent(spaces: 9, services: 40, links: 40, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )
        let nextBest = StoreCandidate(
            url: dir.appendingPathComponent("s.bak"),
            kind: .snapshot(version: "1.5.11+20"),
            takenAt: Date(timeIntervalSince1970: 1_000),
            content: StoreContent(spaces: 4, services: 13, links: 13, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )
        let empty = StoreContent(spaces: 0, services: 0, links: 0, spaceNames: [], serviceLabels: [])

        XCTAssertEqual(
            StoreInventory.preselection(among: [corruptWinner, nextBest], liveContent: empty),
            nextBest,
            "a corrupt winner must fall through to the next-best non-corrupt candidate, not suppress preselection entirely"
        )
    }

    /// The offer rule: two triggers, and the case that must stay silent.
    func testOfferRuleTriggersAndSilence() {
        let dir = URL(fileURLWithPath: "/tmp/offer")
        let backup = StoreCandidate(
            url: dir.appendingPathComponent("s.bak"),
            kind: .snapshot(version: "1.5.11+20"),
            takenAt: Date(timeIntervalSince1970: 1_000),
            content: StoreContent(spaces: 4, services: 13, links: 13, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )
        let seeded = StoreContent(
            spaces: 2, services: 7, links: 7,
            spaceNames: DefaultSeed.spaces.map(\.name),
            serviceLabels: DefaultSeed.allServiceLabels
        )
        let partial = StoreContent(spaces: 1, services: 4, links: 4, spaceNames: ["Home"], serviceLabels: [])
        let record = StoreContent(spaces: 4, services: 13, links: 13, spaceNames: [], serviceLabels: [])

        // Trigger 1: below the record, with a backup that covers the gap.
        XCTAssertEqual(
            StoreInventory.offer(liveContent: partial, best: backup, record: record, declinedKeys: []),
            .belowRecord
        )

        // Trigger 2: no record yet, and the live store is the untouched seed.
        // This is the already-lost user's first launch on a build that records.
        XCTAssertEqual(
            StoreInventory.offer(liveContent: seeded, best: backup, record: nil, declinedKeys: []),
            .nothingToLose
        )

        // The case that must stay silent: the user deleted spaces on purpose, so
        // the record matches what is there, and their store is their own.
        XCTAssertNil(
            StoreInventory.offer(liveContent: partial, best: backup, record: partial, declinedKeys: []),
            "a store matching its record is not loss, even with a fuller backup"
        )

        // No backup that holds more means nothing to offer.
        let thin = StoreCandidate(
            url: dir.appendingPathComponent("t.bak"),
            kind: .snapshot(version: nil),
            takenAt: nil,
            content: StoreContent(spaces: 1, services: 2, links: 2, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )
        XCTAssertNil(StoreInventory.offer(liveContent: partial, best: thin, record: record, declinedKeys: []))
        XCTAssertNil(StoreInventory.offer(liveContent: partial, best: nil, record: record, declinedKeys: []))

        // A remembered decline silences the same pairing.
        let key = StoreInventory.declineKey(live: partial, candidate: backup)
        XCTAssertNil(
            StoreInventory.offer(liveContent: partial, best: backup, record: record, declinedKeys: [key]),
            "a declined pairing must not ask again"
        )
        // A different live state is a different pairing, so it may ask again.
        XCTAssertNotNil(
            StoreInventory.offer(liveContent: seeded, best: backup, record: record, declinedKeys: [key])
        )

        // An unreadable live store (liveContent: nil) but a record on file: the
        // record branch for unknown live content fires directly.
        XCTAssertEqual(
            StoreInventory.offer(liveContent: nil, best: backup, record: record, declinedKeys: []),
            .belowRecord
        )

        // An unreadable live store and no record: this pins current behavior.
        // "Unknown" is deliberately treated as "nothing to lose" here, because
        // the outcome is an offer the user can decline, not an automatic action.
        XCTAssertEqual(
            StoreInventory.offer(liveContent: nil, best: backup, record: nil, declinedKeys: []),
            .nothingToLose,
            "an unreadable live store with no record is treated as nothing to lose here, since the result is a declinable offer, not an automatic restore"
        )

        // The coverage bypass: with liveContent nil there is nothing to compare
        // against, so even `thin` -- which fails the "holds more" gate against a
        // concrete live store above -- is not suppressed by that gate here.
        XCTAssertEqual(
            StoreInventory.offer(liveContent: nil, best: thin, record: nil, declinedKeys: []),
            .nothingToLose,
            "an unknown live store means there is nothing to compare against, so the coverage gate must not suppress even a thin backup"
        )
    }

    /// The record round-trips through the string form kept in UserDefaults.
    func testContentRecordRoundTrip() throws {
        let content = StoreContent(spaces: 4, services: 13, links: 13, spaceNames: [], serviceLabels: [])
        let encoded = StoreInventory.encodeRecord(content)
        let decoded = try XCTUnwrap(StoreInventory.decodeRecord(encoded))
        XCTAssertEqual(decoded.spaces, 4)
        XCTAssertEqual(decoded.services, 13)
        XCTAssertEqual(decoded.links, 13)

        XCTAssertNil(StoreInventory.decodeRecord("garbage"), "an unparseable record is no record")
        XCTAssertNil(StoreInventory.decodeRecord("4-13"), "a short record is no record")
        XCTAssertNil(StoreInventory.decodeRecord(""))
    }

    /// The pending filename comes from UserDefaults, which is external input, so
    /// it must be validated before any file operation uses it.
    func testValidatedRestoreNameRejectsAnythingUnexpected() {
        let store = "default.store"
        XCTAssertEqual(
            StoreRepair.validatedRestoreName("default.store.snapshot-1700000000-1.5.11+20.bak", storeName: store),
            "default.store.snapshot-1700000000-1.5.11+20.bak"
        )
        XCTAssertEqual(
            StoreRepair.validatedRestoreName("default.store.prerestore-1700000000.bak", storeName: store),
            "default.store.prerestore-1700000000.bak"
        )
        XCTAssertEqual(
            StoreRepair.validatedRestoreName("default.store.prepick-1700000000.bak", storeName: store),
            "default.store.prepick-1700000000.bak",
            "the prepick family (a prior deliberate restore's aside) must itself be walkable-back-from"
        )
        XCTAssertNil(StoreRepair.validatedRestoreName("../../etc/passwd", storeName: store), "no traversal")
        XCTAssertNil(StoreRepair.validatedRestoreName("/tmp/default.store.snapshot-1.bak", storeName: store), "no absolute paths")
        XCTAssertNil(StoreRepair.validatedRestoreName("default.store.snapshot-1/../x.bak", storeName: store), "no separators")
        XCTAssertNil(StoreRepair.validatedRestoreName("default.store", storeName: store), "the live store is not a backup")
        XCTAssertNil(StoreRepair.validatedRestoreName("other.store.snapshot-1.bak", storeName: store), "must belong to this store")
        XCTAssertNil(StoreRepair.validatedRestoreName("default.store.snapshot-1.txt", storeName: store), "must be a .bak")
        XCTAssertNil(StoreRepair.validatedRestoreName("", storeName: store))
    }

    /// Applying a pending restore must copy the chosen backup into place, always
    /// set the current store aside first, and clear the key so a crash cannot
    /// leave it looping.
    func testApplyPendingRestoreCopiesAndAlwaysBacksUp() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 4)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.0.0")
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 1)
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 1, "precondition: live store thinned out")

        defaults.set("store.sqlite.snapshot-1700000000-1.0.0.bak", forKey: StoreRepair.pendingRestoreKey)
        XCTAssertTrue(StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults))

        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 4, "the chosen backup must be in place")
        XCTAssertNil(defaults.string(forKey: StoreRepair.pendingRestoreKey), "the key must be cleared")

        let asideCount = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("store.sqlite.prepick-") && $0.hasSuffix(".bak") }
            .count
        XCTAssertEqual(asideCount, 1, "the thinned store must have been set aside, in its own .prepick- family (not .prerestore-, which restoreFromSnapshot's sentinel checks)")

        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix("store.sqlite.prerestore-") }
                .isEmpty,
            "a deliberate restore must never write into the .prerestore- family that restoreFromSnapshot's sentinel watches"
        )

        // A second apply with no key set is a no-op.
        XCTAssertFalse(StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults))

        // A rejected filename must clear the key and change nothing.
        defaults.set("../escape.bak", forKey: StoreRepair.pendingRestoreKey)
        XCTAssertFalse(StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults))
        XCTAssertNil(defaults.string(forKey: StoreRepair.pendingRestoreKey))
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 4, "a rejected name must not touch the store")
    }

    /// The revert branch (the chosen backup turns out unreadable) must put the
    /// previous store back exactly, and must not leave the CHOSEN BACKUP's
    /// `-wal` sitting beside the reverted main file. `copyTriple` used to skip
    /// removing a destination suffix whenever the source lacked it, which is
    /// harmless for the aside copy (a fresh path) but not for the revert: if
    /// the aside has no `-wal` (the normal post-clean-shutdown state) and the
    /// chosen backup's replace step left one behind, the revert would restore
    /// the old main file while leaving that foreign `-wal` in place — and
    /// SQLite does not bind a WAL to a specific database, so the next open
    /// would replay those frames onto the wrong store.
    func testApplyPendingRestoreRevertsWithoutLeavingAForeignWAL() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-revert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // The live store, in the normal post-clean-shutdown shape: real data,
        // no `-wal`/`-shm` siblings. This is what the aside copy will capture.
        try makePopulatedStore(at: storeURL, spaces: 3)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path + "-wal"), "precondition: no -wal sibling")
        let before = try XCTUnwrap(StoreRepair.spaceCount(at: storeURL), "precondition: live store is readable")
        XCTAssertEqual(before, 3)

        // A validly-named, but garbage, chosen backup — readContent will fail
        // on it — WITH a `-wal` sibling of its own. This is the "foreign WAL"
        // that must not survive the revert.
        let backupName = "store.sqlite.corrupt-1700001000.bak"
        let backupURL = dir.appendingPathComponent(backupName)
        try "not a database".write(to: backupURL, atomically: true, encoding: .utf8)
        try "someone else's WAL frames".write(
            to: URL(fileURLWithPath: backupURL.path + "-wal"),
            atomically: true,
            encoding: .utf8
        )

        defaults.set(backupName, forKey: StoreRepair.pendingRestoreKey)
        XCTAssertFalse(
            StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults),
            "an unreadable chosen backup must report failure"
        )

        XCTAssertNil(defaults.string(forKey: StoreRepair.pendingRestoreKey), "the key must still be cleared even on revert")
        XCTAssertEqual(
            StoreRepair.spaceCount(at: storeURL), before,
            "the revert must restore exactly what was live before the attempt"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeURL.path + "-wal"),
            "no foreign -wal from the rejected backup may remain beside the reverted store"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeURL.path + "-shm"),
            "no foreign -shm from the rejected backup may remain beside the reverted store"
        )
    }

    /// The missing-source branch: a filename that passes validation (it names
    /// one of the backup families and belongs to this store) but whose file is
    /// no longer on disk. This must return false, clear the key so it can't
    /// loop, and leave the live store completely untouched — no aside copy, no
    /// partial write.
    func testApplyPendingRestoreMissingSourceLeavesStoreUntouched() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 2)
        let before = try XCTUnwrap(StoreRepair.spaceCount(at: storeURL))

        // Validly named for this store, but never written to disk.
        let missingName = "store.sqlite.snapshot-1700009999-1.9.9.bak"
        XCTAssertNotNil(
            StoreRepair.validatedRestoreName(missingName, storeName: storeURL.lastPathComponent),
            "precondition: the name itself must pass validation"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(missingName).path))

        defaults.set(missingName, forKey: StoreRepair.pendingRestoreKey)
        XCTAssertFalse(StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults))

        XCTAssertNil(defaults.string(forKey: StoreRepair.pendingRestoreKey), "the key must be cleared")
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), before, "a missing source must not touch the store")

        let anyAsideFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("store.sqlite.prepick-") }
        XCTAssertTrue(anyAsideFiles.isEmpty, "a missing source must return before any aside copy is made")
    }

    /// Review Finding 1: `copyTriple`'s `Bool` return is the mechanism the fix
    /// depends on, so it is tested directly rather than only indirectly through
    /// `applyPendingRestore`. A real copy into an existing directory succeeds;
    /// a destination inside a directory that does not exist cannot be written
    /// to, so `copyItem` throws and this must report failure, not silently
    /// swallow it the way the old `Void`-returning version did.
    func testCopyTripleReportsSuccessAndFailure() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-copytriple-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("source.sqlite")
        try "some store bytes".write(to: sourceURL, atomically: true, encoding: .utf8)

        let goodDestination = dir.appendingPathComponent("dest.sqlite")
        XCTAssertTrue(
            StoreRepair.copyTriple(from: sourceURL.path, to: goodDestination.path, label: "test-good"),
            "a real copy into an existing directory must report success"
        )
        XCTAssertEqual(try String(contentsOf: goodDestination, encoding: .utf8), "some store bytes")

        let badDestination = dir.appendingPathComponent("does-not-exist").appendingPathComponent("dest.sqlite")
        XCTAssertFalse(
            StoreRepair.copyTriple(from: sourceURL.path, to: badDestination.path, label: "test-bad"),
            "a destination inside a directory that doesn't exist must report failure, not silently succeed"
        )
    }

    /// Review Finding 1, the false-success half. The apply step's `removeItem`
    /// on the live store's own main file is made to fail here by setting the
    /// `uchg` (immutable) flag, which blocks deletion even for the file's
    /// owner (verified empirically on this filesystem: `FileManager
    /// .removeItem` fails with "Operation not permitted" under it, the same
    /// failure shape a real permissions or flag problem would produce).
    /// `copyItem` then throws "file already exists" because the (still
    /// present) destination was never actually removed. Before the fix,
    /// `applyPendingRestore` only checked whether `storeURL` still read
    /// afterward — and it did, because it was untouched — so this reported
    /// success having changed nothing. `copyTriple`'s return value now catches
    /// this directly.
    func testApplyPendingRestoreReportsFailureWhenTheLiveFileResistsRemoval() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-uchg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        // `copyItem` carries BSD flags across, so the aside copy of the live file
        // can arrive holding `UF_IMMUTABLE` too — and a directory holding an
        // immutable file cannot be removed. Clear the flag on every entry, not
        // just the live file, or this fixture survives the run in the temp
        // directory and `try?` hides that it did.
        defer {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                _ = chflags(dir.appendingPathComponent(name).path, 0)
            }
            _ = chflags(dir.path, 0)
            try? fm.removeItem(at: dir)
        }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 2)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        let before = try XCTUnwrap(StoreRepair.spaceCount(at: storeURL), "precondition: live store is readable")
        XCTAssertEqual(before, 2)

        StoreRepair.snapshot(at: storeURL, stamp: "1700002000-1.0.0")
        let snapshotName = "store.sqlite.snapshot-1700002000-1.0.0.bak"
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(snapshotName).path),
            "precondition: the snapshot to restore from must exist"
        )

        // Lock the live main file so the apply step's own removeItem fails.
        XCTAssertEqual(
            chflags(storeURL.path, UInt32(UF_IMMUTABLE)), 0,
            "precondition: chflags uchg must succeed on this filesystem, or this test cannot exercise the bug"
        )
        defer { _ = chflags(storeURL.path, 0) }

        defaults.set(snapshotName, forKey: StoreRepair.pendingRestoreKey)
        let result = StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults)

        XCTAssertFalse(
            result,
            "a removeItem failure during apply must be reported as failure, not masked by a stale-but-readable store"
        )
        XCTAssertNil(defaults.string(forKey: StoreRepair.pendingRestoreKey), "the key must still be cleared")
        // Reading (unlike removing or writing) is unaffected by `uchg`, so this
        // is safe to check before the flag is cleared by the `defer` above.
        XCTAssertEqual(
            StoreRepair.spaceCount(at: storeURL), before,
            "the store must still hold its original content -- the apply must not have silently done nothing while reporting success"
        )
    }

    /// A live store that will not open is one of the main situations this picker
    /// exists to rescue, so a restore over one has to go through. The aside copy
    /// of an unreadable store is itself unreadable -- a faithful copy of a
    /// corrupt file is a corrupt file -- so gating the restore on the ASIDE
    /// being readable refused exactly the case the feature was built for. And it
    /// refused it on every launch forever, because the pending key is cleared
    /// before the file work: the user picks a backup, the app restarts, nothing
    /// happens, and there is nothing left to retry.
    func testApplyPendingRestoreWorksWhenTheLiveStoreCannotBeRead() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-unreadable-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 3)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        StoreRepair.snapshot(at: storeURL, stamp: "1700003000-1.0.0")
        let snapshotName = "store.sqlite.snapshot-1700003000-1.0.0.bak"
        XCTAssertEqual(
            StoreInventory.readContent(at: dir.appendingPathComponent(snapshotName))?.spaces, 3,
            "precondition: the chosen backup must be readable and hold the data"
        )

        // Now make the live store unopenable, which is what the user reaches for
        // the picker to escape.
        try "not a database".write(to: storeURL, atomically: true, encoding: .utf8)
        XCTAssertNil(
            StoreInventory.readContent(at: storeURL),
            "precondition: the live store must not be readable"
        )

        defaults.set(snapshotName, forKey: StoreRepair.pendingRestoreKey)
        XCTAssertTrue(
            StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults),
            "a restore over an unreadable live store must go through -- refusing it strands the user on the store they asked to escape"
        )
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 3, "the chosen backup must be in place")
        XCTAssertNil(defaults.string(forKey: StoreRepair.pendingRestoreKey), "the key must be cleared")

        // The unreadable store is still kept, byte for byte: a corrupt copy is
        // exactly the way back to what the user had, so it is worth keeping even
        // though nothing can read it.
        let asides = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("store.sqlite.prepick-") && $0.hasSuffix(".bak") }
        XCTAssertEqual(asides.count, 1, "the unreadable store must still have been set aside")
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent(asides[0]), encoding: .utf8),
            "not a database",
            "the aside must be a byte-for-byte copy of what was replaced"
        )
    }

    /// Review Finding 1's own case: the aside copy itself failing. No
    /// `FileManager` seam is needed to reach it -- a containing directory the
    /// process cannot write to blocks every copy into it while leaving the store
    /// perfectly readable (reads need only `r-x`). Nothing may touch the live
    /// store once the way back could not be written.
    ///
    /// Scope, measured rather than assumed: this is a scenario guard, not a
    /// test of the aside gate in isolation. An unwritable directory also stops
    /// the apply step's own copy, so the closing "did the result read?" gate
    /// reaches the same refusal on its own -- removing both aside checks leaves
    /// this test green. The discriminating case is
    /// `testApplyPendingRestoreRefusesWhenOnlyTheAsidesWALFailsToCopy` below,
    /// where the directory stays writable and only the aside is incomplete.
    func testApplyPendingRestoreRefusesWhenTheAsideCannotBeWritten() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-aside-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer {
            _ = chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // A 2-space backup and a 1-space live store, so a restore that wrongly
        // went ahead would be visible in the count afterward.
        try makePopulatedStore(at: storeURL, spaces: 2)
        StoreRepair.snapshot(at: storeURL, stamp: "1700004000-1.0.0")
        let snapshotName = "store.sqlite.snapshot-1700004000-1.0.0.bak"
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 1)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeURL.path + "-wal"),
            "precondition: no -wal sibling, so the store stays readable through a read-only directory"
        )
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 1, "precondition: live store thinned out")

        // Read and traverse, but not write: the aside copy cannot land.
        XCTAssertEqual(chmod(dir.path, 0o500), 0, "precondition: chmod must succeed on this filesystem")
        XCTAssertNotEqual(
            access(dir.path, W_OK), 0,
            "precondition: the directory must be unwritable, or this test cannot make the aside copy fail"
        )

        defaults.set(snapshotName, forKey: StoreRepair.pendingRestoreKey)
        XCTAssertFalse(
            StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults),
            "an aside copy that could not be written must stop the restore"
        )
        XCTAssertNil(defaults.string(forKey: StoreRepair.pendingRestoreKey), "the key must still be cleared")
        XCTAssertEqual(
            StoreRepair.spaceCount(at: storeURL), 1,
            "with no way back written, the live store must still hold exactly what it held"
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix("store.sqlite.prepick-") }
                .isEmpty,
            "nothing could be written, so no aside may be left claiming otherwise"
        )
    }

    /// The subtle half of Finding 1, and the reason the aside step must keep
    /// `copyTriple`'s result instead of only re-reading the aside afterward: a
    /// copy that fails on the `-wal` alone leaves an aside with no `-wal`
    /// sibling, and `openReadOnly` applies its `immutable=1` fallback precisely
    /// BECAUSE no `-wal` is there. So the aside reads fine while missing the
    /// committed-but-uncheckpointed rows the live `-wal` holds, a readability
    /// check waves it through, and the apply then deletes that `-wal` -- real
    /// data loss, of exactly the kind the finding was about.
    func testApplyPendingRestoreRefusesWhenOnlyTheAsidesWALFailsToCopy() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-aside-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        defer {
            _ = chmod(walURL.path, 0o600)
            try? FileManager.default.removeItem(at: dir)
        }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 2)
        StoreRepair.snapshot(at: storeURL, stamp: "1700005000-1.0.0")
        let snapshotName = "store.sqlite.snapshot-1700005000-1.0.0.bak"
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 1)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }

        // Stand in for the partial `ENOSPC`: a `-wal` beside the live store that
        // the copy will attempt and fail on, while the main file copies fine.
        try "rows only this -wal knows about".write(to: walURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(walURL.path, 0o000), 0, "precondition: chmod must succeed on this filesystem")
        XCTAssertNotEqual(
            access(walURL.path, R_OK), 0,
            "precondition: the -wal must be unreadable, or its copy cannot be made to fail"
        )
        let liveBytesBefore = try Data(contentsOf: storeURL)

        defaults.set(snapshotName, forKey: StoreRepair.pendingRestoreKey)
        XCTAssertFalse(
            StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults),
            "an aside missing a suffix that failed to copy is not a way back, so the restore must stop"
        )
        XCTAssertNil(defaults.string(forKey: StoreRepair.pendingRestoreKey), "the key must still be cleared")
        XCTAssertEqual(
            try Data(contentsOf: storeURL), liveBytesBefore,
            "the live store must be untouched, byte for byte"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: walURL.path),
            "the live -wal must survive: its committed rows were never captured by the aside"
        )

        // The half-written aside reads fine, which is the whole point: a
        // readability check on it cannot catch this, only the copy's own result.
        let asides = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("store.sqlite.prepick-") && $0.hasSuffix(".bak") }
        XCTAssertEqual(asides.count, 1, "the main file did copy, so one aside primary exists")
        let asideURL = dir.appendingPathComponent(asides[0])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: asideURL.path + "-wal"),
            "the -wal copy is the one that failed, so the aside has no -wal sibling"
        )
        XCTAssertNotNil(
            StoreInventory.readContent(at: asideURL),
            "the incomplete aside still READS -- pinning why readability is the wrong predicate here"
        )
    }

    /// End to end through AppState's own helpers: a store thinned out below its
    /// record, with a fuller backup present, must produce an offer whose
    /// preselected candidate is that backup.
    func testEvaluateStoreRecoveryOffersTheFullestBackup() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-evaluate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePopulatedStore(at: storeURL, spaces: 4)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.5.11+20")
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")

        let live = StoreInventory.readContent(at: storeURL)
        let candidates = StoreInventory.candidates(for: storeURL, liveContent: live)
        let best = StoreInventory.best(among: candidates)
        let record = StoreContent(spaces: 4, services: 0, links: 0, spaceNames: [], serviceLabels: [])

        XCTAssertEqual(
            StoreInventory.offer(liveContent: live, best: best, record: record, declinedKeys: []),
            .belowRecord
        )
        XCTAssertEqual(
            StoreInventory.preselection(among: candidates, liveContent: live)?.content?.spaces,
            4,
            "the 4-space snapshot must be preselected over an emptied live store"
        )
    }

    /// Pins the five independent guards `recordStoreContent` relies on, without
    /// standing up a live `AppState` (the suite deliberately never constructs
    /// one). A store that lost all its spaces but kept its services is the
    /// partial-loss shape that matters most here: it is not `isEmpty`, so only
    /// the offer-outstanding and restore-scheduled guards stop it from being
    /// recorded over while an offer (or an already-accepted pick) about that
    /// very loss is still live.
    func testShouldRecordContentGuardsNilEmptyFallbackOutstandingOfferAndScheduledRestore() {
        let partialLoss = StoreContent(spaces: 0, services: 5, links: 5, spaceNames: [], serviceLabels: [])
        let empty = StoreContent(spaces: 0, services: 0, links: 0, spaceNames: [], serviceLabels: [])

        XCTAssertFalse(
            AppState.shouldRecordContent(nil, offerOutstanding: false, isInMemoryFallback: false, restoreScheduled: false),
            "unreadable (nil) content is unknown, never recorded as if it were empty"
        )
        XCTAssertFalse(
            AppState.shouldRecordContent(empty, offerOutstanding: false, isInMemoryFallback: false, restoreScheduled: false),
            "an empty store must never overwrite the record"
        )
        XCTAssertFalse(
            AppState.shouldRecordContent(partialLoss, offerOutstanding: true, isInMemoryFallback: false, restoreScheduled: false),
            "a partial-loss store with an offer still outstanding must not be recorded over"
        )
        XCTAssertTrue(
            AppState.shouldRecordContent(partialLoss, offerOutstanding: false, isInMemoryFallback: false, restoreScheduled: false),
            "the same partial-loss store, once no offer is outstanding (including right after a decline), must record normally"
        )
        XCTAssertFalse(
            AppState.shouldRecordContent(partialLoss, offerOutstanding: false, isInMemoryFallback: true, restoreScheduled: false),
            "the in-memory-fallback container is a throwaway; its content must never be recorded"
        )
        XCTAssertFalse(
            AppState.shouldRecordContent(partialLoss, offerOutstanding: false, isInMemoryFallback: false, restoreScheduled: true),
            "review Finding 3: a restore waiting to apply at the next launch must not have the store's about-to-change shape recorded over the evidence of loss"
        )
    }

    /// The filename a choice writes must be one the launch path will accept.
    /// This is the seam between the picker and `applyPendingRestore`, and a
    /// mismatch here would silently do nothing on the next launch.
    func testChosenCandidateNameSurvivesValidation() {
        let storeURL = URL(fileURLWithPath: "/tmp/whatever/default.store")
        let cases: [(name: String, kind: StoreCandidate.Kind)] = [
            ("default.store.snapshot-1700000000-1.5.11+20.bak", .snapshot(version: "1.5.11+20")),
            ("default.store.prerestore-1700000500.bak", .prerestore),
            ("default.store.corrupt-1700000600.bak", .corrupt),
            ("default.store.prepick-1700000700.bak", .prepick),
        ]
        for (name, kind) in cases {
            let candidate = StoreCandidate(
                url: storeURL.deletingLastPathComponent().appendingPathComponent(name),
                kind: kind,
                takenAt: nil,
                content: StoreContent(spaces: 1, services: 1, links: 1, spaceNames: [], serviceLabels: []),
                isDamaged: false
            )
            XCTAssertEqual(
                StoreRepair.validatedRestoreName(candidate.url.lastPathComponent, storeName: storeURL.lastPathComponent),
                name,
                "a candidate the picker can show must be one the launch path accepts"
            )
            XCTAssertTrue(
                candidate.isRestorable,
                "every candidate this test claims the picker can show must actually be restorable"
            )
        }
    }

    /// A quit requested while a sheet is attached is refused by AppKit and
    /// dropped, not deferred. The picker hit this for real: it quit from inside
    /// its own sheet, so the app stayed running, the relaunch poller expired,
    /// and the restore only landed when the user next opened Chorus by hand.
    /// The rule below is what keeps the quit waiting for the sheet to go.
    func testWaitsForAnAttachedSheetBeforeQuitting() {
        XCTAssertTrue(
            AppRelauncher.shouldWaitForSheet(sheetAttached: true, attempt: 0),
            "a quit through an attached sheet is dropped, so it has to wait"
        )
        XCTAssertTrue(AppRelauncher.shouldWaitForSheet(sheetAttached: true, attempt: 1))
    }

    /// Nothing in the way means quit now: waiting on every restart would add a
    /// delay to the one path this feature exists for.
    func testQuitsImmediatelyWithNoSheetAttached() {
        XCTAssertFalse(AppRelauncher.shouldWaitForSheet(sheetAttached: false, attempt: 0))
        XCTAssertFalse(
            AppRelauncher.shouldWaitForSheet(sheetAttached: false, attempt: 99),
            "no sheet is no sheet, whatever the attempt count"
        )
    }

    /// The wait is bounded. A sheet that never closes must not strand a restore
    /// the user already picked and that is already written to disk; past the
    /// bound Chorus quits anyway and lets AppKit decide.
    func testStopsWaitingForASheetThatNeverCloses() {
        XCTAssertFalse(
            AppRelauncher.shouldWaitForSheet(sheetAttached: true, attempt: 1_000),
            "an unbounded wait would leave the app up with a restore pending"
        )
    }

    /// `scheduleRestore` is the guards-plus-write half of `chooseStoreRestore`,
    /// hoisted out to a `nonisolated static` so it's testable without building
    /// an `AppState` (the suite deliberately never does). A restorable
    /// candidate whose filename belongs to this store must write exactly the
    /// name the launch path (`StoreRepair.applyPendingRestore`) will look for.
    func testScheduleRestoreWritesValidNameForRestorableCandidate() {
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storeURL = URL(fileURLWithPath: "/tmp/whatever/default.store")
        let name = "default.store.snapshot-1700000000-1.5.11+20.bak"
        let candidate = StoreCandidate(
            url: storeURL.deletingLastPathComponent().appendingPathComponent(name),
            kind: .snapshot(version: "1.5.11+20"),
            takenAt: nil,
            content: StoreContent(spaces: 2, services: 3, links: 3, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )

        XCTAssertTrue(AppState.scheduleRestore(candidate, storeName: storeURL.lastPathComponent, defaults: defaults))
        XCTAssertEqual(
            defaults.string(forKey: StoreRepair.pendingRestoreKey),
            name,
            "the written key must be exactly what applyPendingRestore validates against"
        )
    }

    /// A non-restorable candidate (here: damaged) must write nothing at all —
    /// not merely return false. A partial write that later gets overwritten by
    /// coincidence would hide this bug, so the key's absence is asserted
    /// directly rather than inferred from the return value.
    func testScheduleRestoreWritesNothingForNonRestorableCandidate() {
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storeURL = URL(fileURLWithPath: "/tmp/whatever/default.store")
        let name = "default.store.corrupt-1700000600.bak"
        let damagedCandidate = StoreCandidate(
            url: storeURL.deletingLastPathComponent().appendingPathComponent(name),
            kind: .corrupt,
            takenAt: nil,
            content: StoreContent(spaces: 1, services: 1, links: 1, spaceNames: [], serviceLabels: []),
            isDamaged: true
        )

        XCTAssertFalse(AppState.scheduleRestore(damagedCandidate, storeName: storeURL.lastPathComponent, defaults: defaults))
        XCTAssertNil(
            defaults.string(forKey: StoreRepair.pendingRestoreKey),
            "a damaged candidate must not schedule a restore"
        )
    }

    /// A candidate whose filename `validatedRestoreName` rejects (wrong store
    /// prefix here) must also write nothing, even though `isRestorable` itself
    /// only looks at damage/content/liveness and would pass it.
    func testScheduleRestoreWritesNothingForFilenameValidationFailure() {
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storeURL = URL(fileURLWithPath: "/tmp/whatever/default.store")
        let wrongStoreName = "other.store.snapshot-1700000000-1.5.11+20.bak"
        let candidate = StoreCandidate(
            url: storeURL.deletingLastPathComponent().appendingPathComponent(wrongStoreName),
            kind: .snapshot(version: "1.5.11+20"),
            takenAt: nil,
            content: StoreContent(spaces: 2, services: 3, links: 3, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )

        XCTAssertFalse(AppState.scheduleRestore(candidate, storeName: storeURL.lastPathComponent, defaults: defaults))
        XCTAssertNil(
            defaults.string(forKey: StoreRepair.pendingRestoreKey),
            "a filename that doesn't belong to this store must not schedule a restore"
        )
    }

    // MARK: - Picker row labels (StoreCandidate.displayTitle / displayDetail)

    private static let labelDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func labelCandidate(
        kind: StoreCandidate.Kind,
        takenAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        content: StoreContent?,
        isDamaged: Bool = false
    ) -> StoreCandidate {
        StoreCandidate(
            url: URL(fileURLWithPath: "/tmp/labels/default.store"),
            kind: kind,
            takenAt: takenAt,
            content: content,
            isDamaged: isDamaged
        )
    }

    /// `displayTitle` is exhaustive over every `Kind`, including both shapes of
    /// `.snapshot` (a parsed version, and a name that didn't parse one).
    func testDisplayTitleCoversEveryKind() {
        let some = StoreContent(spaces: 1, services: 1, links: 1, spaceNames: [], serviceLabels: [])
        XCTAssertEqual(labelCandidate(kind: .live, content: some).displayTitle, "Your data now")
        XCTAssertEqual(labelCandidate(kind: .snapshot(version: "1.5.11+20"), content: some).displayTitle, "Backup from before 1.5.11+20")
        XCTAssertEqual(labelCandidate(kind: .snapshot(version: nil), content: some).displayTitle, "Backup from before an update")
        XCTAssertEqual(labelCandidate(kind: .prerestore, content: some).displayTitle, "Backup from an earlier restore")
        XCTAssertEqual(labelCandidate(kind: .corrupt, content: some).displayTitle, "Backup from before a repair")
        XCTAssertEqual(labelCandidate(kind: .prepick, content: some).displayTitle, "Your data before you restored a backup")
    }

    /// A backup's detail line pluralizes spaces/services independently and
    /// leads with the filename-parsed date.
    func testDisplayDetailPluralizesCountsAndLeadsWithDate() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let when = Self.labelDateFormatter.string(from: stamp)

        let singular = labelCandidate(
            kind: .snapshot(version: "1.5.11+20"),
            takenAt: stamp,
            content: StoreContent(spaces: 1, services: 1, links: 1, spaceNames: [], serviceLabels: [])
        )
        XCTAssertEqual(singular.displayDetail, "\(when) — 1 space, 1 service")

        let plural = labelCandidate(
            kind: .snapshot(version: "1.5.11+20"),
            takenAt: stamp,
            content: StoreContent(spaces: 3, services: 4, links: 4, spaceNames: [], serviceLabels: [])
        )
        XCTAssertEqual(plural.displayDetail, "\(when) — 3 spaces, 4 services")
    }

    /// A backup with no parseable stamp reads "date unknown" rather than
    /// omitting the date clause outright.
    func testDisplayDetailUnknownDateFallsBackToDateUnknown() {
        let candidate = labelCandidate(
            kind: .prerestore,
            takenAt: nil,
            content: StoreContent(spaces: 2, services: 5, links: 5, spaceNames: [], serviceLabels: [])
        )
        XCTAssertEqual(candidate.displayDetail, "date unknown — 2 spaces, 5 services")
    }

    /// Review Finding 5: a backup that is empty but readable — all-zero
    /// content — is still restorable, so its detail line must say exactly what
    /// it holds, not something that reads like "can't be read". This string is
    /// the only thing telling a user they are about to restore over good data
    /// with literally nothing, and it also pins the empty-vs-unreadable
    /// distinction: this must never collapse into the nil-content case above.
    func testDisplayDetailZeroContentBackupReadsZeroSpacesZeroServices() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let when = Self.labelDateFormatter.string(from: stamp)
        let candidate = labelCandidate(
            kind: .snapshot(version: "1.5.11+20"),
            takenAt: stamp,
            content: StoreContent(spaces: 0, services: 0, links: 0, spaceNames: [], serviceLabels: [])
        )
        XCTAssertEqual(candidate.displayDetail, "\(when) — 0 spaces, 0 services")
    }

    /// An unreadable backup (`content == nil`, which the real candidate
    /// builder always pairs with `isDamaged == true`) reads "can't be read"
    /// with no separate damaged marker appended — the marker only applies
    /// when there IS a count to attach it to, so the two can never double up.
    func testDisplayDetailNilContentReadsCantBeReadWithoutDoubledDamagedMarker() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let when = Self.labelDateFormatter.string(from: stamp)
        let candidate = labelCandidate(kind: .corrupt, takenAt: stamp, content: nil, isDamaged: true)
        XCTAssertEqual(candidate.displayDetail, "\(when) — can't be read")
    }

    /// A damaged file that could still be read gets the marker exactly once,
    /// after the counts.
    func testDisplayDetailDamagedButReadableAddsMarkerOnce() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let when = Self.labelDateFormatter.string(from: stamp)
        let candidate = labelCandidate(
            kind: .snapshot(version: nil),
            takenAt: stamp,
            content: StoreContent(spaces: 1, services: 2, links: 2, spaceNames: [], serviceLabels: []),
            isDamaged: true
        )
        XCTAssertEqual(candidate.displayDetail, "\(when) — 1 space, 2 services — damaged")
    }

    /// Review Finding 4: the live row's `takenAt` is the store file's mtime,
    /// not a real snapshot stamp, and under WAL journaling that can trail the
    /// store's actual last write — showing it invites restoring the wrong
    /// copy. The live row must omit the date and show counts only, with or
    /// without a readable `content`.
    func testDisplayDetailLiveRowOmitsDateRegardlessOfContent() {
        let withContent = labelCandidate(
            kind: .live,
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            content: StoreContent(spaces: 3, services: 10, links: 10, spaceNames: [], serviceLabels: [])
        )
        XCTAssertEqual(withContent.displayDetail, "3 spaces, 10 services")

        let unreadable = labelCandidate(
            kind: .live,
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            content: nil
        )
        XCTAssertEqual(unreadable.displayDetail, "can't be read")
    }

    // MARK: - Moving the store out of the shared default path

    /// A scratch pair of folders standing in for `Application Support` and the
    /// `Chorus` folder inside it.
    private func makeRelocationDirs(_ label: String) throws -> (support: URL, legacy: URL, scoped: URL) {
        let support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return (
            support,
            support.appendingPathComponent("default.store"),
            support.appendingPathComponent("Chorus").appendingPathComponent("default.store")
        )
    }

    /// Stands in for the store another app leaves at the shared path. Modelled
    /// on the real thing: Bartender 6's store has one entity, `WidgetSettings`,
    /// and none of Chorus's tables.
    private static func makeForeignStore(at url: URL) throws {
        _ = try runSQLite(url, """
            CREATE TABLE ZWIDGETSETTINGS (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZTITLE VARCHAR);
            """)
    }

    /// The ordinary upgrade: Chorus's own store and its backups move into the
    /// app's folder, and the old path is left clean.
    func testRelocationMovesOurStoreAndItsBackupsIntoTheAppsFolder() throws {
        let (support, legacy, scoped) = try makeRelocationDirs("relocate-ours")
        defer { try? FileManager.default.removeItem(at: support) }

        try makePopulatedStore(at: legacy, spaces: 3)
        StoreRepair.snapshot(at: legacy, stamp: "1700000000-1.0.0")

        XCTAssertEqual(StoreRelocation.resolveStoreURL(legacy: legacy, scoped: scoped), scoped)
        XCTAssertEqual(StoreRepair.spaceCount(at: scoped), 3, "the store's data must arrive intact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "the old store must not be left behind")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scoped.path + ".snapshot-1700000000-1.0.0.bak"),
            "backups must follow the store, or the recovery picker loses sight of them"
        )
        XCTAssertNotNil(
            StoreRepair.newestRestorableSnapshot(for: scoped),
            "the moved snapshot must still be found from the new path"
        )
    }

    /// The state this whole change exists to survive: another app's store is
    /// sitting at the shared path. It must be left exactly where it is —
    /// moving or migrating it would destroy that app's data the same way it
    /// destroyed Chorus's — while Chorus's own backups still come along.
    func testRelocationLeavesAnotherAppsStoreAloneAndTakesOnlyTheBackups() throws {
        let (support, legacy, scoped) = try makeRelocationDirs("relocate-foreign")
        defer { try? FileManager.default.removeItem(at: support) }

        // Build a Chorus store, snapshot it, then replace the live file with a
        // foreign one — precisely what the collision leaves on disk.
        try makePopulatedStore(at: legacy, spaces: 4)
        StoreRepair.snapshot(at: legacy, stamp: "1700000000-1.0.0")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: legacy.path + suffix))
        }
        try Self.makeForeignStore(at: legacy)

        XCTAssertEqual(StoreRelocation.resolveStoreURL(legacy: legacy, scoped: scoped), scoped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "the other app's store must be left in place")
        XCTAssertEqual(
            try Self.runSQLite(legacy, "SELECT count(*) FROM sqlite_master WHERE name = 'ZWIDGETSETTINGS';")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "1",
            "the other app's schema must be untouched"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: scoped.path), "a foreign store must not be adopted as ours")
        XCTAssertNotNil(
            StoreRepair.newestRestorableSnapshot(for: scoped),
            "Chorus's own backups must still move, since they are the only way back"
        )
    }

    /// End-to-end proof that the collision is recoverable: relocate past a
    /// foreign store, then open. The user has had data, there is no live store
    /// at the new path, and the snapshot that moved with it must be restored
    /// rather than seeded over.
    func testRelocatingPastAForeignStoreThenOpeningRestoresTheUsersData() throws {
        let (support, legacy, scoped) = try makeRelocationDirs("relocate-recover")
        defer { try? FileManager.default.removeItem(at: support) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: legacy, spaces: 4)
        StoreRepair.snapshot(at: legacy, stamp: "1700000000-1.0.0")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: legacy.path + suffix))
        }
        try Self.makeForeignStore(at: legacy)
        defaults.set(true, forKey: AppState.hasEverHadDataKey)

        let url = StoreRelocation.resolveStoreURL(legacy: legacy, scoped: scoped)
        let config = ModelConfiguration(schema: Self.storeSchema, url: url)
        let (container, outcome) = AppState.loadContainer(schema: Self.storeSchema, config: config, defaults: defaults)

        guard case .restoredFromSnapshot = outcome else {
            return XCTFail("expected .restoredFromSnapshot, got \(outcome)")
        }
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<Space>()), 4,
            "the spaces the other app wiped must come back from the snapshot"
        )
    }

    /// Once moved, the old path is never read again. An older build of Chorus
    /// run in between could leave a store there, and importing it would
    /// overwrite newer data with older.
    func testRelocationIgnoresTheOldPathOnceTheAppsFolderHasAStore() throws {
        let (support, legacy, scoped) = try makeRelocationDirs("relocate-idempotent")
        defer { try? FileManager.default.removeItem(at: support) }

        try FileManager.default.createDirectory(at: scoped.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePopulatedStore(at: scoped, spaces: 1)
        try makePopulatedStore(at: legacy, spaces: 9)

        XCTAssertEqual(StoreRelocation.resolveStoreURL(legacy: legacy, scoped: scoped), scoped)
        XCTAssertEqual(StoreRepair.spaceCount(at: scoped), 1, "the store already in place must win")
        XCTAssertEqual(StoreRepair.spaceCount(at: legacy), 9, "and the old path must be left alone, not consumed")
    }

    // MARK: - Keeping chat services live outside the active space

    private func makeService(label: String, catalogID: String?) -> ServiceInstance {
        ServiceInstance(label: label, url: "https://example.com", catalogEntryID: catalogID)
    }

    /// A chat service the active-space preload doesn't cover must still be kept
    /// live — it is the only way it can post a notification banner. A non-chat
    /// service must not be, and one already covered must not be preloaded twice.
    func testChatServicesOutsideTheActiveSpaceAreKeptLive() {
        let slack = makeService(label: "Slack", catalogID: "slack")
        let coveredSlack = makeService(label: "Slack (this space)", catalogID: "slack")
        let reddit = makeService(label: "Reddit", catalogID: "reddit")
        let custom = makeService(label: "Custom chat", catalogID: nil)

        let chosen = AppState.criticalServicesToKeepLive(
            among: [slack, coveredSlack, reddit, custom],
            covered: [coveredSlack.id],
            limit: 5
        )
        XCTAssertEqual(chosen.map(\.id), [slack.id], "only the uncovered chat service is kept live")
    }

    /// The cap exists because these are exempt from eviction: without it a user
    /// with many chat services would pin every slot in the pool. It must also
    /// pick the SAME ones each launch, or a different set would be kept live
    /// every time the app started.
    func testKeepLiveSelectionIsCappedAndStable() {
        let services = (0..<12).map { makeService(label: "Slack \($0)", catalogID: "slack") }

        let first = AppState.criticalServicesToKeepLive(among: services, covered: [], limit: 5)
        XCTAssertEqual(first.count, 5, "the cap must bound how many are kept live")
        XCTAssertLessThan(
            AppState.maxCrossSpaceCriticalServices, 15,
            "the cap must stay below the pool's maxLoaded or the LRU sweep has nothing to reclaim"
        )

        let shuffled = AppState.criticalServicesToKeepLive(among: services.shuffled(), covered: [], limit: 5)
        XCTAssertEqual(first.map(\.id), shuffled.map(\.id), "the same services must win the cap regardless of fetch order")
    }

    // MARK: - Protecting a live service's cookies

    /// The tombstone list lives in UserDefaults and the services live in the
    /// store, so restoring a backup can bring back a service whose data store is
    /// still tombstoned from when it was deleted. Wiping it would log the user
    /// out of a service they can see. The stale tombstone must be dropped.
    func testTombstoneForALiveServiceIsDroppedNotHonoured() {
        let live = UUID()
        let genuinelyDeleted = UUID()

        let result = AppState.reconciledTombstones(
            tombstoned: [live, genuinelyDeleted],
            claimed: [live, UUID()]
        )
        XCTAssertEqual(result.dropped, [live], "a tombstone whose service exists again is wrong and must be dropped")
        XCTAssertEqual(result.keep, [genuinelyDeleted], "a real orphan must still be reclaimed")
    }

    /// An unreadable store yields no claims. Treating that as "nothing is
    /// claimed" would mark every store on disk as garbage and wipe every login
    /// the user has, so it must reclaim nothing at all.
    func testUnreferencedStoresReclaimsNothingWhenTheStoreCannotBeRead() {
        let onDisk: Set<UUID> = [UUID(), UUID(), UUID()]
        XCTAssertEqual(
            AppState.unreferencedDataStoreIdentifiers(onDisk: onDisk, claimed: []), [],
            "an empty claim set means unknown, never 'all of them are garbage'"
        )
    }

    /// The leak this closes: a store no service points at, left behind when a
    /// service row vanished without going through a delete.
    func testUnreferencedStoresFindsTheOnesNoServiceClaims() {
        let claimedA = UUID(), claimedB = UUID(), stranded = UUID()
        XCTAssertEqual(
            AppState.unreferencedDataStoreIdentifiers(
                onDisk: [claimedA, claimedB, stranded],
                claimed: [claimedA, claimedB]
            ),
            [stranded]
        )
    }

    func testWebsiteDataStoreDirectoryIsScopedToTheBundle() {
        let dir = AppState.websiteDataStoreDirectory(bundleID: "com.example.App")
        XCTAssertEqual(dir?.lastPathComponent, "WebsiteDataStore")
        XCTAssertEqual(dir?.deletingLastPathComponent().lastPathComponent, "com.example.App")
        XCTAssertNil(AppState.websiteDataStoreDirectory(bundleID: nil))
        XCTAssertNil(AppState.websiteDataStoreDirectory(bundleID: ""))
    }

    /// The signal that gates both destructive reclaim paths. It has to be read
    /// from the raw file before the open path repairs the damage away.
    func testHasDanglingLinksSeesDamageAndClearsAfterRepair() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-damaged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePopulatedStore(at: storeURL, spaces: 2)
        XCTAssertFalse(StoreRepair.hasDanglingLinks(at: storeURL), "a healthy store is not damaged")

        // A link pointing at a space that isn't there — what a lost Space row
        // leaves behind.
        _ = try Self.runSQLite(storeURL, """
            INSERT INTO ZSPACESERVICELINK (Z_PK, Z_ENT, Z_OPT, ZSPACE, ZSERVICE, ZSORTORDER)
            VALUES (9001, 3, 1, 8888, 9999, 0);
            """)
        XCTAssertTrue(StoreRepair.hasDanglingLinks(at: storeURL), "a dangling link must be reported as damage")

        StoreRepair.repairDanglingLinks(at: storeURL)
        XCTAssertFalse(StoreRepair.hasDanglingLinks(at: storeURL), "and must read clean once repaired")
    }

    // MARK: - The notification interception script

    /// Pulls the injected notification script out of a configured controller.
    @MainActor
    private func notificationScriptSource() throws -> String {
        let manager = UserScriptManager()
        let controller = WKUserContentController()
        manager.installUserScripts(
            for: makeService(label: "Slack", catalogID: "slack"),
            customCSS: nil,
            darkInjection: .none,
            stayActiveInBackground: false,
            on: controller
        )
        return try XCTUnwrap(
            controller.userScripts.map(\.source).first { $0.contains("chorusNotification") },
            "no notification interception script was installed"
        )
    }

    /// The shim replaces `window.Notification`, so it has to keep the API it
    /// replaced: instances must still satisfy `instanceof`, and the statics the
    /// original carried must survive. The first version dropped both.
    func testNotificationShimKeepsPrototypeAndStatics() throws {
        let context = try XCTUnwrap(JSContext(), "Could not create a JSContext")
        var posted: [String] = []
        let record: @convention(block) (String) -> Void = { posted.append($0) }

        context.evaluateScript("var window = this; var posted = [];")
        context.setObject(record, forKeyedSubscript: "chorusPost" as NSString)
        context.evaluateScript("""
            window.webkit = { messageHandlers: { chorusNotification: { postMessage: function(m) { chorusPost(m); } } } };
            function Notification(title, options) { this.title = title; }
            Notification.prototype.close = function() { this.closed = true; };
            Notification.maxActions = 2;
            Notification.permission = 'default';
            window.Notification = Notification;
            """)

        context.evaluateScript(try notificationScriptSource())

        XCTAssertEqual(
            context.evaluateScript("(new window.Notification('hi', {body: 'b'})) instanceof window.Notification")?.toBool(),
            true,
            "instanceof must still hold — a site that feature-detects this way breaks otherwise"
        )
        XCTAssertEqual(
            context.evaluateScript("typeof (new window.Notification('hi')).close")?.toString(), "function",
            "the prototype's methods must still be reachable"
        )
        XCTAssertEqual(
            context.evaluateScript("window.Notification.maxActions")?.toInt32(), 2,
            "statics the original carried must be copied across"
        )
        XCTAssertEqual(
            context.evaluateScript("window.Notification.permission")?.toString(), "granted",
            "and Chorus's own overrides must win over the copied ones"
        )
        XCTAssertEqual(posted.count, 2, "each constructed notification is forwarded once")
        XCTAssertTrue(posted[0].contains("\"body\":\"b\""), "the payload must carry the body")
    }

    /// The path that was not covered at all. Web apps raise notifications
    /// through the service worker registration rather than the constructor, so
    /// without this they never reached Chorus.
    func testNotificationShimForwardsServiceWorkerNotifications() throws {
        let context = try XCTUnwrap(JSContext(), "Could not create a JSContext")
        var posted: [String] = []
        let record: @convention(block) (String) -> Void = { posted.append($0) }

        context.evaluateScript("var window = this;")
        context.setObject(record, forKeyedSubscript: "chorusPost" as NSString)
        context.evaluateScript("""
            window.webkit = { messageHandlers: { chorusNotification: { postMessage: function(m) { chorusPost(m); } } } };
            var showCalls = 0;
            function ServiceWorkerRegistration() {}
            ServiceWorkerRegistration.prototype.showNotification = function(t, o) { showCalls++; return 'orig'; };
            window.ServiceWorkerRegistration = ServiceWorkerRegistration;
            """)

        context.evaluateScript(try notificationScriptSource())

        let returned = context.evaluateScript("""
            (new ServiceWorkerRegistration()).showNotification('Nico', {body: 'sent a message'});
            """)?.toString()
        XCTAssertEqual(returned, "orig", "the original call must still run and its result be passed through")
        XCTAssertEqual(context.evaluateScript("showCalls")?.toInt32(), 1, "exactly once — not swallowed, not doubled")
        XCTAssertEqual(posted.count, 1, "and the notification must reach Chorus")
        XCTAssertTrue(posted[0].contains("\"title\":\"Nico\""))
    }

    /// A page that has torn the bridge down must not take the site's own
    /// notification call with it.
    func testNotificationShimSurvivesAMissingBridge() throws {
        let context = try XCTUnwrap(JSContext(), "Could not create a JSContext")
        context.evaluateScript("""
            var window = this;
            window.webkit = undefined;
            function Notification(title) { this.title = title; }
            window.Notification = Notification;
            """)
        context.evaluateScript(try notificationScriptSource())

        XCTAssertEqual(
            context.evaluateScript("(new window.Notification('hi')).title")?.toString(), "hi",
            "the original constructor must still run when the bridge is gone"
        )
        XCTAssertNil(context.exception, "and no exception must escape into the page")
    }

    /// A fresh install has nothing at either path, and must simply open in the
    /// app's folder without any of the move machinery running.
    func testRelocationOnAFreshInstallOpensInTheAppsFolder() throws {
        let (support, legacy, scoped) = try makeRelocationDirs("relocate-fresh")
        defer { try? FileManager.default.removeItem(at: support) }

        XCTAssertEqual(StoreRelocation.resolveStoreURL(legacy: legacy, scoped: scoped), scoped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scoped.path), "nothing is created until the container opens")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scoped.deletingLastPathComponent().path),
            "the folder itself must exist so the container can be created in it"
        )
    }

}
