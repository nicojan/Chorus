# Dark Reader → manual-only; remove Readability

Date: 2026-07-21
Status: approved for planning

## Goal

Two independent trims to reduce the app's automatic behavior:

1. **Dark Reader becomes manual-only.** Chorus no longer detects whether a site
   lacks a dark theme and no longer themes anything on its own. A service is
   dark-themed only when the user explicitly sets it to **On** in that service's
   settings sheet (and the app is dark). Off is the default.
2. **Remove Readability (reader mode) entirely.** The feature and all its code,
   assets, scripts, and tests go.

This supersedes the auto-dark-mode design (`2026-07-09-auto-dark-mode-design.md`)
and narrows the Dark Reader design (`2026-07-09-dark-reader-design.md`) to its
per-service `.on` path.

## Dark Reader: what stays and what goes

### Policy (the source of truth)

`DarkReaderSupport.injection` collapses to two inputs:

```
injection(mode, appDark) = appDark && mode == .on ? .themed : .none
```

The `globalAuto`, `detectedLacksDark`, and `nativeDark` parameters are removed,
along with the `.probe` case. `shouldTheme` follows.

The "only theme while the app is dark" contract is preserved: setting a service
to On while the app runs Light leaves the page light, so a themed page never
sits under light app chrome.

### Model changes (`ServiceInstance`, `AppPreferences`)

- `ServiceDarkMode` drops `.auto`; it becomes `{ on, off }`.
- `ServiceInstance.darkMode` accessor migrates stored values:
  - an explicit `darkModeRaw` of `"on"` → `.on`; `"off"` → `.off`;
  - legacy `forceDarkMode == true` → `.on` (unchanged);
  - a stored `"auto"`, an unknown value, or nil → **`.off`**.
  So any service that rode auto stops theming on upgrade until the user opts it
  in. This is the intended "off by default" behavior.
- Remove `ServiceInstance.detectedLacksDarkTheme` (optional attribute; safe for
  SwiftData lightweight migration to drop).
- Remove `AppPreferences.autoDarkModeEnabled`, its init parameter, and
  `autoDarkModeEnabledEffective`.

### Deletions

- **Theme cache:** delete `Chorus/Services/DarkThemeCacheStore.swift` and all pool
  wiring — the `darkThemeCache` field, `cachedDarkCSS`/`store`/`dropDarkThemeCache`
  calls, the cached-style document-start injection, and the
  `exportGeneratedCSS` export script.
- **Detection probe:** delete the `.probe` injection case,
  `UserScriptManager.makeDarkProbeScript`, `DarkProbeMessageHandler`,
  `DarkProbePayload`, `onDarkProbeVerdict`, the `chorusDarkProbe` script-message
  handler, and `DarkReaderSupport.classifyLacksDark` /
  `DarkReaderSupport.relativeLuminance`.
- **Re-detect:** delete `AppState.redetectDarkTheme` and the "Re-detect dark
  theme" button in `EditServiceSheet`.
- **Global auto toggle:** remove the pool's `autoDarkModeEnabled` field and the
  Settings → Appearance toggle "Give services a dark theme when they lack one"
  plus its explanatory caption. `AppState.setAutoDarkModeEnabled` and the
  `autoEnabled` parameter threading through `applyDarkState` go too;
  `applyDarkState` keeps only `isDark` and the service list.
- **Native-dark allowlist:** remove `WebViewPool.nativeDark(for:)` and its use.
  The `ServiceCatalogEntry.nativeDark` JSON field stays dormant (removing a
  catalog column is riskier and buys nothing); the code simply stops reading it.

### Load cover (kept, simplified)

The anti-flash cover stays so an On service does not flash white→dark on load.
Because theming is now always baked at document-start (no probe), the cover no
longer needs its deferred-reveal path:

- Remove the `deferReveal` parameter, the `__chorusCoverBeginSettle` deferral,
  and `beginCoverSettleJS`. The cover always begins settling immediately, then
  reveals once the page goes quiet (existing MutationObserver logic), with the
  same settle-cap and failsafe timers.
- `disableJS` keeps its cover-dismiss call but drops the cached-style removal.

### UI (`EditServiceSheet`)

The per-service picker becomes a two-value On/Off control, default Off. Remove
the Auto tag, the Auto-only "Re-detect dark theme" button, and revise the help
text to describe only On and Off.

## Readability: full removal

Delete:

- `Chorus/Services/ReaderMode.swift`
- `Chorus/Resources/readability.js`
- `scripts/fetch_readability.sh`
- The "Reader" `navButton` in `Chorus/Views/MainWindow/WebToolbarView.swift`
- The `readability.js` resource entry in `project.yml` and the corresponding
  `.pbxproj` reference (keep the two in sync per project convention).
- The `testReaderModeLibraryLoads` test.

## Tests

Remove: the Dark Reader cache tests, the probe/`classifyLacksDark` tests, the
`autoDarkModeEnabled` preference test, the `nativeDark` catalog assertions, and
the reader-mode test.

Rewrite: the `injection` truth-table test for the two-input policy — assert
`.themed` only for `(mode: .on, appDark: true)` and `.none` for every other
combination of `mode ∈ {on, off}` and `appDark ∈ {true, false}`.

Add: a migration test confirming `darkMode` resolves a stored `"auto"` and a nil
`darkModeRaw` to `.off`, and `forceDarkMode == true` to `.on`.

## Risks and non-goals

- **Migration:** dropping an optional SwiftData attribute
  (`detectedLacksDarkTheme`) and an `AppPreferences` field is a lightweight
  migration; no store version bump expected. Verify a launch against an existing
  store during manual test.
- **Non-goal:** changing the "theme only while the app is dark" rule for On, or
  removing the dormant `nativeDark` catalog field.
- **Accepted regression:** heavy On services (e.g. Gmail) lose the cache's fast
  first paint. The load cover hides the wash during the live pass; this is the
  agreed trade for dropping the cache.
