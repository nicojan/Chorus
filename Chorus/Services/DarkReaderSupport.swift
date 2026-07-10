import WebKit

/// Dark Reader integration: the isolated JS world it runs in, the bundled
/// library source, the injected scripts, and the pure "should this be themed"
/// policy.
///
/// Dark Reader (MIT) themes any page with a real per-element dark theme, unlike
/// the old crude `invert()` filter. Its API build stubs `window.chrome` and
/// defines a `DarkReader` global, which would break sites that feature-detect
/// `window.chrome` — so it is injected into an ISOLATED content world, never the
/// page's own world. The DOM is shared across worlds, so the theme `<style>` it
/// creates still applies; only its JS globals stay hidden from the site.
enum DarkReaderSupport {

    /// The single isolated world Dark Reader lives in. `world(name:)` returns the
    /// same instance for a given name, so the world used to add user scripts is
    /// the one `evaluateJavaScript(_:in:contentWorld:)` reaches. Main-actor
    /// isolated because the WebKit lookup is.
    @MainActor static var world: WKContentWorld {
        WKContentWorld.world(name: "ChorusDarkReader")
    }

    /// Element id for the anti-flash background style, so it can be removed when
    /// theming is turned off.
    private static let antiFlashID = "chorus-dr-antiflash"

    /// Whether a service should be themed right now: it's opted in AND the app's
    /// effective appearance is dark. Pure; unit-tested.
    static func shouldTheme(marked: Bool, effectiveDark: Bool) -> Bool {
        marked && effectiveDark
    }

    /// The Dark Reader library source, loaded once from the app bundle.
    static let libraryJS: String = {
        guard let url = Bundle.main.url(forResource: "darkreader", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            AppLogger.general.error("darkreader.js not found in bundle; dark theming disabled")
            return ""
        }
        return js
    }()

    /// A tiny style added at document-start (before the library themes) so a
    /// dark-themed service doesn't flash white while the library initializes.
    /// Injected only when the initial state is dark.
    static func antiFlashScript() -> String {
        """
        (function() {
            if (document.getElementById('\(antiFlashID)')) return;
            var s = document.createElement('style');
            s.id = '\(antiFlashID)';
            s.textContent = 'html { background: #1a1a1a !important; }';
            (document.head || document.documentElement).appendChild(s);
        })();
        """
    }

    /// Runs right after the library at document-start: wires a fetch method so
    /// Dark Reader can read cross-origin stylesheets, and enables theming when the
    /// baked initial state is dark.
    static func bootstrapScript(enable: Bool) -> String {
        let enableLine = enable ? "DarkReader.enable({});" : ""
        return """
        (function() {
            if (!window.DarkReader) return;
            try { DarkReader.setFetchMethod(window.fetch); } catch (e) {}
            \(enableLine)
        })();
        """
    }

    /// Snippet to enable theming on an already-loaded document (live change).
    static let enableJS = """
    if (window.DarkReader) {
        try { DarkReader.setFetchMethod(window.fetch); } catch (e) {}
        DarkReader.enable({});
    }
    """

    /// Snippet to disable theming on an already-loaded document and drop the
    /// anti-flash background.
    static let disableJS = """
    if (window.DarkReader) { DarkReader.disable(); }
    var af = document.getElementById('\(antiFlashID)');
    if (af) af.remove();
    """
}
