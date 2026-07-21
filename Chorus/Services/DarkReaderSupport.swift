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

    /// Element id for the load cover, so it can be removed when theming is turned
    /// off.
    private static let antiFlashID = "chorus-dr-antiflash"

    /// Element id for the cached-theme `<style>` injected at document-start on a
    /// cache hit, so it can be removed when theming is turned off and once the
    /// live Dark Reader pass has taken over. See `DarkThemeCacheStore`.
    static let cacheStyleID = "chorus-dr-cache"

    /// What to inject for a service: nothing, the theme (library + enable), or the
    /// detection probe.
    enum DarkInjection {
        case none, themed, probe
    }

    /// The single source of truth for what a service needs, given its mode, the
    /// global auto setting, the app's effective appearance, any cached detection
    /// verdict, and whether the service is known to ship its own dark theme
    /// (`nativeDark`). Pure; unit-tested. Because it guards on `appDark`,
    /// `.themed` always implies the app is dark.
    ///
    /// `nativeDark` marks services that already render dark on their own when the
    /// app is dark — either always-dark web apps (Spotify), dark-by-default ones
    /// (Discord), or ones that follow `prefers-color-scheme` by default (GitHub,
    /// iCloud Mail). Theming those with Dark Reader double-darkens and breaks
    /// them, so in `.auto` they are left alone (no theme, and no probe). The
    /// user's explicit `.on` still wins — it is a deliberate override.
    static func injection(
        mode: ServiceDarkMode,
        globalAuto: Bool,
        appDark: Bool,
        detectedLacksDark: Bool?,
        nativeDark: Bool = false
    ) -> DarkInjection {
        guard appDark else { return .none }
        switch mode {
        case .off: return .none
        case .on: return .themed
        case .auto:
            guard globalAuto else { return .none }
            if nativeDark { return .none }
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
        detectedLacksDark: Bool?,
        nativeDark: Bool = false
    ) -> Bool {
        injection(mode: mode, globalAuto: globalAuto, appDark: appDark, detectedLacksDark: detectedLacksDark, nativeDark: nativeDark) == .themed
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

    /// An opaque dark cover laid over the whole viewport at document-start, so the
    /// user never sees the intermediate render while a themed service loads: not a
    /// white flash, and — the point on heavy services like Gmail — not Dark
    /// Reader's washed, low-contrast state while it re-themes a large light UI.
    ///
    /// The cover reveals only once theming has actually started AND the page then
    /// stops mutating (Dark Reader has finished its pass and the app shell has
    /// hydrated), or after a settle cap once theming starts, or an absolute
    /// failsafe — whichever comes first. "Theming has started" matters because of
    /// the probe path (see `deferReveal`): there Dark Reader isn't baked, it is
    /// enabled later when the detection verdict comes back, so revealing on plain
    /// DOM-quiet would show the still-light page and then let Dark Reader wash it
    /// in view — the very thing the cover exists to hide. A subtle spinner fades
    /// in only if the cover lingers, so quick loads don't flash it. Injected only
    /// when the initial state is dark.
    ///
    /// The cover runs in Dark Reader's isolated world and exposes hooks on that
    /// world's globals: `__chorusCoverBeginSettle()` (called from
    /// `beginCoverSettleJS` right after Dark Reader is enabled live) starts the
    /// settle-and-reveal, and `__chorusCoverDismiss()` (called from `disableJS`)
    /// tears the cover down at once when theming is turned off.
    ///
    /// `deferReveal` false (themed path, Dark Reader baked at document-start):
    /// theming is already underway, so settling starts immediately. `deferReveal`
    /// true (probe path): settling waits for `__chorusCoverBeginSettle()`, so the
    /// cover holds through the sample-then-theme sequence. `settleCapMs` bounds how
    /// long after theming starts the cover waits for quiet; `failsafeMs` is the
    /// absolute never-trap ceiling.
    static func antiFlashScript(
        settleCapMs: Int = 6000,
        deferReveal: Bool = false,
        failsafeMs: Int = 10000
    ) -> String {
        """
        (function() {
            var ID = '\(antiFlashID)';
            if (document.getElementById(ID)) return;
            var root = document.documentElement;
            if (!root) return;
            var cover = document.createElement('div');
            cover.id = ID;
            cover.setAttribute('style',
                'position:fixed;top:0;left:0;right:0;bottom:0;background:#1a1a1a;' +
                'z-index:2147483647;transition:opacity 200ms ease;opacity:1;' +
                // The cover's job is visual only, never modal: pass every click,
                // scroll, and keypress through to the page underneath. Otherwise
                // a page that renders and settles before the probe verdict lands
                // (up to the settle cap / failsafe) would swallow all input while
                // it's usable underneath.
                'pointer-events:none;' +
                'display:flex;align-items:center;justify-content:center;');
            var spin = document.createElement('div');
            spin.setAttribute('style',
                'width:28px;height:28px;border-radius:50%;opacity:0;' +
                'transition:opacity 300ms ease;' +
                'border:3px solid rgba(255,255,255,0.15);' +
                'border-top-color:rgba(255,255,255,0.5);');
            cover.appendChild(spin);
            root.appendChild(cover);
            try {
                spin.animate(
                    [{ transform: 'rotate(0deg)' }, { transform: 'rotate(360deg)' }],
                    { duration: 800, iterations: Infinity });
            } catch (e) {}

            var QUIET_MS = 400, SETTLE_CAP_MS = \(settleCapMs), FAILSAFE_MS = \(failsafeMs);
            var DEFER = \(deferReveal ? "true" : "false");
            var quietTimer = null, capTimer = null, failsafeTimer = null, spinTimer = null;
            var revealed = false, settling = false, obs = null;

            function clearTimers() {
                clearTimeout(quietTimer); clearTimeout(capTimer);
                clearTimeout(failsafeTimer); clearTimeout(spinTimer);
            }
            function teardown() {
                if (obs) { try { obs.disconnect(); } catch (e) {} }
                clearTimers();
            }
            function reveal() {
                if (revealed) return;
                revealed = true;
                teardown();
                cover.style.pointerEvents = 'none';   // already none; kept explicit through the fade
                cover.style.opacity = '0';
                setTimeout(function() {
                    if (cover.parentNode) cover.parentNode.removeChild(cover);
                }, 250);
            }
            function bump() {
                if (revealed || !settling) return;    // only chase quiet once theming has started
                clearTimeout(quietTimer);
                quietTimer = setTimeout(reveal, QUIET_MS);
            }
            function beginSettle() {
                if (revealed || settling) return;
                settling = true;
                clearTimeout(failsafeTimer);          // superseded by the settle cap
                capTimer = setTimeout(reveal, SETTLE_CAP_MS);
                bump();
            }
            // Torn down at once (no fade) when theming is turned off live.
            function dismiss() {
                if (revealed) return;
                revealed = true;
                teardown();
                if (cover.parentNode) cover.parentNode.removeChild(cover);
            }
            window.__chorusCoverBeginSettle = beginSettle;
            window.__chorusCoverDismiss = dismiss;

            try {
                obs = new MutationObserver(bump);
                // childList + characterData catches both the app shell building
                // and Dark Reader rewriting its <style> blocks (its slow, washed
                // phase). Attributes are deliberately left out: some pages churn
                // them forever, which would pin the cover open until the cap.
                obs.observe(root, { childList: true, subtree: true, characterData: true });
            } catch (e) {}

            spinTimer = setTimeout(function() { spin.style.opacity = '1'; }, 700);
            failsafeTimer = setTimeout(reveal, FAILSAFE_MS);
            if (!DEFER) beginSettle();
        })();
        """
    }

    /// Tells the load cover (if one is present in the isolated world) that Dark
    /// Reader has just been enabled, so it stops waiting for a verdict and reveals
    /// once the now-theming page settles. A no-op when no cover is present (a live
    /// appearance toggle on an already-visible page).
    static let beginCoverSettleJS = "if (window.__chorusCoverBeginSettle) { window.__chorusCoverBeginSettle(); }"

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

    /// Snippet to disable theming on an already-loaded document and drop the load
    /// cover and any cached-theme style. Calls the cover's own teardown so its
    /// observer and timers stop (not just the element removed), then falls back to
    /// removing the elements by id.
    static let disableJS = """
    if (window.DarkReader) { DarkReader.disable(); }
    if (window.__chorusCoverDismiss) { window.__chorusCoverDismiss(); }
    var af = document.getElementById('\(antiFlashID)');
    if (af) af.remove();
    var drc = document.getElementById('\(cacheStyleID)');
    if (drc) drc.remove();
    """
}
