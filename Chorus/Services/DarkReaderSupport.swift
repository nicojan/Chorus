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

    /// What to inject for a service: nothing, the theme (library + enable), or the
    /// detection probe.
    enum DarkInjection {
        case none, themed, probe
    }

    /// The single source of truth for what a service needs, given its mode, the
    /// global auto setting, the app's effective appearance, and any cached
    /// detection verdict. Pure; unit-tested. Because it guards on `appDark`,
    /// `.themed` always implies the app is dark.
    static func injection(
        mode: ServiceDarkMode,
        globalAuto: Bool,
        appDark: Bool,
        detectedLacksDark: Bool?
    ) -> DarkInjection {
        guard appDark else { return .none }
        switch mode {
        case .off: return .none
        case .on: return .themed
        case .auto:
            guard globalAuto else { return .none }
            switch detectedLacksDark {
            case .some(true): return .themed
            case .some(false): return .none
            case .none: return .probe
            }
        }
    }

    /// Whether a service should be themed right now. Derived from `injection`.
    static func shouldTheme(
        mode: ServiceDarkMode,
        globalAuto: Bool,
        appDark: Bool,
        detectedLacksDark: Bool?
    ) -> Bool {
        injection(mode: mode, globalAuto: globalAuto, appDark: appDark, detectedLacksDark: detectedLacksDark) == .themed
    }

    /// Relative luminance (0…1) of an sRGB color, ignoring gamma (good enough to
    /// separate a near-black dark theme from a near-white light page).
    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
    }

    /// Classifies a sampled background color as "the site lacks a dark theme."
    /// A near-transparent background means the browser default (white) shows
    /// through, so treat it as light. Otherwise a bright background (luminance
    /// above the threshold) means the site didn't go dark on its own.
    static func classifyLacksDark(r: Double, g: Double, b: Double, a: Double, threshold: Double = 0.5) -> Bool {
        guard a >= 0.5 else { return true }
        return relativeLuminance(r: r, g: g, b: b) > threshold
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
