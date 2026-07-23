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

    /// What to inject for a service: nothing, or the theme (library + enable).
    enum DarkInjection {
        case none, themed
    }

    /// The single source of truth for what a service needs: a service themes
    /// only when the user set it to On AND the app is currently dark. Pure;
    /// unit-tested.
    static func injection(mode: ServiceDarkMode, appDark: Bool) -> DarkInjection {
        appDark && mode == .on ? .themed : .none
    }

    /// Whether a service should be themed right now. Derived from `injection`.
    static func shouldTheme(mode: ServiceDarkMode, appDark: Bool) -> Bool {
        injection(mode: mode, appDark: appDark) == .themed
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
    /// The cover reveals only once the page stops mutating (Dark Reader has
    /// finished its pass and the app shell has hydrated), or after a settle cap,
    /// or an absolute failsafe — whichever comes first. A subtle spinner fades in
    /// only if the cover lingers, so quick loads don't flash it. Injected only
    /// when the initial state is dark.
    ///
    /// The cover runs in Dark Reader's isolated world and exposes
    /// `__chorusCoverDismiss()` on that world's globals, called from `disableJS`
    /// to tear the cover down at once when theming is turned off. Because Dark
    /// Reader is always baked at document-start (theming is never enabled after
    /// the fact), settling starts immediately — there's no verdict to wait for.
    /// `settleCapMs` bounds how long after the page starts settling the cover
    /// waits for quiet; `failsafeMs` is the absolute never-trap ceiling.
    static func antiFlashScript(
        settleCapMs: Int = 6000,
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
                // a page that renders and settles before the settle cap / failsafe
                // would swallow all input while it's usable underneath.
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
                if (revealed || !settling) return;    // only chase quiet once settling has started
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
            beginSettle();
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

    /// Snippet to disable theming on an already-loaded document and drop the load
    /// cover. Calls the cover's own teardown so its observer and timers stop (not
    /// just the element removed), then falls back to removing the element by id.
    static let disableJS = """
    if (window.DarkReader) { DarkReader.disable(); }
    if (window.__chorusCoverDismiss) { window.__chorusCoverDismiss(); }
    var af = document.getElementById('\(antiFlashID)');
    if (af) af.remove();
    """
}
