import XCTest
import SwiftData
@testable import Chorus

/// Shared sign-ins (issue #39): the rules for picking a store, and the setup
/// file carrying which services share one.
@MainActor
final class SignInSharingTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    /// Commits the ends before building the link: building one wires the
    /// inverses, and a second insert is fatal on macOS 14.
    private func link(_ service: ServiceInstance, to space: Space, order: Int, in ctx: ModelContext) {
        let link = SpaceServiceLink(sortOrder: order, space: space, service: service)
        if link.modelContext == nil { ctx.insert(link) }
    }

    // MARK: - Choosing a store

    func testSharingTakesThePartnersStore() {
        let partner = ServiceInstance(label: "Gmail", url: "https://mail.google.com")
        let mine = UUID()
        XCTAssertEqual(
            SignInSharing.newIdentifier(current: mine, sharingWith: partner, isSharedNow: false),
            partner.dataStoreIdentifier
        )
        XCTAssertNil(
            SignInSharing.newIdentifier(current: partner.dataStoreIdentifier, sharingWith: partner, isSharedNow: true),
            "already on the partner's store: nothing changes, and nobody is signed out"
        )
    }

    func testItsOwnGivesAFreshStoreOnlyWhenShared() {
        let current = UUID()
        let fresh = SignInSharing.newIdentifier(current: current, sharingWith: nil, isSharedNow: true)
        XCTAssertNotNil(fresh)
        XCTAssertNotEqual(fresh, current, "leaving a shared store must not keep using it")
        XCTAssertNil(
            SignInSharing.newIdentifier(current: current, sharingWith: nil, isSharedNow: false),
            "a service on its own store keeps it, and its sign-in"
        )
    }

    func testPartnersAreTheOtherServicesOnTheSameStore() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let gmail = ServiceInstance(label: "Gmail", url: "https://mail.google.com")
        let calendar = ServiceInstance(label: "Calendar", url: "https://calendar.google.com",
                                       dataStoreIdentifier: gmail.dataStoreIdentifier)
        let slack = ServiceInstance(label: "Slack", url: "https://slack.com")
        [gmail, calendar, slack].forEach(ctx.insert)
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<ServiceInstance>())

        XCTAssertEqual(SignInSharing.partners(of: gmail, among: all).map(\.label), ["Calendar"])
        XCTAssertEqual(SignInSharing.partners(of: calendar, among: all).map(\.label), ["Gmail"])
        XCTAssertTrue(SignInSharing.partners(of: slack, among: all).isEmpty)
    }

    // MARK: - The setup file

    func testSharedGroupsAreTwoOrMoreAndInOrder() {
        let a = UUID(), b = UUID()
        let groups = SetupArchive.sharedSignInGroups(storeByIndex: [0: a, 1: b, 2: a, 3: UUID(), 4: b, 5: b])
        XCTAssertEqual(groups, [[0, 2], [1, 4, 5]])
        XCTAssertTrue(SetupArchive.sharedSignInGroups(storeByIndex: [0: a, 1: b]).isEmpty)
    }

    /// Export then import: services that shared a store on this Mac share one
    /// fresh store on the other, and a service that shared nothing stays alone.
    func testSetupCarriesSharedSignInsAsOneFreshStorePerGroup() throws {
        let source = try makeContainer()
        let src = source.mainContext
        let space = Space(name: "Google", emoji: "🔎", sortOrder: 0)
        let gmail = ServiceInstance(label: "Gmail", url: "https://mail.google.com")
        let drive = ServiceInstance(label: "Drive", url: "https://drive.google.com",
                                    dataStoreIdentifier: gmail.dataStoreIdentifier)
        let calendar = ServiceInstance(label: "Calendar", url: "https://calendar.google.com",
                                       dataStoreIdentifier: gmail.dataStoreIdentifier,
                                       isGlobal: true, globalSortOrder: 0)
        let slack = ServiceInstance(label: "Slack", url: "https://slack.com")
        src.insert(space)
        [gmail, drive, calendar, slack].forEach(src.insert)
        try src.save()
        link(gmail, to: space, order: 0, in: src)
        link(drive, to: space, order: 1, in: src)
        link(slack, to: space, order: 2, in: src)
        try src.save()

        let archive = try SetupArchive.decode(try SetupArchive.capture(from: src, appVersion: nil).encoded())
        let groups = try XCTUnwrap(archive.sharedSignIns)
        XCTAssertEqual(groups.map { $0.map { archive.services[$0].label }.sorted() }, [["Calendar", "Drive", "Gmail"]])

        let target = try makeContainer()
        let dst = target.mainContext
        _ = try archive.apply(to: dst)
        let imported = try dst.fetch(FetchDescriptor<ServiceInstance>())
        let store = Dictionary(uniqueKeysWithValues: imported.map { ($0.label, $0.dataStoreIdentifier) })

        XCTAssertEqual(store["Gmail"], store["Drive"])
        XCTAssertEqual(store["Gmail"], store["Calendar"], "a global service shares too")
        XCTAssertNotEqual(store["Gmail"], store["Slack"])
        XCTAssertNotEqual(store["Gmail"], gmail.dataStoreIdentifier, "the sign-in itself never travels")
    }

    func testSetupFileWithABadSharedIndexIsRefused() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let space = Space(name: "Home", emoji: "🏠", sortOrder: 0)
        let gmail = ServiceInstance(label: "Gmail", url: "https://mail.google.com")
        ctx.insert(space)
        ctx.insert(gmail)
        try ctx.save()
        link(gmail, to: space, order: 0, in: ctx)
        try ctx.save()

        var archive = try SetupArchive.capture(from: ctx, appVersion: nil)
        archive.sharedSignIns = [[0, 7]]
        XCTAssertThrowsError(try SetupArchive.decode(try archive.encoded()))
    }
}
