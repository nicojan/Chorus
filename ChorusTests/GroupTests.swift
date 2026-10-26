import XCTest
import SwiftData
@testable import Chorus

/// Service groups: the stored shape and the migration that adds it.
@MainActor
final class GroupTests: XCTestCase {
    // MARK: - Migration

    /// A 1.5.29 store (global services and dividers, before groups) opens at the
    /// current shape with every row intact, no link in a group, and no groups.
    func testMigratesFrom1_5_29WithNoGroups() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "chorus-migr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")
        let serviceID = UUID(), spaceID = UUID(), linkID = UUID(), dividerID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: ChorusSchemaV1_5_29.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let ctx = container.mainContext
            let space = ChorusSchemaV1_5_29.Space(id: spaceID, name: "Work", emoji: "🏢", sortOrder: 1)
            let service = ChorusSchemaV1_5_29.ServiceInstance(id: serviceID, label: "Slack", url: "https://slack.com")
            ctx.insert(space)
            ctx.insert(service)
            ctx.insert(ChorusSchemaV1_5_29.RailDivider(id: dividerID, kindRaw: "services", spaceID: spaceID, sortOrder: 5))
            try ctx.save()
            let link = ChorusSchemaV1_5_29.SpaceServiceLink(id: linkID, sortOrder: 3, space: space, service: service)
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

        let link = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SpaceServiceLink>()).first)
        XCTAssertEqual(link.id, linkID)
        XCTAssertNil(link.groupID)
        XCTAssertEqual(link.sortOrder, 3)
        XCTAssertEqual(link.liveEnds?.space.id, spaceID)
        XCTAssertEqual(link.liveEnds?.service.id, serviceID)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<RailDivider>()).map(\.id), [dividerID])
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<ServiceGroup>()).isEmpty)

        // And the new entity takes rows after the migration.
        ctx.insert(ServiceGroup(spaceID: spaceID, name: "Chat"))
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ServiceGroup>()).count, 1)
    }

    // MARK: - Rules

    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), f = UUID(), x = UUID(), y = UUID(), w = UUID()
    private let g = UUID(), n = UUID()

    private func e(_ id: UUID, _ group: UUID? = nil, divider: Bool = false) -> GroupEntry {
        GroupEntry(id: id, groupID: group, isDivider: divider)
    }

    func testRepairedDissolvesAOneMemberGroup() {
        XCTAssertEqual(GroupRules.repaired([e(a, g), e(b)]), [e(a), e(b)])
    }

    func testRepairedMovesAnOutsiderAfterTheRun() {
        XCTAssertEqual(GroupRules.repaired([e(a, g), e(x), e(b, g), e(c)]), [e(a, g), e(b, g), e(x), e(c)])
    }

    func testRepairedMovesADividerOutOfTheRun() {
        XCTAssertEqual(
            GroupRules.repaired([e(a, g), e(d, divider: true), e(b, g)]),
            [e(a, g), e(b, g), e(d, divider: true)]
        )
    }

    func testJoiningFromBelowLandsAfterTheTarget() {
        XCTAssertEqual(
            GroupRules.joining(c, onto: a, in: [e(a), e(b), e(c)], newGroupID: n),
            [e(a, n), e(c, n), e(b)]
        )
    }

    func testJoiningFromAboveLandsBeforeTheTarget() {
        XCTAssertEqual(
            GroupRules.joining(a, onto: c, in: [e(a), e(b), e(c)], newGroupID: n),
            [e(b), e(a, n), e(c, n)]
        )
    }

    func testJoiningAGroupedTargetAddsToItsGroup() {
        XCTAssertEqual(
            GroupRules.joining(c, onto: b, in: [e(a, g), e(b, g), e(c)], newGroupID: n),
            [e(a, g), e(b, g), e(c, g)]
        )
    }

    func testJoiningLeavesTheOldGroupAndDissolvesIt() {
        XCTAssertEqual(
            GroupRules.joining(b, onto: c, in: [e(a, g), e(b, g), e(c)], newGroupID: n),
            [e(a), e(b, n), e(c, n)]
        )
    }

    func testPlacingAtEitherEndOfALitRunJoins() {
        let top = GroupRules.placing(x, in: [e(x), e(a, g), e(b, g)], litGroup: g)
        XCTAssertEqual(top.first(where: { $0.id == x })?.groupID, g)
        let bottom = GroupRules.placing(x, in: [e(a, g), e(b, g), e(x)], litGroup: g)
        XCTAssertEqual(bottom.first(where: { $0.id == x })?.groupID, g)
    }

    func testPlacingIgnoresAStaleLitGroup() {
        let result = GroupRules.placing(x, in: [e(a, g), e(b, g), e(y), e(x)], litGroup: g)
        XCTAssertNil(result.first(where: { $0.id == x })?.groupID)
        XCTAssertEqual(result.first(where: { $0.id == a })?.groupID, g)
    }

    func testPlacingWithNoLitBoxLeavesAndDissolves() {
        let result = GroupRules.placing(b, in: [e(a, g), e(c), e(b, g)], litGroup: nil)
        XCTAssertNil(result.first(where: { $0.id == b })?.groupID)
        XCTAssertNil(result.first(where: { $0.id == a })?.groupID)
    }

    func testLandingAnchorSkipsPastARun() {
        XCTAssertEqual(GroupRules.landingAnchor(before: b, in: [e(a, g), e(b, g), e(c)]), c)
        XCTAssertEqual(GroupRules.landingAnchor(before: a, in: [e(a, g), e(b, g), e(c)]), a)
        XCTAssertNil(GroupRules.landingAnchor(before: b, in: [e(a, g), e(b, g)]))
        XCTAssertNil(GroupRules.landingAnchor(before: nil, in: [e(a, g), e(b, g)]))
    }

    func testSteppingAMemberStaysInItsRun() {
        let list = [e(x), e(a, g), e(b, g), e(c, g), e(y)]
        XCTAssertEqual(GroupRules.stepping(b, forward: true, in: list), [x, a, c, b, y])
        XCTAssertEqual(GroupRules.stepping(b, forward: false, in: list), [x, b, a, c, y])
        XCTAssertEqual(GroupRules.stepping(a, forward: false, in: list), [x, a, b, c, y])
        XCTAssertEqual(GroupRules.stepping(c, forward: true, in: list), [x, a, b, c, y])
    }

    func testSteppingAnOutsiderJumpsAWholeRun() {
        let list = [e(x), e(a, g), e(b, g), e(y)]
        XCTAssertEqual(GroupRules.stepping(x, forward: true, in: list), [a, b, x, y])
        XCTAssertEqual(GroupRules.stepping(y, forward: false, in: list), [x, y, a, b])
    }

    func testSteppingADividerJumpsAWholeRun() {
        let list = [e(a, g), e(b, g), e(d, divider: true), e(x)]
        XCTAssertEqual(GroupRules.stepping(d, forward: false, in: list), [d, a, b, x])
    }

    func testSteppingAGroupPassesItsNeighbour() {
        let h = UUID()
        let list = [e(x), e(a, g), e(b, g), e(d, divider: true), e(c, h), e(f, h)]
        XCTAssertEqual(GroupRules.steppingGroup(g, forward: true, in: list), [x, d, a, b, c, f])
        XCTAssertEqual(GroupRules.steppingGroup(g, forward: false, in: list), [a, b, x, d, c, f])
        XCTAssertEqual(GroupRules.steppingGroup(h, forward: false, in: list), [x, a, b, c, f, d])
        XCTAssertEqual(GroupRules.steppingGroup(h, forward: true, in: list), [x, a, b, d, c, f])
    }

    func testGroupWithCandidatesAreTheOutsideNeighbours() {
        let list = [e(a, g), e(b, g), e(c), e(d, divider: true), e(f)]
        XCTAssertEqual(GroupRules.groupWithCandidates(for: c, in: list), [b])
        XCTAssertEqual(GroupRules.groupWithCandidates(for: x, in: [e(w), e(x), e(y)]), [w, y])
    }

    // MARK: - Store edits

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// A space with the given services as members, in order. The ends are saved
    /// before the links are built, since a second insert is fatal on macOS 14.
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

    /// Links an existing service into an existing space at the end.
    @discardableResult
    private func addLink(_ service: ServiceInstance, to space: Space, in ctx: ModelContext) throws -> SpaceServiceLink {
        let link = SpaceServiceLink(
            sortOrder: RailEdits.nextOrder(in: .space(space.id), context: ctx),
            space: space,
            service: service
        )
        if link.modelContext == nil { ctx.insert(link) }
        try ctx.save()
        return link
    }

    private func order(_ space: Space, _ ctx: ModelContext) -> [UUID] {
        RailEdits.entries(in: .space(space.id), context: ctx).map(\.id)
    }

    private func groups(_ ctx: ModelContext) throws -> [ServiceGroup] {
        try ctx.fetch(FetchDescriptor<ServiceGroup>())
    }

    private func link(_ id: UUID, _ ctx: ModelContext) throws -> SpaceServiceLink? {
        try ctx.fetch(FetchDescriptor<SpaceServiceLink>()).first { $0.id == id && $0.modelContext != nil }
    }

    func testGroupLinkMakesAGroupRowAndSetsBothLinks() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, links) = try makeSpace("Work", order: 0, services: ["a", "b", "c"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(links[2].id, onto: links[0].id, context: ctx))

        let group = try XCTUnwrap(try groups(ctx).first)
        XCTAssertEqual(try groups(ctx).count, 1)
        XCTAssertEqual(group.spaceID, space.id)
        XCTAssertEqual(links[0].groupID, group.id)
        XCTAssertEqual(links[2].groupID, group.id)
        XCTAssertNil(links[1].groupID)
        XCTAssertEqual(order(space, ctx), [links[0].id, links[2].id, links[1].id])
    }

    func testGroupLinkRefusesLinksInDifferentSpaces() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, _, first) = try makeSpace("Work", order: 0, services: ["a"], in: ctx)
        let (_, _, second) = try makeSpace("Home", order: 1, services: ["b"], in: ctx)
        XCTAssertFalse(RailEdits.groupLink(first[0].id, onto: second[0].id, context: ctx))
        XCTAssertTrue(try groups(ctx).isEmpty)
        XCTAssertNil(first[0].groupID)
        XCTAssertNil(second[0].groupID)
    }

    func testFinishDragReadsTheOrderFromTheStore() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c", "d"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[1].id, onto: l[0].id, context: ctx))
        let group = try XCTUnwrap(l[0].groupID)

        // The live moves of a drag: d passes c and sits under the box.
        RailEdits.reorder([l[0].id, l[1].id, l[3].id, l[2].id], in: .space(space.id), context: ctx)
        XCTAssertTrue(RailEdits.finishDrag(l[3].id, inSpace: space.id, litGroup: group, context: ctx))

        XCTAssertEqual(order(space, ctx), [l[0].id, l[1].id, l[3].id, l[2].id])
        XCTAssertEqual(l[3].groupID, group)
        XCTAssertNil(l[2].groupID)
    }

    func testRemovingTheSecondLastMemberDeletesTheGroupRow() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[1].id, onto: l[0].id, context: ctx))
        XCTAssertTrue(RailEdits.removeFromGroup(l[0].id, context: ctx))

        XCTAssertTrue(try groups(ctx).isEmpty)
        XCTAssertNil(l[0].groupID)
        XCTAssertNil(l[1].groupID)
        // It steps out just below the box.
        XCTAssertEqual(order(space, ctx), [l[1].id, l[0].id, l[2].id])
    }

    func testRemoveFromGroupMovesAMidRunMemberBelowTheBox() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c", "d"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[1].id, onto: l[0].id, context: ctx))
        XCTAssertTrue(RailEdits.groupLink(l[2].id, onto: l[1].id, context: ctx))
        let group = try XCTUnwrap(l[0].groupID)
        XCTAssertTrue(RailEdits.removeFromGroup(l[1].id, context: ctx))

        XCTAssertEqual(order(space, ctx), [l[0].id, l[2].id, l[1].id, l[3].id])
        XCTAssertNil(l[1].groupID)
        XCTAssertEqual(l[0].groupID, group)
        XCTAssertEqual(l[2].groupID, group)
        XCTAssertEqual(try groups(ctx).count, 1)
    }

    // MARK: Review Focus 1: leaving a space leaves the group

    func testMoveMembershipLeavesTheGroup() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, _, l) = try makeSpace("Work", order: 0, services: ["a", "b"], in: ctx)
        let (home, _, h) = try makeSpace("Home", order: 1, services: ["x"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[1].id, onto: l[0].id, context: ctx))

        XCTAssertTrue(RailEdits.moveMembership(l[1].id, toSpace: home.id, context: ctx))

        XCTAssertNil(l[1].groupID)
        XCTAssertNil(l[0].groupID)
        XCTAssertTrue(try groups(ctx).isEmpty)
        XCTAssertEqual(order(work, ctx), [l[0].id])
        XCTAssertEqual(order(home, ctx), [h[0].id, l[1].id])
    }

    func testMoveServiceFromTheMenuDoesNotCarryTheGroup() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, _, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c", "d"], in: ctx)
        let (home, _, _) = try makeSpace("Home", order: 1, services: [], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[1].id, onto: l[0].id, context: ctx))
        XCTAssertTrue(RailEdits.groupLink(l[2].id, onto: l[1].id, context: ctx))
        XCTAssertTrue(RailEdits.groupLink(l[3].id, onto: l[2].id, context: ctx))
        let group = try XCTUnwrap(l[0].groupID)
        XCTAssertEqual(Set(l.map(\.groupID)), [group])

        XCTAssertTrue(RailEdits.moveMembership(l[2].id, toSpace: home.id, context: ctx))
        XCTAssertTrue(RailEdits.moveMembership(l[3].id, toSpace: home.id, context: ctx))

        XCTAssertNil(l[2].groupID)
        XCTAssertNil(l[3].groupID)
        XCTAssertEqual(order(home, ctx), [l[2].id, l[3].id])
        XCTAssertEqual(l[0].groupID, group)
        XCTAssertEqual(l[1].groupID, group)
        XCTAssertEqual(order(work, ctx), [l[0].id, l[1].id])
        XCTAssertEqual(try groups(ctx).map(\.id), [group])
    }

    func testMakeGlobalTidiesEverySpaceItLeaves() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, s, w) = try makeSpace("Work", order: 0, services: ["shared", "a"], in: ctx)
        let (home, _, h) = try makeSpace("Home", order: 1, services: ["b"], in: ctx)
        let homeLink = try addLink(s[0], to: home, in: ctx)
        XCTAssertTrue(RailEdits.groupLink(w[1].id, onto: w[0].id, context: ctx))
        XCTAssertTrue(RailEdits.groupLink(homeLink.id, onto: h[0].id, context: ctx))
        XCTAssertEqual(try groups(ctx).count, 2)

        XCTAssertTrue(RailEdits.makeGlobal(s[0].id, context: ctx))

        XCTAssertNil(w[1].groupID)
        XCTAssertNil(h[0].groupID)
        XCTAssertTrue(try groups(ctx).isEmpty)
        XCTAssertEqual(order(work, ctx), [w[1].id])
        XCTAssertEqual(order(home, ctx), [h[0].id])
    }

    func testLeaveSpaceLeavesTheGroup() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[1].id, onto: l[0].id, context: ctx))
        let survivor = l[1].id

        RailEdits.leaveSpace(l[0].id, context: ctx)
        try ctx.save()

        XCTAssertNil(try link(survivor, ctx)?.groupID)
        XCTAssertTrue(try groups(ctx).isEmpty)
        XCTAssertEqual(order(space, ctx), [l[1].id, l[2].id])
    }

    func testForgetServiceLeavesItsGroups() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, s, w) = try makeSpace("Work", order: 0, services: ["gone", "a"], in: ctx)
        let (home, _, h) = try makeSpace("Home", order: 1, services: ["b", "c"], in: ctx)
        let homeLink = try addLink(s[0], to: home, in: ctx)
        XCTAssertTrue(RailEdits.groupLink(w[1].id, onto: w[0].id, context: ctx))
        XCTAssertTrue(RailEdits.groupLink(homeLink.id, onto: h[0].id, context: ctx))
        XCTAssertTrue(RailEdits.groupLink(h[1].id, onto: h[0].id, context: ctx))
        let homeGroup = try XCTUnwrap(h[0].groupID)

        // What `AppState.deleteServiceEntirely` does with the store.
        RailEdits.forgetService(s[0].id, context: ctx)
        for gone in [w[0], homeLink] { ctx.delete(gone) }
        ctx.delete(s[0])
        try ctx.save()

        XCTAssertNil(w[1].groupID)
        XCTAssertEqual(h[0].groupID, homeGroup)
        XCTAssertEqual(h[1].groupID, homeGroup)
        XCTAssertEqual(try groups(ctx).map(\.id), [homeGroup])
        XCTAssertEqual(order(work, ctx), [w[1].id])
        XCTAssertEqual(order(home, ctx), [h[0].id, h[1].id])
    }

    // MARK: Review Focus 2: a group id with no row of this space reads as none

    func testGroupEntriesIgnoresAMissingOrForeignGroup() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, _, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c"], in: ctx)
        let (home, _, _) = try makeSpace("Home", order: 1, services: [], in: ctx)
        let foreign = ServiceGroup(spaceID: home.id)
        ctx.insert(foreign)
        let known = UUID()
        l[0].groupID = UUID()
        l[1].groupID = foreign.id
        l[2].groupID = known
        try ctx.save()

        let plain = RailEdits.groupEntries(inSpace: work.id, context: ctx)
        XCTAssertEqual(plain.map(\.id), l.map(\.id))
        XCTAssertEqual(plain.map(\.groupID), [nil, nil, nil])

        let withKnown = RailEdits.groupEntries(inSpace: work.id, context: ctx, knownGroups: [known: work.id])
        XCTAssertEqual(withKnown.map(\.groupID), [nil, nil, known])
        let foreignKnown = RailEdits.groupEntries(inSpace: work.id, context: ctx, knownGroups: [known: home.id])
        XCTAssertEqual(foreignKnown.map(\.groupID), [nil, nil, nil])

        let without = RailEdits.groupEntries(inSpace: work.id, context: ctx, removedLinks: [l[1].id])
        XCTAssertEqual(without.map(\.id), [l[0].id, l[2].id])
    }

    // MARK: Review Focus 3: arriving never lands inside a run

    func testMoveMembershipBeforeAMidRunMemberLandsAfterTheRun() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, _, w) = try makeSpace("Work", order: 0, services: ["x"], in: ctx)
        let (home, _, h) = try makeSpace("Home", order: 1, services: ["p", "q", "r"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(h[1].id, onto: h[0].id, context: ctx))

        XCTAssertTrue(RailEdits.moveMembership(w[0].id, toSpace: home.id, before: h[1].id, context: ctx))

        XCTAssertEqual(order(home, ctx), [h[0].id, h[1].id, w[0].id, h[2].id])
        XCTAssertNil(w[0].groupID)
    }

    func testMoveIntoSpaceBeforeAMidRunMemberLandsAfterTheRun() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (home, _, h) = try makeSpace("Home", order: 0, services: ["p", "q", "r"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(h[1].id, onto: h[0].id, context: ctx))
        let global = ServiceInstance(label: "g", url: "https://g.example")
        ctx.insert(global)
        RailEdits.appendGlobal(global, context: ctx)
        try ctx.save()

        XCTAssertTrue(RailEdits.moveIntoSpace(global.id, spaceID: home.id, before: h[1].id, context: ctx))

        let arrived = try XCTUnwrap(RailEdits.links(inSpace: home.id, context: ctx).first { $0.liveService?.id == global.id })
        XCTAssertEqual(order(home, ctx), [h[0].id, h[1].id, arrived.id, h[2].id])
        XCTAssertNil(arrived.groupID)
    }

    func testAddDividerAfterAMidRunMemberLandsAfterTheRun() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (home, _, h) = try makeSpace("Home", order: 0, services: ["p", "q", "r"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(h[1].id, onto: h[0].id, context: ctx))

        let divider = try XCTUnwrap(RailEdits.addDivider(in: .space(home.id), after: h[0].id, context: ctx))

        XCTAssertEqual(order(home, ctx), [h[0].id, h[1].id, divider, h[2].id])
    }

    func testDeleteSpaceDeletesItsGroups() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, _, w) = try makeSpace("Work", order: 0, services: ["a", "b"], in: ctx)
        let (_, _, h) = try makeSpace("Home", order: 1, services: ["c", "d"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(w[1].id, onto: w[0].id, context: ctx))
        XCTAssertTrue(RailEdits.groupLink(h[1].id, onto: h[0].id, context: ctx))
        let homeGroup = try XCTUnwrap(h[0].groupID)

        // The store half of `AppState.deleteSpace`.
        for gone in w { ctx.delete(gone) }
        RailEdits.deleteDividers(ofSpace: work.id, context: ctx)
        RailEdits.deleteGroups(ofSpace: work.id, context: ctx)
        ctx.delete(work)
        try ctx.save()

        XCTAssertEqual(try groups(ctx).map(\.id), [homeGroup])
    }

    func testNameGroupTrimsClearsAndCaps() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, _, l) = try makeSpace("Work", order: 0, services: ["a", "b"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[1].id, onto: l[0].id, context: ctx))
        let group = try XCTUnwrap(try groups(ctx).first)

        XCTAssertTrue(RailEdits.nameGroup(group.id, "  Chat \n", context: ctx))
        XCTAssertEqual(group.name, "Chat")
        XCTAssertTrue(RailEdits.nameGroup(group.id, "   ", context: ctx))
        XCTAssertNil(group.name)
        XCTAssertTrue(RailEdits.nameGroup(group.id, "Chat", context: ctx))
        XCTAssertTrue(RailEdits.nameGroup(group.id, nil, context: ctx))
        XCTAssertNil(group.name)
        let long = String(repeating: "x", count: SetupArchive.Limit.textLength + 10)
        XCTAssertTrue(RailEdits.nameGroup(group.id, long, context: ctx))
        XCTAssertEqual(group.name?.count, SetupArchive.Limit.textLength)
        XCTAssertFalse(RailEdits.nameGroup(UUID(), "Nope", context: ctx))
    }

    func testUngroupClearsEveryMemberAndKeepsTheOrder() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[2].id, onto: l[0].id, context: ctx))
        let before = order(space, ctx)
        let group = try XCTUnwrap(l[0].groupID)

        XCTAssertTrue(RailEdits.ungroup(group, context: ctx))

        XCTAssertTrue(l.allSatisfy { $0.groupID == nil })
        XCTAssertTrue(try groups(ctx).isEmpty)
        XCTAssertEqual(order(space, ctx), before)
    }

    // MARK: Moving a whole group

    func testMoveGroupTakesEveryMemberAndTheName() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, _, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c", "d"], in: ctx)
        let (home, _, h) = try makeSpace("Home", order: 1, services: ["x", "y"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[2].id, onto: l[1].id, context: ctx))
        let group = try XCTUnwrap(l[1].groupID)
        XCTAssertTrue(RailEdits.nameGroup(group, "Mail", context: ctx))

        XCTAssertTrue(RailEdits.moveGroup(group, toSpace: home.id, before: h[1].id, context: ctx))

        XCTAssertEqual(order(home, ctx), [h[0].id, l[1].id, l[2].id, h[1].id])
        XCTAssertEqual(order(work, ctx), [l[0].id, l[3].id])
        XCTAssertEqual(l[1].groupID, group)
        XCTAssertEqual(l[2].groupID, group)
        let row = try XCTUnwrap(try groups(ctx).first)
        XCTAssertEqual(try groups(ctx).count, 1)
        XCTAssertEqual(row.spaceID, home.id)
        XCTAssertEqual(row.name, "Mail")
        XCTAssertEqual(RailEdits.groupEntries(inSpace: home.id, context: ctx).compactMap(\.groupID), [group, group])
    }

    func testMoveGroupIsRefusedWhenAMemberIsAlreadyThere() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, services, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c"], in: ctx)
        let (home, _, _) = try makeSpace("Home", order: 1, services: ["x"], in: ctx)
        try addLink(services[1], to: home, in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[1].id, onto: l[0].id, context: ctx))
        let group = try XCTUnwrap(l[0].groupID)
        let before = order(work, ctx)
        let homeBefore = order(home, ctx)

        XCTAssertFalse(RailEdits.moveGroup(group, toSpace: home.id, before: nil, context: ctx))

        XCTAssertEqual(order(work, ctx), before)
        XCTAssertEqual(order(home, ctx), homeBefore)
        XCTAssertEqual(try groups(ctx).first?.spaceID, work.id)
        XCTAssertEqual(l[0].groupID, group)
    }

    func testEligibleSpacesLeaveOutSpacesHoldingAMember() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (work, services, l) = try makeSpace("Work", order: 0, services: ["a", "b"], in: ctx)
        let (home, _, _) = try makeSpace("Home", order: 1, services: ["x"], in: ctx)
        let (play, _, _) = try makeSpace("Play", order: 2, services: ["z"], in: ctx)
        try addLink(services[0], to: play, in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[1].id, onto: l[0].id, context: ctx))
        let group = try XCTUnwrap(l[0].groupID)

        let eligible = RailEdits.eligibleSpaces(forGroup: group, context: ctx)

        XCTAssertEqual(eligible, [home.id])
        XCTAssertFalse(eligible.contains(work.id))
    }

    func testReorderGroupMovesTheRunAsOne() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c", "d"], in: ctx)
        XCTAssertTrue(RailEdits.groupLink(l[1].id, onto: l[0].id, context: ctx))
        let group = try XCTUnwrap(l[0].groupID)

        let ok = RailEdits.reorderGroup(group, order: [l[2].id, l[3].id, l[0].id, l[1].id], inSpace: space.id, context: ctx)

        XCTAssertTrue(ok)
        XCTAssertEqual(order(space, ctx), [l[2].id, l[3].id, l[0].id, l[1].id])
        XCTAssertEqual(l[0].groupID, group)
        XCTAssertEqual(l[1].groupID, group)
        XCTAssertNil(l[2].groupID)
        XCTAssertFalse(RailEdits.reorderGroup(UUID(), order: [], inSpace: space.id, context: ctx))
    }

    func testGroupMovePromptNamesTheServices() {
        let unnamed = AppState.groupMovePrompt(name: nil, labels: ["Gmail", "Slack", "Teams"], spaceName: "Home")
        XCTAssertEqual(unnamed.title, "Move these services to Home?")
        XCTAssertTrue(unnamed.message.contains("Gmail, Slack and Teams"))
        XCTAssertTrue(unnamed.message.contains("sign-in"))
        XCTAssertEqual(unnamed.confirm, "Move")
        let named = AppState.groupMovePrompt(name: "Mail", labels: ["Gmail", "Slack"], spaceName: "Home")
        XCTAssertEqual(named.title, "Move Mail to Home?")
    }

    // MARK: - Launch repair and runs

    func testRepairGroupsFixesASplitRunAndAOneMemberGroup() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c", "d"], in: ctx)
        let split = ServiceGroup(spaceID: space.id)
        let lone = ServiceGroup(spaceID: space.id)
        ctx.insert(split)
        ctx.insert(lone)
        l[0].groupID = split.id
        l[2].groupID = split.id
        l[3].groupID = lone.id
        try ctx.save()

        XCTAssertTrue(RailEdits.repairGroups(context: ctx))

        XCTAssertNil(l[3].groupID)
        XCTAssertEqual(try groups(ctx).map(\.id), [split.id])
        XCTAssertEqual(l[0].groupID, split.id)
        XCTAssertEqual(l[2].groupID, split.id)
        XCTAssertNil(l[1].groupID)
        XCTAssertEqual(order(space, ctx), [l[0].id, l[2].id, l[1].id, l[3].id])
        XCTAssertFalse(RailEdits.repairGroups(context: ctx))
    }

    func testRepairGroupsDeletesAGroupWhoseSpaceIsGone() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        ctx.insert(ServiceGroup(spaceID: UUID()))
        try ctx.save()

        XCTAssertTrue(RailEdits.repairGroups(context: ctx))

        XCTAssertTrue(try groups(ctx).isEmpty)
        XCTAssertFalse(RailEdits.repairGroups(context: ctx))
    }

    private func items(_ l: [SpaceServiceLink]) -> [RailItem] {
        l.map { .member($0, $0.service!) }
    }

    func testRunsDrawAOneMemberGroupAsARow() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, _, l) = try makeSpace("Work", order: 0, services: ["a", "b"], in: ctx)
        let g = UUID()
        let runs = RailRuns.runs(items(l), groupOf: { $0 == l[0].id ? g : nil }, nameOf: { _ in nil })
        XCTAssertEqual(runs.count, 2)
        for run in runs { if case .group = run { XCTFail("drew a box") } }
        XCTAssertNil(RailRuns.litGroup(in: runs))
    }

    func testRunsDrawASplitGroupAsRows() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, _, l) = try makeSpace("Work", order: 0, services: ["a", "x", "b"], in: ctx)
        let g = UUID()
        let runs = RailRuns.runs(items(l), groupOf: { $0 == l[1].id ? nil : g }, nameOf: { _ in nil })
        XCTAssertEqual(runs.count, 3)
        for run in runs { if case .group = run { XCTFail("drew a box") } }
    }

    func testRunsBoxAWholeRun() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, _, l) = try makeSpace("Work", order: 0, services: ["a", "b", "c"], in: ctx)
        let g = UUID()
        let runs = RailRuns.runs(items(l), groupOf: { $0 == l[2].id ? nil : g }, nameOf: { _ in "Mail" })
        XCTAssertEqual(runs.count, 2)
        guard case .group(let id, let name, let boxed, let holds) = runs[0] else { return XCTFail("no box") }
        XCTAssertEqual(id, g)
        XCTAssertEqual(name, "Mail")
        XCTAssertEqual(boxed.map(\.id), [l[0].id, l[1].id])
        XCTAssertFalse(holds)
        guard case .row(let r) = runs[1] else { return XCTFail("no row") }
        XCTAssertEqual(r.id, l[2].id)
    }

    func testRunsKeepTheBoxRoundADraggedRowInsideIt() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, _, l) = try makeSpace("Work", order: 0, services: ["a", "x", "b"], in: ctx)
        let g = UUID()
        let runs = RailRuns.runs(
            items(l), groupOf: { $0 == l[1].id ? nil : g }, nameOf: { _ in nil }, dragged: l[1].id
        )
        XCTAssertEqual(runs.count, 1)
        guard case .group(let id, _, let boxed, let holds) = runs[0] else { return XCTFail("no box") }
        XCTAssertEqual(id, g)
        XCTAssertEqual(boxed.count, 3)
        XCTAssertTrue(holds)
        XCTAssertEqual(RailRuns.litGroup(in: runs), g)
    }

    func testRunsKeepTheBoxRoundADraggedMemberOfAnotherGroup() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (_, _, l) = try makeSpace("Work", order: 0, services: ["a", "x", "b", "c", "d"], in: ctx)
        let g1 = UUID(), g2 = UUID()
        let groups: [UUID: UUID] = [l[0].id: g1, l[1].id: g2, l[2].id: g1, l[3].id: g2, l[4].id: g2]
        let runs = RailRuns.runs(items(l), groupOf: { groups[$0] }, nameOf: { _ in nil }, dragged: l[1].id)
        XCTAssertEqual(runs.count, 2)
        guard case .group(let id1, _, let first, let holds) = runs[0] else { return XCTFail("no g1 box") }
        XCTAssertEqual(id1, g1)
        XCTAssertEqual(first.map(\.id), [l[0].id, l[1].id, l[2].id])
        XCTAssertTrue(holds)
        guard case .group(let id2, _, let second, let holds2) = runs[1] else { return XCTFail("no g2 box") }
        XCTAssertEqual(id2, g2)
        XCTAssertEqual(second.map(\.id), [l[3].id, l[4].id])
        XCTAssertFalse(holds2)
        XCTAssertEqual(RailRuns.litGroup(in: runs), g1)
    }

    func testRunsDoNotHoldADraggedDivider() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let (space, _, l) = try makeSpace("Work", order: 0, services: ["a", "b"], in: ctx)
        let divider = RailDivider(kind: .services, spaceID: space.id, sortOrder: 5)
        ctx.insert(divider)
        let g = UUID()
        let list: [RailItem] = [.member(l[0], l[0].service!), .divider(divider), .member(l[1], l[1].service!)]
        let runs = RailRuns.runs(list, groupOf: { _ in g }, nameOf: { _ in nil }, dragged: divider.id)
        XCTAssertEqual(runs.count, 3)
        for run in runs { if case .group = run { XCTFail("drew a box") } }
        XCTAssertNil(RailRuns.litGroup(in: runs))
    }
}
