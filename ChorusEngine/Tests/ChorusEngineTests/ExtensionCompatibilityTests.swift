import XCTest
@testable import ChorusEngine

/// The package rewrite behind `ExtensionCompatibility`. The host tests
/// `testServiceWorkerSurvivesOpeningAWebSocket` and
/// `testExtensionContextsHaveDisposeSymbols` run the result in WebKit.
final class ExtensionCompatibilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ext-compat-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeManifest(_ fields: String) throws {
        let manifest = #"{ "manifest_version": 3, "name": "X", "version": "1"\#(fields) }"#
        try Data(manifest.utf8).write(to: root.appending(path: "manifest.json"))
    }

    private func manifest() throws -> [String: Any] {
        try XCTUnwrap(WebExtensionLibrary.readManifest(at: root))
    }

    private func text(_ name: String) throws -> String {
        try String(contentsOf: root.appending(path: name), encoding: .utf8)
    }

    func testClassicWorkerLoadsTheScriptFirst() throws {
        try writeManifest(#", "background": { "service_worker": "background.js" }"#)
        try ExtensionCompatibility.apply(to: root)
        let background = try XCTUnwrap(try manifest()["background"] as? [String: Any])
        XCTAssertEqual(background["service_worker"] as? String, ExtensionCompatibility.workerFile)
        XCTAssertEqual(try text(ExtensionCompatibility.workerFile),
                       "importScripts(\"/__chorus_compat.js\", \"/background.js\");\n")
        XCTAssertEqual(try text(ExtensionCompatibility.scriptFile), ExtensionCompatibility.script)
    }

    func testModuleWorkerImportsTheScriptFirst() throws {
        try writeManifest(#", "background": { "service_worker": "sw/main.js", "type": "module" }"#)
        try ExtensionCompatibility.apply(to: root)
        let background = try XCTUnwrap(try manifest()["background"] as? [String: Any])
        XCTAssertEqual(background["type"] as? String, "module", "the worker stays a module")
        XCTAssertEqual(try text(ExtensionCompatibility.workerFile),
                       "import \"/__chorus_compat.js\";\nimport \"/sw/main.js\";\n")
    }

    func testBackgroundScriptsAndContentScriptsGetTheScriptFirst() throws {
        try writeManifest(#"""
        , "background": { "scripts": ["a.js", "b.js"] },
          "content_scripts": [
            { "matches": ["<all_urls>"], "js": ["cs.js"], "run_at": "document_start" },
            { "matches": ["<all_urls>"], "css": ["only.css"] } ]
        """#)
        try ExtensionCompatibility.apply(to: root)
        let manifest = try manifest()
        XCTAssertEqual((manifest["background"] as? [String: Any])?["scripts"] as? [String], ["__chorus_compat.js", "a.js", "b.js"])
        let entries = try XCTUnwrap(manifest["content_scripts"] as? [[String: Any]])
        XCTAssertEqual(entries[0]["js"] as? [String], ["__chorus_compat.js", "cs.js"])
        XCTAssertEqual(entries[0]["run_at"] as? String, "document_start", "other keys stay")
        XCTAssertNil(entries[1]["js"], "a CSS-only entry gets no script")
    }

    /// Runs at every load: a second run must not wrap twice.
    func testApplyingTwiceChangesNothingMore() throws {
        try writeManifest(#", "background": { "service_worker": "background.js" }, "content_scripts": [{ "matches": ["<all_urls>"], "js": ["cs.js"] }]"#)
        try Data("<html><head><title>P</title></head></html>".utf8).write(to: root.appending(path: "p.html"))
        try ExtensionCompatibility.apply(to: root)
        let manifestAfterFirst = try Data(contentsOf: root.appending(path: "manifest.json"))
        let pageAfterFirst = try text("p.html")
        try Data("old".utf8).write(to: root.appending(path: ExtensionCompatibility.scriptFile))

        try ExtensionCompatibility.apply(to: root)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "manifest.json")), manifestAfterFirst)
        XCTAssertEqual(try text("p.html"), pageAfterFirst)
        XCTAssertTrue(try text(ExtensionCompatibility.workerFile).contains("/background.js"))
        XCTAssertEqual(try text(ExtensionCompatibility.scriptFile), ExtensionCompatibility.script, "a later Chorus refreshes the script")
    }

    func testManifestKeepsEverythingElse() throws {
        try writeManifest(#", "description": "D", "permissions": ["storage"], "background": { "service_worker": "bg.js" }"#)
        let before = try manifest()
        try ExtensionCompatibility.apply(to: root)
        let after = try manifest()
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        XCTAssertEqual(after["description"] as? String, "D")
        XCTAssertEqual(after["permissions"] as? [String], ["storage"])
    }

    func testPagesGetTheTagAtTheTopOfTheirHead() {
        let tag = #"<script src="/__chorus_compat.js"></script>"#
        XCTAssertEqual(ExtensionCompatibility.withScriptTag(#"<html><HEAD lang="en"><script src="a.js"></script></HEAD></html>"#),
                       #"<html><HEAD lang="en">"# + tag + #"<script src="a.js"></script></HEAD></html>"#)
        XCTAssertEqual(ExtensionCompatibility.withScriptTag("<html><body>x</body></html>"),
                       "<html><head>" + tag + "</head><body>x</body></html>")
        XCTAssertEqual(ExtensionCompatibility.withScriptTag("<p>x</p>"), tag + "<p>x</p>")
        XCTAssertNil(ExtensionCompatibility.withScriptTag("<head>" + tag + "</head>"))
        XCTAssertEqual(ExtensionCompatibility.withScriptTag("<header>x</header><head></head>"),
                       "<header>x</header><head>" + tag + "</head>", "a <header> is not the head")
    }

    func testAWorkerNameWithQuotesStaysOneString() {
        XCTAssertEqual(ExtensionCompatibility.entryScript(loading: #"a"b.js"#, isModule: false),
                       #"importScripts("/__chorus_compat.js", "/a\"b.js");"# + "\n")
    }
}
