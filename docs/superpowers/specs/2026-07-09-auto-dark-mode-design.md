# Auto dark mode — design

_2026-07-09_

## Goal

Add a global Appearance setting that gives a dark theme (via Dark Reader) to
services that lack one, using best-effort detection, with a per-service override.
Builds on the shipped Dark Reader integration (see
`2026-07-09-dark-reader-design.md`).

## Decisions (from brainstorming)

1. **Auto-detect + manual override.** A global toggle turns on detection; each
   service also has an explicit control that wins over detection.
2. **Global default off.** Opt-in; no behavior change on upgrade.
3. **Re-probe only when there's no cached verdict.** Trust the cache afterward;
   the per-service override is the escape hatch.

## State model

- **Global:** `AppPreferences.autoDarkModeEnabled: Bool?` (nil → false). Surfaced
  in Settings → Appearance, active only when the effective appearance can be dark
  (System or Dark); shown greyed with a note under Light.
- **Per-service:** replace the on/off flag with three states —
  `ServiceDarkMode { auto, on, off }`, stored as `ServiceInstance.darkModeRaw:
  String?`. Effective mode: explicit `darkModeRaw` wins; else legacy
  `forceDarkMode == true` → `.on`; else `.auto`. No data-migration pass; existing
  dark-forced services stay `.on`.
- **Detection cache:** `ServiceInstance.detectedLacksDarkTheme: Bool?` — nil until
  first probed.

## Effective decision (pure, unit-tested)

`shouldTheme(mode, globalAuto, appDark, detectedLacksDark)`:
- `appDark == false` → false (dark theming only when the app is Dark).
- `mode == .on` → true.
- `mode == .off` → false.
- `mode == .auto` → `globalAuto && (detectedLacksDark == true)`.

`.on` works regardless of the global toggle, preserving today's explicit
per-service capability; the global toggle only drives `.auto` services.

## Detection flow

For an `.auto` service when global-auto is on and the app is dark:
- **Cached verdict present:** bake the decision at `makeConfiguration` time — if
  it lacks a dark theme, inject Dark Reader + enable at document-start (no flash);
  otherwise inject nothing.
- **No cached verdict:** inject a small luminance probe (page world,
  `.atDocumentEnd`) that, after a short settle delay, reads
  `getComputedStyle(document.documentElement/body).backgroundColor`, computes
  luminance, and posts `{serviceID, lacksDark}` to a `chorusDarkProbe` message
  handler. The app caches the verdict; if it lacks dark, it injects the Dark
  Reader library + enables live (the one accepted first-visit flash) and re-bakes
  the view's user scripts so later navigations are flash-free.

Only services that need it ever load the heavy Dark Reader library; every `.auto`
service pays only the tiny probe on its first visit.

## Interaction with existing appearance handling

- The appearance fan-out (`WebViewPool.applyAppearance`) and the per-service edit
  path already re-bake user scripts; extend them to compute the effective decision
  per service (mode + global + appDark + cached verdict) instead of the old bool.
- Toggling the global switch triggers the same fan-out.

## UI

- Settings/Appearance: the global toggle + one plain caption (what it does; that
  it can't perfectly tell which sites already have dark mode; override per
  service). Copy passes humanizer + Orwell.
- EditServiceSheet: the current toggle becomes an Auto / On / Off picker with help
  text.

## Edge cases

- SPAs theme late → probe after a settle delay; misreads fixed by override.
- Intentionally-light sites → override to Off.
- App in Light → nothing themes.
- A service already `.on` (migrated) never probes.

## Testing

- Unit: `shouldTheme(...)`; the luminance→"lacks dark" classifier; mode migration
  (legacy `forceDarkMode` → effective mode).
- Headless: probe classifies a light page as lacking dark and a dark page as not;
  effective decision drives injection.

## Out of scope (YAGNI)

- Re-detecting on every load / reacting to a site adding dark mode later (override
  or clear-cache instead).
- Detecting in-site manual dark toggles.
- Per-service brightness/contrast tuning.
