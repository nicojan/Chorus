import XCTest
@testable import ChorusEngine

/// The extension list on disk, importing packages, finding Safari extensions,
/// and the words shown before adding one.
final class WebExtensionLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var library: WebExtensionLibrary {
        WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
    }

    // MARK: - Records

    func testRecordsRoundTrip() throws {
        let records = [
            WebExtensionRecord(source: .appExtension(path: "/Applications/A.app/Contents/PlugIns/A.appex"), name: "A",
                               grantedPermissions: ["tabs"], grantedMatchPatterns: ["<all_urls>"]),
            WebExtensionRecord(source: .package(folder: UUID().uuidString), name: "B", isEnabled: false,
                               grantedPermissions: [], grantedMatchPatterns: []),
        ]
        try library.saveRecords(records)
        let loaded = library.loadRecords()
        XCTAssertEqual(loaded.map(\.id), records.map(\.id))
        XCTAssertEqual(loaded.map(\.source), records.map(\.source))
        XCTAssertEqual(loaded.map(\.isEnabled), [true, false])
        XCTAssertEqual(loaded[0].grantedMatchPatterns, ["<all_urls>"])
    }

    func testNoFileMeansNoRecords() {
        XCTAssertEqual(library.loadRecords(), [])
    }

    func testUnreadableListIsMovedAsideNotLost() throws {
        try FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: library.recordsFile)
        XCTAssertEqual(library.loadRecords(), [])
        let names = try FileManager.default.contentsOfDirectory(atPath: library.directory.path)
        XCTAssertFalse(names.contains("extensions.json"))
        XCTAssertTrue(names.contains { $0.hasPrefix("extensions.unreadable-") }, "the damaged file is kept to look at")
    }

    func testRecordChangesReturnNewRecords() {
        let record = WebExtensionRecord(source: .package(folder: "x"), name: "X", grantedPermissions: ["b", "a"], grantedMatchPatterns: [])
        let off = record.enabled(false)
        XCTAssertTrue(record.isEnabled)
        XCTAssertFalse(off.isEnabled)
        XCTAssertEqual(off.id, record.id)
        let granted = record.granting(permissions: ["tabs", "storage", "tabs"], matchPatterns: ["*://*.example.com/*"])
        XCTAssertEqual(granted.grantedPermissions, ["storage", "tabs"])
        XCTAssertEqual(record.grantedPermissions, ["b", "a"])
    }

    func testBaseURLIsStablePerRecord() {
        let id = UUID()
        let a = WebExtensionRecord(id: id, source: .package(folder: "x"), name: "X", grantedPermissions: [], grantedMatchPatterns: [])
        let b = WebExtensionRecord(id: id, source: .package(folder: "y"), name: "Y", grantedPermissions: [], grantedMatchPatterns: [])
        XCTAssertEqual(a.baseURL, b.baseURL, "storage is keyed by origin, so it must not change between launches")
        XCTAssertEqual(a.baseURL.scheme, "webkit-extension")
    }

    // MARK: - Importing

    private func makeExtensionFolder(at url: URL, name: String = "Probe") throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version": 3, "name": "\#(name)", "version": "1.0"}"#
        try Data(manifest.utf8).write(to: url.appending(path: "manifest.json"))
        try Data("// cs".utf8).write(to: url.appending(path: "cs.js"))
    }

    func testImportsAFolder() throws {
        let source = root.appending(path: "ext", directoryHint: .isDirectory)
        try makeExtensionFolder(at: source)
        let folder = try library.importPackage(from: source)
        XCTAssertNotNil(UUID(uuidString: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.packageURL(folder: folder).appending(path: "cs.js").path))
    }

    func testImportsAZipWithTheManifestOneFolderDown() throws {
        let staging = root.appending(path: "zipsrc", directoryHint: .isDirectory)
        try makeExtensionFolder(at: staging.appending(path: "dist-chrome", directoryHint: .isDirectory))
        let zip = root.appending(path: "ext.zip")
        try zipFolder(staging.appending(path: "dist-chrome"), to: zip, keepParent: true)
        let folder = try library.importPackage(from: zip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.packageURL(folder: folder).appending(path: "manifest.json").path))
    }

    func testReadsAZipsUnpackedSize() throws {
        let staging = root.appending(path: "sizesrc", directoryHint: .isDirectory)
        try makeExtensionFolder(at: staging)
        try Data(repeating: 0x41, count: 10_000).write(to: staging.appending(path: "big.js"))
        let zip = root.appending(path: "size.zip")
        try zipFolder(staging, to: zip, keepParent: false)
        let size = try WebExtensionLibrary.unpackedSize(ofZip: zip)
        XCTAssertGreaterThan(size, 10_000)
        XCTAssertLessThan(size, 11_000)
    }

    func testImportsACRX3() throws {
        let staging = root.appending(path: "crxsrc", directoryHint: .isDirectory)
        try makeExtensionFolder(at: staging)
        let zip = root.appending(path: "payload.zip")
        try zipFolder(staging, to: zip, keepParent: false)
        let header = Data([0x43, 0x72, 0x32, 0x34, 3, 0, 0, 0, 4, 0, 0, 0, 9, 9, 9, 9])
        let crx = root.appending(path: "ext.crx")
        try (header + Data(contentsOf: zip)).write(to: crx)
        let folder = try library.importPackage(from: crx)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.packageURL(folder: folder).appending(path: "manifest.json").path))
    }

    func testCRXParsing() {
        XCTAssertNil(WebExtensionLibrary.zipPayload(ofCRX: Data("PK\u{3}\u{4}plain zip".utf8)))
        let v2 = Data([0x43, 0x72, 0x32, 0x34, 2, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0xAA, 0xBB, 0xCC, 0x50, 0x4B, 3, 4, 7])
        XCTAssertEqual(WebExtensionLibrary.zipPayload(ofCRX: v2), Data([0x50, 0x4B, 3, 4, 7]))
        let wrongOffset = Data([0x43, 0x72, 0x32, 0x34, 3, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5])
        XCTAssertNil(WebExtensionLibrary.zipPayload(ofCRX: wrongOffset))
    }

    func testRejectsAFolderWithoutAManifest() throws {
        let source = root.appending(path: "notext", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertThrowsError(try library.importPackage(from: source)) {
            XCTAssertEqual($0 as? WebExtensionLibrary.ImportError, .noManifest)
        }
    }

    func testRejectsAManifestThatIsNotOne() throws {
        let source = root.appending(path: "bad", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"name": "no version"}"#.utf8).write(to: source.appending(path: "manifest.json"))
        XCTAssertThrowsError(try library.importPackage(from: source)) {
            XCTAssertEqual($0 as? WebExtensionLibrary.ImportError, .unreadableManifest)
        }
    }

    func testRejectsAnUnknownFileType() throws {
        let file = root.appending(path: "ext.dmg")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try library.importPackage(from: file)) {
            XCTAssertEqual($0 as? WebExtensionLibrary.ImportError, .unsupportedArchive)
        }
    }

    func testRemovePackageOnlyTouchesLibraryFolders() throws {
        let outside = root.appending(path: "keep", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        library.removePackage(folder: "../../keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "a non-UUID folder name is refused")

        let source = root.appending(path: "ext", directoryHint: .isDirectory)
        try makeExtensionFolder(at: source)
        let folder = try library.importPackage(from: source)
        library.removePackage(folder: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.packageURL(folder: folder).path))
    }

    func testRejectsAPackageWithASymbolicLink() throws {
        let source = root.appending(path: "linked", directoryHint: .isDirectory)
        try makeExtensionFolder(at: source)
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "icon.png"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        XCTAssertThrowsError(try library.importPackage(from: source)) {
            XCTAssertEqual($0 as? WebExtensionLibrary.ImportError, .containsLinks)
        }
    }

    func testRejectsAZipCarryingASymbolicLink() throws {
        let staging = root.appending(path: "zlink", directoryHint: .isDirectory)
        try makeExtensionFolder(at: staging)
        try FileManager.default.createSymbolicLink(
            at: staging.appending(path: "key"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        let zip = root.appending(path: "linked.zip")
        try zipFolder(staging, to: zip, keepParent: false)
        XCTAssertThrowsError(try library.importPackage(from: zip)) {
            XCTAssertEqual($0 as? WebExtensionLibrary.ImportError, .containsLinks)
        }
    }

    func testSweepRemovesOnlyUnusedPackages() throws {
        let keep = try library.importPackage(from: { let u = root.appending(path: "a", directoryHint: .isDirectory); try makeExtensionFolder(at: u); return u }())
        let drop = try library.importPackage(from: { let u = root.appending(path: "b", directoryHint: .isDirectory); try makeExtensionFolder(at: u); return u }())
        library.removeUnusedPackages(keeping: [keep])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.packageURL(folder: keep).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.packageURL(folder: drop).path))
    }

    func testSweepWaitsWhileTheListIsUnreadable() throws {
        let folder = try library.importPackage(from: { let u = root.appending(path: "c", directoryHint: .isDirectory); try makeExtensionFolder(at: u); return u }())
        try Data("garbage".utf8).write(to: library.recordsFile)
        XCTAssertEqual(library.loadRecords(), [])
        library.removeUnusedPackages(keeping: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.packageURL(folder: folder).path),
                      "the moved-aside list may still name this package")
    }

    private func zipFolder(_ folder: URL, to zip: URL, keepParent: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Finding Safari extensions

    func testScannerFindsSafariExtensionsOnly() throws {
        let apps = root.appending(path: "Applications", directoryHint: .isDirectory)
        try makeApp(at: apps.appending(path: "Velja.app"), appName: "Velja", plugins: [
            ("Web Extension", "com.example.velja.ext", "com.apple.Safari.web-extension"),
            ("Share", "com.example.velja.share", "com.apple.share-services"),
        ])
        try makeApp(at: apps.appending(path: "Utilities/Tool.app"), appName: "Tool", plugins: [
            ("Tool Extension", "com.example.tool.ext", "com.apple.Safari.web-extension"),
        ])
        let found = SafariExtensionScanner.scan(in: [apps])
        XCTAssertEqual(found.map(\.bundleIdentifier), ["com.example.tool.ext", "com.example.velja.ext"])
        XCTAssertEqual(found.first?.appName, "Tool", "apps one folder down are found")
        XCTAssertTrue(found.last?.path.hasSuffix("Web Extension.appex") ?? false)
    }

    private func makeApp(at app: URL, appName: String, plugins: [(String, String, String)]) throws {
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try plist(["CFBundleName": appName]).write(to: contents.appending(path: "Info.plist"))
        for (name, bundleID, point) in plugins {
            let appexContents = contents.appending(path: "PlugIns/\(name).appex/Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: appexContents, withIntermediateDirectories: true)
            try plist([
                "CFBundleIdentifier": bundleID,
                "CFBundleDisplayName": name,
                "NSExtension": ["NSExtensionPointIdentifier": point],
            ]).write(to: appexContents.appending(path: "Info.plist"))
        }
    }

    private func plist(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    // MARK: - Words

    func testPermissionLinesSkipQuietOnesAndRepeats() {
        let lines = WebExtensionPermissionText.lines(forPermissions: ["storage", "alarms", "tabs", "contextMenus", "menus"])
        XCTAssertEqual(lines, [
            "See the address and title of each page",
            "Add items to the menu you get with a right click",
        ])
    }

    func testSiteLine() {
        XCTAssertNil(WebExtensionPermissionText.siteLine(forMatchPatterns: []))
        XCTAssertEqual(WebExtensionPermissionText.siteLine(forMatchPatterns: ["<all_urls>"]),
                       "Read and change every site you open in Chorus")
        XCTAssertEqual(WebExtensionPermissionText.siteLine(forMatchPatterns: ["https://*/*"]),
                       "Read and change every site you open in Chorus")
        XCTAssertEqual(WebExtensionPermissionText.siteLine(forMatchPatterns: ["*://*.youtube.com/*", "https://youtube.com/*"]),
                       "Read and change pages on *.youtube.com, youtube.com")
        let many = (1...6).map { "https://site\($0).com/*" }
        XCTAssertEqual(WebExtensionPermissionText.siteLine(forMatchPatterns: many),
                       "Read and change pages on site1.com, site2.com, site3.com, site4.com and 2 more")
    }
}
