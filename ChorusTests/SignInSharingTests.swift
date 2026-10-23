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
            SignInSharing.newIdentifier(current: mine, target: partner.dataStoreIdentifier, isSharedNow: false),
            partner.dataStoreIdentifier
        )
        XCTAssertNil(
            SignInSharing.newIdentifier(current: partner.dataStoreIdentifier, target: partner.dataStoreIdentifier, isSharedNow: true),
            "already on the partner's store: nothing changes, and nobody is signed out"
        )
    }

    func testItsOwnGivesAFreshStoreOnlyWhenShared() {
        let current = UUID()
        let fresh = SignInSharing.newIdentifier(current: current, target: nil, isSharedNow: true)
        XCTAssertNotNil(fresh)
        XCTAssertNotEqual(fresh, current, "leaving a shared store must not keep using it")
        XCTAssertNil(
            SignInSharing.newIdentifier(current: current, target: nil, isSharedNow: false),
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

    // MARK: - Removing a store

    /// The guard every delete path goes through. A store another service
    /// still uses is never tombstoned, and neither is any store while the
    /// claims can't be read: removing a shared store signs out the services
    /// that remain, with no way back.
    func testTombstoningSparesAClaimedStoreAndAnUnreadableStore() {
        let shared = UUID(), alone = UUID(), earlier = UUID()

        XCTAssertEqual(
            AppState.tombstones(adding: shared, to: [earlier], claimed: [shared]),
            [earlier],
            "a store a remaining service uses must not be tombstoned"
        )
        XCTAssertEqual(
            AppState.tombstones(adding: alone, to: [earlier], claimed: [shared]),
            [earlier, alone],
            "a store nobody uses any more is"
        )
        XCTAssertEqual(
            AppState.tombstones(adding: alone, to: [earlier], claimed: nil),
            [earlier],
            "unreadable claims are unknown, never empty"
        )
        XCTAssertEqual(AppState.tombstones(adding: alone, to: [], claimed: []), [alone], "no services at all: nothing claims it")
    }

    /// A Mac app has no cookies, so it is never shown or counted as a partner.
    func testAMacAppIsNeverASignInPartner() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let gmail = ServiceInstance(label: "Gmail", url: "https://mail.google.com")
        let app = ServiceInstance(label: "LINE", url: NativeApp.serviceURL(forBundleID: "jp.naver.line.mac"),
                                  dataStoreIdentifier: gmail.dataStoreIdentifier)
        [gmail, app].forEach(ctx.insert)
        try ctx.save()
        XCTAssertTrue(SignInSharing.partners(of: gmail, among: try ctx.fetch(FetchDescriptor<ServiceInstance>())).isEmpty)
    }

    /// A service in two groups would end up in whichever came last and split
    /// the first, so a file that does that is refused.
    func testSetupFileWithOverlappingGroupsIsRefused() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let space = Space(name: "Home", emoji: "🏠", sortOrder: 0)
        let services = ["a", "b", "c"].map { ServiceInstance(label: $0, url: "https://\($0).example") }
        ctx.insert(space)
        services.forEach(ctx.insert)
        try ctx.save()
        for (order, service) in services.enumerated() { link(service, to: space, order: order, in: ctx) }
        try ctx.save()

        var archive = try SetupArchive.capture(from: ctx, appVersion: nil)
        archive.sharedSignIns = [[0, 1], [1, 2]]
        XCTAssertThrowsError(try SetupArchive.decode(try archive.encoded()))
        archive.sharedSignIns = [[0, 1, 2]]
        XCTAssertNoThrow(try SetupArchive.decode(try archive.encoded()))
    }

    // MARK: - Shared sign-ins by default

    func testNewServicesShareTheirPlacesSignInUnlessKeptSeparate() {
        let space = UUID()
        XCTAssertEqual(ServiceAdding.store(for: .init(spaceID: space)), space, "a space's services share its store")
        XCTAssertEqual(ServiceAdding.store(for: .init(spaceID: space, global: true)), ServiceAdding.globalStore)
        let separate = ServiceAdding.store(for: .init(spaceID: space, separate: true))
        XCTAssertNotEqual(separate, space)
        XCTAssertNotEqual(separate, ServiceAdding.globalStore)
        XCTAssertNotEqual(separate, ServiceAdding.store(for: .init(spaceID: space, separate: true)), "each separate one is its own")
        XCTAssertTrue(SignInSharing.isSharedStore(space, spaceIDs: [space]))
        XCTAssertTrue(SignInSharing.isSharedStore(ServiceAdding.globalStore, spaceIDs: []))
        XCTAssertFalse(SignInSharing.isSharedStore(separate, spaceIDs: [space]))
    }

    func testSiteKeyMatchesACatalogEntryOrAHost() {
        XCTAssertEqual(ServiceAdding.siteKey(catalogEntryID: "gmail", url: "https://x.example"), "catalog:gmail")
        XCTAssertEqual(
            ServiceAdding.siteKey(catalogEntryID: nil, url: "https://www.Notion.so/workspace"),
            ServiceAdding.siteKey(catalogEntryID: nil, url: "https://notion.so")
        )
        XCTAssertNil(ServiceAdding.siteKey(catalogEntryID: nil, url: "not a url"))
    }

    /// A second copy of a site is only a question when the new one would land
    /// on the same store as the first: the two would open one account.
    func testASecondCopyIsFoundOnlyOnTheStoreItWouldShare() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let work = Space(name: "Work", emoji: "💼", sortOrder: 0)
        let home = Space(name: "Home", emoji: "🏠", sortOrder: 1)
        let gmail = ServiceInstance(label: "Gmail", url: "https://mail.google.com", catalogEntryID: "gmail",
                                    dataStoreIdentifier: ServiceAdding.sharedStore(forSpace: work.id))
        let ownSlack = ServiceInstance(label: "Slack", url: "https://slack.com")
        [work, home].forEach(ctx.insert)
        [gmail, ownSlack].forEach(ctx.insert)
        try ctx.save()

        let sameSpace = ServiceAdding.Destination(spaceID: work.id)
        XCTAssertEqual(
            ServiceAdding.sameSiteOnSharedStore(catalogEntryID: "gmail", url: "https://mail.google.com", destination: sameSpace, context: ctx)?.id,
            gmail.id
        )
        XCTAssertNil(
            ServiceAdding.sameSiteOnSharedStore(catalogEntryID: "gmail", url: "https://mail.google.com", destination: .init(spaceID: work.id, separate: true), context: ctx),
            "keeping it separate is the answer already"
        )
        XCTAssertNil(
            ServiceAdding.sameSiteOnSharedStore(catalogEntryID: "gmail", url: "https://mail.google.com", destination: .init(spaceID: home.id), context: ctx),
            "another space's sign-in is another account"
        )
        XCTAssertNil(
            ServiceAdding.sameSiteOnSharedStore(catalogEntryID: nil, url: "https://slack.com", destination: sameSpace, context: ctx),
            "a Slack on its own store shares nothing with a new one"
        )
    }

    func testPlacingANewServiceInASpaceOrInEverySpace() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let work = Space(name: "Work", emoji: "💼", sortOrder: 0)
        ctx.insert(work)
        try ctx.save()
        let divider = try XCTUnwrap(RailEdits.addDivider(in: .space(work.id), after: nil, context: ctx))

        let inSpace = ServiceInstance(label: "Docs", url: "https://docs.google.com",
                                      dataStoreIdentifier: ServiceAdding.store(for: .init(spaceID: work.id)))
        ctx.insert(inSpace)
        XCTAssertTrue(ServiceAdding.place(inSpace, at: .init(spaceID: work.id), context: ctx))
        let everywhere = ServiceInstance(label: "Calendar", url: "https://calendar.google.com")
        ctx.insert(everywhere)
        XCTAssertTrue(ServiceAdding.place(everywhere, at: .init(spaceID: work.id, global: true), context: ctx))
        try ctx.save()

        XCTAssertEqual(RailEdits.entries(in: .space(work.id), context: ctx).map(\.id).first, divider)
        XCTAssertEqual(RailEdits.links(inSpace: work.id, context: ctx).compactMap(\.liveService?.id), [inSpace.id], "past the divider")
        XCTAssertTrue(everywhere.isGlobalEffective)
        XCTAssertTrue(RailEdits.links(inSpace: work.id, context: ctx).allSatisfy { $0.liveService?.id != everywhere.id }, "a global service has no link")
        XCTAssertEqual(inSpace.dataStoreIdentifier, work.id)
    }

    // MARK: - Moving between spaces

    func testMovingAMembershipKeepsTheServiceAndItsStore() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let work = Space(name: "Work", emoji: "💼", sortOrder: 0)
        let home = Space(name: "Home", emoji: "🏠", sortOrder: 1)
        let slack = ServiceInstance(label: "Slack", url: "https://slack.com", dataStoreIdentifier: work.id)
        let mail = ServiceInstance(label: "Mail", url: "https://mail.example")
        [work, home].forEach(ctx.insert)
        [slack, mail].forEach(ctx.insert)
        try ctx.save()
        link(slack, to: work, order: 0, in: ctx)
        link(mail, to: home, order: 0, in: ctx)
        try ctx.save()
        let linkID = try XCTUnwrap(RailEdits.links(inSpace: work.id, context: ctx).first?.id)
        let mailLink = try XCTUnwrap(RailEdits.links(inSpace: home.id, context: ctx).first?.id)

        XCTAssertTrue(RailEdits.moveMembership(linkID, toSpace: home.id, before: mailLink, context: ctx))

        XCTAssertTrue(RailEdits.links(inSpace: work.id, context: ctx).isEmpty)
        let order = RailEdits.links(inSpace: home.id, context: ctx).sorted { $0.sortOrder < $1.sortOrder }.compactMap(\.liveService?.label)
        XCTAssertEqual(order, ["Slack", "Mail"])
        XCTAssertEqual(slack.dataStoreIdentifier, work.id, "its cookies come with it")
        XCTAssertFalse(RailEdits.moveMembership(linkID, toSpace: home.id, context: ctx), "already there")
    }

    func testListedNamesReadAsASentence() {
        XCTAssertEqual(AppState.listed([]), "")
        XCTAssertEqual(AppState.listed(["Gmail"]), "Gmail")
        XCTAssertEqual(AppState.listed(["Gmail", "Drive"]), "Gmail and Drive")
        XCTAssertEqual(AppState.listed(["Gmail", "Drive", "Docs"]), "Gmail, Drive and Docs")
    }

    // MARK: - Reused store ids

    /// The rule that stops the removal pass taking a store a service has
    /// just claimed again: a space's store id, or the global one, comes back
    /// when a service is added after the last one there was deleted.
    func testRemovalLeavesAStoreAServiceClaimedAgain() {
        let store = UUID(), other = UUID()
        XCTAssertEqual(AppState.removalDecision(for: store, claimedNow: [store], inUseOffscreen: []), .keep)
        XCTAssertEqual(AppState.removalDecision(for: store, claimedNow: [other], inUseOffscreen: []), .remove)
        XCTAssertEqual(AppState.removalDecision(for: store, claimedNow: nil, inUseOffscreen: []), .wait, "unreadable claims are unknown")
        XCTAssertEqual(AppState.removalDecision(for: store, claimedNow: [], inUseOffscreen: [store]), .wait, "an offscreen view still has it")
        XCTAssertEqual(AppState.removalDecision(for: store, claimedNow: [store], inUseOffscreen: [store]), .keep)
    }

    func testChatSitesAreKnownByCatalogEntryOrHost() {
        let chat = ServiceCatalog.shared.entries.first { ServiceInstance.notificationCriticalCategories.contains($0.category) }
        let notChat = ServiceCatalog.shared.entries.first { !ServiceInstance.notificationCriticalCategories.contains($0.category) }
        if let chat {
            XCTAssertTrue(ServiceAdding.isChat(catalogEntryID: chat.id, url: chat.url))
            XCTAssertTrue(ServiceAdding.isChat(catalogEntryID: nil, url: chat.url), "a custom address of a chat site")
        }
        if let notChat {
            XCTAssertFalse(ServiceAdding.isChat(catalogEntryID: notChat.id, url: notChat.url))
        }
        XCTAssertFalse(ServiceAdding.isChat(catalogEntryID: nil, url: "https://nothing-chat.example"))
        XCTAssertNotNil(chat, "the catalog has chat services to test against")
    }
}
