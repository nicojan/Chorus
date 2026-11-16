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

    /// A list that exists but cannot be read is not the same as no list: it
    /// is moved aside, so the launch sweep leaves every package alone.
    func testListThatCannotBeReadIsMovedAside() throws {
        let kept = try importedPackage()
        let record = WebExtensionRecord(source: .package(folder: kept), name: "A", grantedPermissions: [], grantedMatchPatterns: [])
        try library.saveRecords([record])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.recordsFile.path)
        defer { restorePermissions() }
        XCTAssertEqual(library.loadRecords(), [])
        let names = try FileManager.default.contentsOfDirectory(atPath: library.directory.path)
        XCTAssertFalse(names.contains("extensions.json"))
        XCTAssertTrue(names.contains { $0.hasPrefix("extensions.unreadable-") }, "the list is kept to look at")
        library.removeUnusedPackages(keeping: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.packageURL(folder: kept).path),
                      "an unreadable list may name every package")
    }

    /// When the unreadable list cannot even be moved, the sweep still waits.
    func testSweepWaitsWhenTheListCannotBeReadOrMoved() throws {
        let kept = try importedPackage()
        try library.saveRecords([])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.recordsFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: library.directory.path)
        defer { restorePermissions() }
        XCTAssertEqual(library.loadRecords(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.recordsFile.path), "precondition: the move failed")
        library.removeUnusedPackages(keeping: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.packageURL(folder: kept).path))
    }

    func testMissingListMovesNothingAside() throws {
        try FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        XCTAssertEqual(library.loadRecords(), [])
        let names = try FileManager.default.contentsOfDirectory(atPath: library.directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix("extensions.unreadable-") })
    }

    private func importedPackage() throws -> String {
        let folder = root.appending(path: "src-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version": 3, "name": "A", "version": "1.0"}"#.utf8).write(to: folder.appending(path: "manifest.json"))
        return try library.importPackage(from: folder)
    }

    private func restorePermissions() {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.directory.path)
        let names = (try? fm.contentsOfDirectory(atPath: library.directory.path)) ?? []
        for name in names where name.hasPrefix("extensions") {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: library.directory.appending(path: name).path)
        }
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

    private func importProbe(_ name: String) throws -> String {
        let source = root.appending(path: name, directoryHint: .isDirectory)
        try makeExtensionFolder(at: source)
        return try library.importPackage(from: source)
    }

    private func packageExists(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: library.packageURL(folder: folder).path)
    }

    func testRemovePackagesDeletesOnlyReleasedFolders() throws {
        let oldCurrent = try importProbe("p1")
        let oldStaged = try importProbe("p2")
        let sharedCurrent = try importProbe("p3")
        let otherStaged = try importProbe("p4")
        let imported = try importProbe("p5")

        func staged(_ folder: String) -> WebExtensionRecord.StagedUpdate {
            WebExtensionRecord.StagedUpdate(folder: folder, version: "2.0", newPermissions: [], newMatchPatterns: [])
        }
        let a = WebExtensionRecord(source: .package(folder: oldCurrent), name: "A", grantedPermissions: [], grantedMatchPatterns: [])
            .staging(staged(oldStaged))
        let b = WebExtensionRecord(source: .package(folder: sharedCurrent), name: "B", grantedPermissions: [], grantedMatchPatterns: [])
            .staging(staged(otherStaged))
        // A no longer names either of its folders; B still names both of its
        // own, and the new list also names one of A's old folders through B.
        let bNow = b.droppingStagedUpdate(skipping: false).staging(staged(oldStaged))
        let before = [a, b]
        let after = [bNow]

        library.removePackages(releasedFrom: before, to: after)

        XCTAssertFalse(packageExists(oldCurrent), "named before, not after")
        XCTAssertFalse(packageExists(otherStaged), "B's old staged folder is released")
        XCTAssertTrue(packageExists(oldStaged), "still staged by another record")
        XCTAssertTrue(packageExists(sharedCurrent), "still current")
        XCTAssertTrue(packageExists(imported), "a folder no record named, such as one waiting at Add, is left alone")
    }

    func testSweepKeepsStagedFolders() throws {
        let current = try importProbe("s1")
        let staged = try importProbe("s2")
        let stray = try importProbe("s3")
        let record = WebExtensionRecord(source: .package(folder: current), name: "S", grantedPermissions: [], grantedMatchPatterns: [])
            .staging(WebExtensionRecord.StagedUpdate(folder: staged, version: "2.0", newPermissions: [], newMatchPatterns: []))
        library.removeUnusedPackages(keeping: Set([record].flatMap(\.packageFolders)))
        XCTAssertTrue(packageExists(current))
        XCTAssertTrue(packageExists(staged), "a staged update's folder survives the launch sweep")
        XCTAssertFalse(packageExists(stray))
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
