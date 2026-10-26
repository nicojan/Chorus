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
}
