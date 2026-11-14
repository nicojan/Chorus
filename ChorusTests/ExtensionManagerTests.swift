import XCTest
import WebKit
@testable import Chorus
@testable import ChorusEngine

/// Adding, switching off and removing extensions through the app's manager,
/// against a library in a temporary folder.
@MainActor
final class ExtensionManagerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-manager-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager() -> ExtensionManager {
        ExtensionManager(
            library: WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory)),
            storageIdentifier: nil
        )
    }

    private func makeExtensionFolder(permissions: [String] = ["storage"]) throws -> URL {
        let folder = root.appending(path: "ext-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let list = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let manifest = #"{"manifest_version": 3, "name": "Probe", "version": "2.1", "permissions": [\#(list)], "action": {}}"#
        try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
        return folder
    }

    func testAddSwitchOffAndRemove() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let manager = makeManager()
        XCTAssertFalse(manager.host?.isActive ?? true, "no extensions, no controller on pages")

        let source = try await manager.importPackage(at: makeExtensionFolder(permissions: ["storage", "nativeMessaging"]))
        let summary = try await manager.inspect(source)
        XCTAssertTrue(summary.needsNativeApp)
        let record = await manager.add(source, summary: summary)

        XCTAssertEqual(record.grantedPermissions, ["storage"], "talking to the Mac app is never granted")
        XCTAssertTrue(manager.isRunning(record.id))
        XCTAssertTrue(manager.host?.isActive ?? false)
        XCTAssertTrue(manager.needsRestart, "pages built before the first extension need a restart")
        XCTAssertEqual(makeManager().records.map(\.id), [record.id], "the list is saved")

        await manager.setEnabled(record.id, false)
        XCTAssertFalse(manager.isRunning(record.id))
        XCTAssertEqual(makeManager().records.first?.isEnabled, false)

        guard case .package(let folder) = source else { return XCTFail("expected a package") }
        let packageURL = manager.library.packageURL(folder: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
        await manager.remove(record.id)
        XCTAssertTrue(manager.records.isEmpty)
        XCTAssertFalse(manager.isRunning(record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path), "the copied files go with it")
        XCTAssertTrue(makeManager().records.isEmpty)
    }

    func testDiscardDropsAPackageNobodyAdded() async throws {
        let manager = makeManager()
        let source = try await manager.importPackage(at: makeExtensionFolder())
        guard case .package(let folder) = source else { return XCTFail("expected a package") }
        manager.discard(source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.library.packageURL(folder: folder).path))
    }

    func testAMissingSafariExtensionShowsWhy() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Web extensions need macOS 15.4") }
        let library = WebExtensionLibrary(directory: root.appending(path: "Library", directoryHint: .isDirectory))
        let gone = WebExtensionRecord(
            source: .appExtension(path: root.appending(path: "Gone.app/Contents/PlugIns/Gone.appex").path),
            name: "Gone", grantedPermissions: [], grantedMatchPatterns: []
        )
        try library.saveRecords([gone])
        let manager = ExtensionManager(library: library, storageIdentifier: nil)
        await manager.startEnabled()
        XCTAssertFalse(manager.isRunning(gone.id))
        XCTAssertNotNil(manager.failures[gone.id], "Settings shows why it is not running")
    }

    func testDebugAndReleaseKeepSeparateLists() {
        XCTAssertTrue(ExtensionManager.defaultDirectory.path.contains("Chorus-debug"),
                      "tests run Debug, which must never read the release list")
    }
}
