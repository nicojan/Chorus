import XCTest
@testable import ChorusEngine

/// What an update asks for that the user has not granted. Uses WebKit's match
/// patterns, so it needs macOS 15.4.
@MainActor
final class WebExtensionUpdateReviewTests: XCTestCase {
    private func newPatterns(_ requested: [String], granted: [String]) throws -> [String] {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        return WebExtensionUpdateReview.newRequests(
            permissions: [], matchPatterns: requested,
            grantedPermissions: [], grantedMatchPatterns: granted
        ).matchPatterns
    }

    private func newPermissions(_ requested: [String], granted: [String]) throws -> [String] {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        return WebExtensionUpdateReview.newRequests(
            permissions: requested, matchPatterns: [],
            grantedPermissions: granted, grantedMatchPatterns: []
        ).permissions
    }

    func testNativeMessagingIsIgnored() throws {
        XCTAssertEqual(try newPermissions(["nativeMessaging", "storage"], granted: ["storage"]), [],
                       "Chorus can never grant it, so it is never an ask")
    }

    func testNewPermissionIsFound() throws {
        XCTAssertEqual(try newPermissions(["tabs", "storage", "alarms", "tabs"], granted: ["storage"]), ["alarms", "tabs"],
                       "every new permission waits, quiet ones too, sorted and once each")
        XCTAssertEqual(try newPermissions(["storage"], granted: ["storage", "tabs"]), [], "asking for less is no ask")
    }

    func testBroadGrantCoversNarrowRequest() throws {
        XCTAssertEqual(try newPatterns(["https://a.example/*"], granted: ["<all_urls>"]), [])
        XCTAssertEqual(try newPatterns(["https://a.example/page/*"], granted: ["*://*.example/*"]), [])
        XCTAssertEqual(try newPatterns(["https://a.example/*"], granted: ["https://a.example/*"]), [], "an exact match")
    }

    func testNarrowGrantDoesNotCoverBroadRequest() throws {
        XCTAssertEqual(try newPatterns(["<all_urls>"], granted: ["https://a.example/*"]), ["<all_urls>"])
        XCTAssertEqual(try newPatterns(["*://*.example/*"], granted: ["https://a.example/*"]), ["*://*.example/*"])
        XCTAssertEqual(try newPatterns(["https://b.example/*"], granted: ["https://a.example/*"]), ["https://b.example/*"])
    }

    func testEverySiteFormsCoverEachOther() throws {
        XCTAssertEqual(try newPatterns(["<all_urls>"], granted: ["*://*/*"]), [])
        XCTAssertEqual(try newPatterns(["*://*/*"], granted: ["<all_urls>"]), [])
        XCTAssertEqual(try newPatterns(["https://*/*"], granted: ["<all_urls>"]), [])
    }

    /// Every host is not every site: the scheme and path still count.
    func testEveryHostOnOneSchemeIsNotEverySite() throws {
        XCTAssertEqual(try newPatterns(["*://*/*"], granted: ["https://*/*"]), ["*://*/*"], "http pages are new")
        XCTAssertEqual(try newPatterns(["<all_urls>"], granted: ["https://*/*"]), ["<all_urls>"])
        XCTAssertEqual(try newPatterns(["<all_urls>"], granted: ["https://*/login"]), ["<all_urls>"])
        XCTAssertEqual(try newPatterns(["https://*/*"], granted: ["https://*/login"]), ["https://*/*"])
    }

    func testPathIsCompared() throws {
        XCTAssertEqual(try newPatterns(["https://a.example/*"], granted: ["https://a.example/page/*"]), ["https://a.example/*"])
        XCTAssertEqual(try newPatterns(["https://a.example/page/*"], granted: ["https://a.example/*"]), [])
    }

    func testUnparseableRequestIsNew() throws {
        XCTAssertEqual(try newPatterns(["not a pattern"], granted: ["<all_urls>"]), ["not a pattern"])
        XCTAssertEqual(try newPatterns(["not a pattern"], granted: ["not a pattern"]), [], "unless granted as the same string")
    }

    func testUnparseableGrantIsSkipped() throws {
        XCTAssertEqual(try newPatterns(["https://a.example/*"], granted: ["garbage", "https://a.example/*"]), [])
        XCTAssertEqual(try newPatterns(["https://a.example/*"], granted: ["garbage"]), ["https://a.example/*"])
    }
}
