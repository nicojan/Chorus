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

    func testProcessPoolManager() {
        let manager = ProcessPoolManager()
        let id = UUID()

        let pool1 = manager.processPool(for: id)
        let pool2 = manager.processPool(for: id)
        XCTAssertTrue(pool1 === pool2, "Same ID should return same pool")

        let otherId = UUID()
        let pool3 = manager.processPool(for: otherId)
        XCTAssertFalse(pool1 === pool3, "Different IDs should return different pools")

        manager.removePool(for: id)
        let pool4 = manager.processPool(for: id)
        XCTAssertFalse(pool1 === pool4, "After removal, should create new pool")
    }
}
