import Foundation
import XCTest
@testable import ChorusEngine

final class BundledResourceTests: XCTestCase {
    func testBlocklistsLoadFromTheModuleBundleAndParse() throws {
        for name in ["hagezi-light", "fanboy-annoyance"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"), "\(name).json is missing")
            let data = try Data(contentsOf: url)
            XCTAssertFalse(data.isEmpty, "\(name).json is empty")
            let parsed = try JSONSerialization.jsonObject(with: data) as? [Any]
            XCTAssertFalse(try XCTUnwrap(parsed, "\(name).json is not a JSON array").isEmpty)
            XCTAssertEqual(ContentBlockerManager.bundledListURL(name)?.lastPathComponent, "\(name).json")
        }
    }

    func testNoticesAndLicensesTravelWithTheBundle() {
        XCTAssertNotNil(Bundle.module.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"))
        for name in ["GPL-3.0", "CC-BY-3.0", "DarkReader-MIT"] {
            XCTAssertNotNil(
                Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "licenses"),
                "licenses/\(name).txt is missing from the engine bundle"
            )
        }
    }

    func testDarkReaderLibraryLoadsFromTheModuleBundle() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "darkreader", withExtension: "js"), "darkreader.js is missing")
        XCTAssertFalse(try Data(contentsOf: url).isEmpty, "darkreader.js is empty")
        XCTAssertEqual(DarkReaderSupport.libraryURL?.lastPathComponent, "darkreader.js")
    }
}
