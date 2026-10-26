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

    // MARK: - The end of a divider drag

    /// Escape ends the drag at once, with the button still down. The live
    /// moves are undone and the divider stays, even off the rail.
    func testEscapeCancelsADividerDragWhereverItIs() {
        XCTAssertEqual(RailDragEnd.classify(dropTaken: false, endedByKey: true, insideRail: true), .cancelled)
        XCTAssertEqual(RailDragEnd.classify(dropTaken: false, endedByKey: true, insideRail: false), .cancelled)
    }

    func testReleasingADividerKeepsItOnTheRailAndRemovesItOff() {
        XCTAssertEqual(RailDragEnd.classify(dropTaken: true, endedByKey: false, insideRail: true), .dropped)
        // Let go over a gap between rows: nothing took the drop, still a move.
        XCTAssertEqual(RailDragEnd.classify(dropTaken: false, endedByKey: false, insideRail: true), .dropped)
        XCTAssertEqual(RailDragEnd.classify(dropTaken: false, endedByKey: false, insideRail: false), .endedOffRail)
        // With no rail to ask, keep it.
        XCTAssertEqual(RailDragEnd.classify(dropTaken: false, endedByKey: false, insideRail: nil), .dropped)
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

    /// The global group is not drawn without services, so its dividers go
    /// with the last one rather than sitting there unseen.
    func testLastGlobalLeavingTakesTheGroupsDividers() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, services, _) = try makeSpace("Work", order: 0, services: ["a", "b"], in: ctx)
        XCTAssertTrue(RailEdits.makeGlobal(services[0].id, context: ctx))
        XCTAssertTrue(RailEdits.makeGlobal(services[1].id, context: ctx))
        let between = try XCTUnwrap(RailEdits.addDivider(in: .global, after: services[0].id, context: ctx))
        let inWork = try XCTUnwrap(RailEdits.addDivider(in: .space(work.id), after: nil, context: ctx))

        XCTAssertTrue(RailEdits.moveIntoSpace(services[0].id, spaceID: work.id, context: ctx))
        XCTAssertEqual(RailEdits.dividers(in: .global, context: ctx).map(\.id), [between], "one global is left")

        XCTAssertTrue(RailEdits.moveIntoSpace(services[1].id, spaceID: work.id, context: ctx))
        XCTAssertTrue(RailEdits.dividers(in: .global, context: ctx).isEmpty)
        XCTAssertEqual(RailEdits.dividers(in: .space(work.id), context: ctx).map(\.id), [inWork], "other lists keep theirs")
    }

    /// A group emptied some other way (a delete) starts clean when a service
    /// next goes global, rather than under a line above nothing.
    func testAGroupStartingOverDropsLeftoverDividers() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, services, _) = try makeSpace("Work", order: 0, services: ["a"], in: ctx)
        ctx.insert(RailDivider(kind: .services, spaceID: nil, sortOrder: 0))
        try ctx.save()

        XCTAssertTrue(RailEdits.makeGlobal(services[0].id, context: ctx))

        XCTAssertTrue(RailEdits.dividers(in: .global, context: ctx).isEmpty)
        XCTAssertEqual(RailEdits.entries(in: .global, context: ctx).map(\.id), [services[0].id])
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

    // MARK: - Setup import

    private func railLink(_ service: ServiceInstance, to space: Space, in ctx: ModelContext) {
        let link = SpaceServiceLink(sortOrder: 0, space: space, service: service)
        if link.modelContext == nil { ctx.insert(link) }
    }

    /// An import into a space that holds a divider puts the new services past
    /// it, rather than on its number.
    func testImportIntoASpaceAppendsPastItsDividers() throws {
        let source = try makeContainer()
        let src = source.mainContext
        let home = Space(name: "Home", emoji: "🏠", sortOrder: 0)
        let gmail = ServiceInstance(label: "Gmail", url: "https://mail.google.com")
        src.insert(home)
        src.insert(gmail)
        try src.save()
        railLink(gmail, to: home, in: src)
        try src.save()
        let archive = try SetupArchive.capture(from: src, appVersion: nil)

        let target = try makeContainer()
        let dst = target.mainContext
        let existingHome = Space(name: "Home", emoji: "🏠", sortOrder: 0)
        let slack = ServiceInstance(label: "Slack", url: "https://slack.com")
        dst.insert(existingHome)
        dst.insert(slack)
        try dst.save()
        railLink(slack, to: existingHome, in: dst)
        try dst.save()
        let divider = try XCTUnwrap(RailEdits.addDivider(in: .space(existingHome.id), after: nil, context: dst))

        _ = try archive.apply(to: dst)

        let homes = try dst.fetch(FetchDescriptor<Space>())
        let entries = homes.flatMap { RailEdits.entries(in: .space($0.id), context: dst) }
        XCTAssertEqual(Set(entries.map(\.sortOrder)).count, entries.count, "no two entries share a number")
        if homes.count == 1 {
            XCTAssertEqual(entries.last?.isDivider, false, "the import lands after the divider")
            XCTAssertTrue(entries.contains { $0.id == divider })
        }
    }

    // MARK: - Setup groups

    /// A source store whose "Work" space holds a, b, c, d with b and c in a
    /// group named "Chat", plus the encoded archive.
    private func groupedArchive(name: String? = "Chat") throws -> SetupArchive {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, links) = try makeSpace("Work", order: 0, services: ["a", "b", "c", "d"], in: ctx)
        let group = ServiceGroup(spaceID: space.id, name: name)
        ctx.insert(group)
        links[1].groupID = group.id
        links[2].groupID = group.id
        try ctx.save()
        return try SetupArchive.capture(from: ctx, appVersion: nil)
    }

    func testSetupRoundTripKeepsGroupsAndNames() throws {
        let archive = try groupedArchive()
        XCTAssertEqual(archive.spaces[0].groups, [.init(name: "Chat", members: [1, 2])])
        let decoded = try SetupArchive.decode(try archive.encoded())

        let target = try makeContainer()
        let ctx = target.mainContext
        _ = try decoded.apply(to: ctx)
        let space = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Space>()).first)
        let groups = try ctx.fetch(FetchDescriptor<ServiceGroup>())
        XCTAssertEqual(groups.map(\.name), ["Chat"])
        let list = RailEdits.groupEntries(inSpace: space.id, context: ctx)
        XCTAssertEqual(list.map { $0.groupID != nil }, [false, false, true, true], "the group sits at the end of the space")
        XCTAssertEqual(Set(list.compactMap(\.groupID)).count, 1)
    }

    func testSetupFromBefore1_5_30DecodesWithNoGroups() throws {
        let json = """
        {"format":"chorus-setup","version":1,"exportedAt":"2026-01-01T00:00:00Z",
         "spaces":[{"name":"Home","emoji":"x","sortOrder":0,"members":[{"service":0,"sortOrder":0}]}],
         "services":[{"label":"a","url":"https://a.example","isMuted":false,"showBadge":true,"neverHibernate":false}]}
        """
        let archive = try SetupArchive.decode(Data(json.utf8))
        XCTAssertNil(archive.spaces[0].groups)
    }

    func testSetupRejectsBadGroups() throws {
        func rejects(_ edit: (inout SetupArchive) -> Void, _ message: String) throws {
            var archive = try groupedArchive()
            edit(&archive)
            XCTAssertThrowsError(try SetupArchive.decode(try archive.encoded()), message)
        }
        try rejects({ $0.spaces[0].groups = [.init(name: nil, members: [1, 99])] }, "index out of range")
        try rejects({
            $0.spaces.append(.init(name: "Other", emoji: "x", sortOrder: 1, members: [.init(service: 0, sortOrder: 0)], groups: nil))
            $0.spaces[1].groups = [.init(name: nil, members: [0, 1])]
        }, "index not a member of that space")
        try rejects({ $0.spaces[0].groups = [.init(name: nil, members: [0, 1]), .init(name: nil, members: [1, 2])] }, "index in two groups")
        try rejects({ $0.globalServices = [1] }, "index also global")
        try rejects({ $0.spaces[0].groups = [.init(name: nil, members: [1])] }, "fewer than two")
        try rejects({ $0.spaces[0].groups = [.init(name: String(repeating: "x", count: SetupArchive.Limit.textLength + 1), members: [1, 2])] }, "name too long")
    }

    func testCaptureLeavesOutAGroupLeftWithFewerThanTwoExportedMembers() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, services, links) = try makeSpace("Work", order: 0, services: ["a", "b", "c"], in: ctx)
        services[2].url = "file:///nope"
        let group = ServiceGroup(spaceID: space.id)
        ctx.insert(group)
        links[1].groupID = group.id
        links[2].groupID = group.id
        try ctx.save()
        let archive = try SetupArchive.capture(from: ctx, appVersion: nil)
        XCTAssertNil(archive.spaces[0].groups)
    }

    func testImportIntoAnExistingSpaceKeepsTheImportedGroupTogether() throws {
        let archive = try groupedArchive()

        let target = try makeContainer()
        let ctx = target.mainContext
        let (space, _, existing) = try makeSpace("Work", order: 0, services: ["x", "y"], in: ctx)
        let old = ServiceGroup(spaceID: space.id, name: "Old")
        ctx.insert(old)
        existing[0].groupID = old.id
        existing[1].groupID = old.id
        try ctx.save()

        _ = try archive.apply(to: ctx)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Space>()).count, 1)
        let list = RailEdits.groupEntries(inSpace: space.id, context: ctx)
        let imported = Set(list.compactMap(\.groupID)).subtracting([old.id])
        XCTAssertEqual(imported.count, 1)
        let importedID = try XCTUnwrap(imported.first)
        let positions = list.indices.filter { list[$0].groupID == importedID }
        XCTAssertEqual(positions.count, 2)
        XCTAssertEqual(positions[1] - positions[0], 1, "one run")
        XCTAssertEqual(list.filter { $0.groupID == old.id }.map(\.id), existing.map(\.id), "no existing service joined")
        XCTAssertEqual(list.prefix(2).map(\.groupID), [old.id, old.id])
    }
}
