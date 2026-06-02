import XCTest
@testable import Chorus

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
}
