# Spec A — Settings redesign + About

Date: 2026-07-03
Status: Approved (decisions delegated to Claude; user reviews the result)

Part of the "Chorus 1.1 — customization, privacy & settings" milestone. This is
the first of three specs:

- **A. Settings redesign + About** (this doc)
- B. Per-service customization (custom CSS + presets, mobile view, spellcheck)
- C. Privacy + notifications (app lock, scheduled DND, content blocking)

Settings comes first so B and C have a clean, extensible home.

## Problem

The current Settings window is poorly laid out (see the two reference
screenshots from 2026-07-02). Two concrete faults:

1. The General tab uses a plain `Form` with no grouped styling, so section
   labels ("Appearance", "Web Content", "Startup") read as loose text and the
   controls are misaligned.
2. The Notifications tab lists every service **three separate times** — once for
   mute, once for macOS notifications, once for badges. With many services this
   is a long, repetitive scroll.

There is also no About surface: no version, no link to the source, no update
button inside Settings, no author credit.

## Goals

- Fix the General tab with a proper grouped `Form`.
- Replace the three repeated service lists with one per-service table.
- Add an About tab.
- Leave the tab structure ready for a future Privacy tab (spec C) without
  building it now.

Non-goals: any privacy feature, scheduled DND, or per-service customization —
those are specs B and C.

## Design

### Window and tabs

`SettingsView` keeps a `TabView`, now with three tabs: General, Notifications,
About. Each tab's content is a `Form` with `.formStyle(.grouped)` for native
macOS grouped styling. Set a comfortable fixed width (~520pt) and let height fit
each tab's content (grouped forms scroll when tall), replacing the current
cramped `450×350–600` frame.

### General tab

Same settings as today, correctly grouped:

- **Appearance**: "Show Chorus in" picker (Dock / Menu bar / Both); "Show badge
  count on Dock icon" toggle.
- **Web Content**: "Automatically dismiss cookie banners" toggle.
- **Startup**: "Open at login" toggle.

No behavior change; only layout and section headers.

### Notifications tab

- **Do Not Disturb** toggle at the top with its caption ("Silences all badge
  counts and notification banners.").
- **One per-service table**, a row per service, built with `Grid`:
  - Columns: Service | On | macOS | Badge.
  - "On" = `!service.isMuted` (the master switch). "macOS" =
    `service.osNotificationsEnabled` (effective). "Badge" = `service.showBadge`.
  - When a row is muted (`On` off), the macOS and Badge toggles are
    `.disabled` — mute is the master override, and disabling shows that
    directly. A short footnote states it too.
  - Toggle side effects preserved: `refreshBadgeState(for:)` on mute and badge
    changes, `save(...)` on every change (same as today).
  - Empty state: "No services added yet." when there are no services.

### About tab

A grouped `Form`:

- **Identity**: app icon (`NSApp.applicationIconImage`, ~64pt) beside "Chorus"
  and "Version X (Y)" read from `Bundle.main`
  (`CFBundleShortVersionString` / `CFBundleVersion`).
- **Check for Updates**: reuse the existing `CheckForUpdatesView(updater:)`
  (already defined in `ChorusApp.swift`, reactive disabled state). Gated on
  `canImport(Sparkle)`.
- **Links**: "GitHub Repository" → https://github.com/nicojan/Chorus ;
  "MIT License" (link to the repo's LICENSE).
- **Credit**: "Built with ♥ by Nico Jan", where "Nico Jan" links to
  https://nicojan.com/ . Built as an `HStack` with an SF Symbol heart and a
  `Link`, so no fragile `Text` concatenation.

### Wiring the updater into Settings

`SettingsView` gains a Sparkle `SPUUpdater` so About can host the update button.
Gate the stored property and `import Sparkle` on `canImport(Sparkle)`. In
`ChorusApp`, pass `updaterController.updater` into `SettingsView` (with a plain
`SettingsView()` in the `#else` branch for builds without Sparkle).

## Files

- `Chorus/Views/Settings/SettingsView.swift` — rewrite: grouped General, table
  Notifications, new About tab. Likely split the three tab views into small
  sibling structs in the same file (each stays well under the size limits).
- `Chorus/App/ChorusApp.swift` — pass the updater into the `Settings` scene.

## Testing

Settings is SwiftUI view code with little pure logic, so the check is a clean
build plus a manual look at each tab. One extractable unit: a small helper that
formats the version string from a bundle's info dictionary — unit-test it with a
stub dictionary (`"1.0.2"`, `"3"` → `"Version 1.0.2 (3)"`). Verify the app
builds and the three tabs render as designed.

## Out of scope / deferred

- Privacy tab and its controls → spec C.
- Scheduled DND section on the Notifications tab → spec C.
- Any per-service customization UI (lives in the Edit Service sheet) → spec B.
