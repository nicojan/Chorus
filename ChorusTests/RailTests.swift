import XCTest
import SwiftData
@testable import Chorus

/// Global services and dividers: the ordering rules, the store edits, the
/// launch reap, and the migration that adds them.
@MainActor
final class RailTests: XCTestCase {
    // MARK: - Fixtures

    /// An in-memory store at the current shape.
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Inserts a space with the given services as members, in order. The ends
    /// are committed before the links are built: building a link wires the
    /// inverses, and inserting it a second time is fatal on macOS 14.
    @discardableResult
    private func makeSpace(
        _ name: String,
        order: Int,
        services labels: [String],
        in ctx: ModelContext
    ) throws -> (Space, [ServiceInstance], [SpaceServiceLink]) {
        let space = Space(name: name, emoji: "📦", sortOrder: order)
        let services = labels.map { ServiceInstance(label: $0, url: "https://\($0).example") }
        ctx.insert(space)
        services.forEach { ctx.insert($0) }
        try ctx.save()
        let links = services.enumerated().map { index, service in
            let link = SpaceServiceLink(sortOrder: index, space: space, service: service)
            if link.modelContext == nil { ctx.insert(link) }
            return link
        }
        try ctx.save()
        return (space, services, links)
    }

    // MARK: - RailOrder

    func testSortedPutsRowsBeforeDividersOnATieAndOldDividersFirst() {
        let row = UUID(), older = UUID(), newer = UUID(), first = UUID()
        let entries = [
            RailOrderEntry(id: newer, sortOrder: 1, isDivider: true, createdAt: Date(timeIntervalSince1970: 20)),
            RailOrderEntry(id: row, sortOrder: 1, isDivider: false),
            RailOrderEntry(id: older, sortOrder: 1, isDivider: true, createdAt: Date(timeIntervalSince1970: 10)),
            RailOrderEntry(id: first, sortOrder: 0, isDivider: false),
        ]
        XCTAssertEqual(RailOrder.sorted(entries).map(\.id), [first, row, older, newer])
    }

    func testNextOrderAndNumbering() {
        XCTAssertEqual(RailOrder.nextOrder(after: []), 0)
        XCTAssertEqual(RailOrder.nextOrder(after: [0, 4, 2]), 5)
        let a = UUID(), b = UUID()
        XCTAssertEqual(RailOrder.numbering([b, a]), [b: 0, a: 1])
    }

    func testInsertingAfterAnAnchorOrAtTheEnd() {
        let a = UUID(), b = UUID(), c = UUID(), new = UUID()
        XCTAssertEqual(RailOrder.inserting(new, after: a, in: [a, b, c]), [a, new, b, c])
        XCTAssertEqual(RailOrder.inserting(new, after: c, in: [a, b, c]), [a, b, c, new])
        XCTAssertEqual(RailOrder.inserting(new, after: nil, in: [a, b]), [a, b, new])
        XCTAssertEqual(RailOrder.inserting(new, after: UUID(), in: [a, b]), [a, b, new], "an unknown anchor appends")
        XCTAssertEqual(RailOrder.inserting(a, after: c, in: [a, b, c]), [b, c, a], "an id already present moves")
    }

    func testPlacingBeforeATarget() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(RailEdits.placing(c, before: a, in: [a, b, c]), [c, a, b])
        XCTAssertEqual(RailEdits.placing(a, before: c, in: [a, b, c]), [b, a, c])
        XCTAssertEqual(RailEdits.placing(a, before: UUID(), in: [a, b]), [b, a])
    }

    /// The reason the order is merged: a service dragged from below a divider
    /// to the top leaves the divider where it was, rather than taking it along
    /// or splitting the group above it.
    func testMovingARowAcrossADividerKeepsTheDividerBetweenTheGroups() {
        let a = UUID(), b = UUID(), divider = UUID(), c = UUID()
        let moved = LiveReorder.moving(c, over: a, in: [a, b, divider, c])
        XCTAssertEqual(moved, [c, a, b, divider])
    }

    // MARK: - Dividers in the store

    func testAddDividerAfterARowRenumbersTheMergedList() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, links) = try makeSpace("Work", order: 0, services: ["a", "b", "c"], in: ctx)

        let dividerID = try XCTUnwrap(RailEdits.addDivider(in: .space(space.id), after: links[0].id, context: ctx))

        let order = RailEdits.entries(in: .space(space.id), context: ctx).map(\.id)
        XCTAssertEqual(order, [links[0].id, dividerID, links[1].id, links[2].id])
        XCTAssertEqual(Set(RailEdits.entries(in: .space(space.id), context: ctx).map(\.sortOrder)).count, 4, "no two entries share a number")
        // The space's own service order, as everything that reads links sees it.
        XCTAssertEqual(
            RailEdits.links(inSpace: space.id, context: ctx).sorted { $0.sortOrder < $1.sortOrder }.map(\.id),
            links.map(\.id)
        )
    }

    func testAddDividerWithNoAnchorAppendsAndRemoveDeletesIt() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, links) = try makeSpace("Work", order: 0, services: ["a", "b"], in: ctx)

        let dividerID = try XCTUnwrap(RailEdits.addDivider(in: .space(space.id), after: nil, context: ctx))
        XCTAssertEqual(RailEdits.entries(in: .space(space.id), context: ctx).map(\.id), links.map(\.id) + [dividerID])

        XCTAssertTrue(RailEdits.removeDivider(dividerID, context: ctx))
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<RailDivider>()).isEmpty)
        XCTAssertTrue(RailEdits.removeDivider(dividerID, context: ctx), "removing one already gone is not a failure")
    }

    func testDividersStayInTheirOwnList() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, _, _) = try makeSpace("Work", order: 0, services: ["a"], in: ctx)
        let (home, _, _) = try makeSpace("Home", order: 1, services: ["b"], in: ctx)

        let inWork = try XCTUnwrap(RailEdits.addDivider(in: .space(work.id), after: nil, context: ctx))
        let inGlobal = try XCTUnwrap(RailEdits.addDivider(in: .global, after: nil, context: ctx))
        let betweenSpaces = try XCTUnwrap(RailEdits.addDivider(in: .spaces, after: work.id, context: ctx))

        XCTAssertEqual(RailEdits.dividers(in: .space(work.id), context: ctx).map(\.id), [inWork])
        XCTAssertTrue(RailEdits.dividers(in: .space(home.id), context: ctx).isEmpty)
        XCTAssertEqual(RailEdits.dividers(in: .global, context: ctx).map(\.id), [inGlobal])
        XCTAssertEqual(RailEdits.dividers(in: .spaces, context: ctx).map(\.id), [betweenSpaces])
        XCTAssertEqual(RailEdits.entries(in: .spaces, context: ctx).map(\.id), [work.id, betweenSpaces, home.id])
    }

    func testReorderNumbersRowsAndDividersTogether() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, links) = try makeSpace("Work", order: 0, services: ["a", "b", "c"], in: ctx)
        let dividerID = try XCTUnwrap(RailEdits.addDivider(in: .space(space.id), after: links[1].id, context: ctx))
        let current = RailEdits.entries(in: .space(space.id), context: ctx).map(\.id)
        XCTAssertEqual(current, [links[0].id, links[1].id, dividerID, links[2].id])

        let moved = try XCTUnwrap(LiveReorder.moving(links[2].id, over: links[0].id, in: current))
        XCTAssertTrue(RailEdits.reorder(moved, in: .space(space.id), context: ctx))

        XCTAssertEqual(
            RailEdits.entries(in: .space(space.id), context: ctx).map(\.id),
            [links[2].id, links[0].id, links[1].id, dividerID]
        )
    }

    // MARK: - Global services in the store

    func testMakeGlobalRemovesEveryMembershipAndKeepsTheService() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, services, _) = try makeSpace("Work", order: 0, services: ["cal", "mail"], in: ctx)
        let (home, _, _) = try makeSpace("Home", order: 1, services: [], in: ctx)
        let calendar = services[0]
        // In two spaces at once, which the app allows.
        let second = SpaceServiceLink(sortOrder: 0, space: home, service: calendar)
        if second.modelContext == nil { ctx.insert(second) }
        try ctx.save()
        let store = calendar.dataStoreIdentifier

        XCTAssertTrue(RailEdits.makeGlobal(calendar.id, context: ctx))

        XCTAssertTrue(calendar.isGlobalEffective)
        XCTAssertEqual(calendar.dataStoreIdentifier, store, "the sign-in goes with it")
        XCTAssertTrue(
            try ctx.fetch(FetchDescriptor<SpaceServiceLink>()).allSatisfy { $0.liveService?.id != calendar.id },
            "a global service has no links"
        )
        XCTAssertEqual(RailEdits.links(inSpace: work.id, context: ctx).compactMap(\.liveService?.id), [services[1].id])
        XCTAssertTrue(RailEdits.links(inSpace: home.id, context: ctx).isEmpty)
        XCTAssertEqual(RailEdits.globalServices(in: ctx).map(\.id), [calendar.id])
        XCTAssertFalse(RailEdits.makeGlobal(calendar.id, context: ctx), "already global")
    }

    func testMakeGlobalAppendsOrPlacesBeforeATarget() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, services, _) = try makeSpace("Work", order: 0, services: ["a", "b", "c"], in: ctx)

        XCTAssertTrue(RailEdits.makeGlobal(services[0].id, context: ctx))
        let dividerID = try XCTUnwrap(RailEdits.addDivider(in: .global, after: nil, context: ctx))
        XCTAssertTrue(RailEdits.makeGlobal(services[1].id, context: ctx))
        XCTAssertEqual(RailEdits.entries(in: .global, context: ctx).map(\.id), [services[0].id, dividerID, services[1].id])

        XCTAssertTrue(RailEdits.makeGlobal(services[2].id, before: dividerID, context: ctx))
        XCTAssertEqual(
            RailEdits.entries(in: .global, context: ctx).map(\.id),
            [services[0].id, services[2].id, dividerID, services[1].id]
        )
    }

    func testMoveIntoSpaceEndsGlobalAndPlacesTheNewLink() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, services, links) = try makeSpace("Work", order: 0, services: ["a", "b", "cal"], in: ctx)
        let calendar = services[2]
        XCTAssertTrue(RailEdits.makeGlobal(calendar.id, context: ctx))

        XCTAssertTrue(RailEdits.moveIntoSpace(calendar.id, spaceID: work.id, before: links[1].id, context: ctx))

        XCTAssertFalse(calendar.isGlobalEffective)
        XCTAssertNil(calendar.globalSortOrder)
        XCTAssertTrue(RailEdits.globalServices(in: ctx).isEmpty)
        let order = RailEdits.entries(in: .space(work.id), context: ctx).map(\.id)
        let memberOrder = RailEdits.links(inSpace: work.id, context: ctx)
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap(\.liveService?.id)
        XCTAssertEqual(order.count, 3)
        XCTAssertEqual(memberOrder, [services[0].id, calendar.id, services[1].id])
        XCTAssertEqual(
            try ctx.fetch(FetchDescriptor<SpaceServiceLink>()).filter { $0.liveService?.id == calendar.id }.count, 1,
            "exactly one link, registered once"
        )
        XCTAssertFalse(RailEdits.moveIntoSpace(calendar.id, spaceID: work.id, context: ctx), "not global any more")
    }

    func testMoveIntoSpaceWithNoTargetAppends() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, services, _) = try makeSpace("Work", order: 0, services: ["a", "b"], in: ctx)
        let (home, _, _) = try makeSpace("Home", order: 1, services: ["c"], in: ctx)
        XCTAssertTrue(RailEdits.makeGlobal(services[0].id, context: ctx))

        XCTAssertTrue(RailEdits.moveIntoSpace(services[0].id, spaceID: home.id, context: ctx))
        let homeMembers = RailEdits.links(inSpace: home.id, context: ctx)
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap(\.liveService?.label)
        XCTAssertEqual(homeMembers, ["c", "a"])
        XCTAssertEqual(RailEdits.links(inSpace: work.id, context: ctx).compactMap(\.liveService?.label), ["b"])
    }

    /// A global service survives a save and a reopen of the store, flag and
    /// order intact. The flag is the only thing that tells it from an orphan.
    func testGlobalFlagPersistsAcrossAReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "chorus-rail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")
        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        var serviceID = UUID()

        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let ctx = container.mainContext
            let (_, services, _) = try makeSpace("Work", order: 0, services: ["cal"], in: ctx)
            serviceID = services[0].id
            XCTAssertTrue(RailEdits.makeGlobal(serviceID, context: ctx))
        }

        let container = try ModelContainer(
            for: schema,
            migrationPlan: ChorusMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        let services = try container.mainContext.fetch(FetchDescriptor<ServiceInstance>())
        XCTAssertEqual(services.map(\.id), [serviceID])
        XCTAssertEqual(services.first?.isGlobal, true)
        XCTAssertEqual(services.first?.globalSortOrder, 0)
        XCTAssertTrue(AppState.reapable(services).isEmpty)
    }

    // MARK: - Launch reap

    func testReapSkipsGlobalServicesButTakesOrphans() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, members, _) = try makeSpace("Work", order: 0, services: ["kept"], in: ctx)
        let orphan = ServiceInstance(label: "orphan", url: "https://orphan.example")
        let global = ServiceInstance(label: "global", url: "https://global.example", isGlobal: true, globalSortOrder: 0)
        ctx.insert(orphan)
        ctx.insert(global)
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<ServiceInstance>())
        XCTAssertEqual(AppState.reapable(all).map(\.id), [orphan.id])
        XCTAssertFalse(AppState.reapable(all).contains { $0.id == members[0].id })
    }

    // MARK: - Deleting a space

    /// `deleteSpace` deletes the space's dividers in the same save, since no
    /// cascade reaches them, and leaves every other list's alone.
    func testDeletingASpaceTakesItsDividersOnly() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, _, _) = try makeSpace("Work", order: 0, services: ["a"], in: ctx)
        let (home, _, _) = try makeSpace("Home", order: 1, services: ["b"], in: ctx)
        try XCTUnwrap(RailEdits.addDivider(in: .space(work.id), after: nil, context: ctx))
        let kept = try XCTUnwrap(RailEdits.addDivider(in: .space(home.id), after: nil, context: ctx))
        let between = try XCTUnwrap(RailEdits.addDivider(in: .spaces, after: nil, context: ctx))

        RailEdits.deleteDividers(ofSpace: work.id, context: ctx)
        try ctx.save()

        XCTAssertEqual(Set(try ctx.fetch(FetchDescriptor<RailDivider>()).map(\.id)), [kept, between])
    }

    // MARK: - Migration

    /// A 1.5.19 store (the shape 1.5.19 to 1.5.28 shipped) opens at the
    /// current shape with every row intact, no service global, and no dividers.
    func testMigratesFrom1_5_19WithNothingGlobalAndNoDividers() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "chorus-migr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")
        let serviceID = UUID(), spaceID = UUID(), linkID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: ChorusSchemaV1_5_19.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let ctx = container.mainContext
            let space = ChorusSchemaV1_5_19.Space(id: spaceID, name: "Work", emoji: "🏢", sortOrder: 2)
            let service = ChorusSchemaV1_5_19.ServiceInstance(id: serviceID, label: "Slack", url: "https://slack.com")
            service.hibernationPolicyRaw = "after"
            service.hibernateAfterMinutes = 15
            service.stayActiveInBackground = true
            ctx.insert(space)
            ctx.insert(service)
            try ctx.save()
            let link = ChorusSchemaV1_5_19.SpaceServiceLink(id: linkID, sortOrder: 4, space: space, service: service)
            if link.modelContext == nil { ctx.insert(link) }
            try ctx.save()
        }

        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: ChorusMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        let ctx = container.mainContext

        let service = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ServiceInstance>()).first)
        XCTAssertEqual(service.id, serviceID)
        XCTAssertEqual(service.hibernationPolicyRaw, "after")
        XCTAssertEqual(service.hibernateAfterMinutes, 15)
        XCTAssertEqual(service.stayActiveInBackground, true)
        XCTAssertNil(service.isGlobal)
        XCTAssertNil(service.globalSortOrder)
        XCTAssertFalse(service.isGlobalEffective)

        let link = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SpaceServiceLink>()).first)
        XCTAssertEqual(link.id, linkID)
        XCTAssertEqual(link.sortOrder, 4)
        XCTAssertEqual(link.liveEnds?.space.id, spaceID)
        XCTAssertEqual(link.liveEnds?.service.id, serviceID)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Space>()).map(\.sortOrder), [2])
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<RailDivider>()).isEmpty)

        // And the new entity takes rows after the migration.
        XCTAssertNotNil(RailEdits.addDivider(in: .space(spaceID), after: linkID, context: ctx))
    }
}
