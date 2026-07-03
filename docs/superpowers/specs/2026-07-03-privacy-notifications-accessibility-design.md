# Spec C — Privacy, notifications & accessibility

Date: 2026-07-03
Status: In progress (decisions delegated to Claude; user reviews the result)

Third and final spec of the "Chorus 1.1" milestone. Four features:

1. **Global default zoom** (accessibility).
2. **Scheduled Do Not Disturb** (quiet hours).
3. **App lock** (Touch ID / password).
4. **Per-service dark mode** (replaced content blocking — see note).

> **Change from the original plan:** content blocking was dropped. For Chorus's
> roster (Slack, LinkedIn, Gmail, WhatsApp, Discord) there's little to block and
> the messaging apps aren't ad-heavy, so the value didn't justify the heaviest,
> riskiest feature (remote list fetch + rule-list compilation within a hard cap).
> Per-service dark mode is a better fit and was swapped in.

## 1. Global default zoom

Replaces the rejected "shrink base font-size for all services" idea. Font-size
scaling doesn't touch fixed-pixel images (LinkedIn's avatars stay large), breaks
per-service layouts, and small-by-default hurts accessibility. Zoom scales
everything uniformly and can go larger *or* smaller.

- `AppPreferences.defaultZoom: Double?` (nil → 1.0; optional for SwiftData
  lightweight migration, matching `pageZoom`).
- `AppState.defaultZoom` loaded from prefs in `loadAppPreferences()`.
- Effective zoom for a service = `service.pageZoom ?? defaultZoom`. Per-service
  ⌘-/⌘+ still overrides the global default (sets an explicit `pageZoom`).
- Applied in `WebContentView` (`webView.pageZoom = effectiveZoom`) and in
  `adjustActiveServiceZoom`. Changing the default in Settings reapplies it live
  to every open service that has no explicit per-service zoom.
- Settings: an "Accessibility" section in General with a Default-zoom picker
  (80%–150%).

## 2. Scheduled Do Not Disturb (quiet hours)

- `AppPreferences`: `scheduledDNDEnabled: Bool?`, `dndStartMinutes: Int?`,
  `dndEndMinutes: Int?` (minutes since midnight; all optional).
- Pure, testable function `isWithinQuietHours(nowMinutes:start:end:)` that handles
  the midnight wrap-around (e.g. 22:00→07:00).
- Effective DND = manual `doNotDisturb` OR (scheduled enabled AND within quiet
  hours). A repeating timer (once a minute) re-evaluates and flips the effective
  DND at the boundaries, driving `badgeManager.doNotDisturb` and the notification
  gate exactly as the manual toggle does today.
- Settings: toggle + start/end `DatePicker`s (hour/minute) in the Notifications
  tab.

## 3. App lock (Touch ID / password)

Chorus is unsandboxed and holds many logged-in sessions; a lock is a real
privacy win.

- `LocalAuthentication` (`LAContext`, `.deviceOwnerAuthentication` — Touch ID
  with automatic password fallback).
- A cover window (opaque overlay over the main window) shown until the user
  authenticates, so content isn't visible behind it.
- `AppPreferences.appLockEnabled: Bool?`. Settings: enable toggle in a Privacy
  tab, plus auto-lock timing.
- **Decision to confirm:** lock triggers. Recommendation: lock on launch and on
  system sleep/screen-lock, plus a manual "Lock Now" command; no idle-timeout in
  v1 (add later if wanted). Auto-lock-on-sleep covers the common "walk away"
  case without a timer.

## 4. Per-service dark mode

Forces a dark appearance on services that have no dark theme of their own (e.g.
LinkedIn). Per service: **Off / On / Auto** (follow the system).

- **Mechanism:** a whole-page CSS inversion filter (`invert(1) hue-rotate(180deg)`
  on `html`), with images/video/backgrounds re-inverted so photos keep their
  real colors. This is the only *universal* way to darken a site with no dark
  theme; it's imperfect by nature. A service that needs a polished result can use
  the per-service **Custom CSS** from Spec B to write a real dark theme.
- Reuses Spec B's CSS-injection path: the dark CSS is appended to a service's
  effective injected CSS at web-view build time, so no flash. `DarkMode.shouldApply(preference:systemIsDark:)`
  is a pure, unit-tested decision.
- `ServiceInstance.darkMode: String?` (nil → off). Changing it rebuilds the web
  view (same path as a custom-CSS change). "Auto" services are rebuilt when the
  system appearance flips (observed via `AppleInterfaceThemeChangedNotification`).
- Settings: a Dark-mode picker in the Edit Service sheet.

Why not a smarter engine (Dark Reader-style color analysis): too heavy to embed;
the invert filter + per-service custom CSS covers the need.

## Status

All four implemented and unit-tested where there's pure logic (effective-zoom
resolution, quiet-hours wrap-around, dark-mode decision). Touch ID and the visual
dark result are verified in the running app (biometrics can't be tested
headlessly).
