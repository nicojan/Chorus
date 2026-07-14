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

    func testHibernatedBadgeExtraction() {
        XCTAssertEqual(HibernatedBadgePoller.extractBadgeFromTitle(html: "<title>(3) Slack</title>"), 3)
        XCTAssertEqual(HibernatedBadgePoller.extractBadgeFromTitle(html: "<title>Gmail</title>"), 0)
        XCTAssertEqual(HibernatedBadgePoller.extractBadgeFromTitle(html: "<title>Inbox (42) - Gmail</title>"), 42)
        XCTAssertEqual(HibernatedBadgePoller.extractBadgeFromTitle(html: "no title tag"), 0)
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

    func testErrorPageWithoutRetryURLHasNoButton() {
        let html = WebViewCoordinator.errorPageHTML(
            title: "Page unavailable", message: "Keeps crashing.", retryURLString: nil)
        XCTAssertFalse(html.contains("<button"))
    }

    // MARK: - Cookie matching (hibernated poller)

    private func makeCookie(domain: String, path: String, name: String = "s", secure: Bool = false) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .path: path, .name: name, .value: "v",
        ]
        if secure { props[.secure] = "TRUE" }
        return HTTPCookie(properties: props)!
    }

    func testCookiePathMatchFollowsRFC6265() {
        let cookie = makeCookie(domain: "example.com", path: "/foo")
        // Exact, trailing-slash, and sub-path match.
        XCTAssertEqual(HibernatedBadgePoller.cookies([cookie], matching: URL(string: "https://example.com/foo")!).count, 1)
        XCTAssertEqual(HibernatedBadgePoller.cookies([cookie], matching: URL(string: "https://example.com/foo/bar")!).count, 1)
        // A path that merely shares the prefix but isn't a sub-path must NOT match.
        XCTAssertEqual(HibernatedBadgePoller.cookies([cookie], matching: URL(string: "https://example.com/foobar")!).count, 0)
    }

    func testCookieDomainAndSecureMatching() {
        let dotCookie = makeCookie(domain: ".example.com", path: "/")
        // Subdomain matches a dot-prefixed domain cookie.
        XCTAssertEqual(HibernatedBadgePoller.cookies([dotCookie], matching: URL(string: "https://mail.example.com/")!).count, 1)
        // Unrelated host doesn't.
        XCTAssertEqual(HibernatedBadgePoller.cookies([dotCookie], matching: URL(string: "https://notexample.com/")!).count, 0)

        // Secure cookies are withheld from http requests.
        let secure = makeCookie(domain: "example.com", path: "/", secure: true)
        XCTAssertEqual(HibernatedBadgePoller.cookies([secure], matching: URL(string: "http://example.com/")!).count, 0)
        XCTAssertEqual(HibernatedBadgePoller.cookies([secure], matching: URL(string: "https://example.com/")!).count, 1)
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
        func inj(_ m: ServiceDarkMode, _ auto: Bool, _ dark: Bool, _ detected: Bool?, _ native: Bool = false) -> I {
            DarkReaderSupport.injection(mode: m, globalAuto: auto, appDark: dark, detectedLacksDark: detected, nativeDark: native)
        }
        // App light → never themes, whatever the mode.
        XCTAssertEqual(inj(.on, true, false, true), I.none)
        // Explicit On themes even with the global toggle off; Off never themes.
        XCTAssertEqual(inj(.on, false, true, nil), I.themed)
        XCTAssertEqual(inj(.off, true, true, true), I.none)
        // Auto needs the global toggle on.
        XCTAssertEqual(inj(.auto, false, true, true), I.none)
        // Auto + global: no verdict → probe; lacks-dark → themed; has-dark → none.
        XCTAssertEqual(inj(.auto, true, true, nil), I.probe)
        XCTAssertEqual(inj(.auto, true, true, true), I.themed)
        XCTAssertEqual(inj(.auto, true, true, false), I.none)
    }

    func testDarkInjectionNativeDarkService() {
        typealias I = DarkReaderSupport.DarkInjection
        func inj(_ m: ServiceDarkMode, _ auto: Bool, _ dark: Bool, _ detected: Bool?, _ native: Bool) -> I {
            DarkReaderSupport.injection(mode: m, globalAuto: auto, appDark: dark, detectedLacksDark: detected, nativeDark: native)
        }
        // A native-dark service in Auto never themes and never even probes — its
        // own dark theme is trusted, so Dark Reader stays out of the way. This
        // holds regardless of any stale detection verdict.
        XCTAssertEqual(inj(.auto, true, true, nil, true), I.none)
        XCTAssertEqual(inj(.auto, true, true, true, true), I.none)
        XCTAssertEqual(inj(.auto, true, true, false, true), I.none)
        // The user's explicit On still wins over the native-dark flag.
        XCTAssertEqual(inj(.on, true, true, nil, true), I.themed)
        // With the flag off, Auto behaves exactly as before (regression guard).
        XCTAssertEqual(inj(.auto, true, true, nil, false), I.probe)
    }

    func testCatalogMarksNativeDarkServices() {
        let catalog = ServiceCatalog.shared
        // Sample of the researched always-dark / follows-system services.
        for id in ["discord", "spotify", "youtube-music", "linear", "icloud-mail",
                   "github", "jira", "confluence", "gitlab", "chatgpt", "claude"] {
            XCTAssertEqual(catalog.entry(for: id)?.nativeDark, true, "\(id) should be marked nativeDark")
        }
        // Services that need Dark Reader (no native dark, or manual-only) must not be marked.
        for id in ["gmail", "slack", "notion", "hackernews", "zoom", "reddit"] {
            XCTAssertNotEqual(catalog.entry(for: id)?.nativeDark, true, "\(id) should not be nativeDark")
        }
    }

    func testDarkProbeScriptPollsUntilSettled() {
        let js = UserScriptManager.makeDarkProbeScript(serviceID: "abc")
        // The hardened probe samples repeatedly (not a single fixed timeout) so a
        // slow SPA that paints its dark theme late isn't misread as a light page.
        XCTAssertTrue(js.contains("chorusDarkProbe"))
        XCTAssertTrue(js.contains("relativeLuminance") || js.contains("luminance"))
        XCTAssertTrue(js.contains("attempts") || js.contains("schedule"))
    }

    func testClassifyLacksDark() {
        XCTAssertTrue(DarkReaderSupport.classifyLacksDark(r: 255, g: 255, b: 255, a: 1))   // white → light
        XCTAssertFalse(DarkReaderSupport.classifyLacksDark(r: 26, g: 26, b: 26, a: 1))     // #1a1a1a → dark
        XCTAssertTrue(DarkReaderSupport.classifyLacksDark(r: 0, g: 0, b: 0, a: 0))         // transparent → light
    }

    func testDarkModeMigrationFromLegacyFlag() {
        // Explicit mode wins.
        XCTAssertEqual(ServiceInstance(label: "x", url: "https://e.com", darkModeRaw: "off").darkMode, .off)
        // Legacy force-dark maps to On.
        XCTAssertEqual(ServiceInstance(label: "x", url: "https://e.com", forceDarkMode: true).darkMode, .on)
        // Nothing set defaults to Auto.
        XCTAssertEqual(ServiceInstance(label: "x", url: "https://e.com").darkMode, .auto)
    }

    func testAutoDarkModeDefaultsFalse() {
        XCTAssertFalse(AppPreferences().autoDarkModeEnabledEffective)
        XCTAssertTrue(AppPreferences(autoDarkModeEnabled: true).autoDarkModeEnabledEffective)
    }

    func testAnnoyanceBlockingDefaultsFalse() {
        XCTAssertFalse(AppPreferences().annoyanceBlockingEnabledEffective)
        XCTAssertTrue(AppPreferences(annoyanceBlockingEnabled: true).annoyanceBlockingEnabledEffective)
    }

    func testReaderModeLibraryLoads() {
        XCTAssertFalse(ReaderMode.libraryJS.isEmpty)
        XCTAssertTrue(ReaderMode.libraryJS.contains("Readability"))
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

}
