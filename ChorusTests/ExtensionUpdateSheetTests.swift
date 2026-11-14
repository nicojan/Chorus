import XCTest
@testable import Chorus

/// The update review sheet lists every new ask, as a line or by raw name.
final class ExtensionUpdateSheetTests: XCTestCase {
    func testPatternsWithNoSiteLineAreListedByName() {
        let asks = ExtensionUpdateSheet.asks(newPermissions: [], newMatchPatterns: ["file:///*"])

        XCTAssertEqual(asks.lines, [])
        XCTAssertEqual(asks.caption, "It also asks for: file:///*.")
    }

    func testQuietPermissionsAreListedByName() {
        let asks = ExtensionUpdateSheet.asks(newPermissions: ["alarms", "storage", "tabs"], newMatchPatterns: [])

        XCTAssertEqual(asks.lines, ["See the address and title of each page"])
        XCTAssertEqual(asks.caption, "It also asks for: alarms, storage.")
    }

    func testPatternsWithASiteLineStayOutOfTheCaption() {
        let asks = ExtensionUpdateSheet.asks(newPermissions: ["tabs"], newMatchPatterns: ["https://example.com/*"])

        XCTAssertEqual(asks.lines, ["Read and change pages on example.com", "See the address and title of each page"])
        XCTAssertNil(asks.caption)
    }

    func testQuietPermissionsAndUnreadablePatternsShareTheCaption() {
        let asks = ExtensionUpdateSheet.asks(newPermissions: ["storage"], newMatchPatterns: ["file:///*"])

        XCTAssertEqual(asks.lines, [])
        XCTAssertEqual(asks.caption, "It also asks for: storage, file:///*.")
    }
}
