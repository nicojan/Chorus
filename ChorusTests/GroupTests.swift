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
}
