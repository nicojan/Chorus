import XCTest
@testable import Chorus
@testable import ChorusEngine

/// The bundled extension catalog: what it lists, in what order, and that each
/// entry reads in the engine's shape.
final class ExtensionCatalogTests: XCTestCase {
    private let pinnedIDs = [
        "bitwarden", "proton-pass", "ublock-origin-lite", "consent-o-matic",
        "simple-translate", "to-deepl", "obsidian-web-clipper", "raindrop", "read-aloud",
        "sponsorblock", "dearrow", "return-youtube-dislike",
    ]

    private var catalog: ExtensionCatalog { .bundled }

    /// Catches a typo the lossy decode would hide, and a renamed id.
    func testBundledCatalogHasTheTwelveCheckedEntries() {
        XCTAssertEqual(catalog.entries.map(\.id), pinnedIDs)
    }

    func testNoDarkReaderOrViolentmonkey() {
        let names = catalog.entries.flatMap { [$0.id.lowercased(), $0.name.lowercased()] }
        for banned in ["dark reader", "darkreader", "dark-reader", "violentmonkey"] {
            XCTAssertFalse(names.contains { $0.contains(banned) }, banned)
        }
    }

    func testYouTubeHelpersComeLast() throws {
        let last = try XCTUnwrap(catalog.sections.last)
        XCTAssertEqual(last.category, .youtube)
        XCTAssertEqual(last.entries.map(\.id), ["sponsorblock", "dearrow", "return-youtube-dislike"])
    }

    func testSectionsFollowCategoryOrder() {
        XCTAssertEqual(catalog.sections.map(\.category), ExtensionCatalogCategory.allCases)
    }

    func testEverySourceHasAnAPIAddress() {
        for entry in catalog.entries {
            XCTAssertNotNil(entry.source.apiURL, entry.id)
        }
    }

    func testEveryTestedVersionParses() {
        for entry in catalog.entries {
            XCTAssertNotNil(WebExtensionVersion(entry.testedVersion), entry.id)
        }
    }

    func testSourcesDecodeInTheEngineShape() {
        XCTAssertEqual(catalog.entry(id: "bitwarden")?.source,
                       .github(owner: "bitwarden", repo: "clients", assetPattern: "dist-chrome-*.zip", tagPrefix: "browser-v"))
        guard case .github(_, _, _, let prefix) = catalog.entry(id: "ublock-origin-lite")?.source else {
            return XCTFail("uBOL should come from GitHub")
        }
        XCTAssertNil(prefix)
        XCTAssertEqual(catalog.entry(id: "simple-translate")?.source, .amo(slug: "simple-translate"))
    }

    func testPublisherLineNamesWhereTheDownloadComesFrom() {
        XCTAssertEqual(catalog.entry(id: "bitwarden")?.publisherLine, "From bitwarden/clients on GitHub")
        XCTAssertEqual(catalog.entry(id: "simple-translate")?.publisherLine, "From addons.mozilla.org")
    }

    func testSummariesAreOneShortLine() {
        for entry in catalog.entries {
            XCTAssertFalse(entry.summary.contains("\n"), entry.id)
            XCTAssertLessThanOrEqual(entry.summary.count, 80, entry.id)
            XCTAssertFalse(entry.summary.isEmpty, entry.id)
            XCTAssertFalse(entry.licence.isEmpty, entry.id)
        }
    }

    func testOneBrokenEntryIsDroppedNotTheList() {
        let json = #"""
        [
         {"id":"a","name":"A","category":"privacy","licence":"MIT","testedVersion":"1.0","summary":"A.",
          "source":{"amo":{"slug":"a"}}},
         {"id":"b","name":"B","category":"no-such-category","licence":"MIT","testedVersion":"1.0","summary":"B.",
          "source":{"amo":{"slug":"b"}}},
         {"id":"c","name":"C","category":"youtube","licence":"MIT","testedVersion":"1.0","summary":"C.",
          "source":{"github":{"owner":"o","repo":"r","assetPattern":"*.zip"}}}
        ]
        """#
        let decoded = ExtensionCatalog.decode(Data(json.utf8))
        XCTAssertEqual(decoded.entries.map(\.id), ["a", "c"])
    }

    func testUnreadableFileGivesAnEmptyCatalog() {
        XCTAssertTrue(ExtensionCatalog.decode(Data("{ nope".utf8)).entries.isEmpty)
    }
}
