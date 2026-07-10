# Dark Reader integration — design

_2026-07-09_

## Goal

Replace Chorus's crude per-service "Force dark mode" (a CSS `invert(1)
hue-rotate(180deg)` filter) with [Dark Reader](https://github.com/darkreader/darkreader)
(MIT), which does real per-element dark theming. Same per-service opt-in; better
result.

## Decisions (from brainstorming)

1. **Replace, don't coexist.** The existing per-service toggle now drives Dark
   Reader. The invert path (`DarkMode.css`) is removed. Existing services with
   `forceDarkMode == true` use the new engine automatically — no data migration.
2. **Follow app appearance.** A marked service is themed only while the app's
   effective appearance is Dark (System→OS dark, or the Light/Dark override).
   In Light, the service shows its normal light theme.
3. **Per-service only.** No global "dark-theme everything" switch (declined).

## Behavior

- For a marked service, Dark Reader themes its pages when the effective app
  appearance is Dark; nothing when Light.
- **Live, no reload:** flipping a service's toggle applies/removes the theme at
  once, and changing the app appearance re-themes all marked live views. (Today
  a toggle rebuilds the whole web view — the new path is strictly better.)
- Only opt-in services run Dark Reader, so only they pay its runtime cost
  (a `MutationObserver` + style processing).

## Architecture

### Isolated content world (important)

Dark Reader's API build stubs `window.chrome` and defines a `DarkReader` global.
Injected into a site's own JS world, that can break sites that feature-detect
`window.chrome`. So Dark Reader is injected into an **isolated `WKContentWorld`**
(not `.page`). Its globals stay invisible to the site; the DOM is shared across
worlds, so the theme `<style>` it injects still applies. All Chorus→Dark Reader
calls use `evaluateJavaScript(_:in:contentWorld:)` targeting that world.

### Components

- **Bundled `darkreader.js`** (MIT) as a versioned app resource — offline, no
  runtime fetch. A pinned-version fetch script (`scripts/fetch_darkreader.sh`,
  mirroring `convert_blocklist.sh`) vendors the prebuilt dist from a CDN; no Node
  build.
- **Injection** (in `UserScriptManager`, alongside the CSS/badge scripts): for a
  marked service, add two `WKUserScript`s in the isolated world at
  `.atDocumentStart`, main frame only:
  1. an anti-flash style (`html { background: #1a1a1a }`) so there's no white
     flash before theming;
  2. the Dark Reader library, followed by a bootstrap that calls
     `DarkReader.setFetchMethod(window.fetch)` and, if the initial appearance is
     dark, `DarkReader.enable(...)`.
- **Appearance fan-out** (`AppState` → `WebViewPool`): on an app-appearance
  change, and when a service's toggle flips, call `enable`/`disable` in the
  isolated world on each affected live web view. Hibernated/destroyed views pick
  up the right state when rebuilt via `makeConfiguration`. Follows the
  `reattachContentBlocker` pattern (live views only).

### Data flow

- `ServiceInstance.forceDarkMode` (existing flag) = "use Dark Reader here." No
  schema change.
- `WebViewPool.makeConfiguration`: if set, inject the Dark Reader scripts into the
  isolated world; remove the old `DarkMode.css` invert.
- Effective appearance is derived from `AppState.appearanceMode` + system (the
  existing `appearanceColorScheme` logic).

## Edge cases / risks

- **`window.chrome` / site detection** — mitigated by the isolated world.
- **Flash on load** — mitigated by the document-start anti-flash style.
- **Cross-origin stylesheets** — Dark Reader may not theme CSS it can't read
  under CSP; it degrades gracefully. Accept.
- **iframes** — main-frame-only first cut, so iframe content may stay light.
  Known limitation; revisit if a common service needs it.
- **Double-dark** — a service with its own dark theme would be darkened twice.
  Guidance (and help copy): only mark services that lack a dark theme. Same as
  today.
- **Sites that break under theming** — turn it off for that service, as today.

## Copy

- Rename the per-service toggle from "Force dark mode" (no longer accurate, since
  it follows app appearance) to something like "Dark theme for sites without one."
  Final wording passes `humanizer_check_text` + Orwell before shipping.
- README/CHANGELOG note the upgrade from invert to Dark Reader.
- Dark Reader (MIT) attribution in the About pane, next to HaGezi.

## Testing

- **Unit:** the pure "should this service be themed right now?" decision
  (flag + effective appearance) and bootstrap-script generation.
- **Headless WebKit:** inject into a test page in the isolated world; confirm the
  `DarkReader` global loads there, that it does NOT leak into the page world, and
  that a theme `<style>` is added to the shared DOM.
- **Manual:** a couple of real no-dark-theme services in Light and Dark.

## Out of scope (YAGNI)

- Per-service brightness/contrast/sepia tuning (use sensible defaults).
- Global "dark-theme all services" switch.
- Theming iframes.
