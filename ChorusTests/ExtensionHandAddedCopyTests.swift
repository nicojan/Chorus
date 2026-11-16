import XCTest
@testable import Chorus
@testable import ChorusEngine

/// A catalog row knowing an extension the user added by hand under one of the
/// entry's names, so it does not offer a second copy. The copy is never
/// adopted: it keeps no catalog id and never updates.
@MainActor
final class ExtensionHandAddedCopyTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-hand-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    private let bitwarden = ExtensionCatalogEntry(
        id: "bitwarden", name: "Bitwarden", summary: "Fills in passwords.", category: .passwords, licence: "GPL-3.0",
        source: .github(owner: "bitwarden", repo: "clients", assetPattern: "dist-chrome-*.zip", tagPrefix: "browser-v"),
        testedVersion: "2026.10.2", knownGaps: nil, alsoNamed: ["Bitwarden Password Manager"]
    )

    private func entry(named name: String) -> ExtensionCatalogEntry {
        ExtensionCatalogEntry(id: name.lowercased(), name: name, summary: "A test extension.", category: .youtube,
                              licence: "MIT", source: .amo(slug: name.lowercased()), testedVersion: "1.0", knownGaps: nil)
    }

    private func record(_ name: String, catalogID: String? = nil, enabled: Bool = true,
                        source: WebExtensionRecord.Source? = nil) -> WebExtensionRecord {
        WebExtensionRecord(source: source ?? .package(folder: UUID().uuidString), name: name, isEnabled: enabled,
                           grantedPermissions: [], grantedMatchPatterns: [], catalogID: catalogID)
    }

    /// A manager over a list holding `records`. Their package folders need not
    /// exist: the match reads only the saved fields.
    private func manager(with records: [WebExtensionRecord]) throws -> ExtensionManager {
        try library.saveRecords(records)
        return ExtensionManager(library: library, storageIdentifier: nil)
    }

    // MARK: - The name rule

    func testIsNamedMatchesWholeNamesOnly() {
        XCTAssertTrue(bitwarden.isNamed("Bitwarden Password Manager"))
        XCTAssertTrue(bitwarden.isNamed(" bitwarden password manager\n"), "trimmed, case ignored")
        XCTAssertTrue(bitwarden.isNamed("Bitwarden"), "the catalog name counts too")
        XCTAssertFalse(bitwarden.isNamed("Bitwarden Authenticator"), "a separate Bitwarden product")
        XCTAssertFalse(bitwarden.isNamed("Bitwarden Password Manager Beta"))
        XCTAssertFalse(bitwarden.isNamed("Bitwarden Password"))
        XCTAssertFalse(bitwarden.isNamed(""))
        XCTAssertFalse(entry(named: "SponsorBlock").isNamed("DeArrow"))
    }

    func testBundledBitwardenListsItsBuildName() throws {
        let bundled = try XCTUnwrap(ExtensionCatalog.bundled.entry(id: "bitwarden"))
        XCTAssertTrue(bundled.alsoNamed?.contains("Bitwarden Password Manager") ?? false)
        XCTAssertTrue(bundled.isNamed("Bitwarden Password Manager"), "the name the GitHub Chrome build gives itself")
    }

    /// WebKit names an extension in the Mac's language, and Bitwarden
    /// translates its name, so a copy added on a German Mac is saved as
    /// "Bitwarden Passwortmanager". The list holds every name in the
    /// `_locales` of the tested build, 2026.10.2: 54 across 64 locales.
    func testBundledBitwardenKnowsItsTranslatedNames() throws {
        let bundled = try XCTUnwrap(ExtensionCatalog.bundled.entry(id: "bitwarden"))
        XCTAssertTrue(bundled.isNamed("Bitwarden Passwortmanager"))
        XCTAssertTrue(bundled.isNamed("Gestionnaire de mots de passe Bitwarden"))
        XCTAssertTrue(bundled.isNamed("Bitwarden パスワードマネージャー"))
        XCTAssertEqual(Set(bundled.alsoNamed ?? []).count, 54)
    }

    /// The other entries' names, read from their tested builds by
    /// `scripts/catalog_extension_names.py`: an AMO build and a GitHub build,
    /// each with its English name and a French one, and Proton Pass's AMO
    /// build, which has only an English one.
    func testBundledEntriesKnowTheirBuildNames() throws {
        let readAloud = try XCTUnwrap(ExtensionCatalog.bundled.entry(id: "read-aloud"))
        XCTAssertTrue(readAloud.isNamed("Read Aloud: A Text to Speech Voice Reader"))
        XCTAssertTrue(readAloud.isNamed("Read Aloud: Lecteur vocal de texte"))
        let sponsorBlock = try XCTUnwrap(ExtensionCatalog.bundled.entry(id: "sponsorblock"))
        XCTAssertTrue(sponsorBlock.isNamed("SponsorBlock for YouTube - Skip Sponsorships"))
        XCTAssertTrue(sponsorBlock.isNamed("SponsorBlock pour YouTube - Supprime les publicités intégrées"))
        let protonPass = try XCTUnwrap(ExtensionCatalog.bundled.entry(id: "proton-pass"))
        XCTAssertTrue(protonPass.isNamed("Proton Pass: Free Password Manager"))
    }

    func testEntryWithoutAlsoNamedStillDecodes() {
        let json = #"[{"id":"x","name":"X","summary":"S.","category":"privacy","licence":"MIT","testedVersion":"1.0","source":{"amo":{"slug":"x"}}}]"#
        let decoded = ExtensionCatalog.decode(Data(json.utf8))
        XCTAssertEqual(decoded.entries.map(\.id), ["x"])
        XCTAssertNil(decoded.entries.first?.alsoNamed)
    }

    /// Two rows claiming one record would both hide Get for it. Checked with
    /// `isNamed` itself, so the comparison is the one the rows use.
    func testNoNameBelongsToTwoEntries() {
        let entries = ExtensionCatalog.bundled.entries
        for entry in entries {
            for name in [entry.name] + (entry.alsoNamed ?? []) {
                let owners = entries.filter { $0.isNamed(name) }.map(\.id)
                XCTAssertEqual(owners, [entry.id], "\(name) belongs to \(owners)")
            }
        }
    }

    /// `alsoNamed` comes from the builds of one version. Bumping an entry's
    /// `testedVersion` fails here until the names are read again with
    /// `python3 -I scripts/catalog_extension_names.py` and `namesReadFrom`
    /// is set to the new version.
    func testNamesWereReadFromTheTestedVersion() {
        for entry in ExtensionCatalog.bundled.entries {
            XCTAssertEqual(entry.namesReadFrom, entry.testedVersion,
                           "\(entry.id): rerun scripts/catalog_extension_names.py for \(entry.testedVersion)")
        }
    }

    // MARK: - Finding the copy

    func testHandAddedCopyMatchesByNameEvenWhenOff() throws {
        let copy = record("Bitwarden Password Manager", enabled: false)
        let manager = try manager(with: [record("Bitwarden Authenticator"), copy])
        XCTAssertEqual(manager.handAddedCopy(of: bitwarden)?.id, copy.id)
        XCTAssertTrue(manager.isAdded(bitwarden))
        XCTAssertFalse(manager.isAdded(catalogID: "bitwarden"), "the copy is not taken for the catalog's")
    }

    func testOnlyTheOtherProductIsNoCopy() throws {
        let manager = try manager(with: [record("Bitwarden Authenticator")])
        XCTAssertNil(manager.handAddedCopy(of: bitwarden))
        XCTAssertFalse(manager.isAdded(bitwarden))
    }

    func testCatalogRecordIsNotAHandAddedCopy() throws {
        let manager = try manager(with: [record("Bitwarden", catalogID: "other")])
        XCTAssertNil(manager.handAddedCopy(of: bitwarden))
        XCTAssertFalse(manager.isAdded(bitwarden))
    }

    func testSafariHandAddedCopyCounts() throws {
        let safari = record("Bitwarden", source: .appExtension(path: "/Applications/Bitwarden.app/Contents/PlugIns/safari.appex"))
        let manager = try manager(with: [safari])
        XCTAssertEqual(manager.handAddedCopy(of: bitwarden)?.id, safari.id)
    }
}
