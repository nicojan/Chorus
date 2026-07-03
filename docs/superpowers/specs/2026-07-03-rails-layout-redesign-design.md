# Rails layout redesign — design spec

Date: 2026-07-03
Status: approved direction, pending spec review
Scope: sub-project A of three (A rails, B brand icons, C app-wide Dynamic Type
& contrast). This spec covers A only. B and C get their own specs.

## Problem

The spaces and services rails are vertical-only, pinned to the left. Users want
the option to put them on top, and want the service selectors to read as folder
tabs rather than a bare icon column. The rails also use fixed point sizes and a
few low-contrast colors (part of the wider C work), which this pass fixes for the
rails as it restyles them.

## Goals

- A user-chosen layout with three modes; the current look stays the default.
- Services render as folder tabs in the horizontal modes (icon + name + badge).
- The rails respect text size and use contrast-safe selection/badge colors.
- No change to existing behavior for users who don't switch modes.

## Non-goals

- Brand icons (sub-project B) — tabs use whatever `ServiceIconView` resolves
  today until B lands.
- Dynamic Type / contrast outside the rails (sub-project C).
- Reordering, hibernation, mute, context menus — carried over unchanged.

## Layout modes

`enum RailLayout: String, CaseIterable { case sidebar, topBars, hybrid }`

- `sidebar` (default): spaces rail + services rail, both vertical on the left —
  today's layout, with a light visual refresh.
- `topBars`: a horizontal spaces row on top, a horizontal services tab row below
  it, web content fills the rest.
- `hybrid`: spaces rail stays vertical on the left, services render as a
  horizontal tab row across the top of the content.

## Preference & persistence

Add to `AppPreferences` (`Chorus/Models/AppPreferences.swift`):

```swift
var railLayoutRaw: String?   // optional → SwiftData lightweight migration; nil = sidebar
```

with an accessor mirroring `defaultZoomEffective` / `darkModePreference`:

```swift
var railLayout: RailLayout {
    railLayoutRaw.flatMap(RailLayout.init(rawValue:)) ?? .sidebar
}
```

Unknown/legacy/nil values resolve to `.sidebar` (same defensive pattern as
`DarkModePreference`). The `init` gains `railLayoutRaw: String? = nil`.

Control: a `Picker("Layout", …)` in Settings → General (`GeneralSettingsView`),
following the `defaultZoom` picker idiom — read `prefs.railLayout`, write
`ensurePrefs().railLayoutRaw = …`, `save(…)`. Segment/menu labels: "Sidebar",
"Top bars", "Spaces left, tabs on top".

## Layout wiring

`ContentView` branches on `appState.railLayout`:

- `sidebar`: current `HStack { SpaceStrip | Divider | ServiceSidebar | Divider |
  WebContent }`.
- `topBars`: `VStack { SpaceStripRow ; Divider ; ServiceTabBar ; Divider ;
  WebContent }`.
- `hybrid`: `HStack { SpaceStrip | Divider | VStack { ServiceTabBar ; Divider ;
  WebContent } }`.

The banners (store error, offline) and sheets/overlay stay at the outer `VStack`
as today.

Rails take an axis so we don't fork the views:

- `SpaceStripView(axis: .vertical | .horizontal)` — swaps its outer `VStack`
  for an `HStack` and the drag/scroll direction accordingly. Space chips are
  unchanged (emoji + selection + badge + mute); in horizontal mode they sit in a
  scrolling row with the "+" pinned at the end.
- Services: rather than overload `ServiceIconView`, add a new
  `ServiceTabView` for the horizontal folder-tab cell. `ServiceSidebarView`
  keeps rendering `ServiceIconView` cells vertically in `sidebar` mode and
  renders `ServiceTabView` cells in a horizontal `ScrollView` for `topBars` /
  `hybrid`. Reorder, context menu, and selection binding are shared.

## Folder-tab component (`ServiceTabView`)

- Content: brand/favicon icon + service name (`.lineLimit(1)`,
  `.truncationMode(.tail)`) + unread badge.
- Selected tab: background continuous with the web content (same fill), rounded
  top corners, no divider line beneath it; unselected tabs recessed
  (`Color.primary.opacity` hover/idle, matching the current rail tints).
- Overflow: horizontal `ScrollView(.horizontal)`; the "+" add button is pinned
  after the tab strip, not inside the scroll region.
- Reuses `ServiceReorder` for drag placement; reuses `serviceContextMenu`.
- Accessibility: `.accessibilityLabel` folds in name + unread + hibernated +
  muted (same string builder as `ServiceIconView`); `.accessibilityAddTraits`
  adds `.isButton` and `.isSelected`.

## Sidebar light refresh (also covers the rails' share of C)

- Replace fixed `.font(.system(size:))` in the rail cells with scalable sizing
  (`@ScaledMetric` for cell/badge dimensions, semantic or scaled font for the
  letter-tile initial) so the rails respond to the system text size.
- Contrast-safe selection and badge colors: keep the accent selection pill but
  verify the badge (white-on-red) and letter-tile (white-on-hashed-palette)
  combinations meet ~4.5:1; darken the tile palette / badge red as needed. Exact
  values decided during implementation against measured contrast.

## Accessibility

- Tabs and chips expose label + `.isSelected` (above).
- Layout is a user preference, so keyboard shortcuts (⌘1–9, ⌘[/], ⌃Tab) are
  unaffected — they act on selection, not geometry.
- Reduce Motion: any new tab-selection transition is gated on
  `accessibilityReduceMotion` (matches `WebContentView`).

## Testing

- Unit: `RailLayout` rawValue round-trip and the nil/garbage → `.sidebar`
  fallback (mirrors `testDarkModePreferenceParsesFromStoredString`).
- Unit: reuse existing `ServiceReorder` tests (unchanged).
- Manual (real app): switch all three modes; tab overflow scroll; drag-reorder
  in a horizontal bar; selection continuity of the active tab; text-size scaling.

## Files touched

- `Chorus/Models/AppPreferences.swift` — `railLayoutRaw` + `railLayout` + init.
- `Chorus/App/AppState.swift` — expose `railLayout` (read-through to prefs).
- `Chorus/Views/MainWindow/ContentView.swift` — branch layout by mode.
- `Chorus/Views/MainWindow/SpaceStripView.swift` — `axis` parameter.
- `Chorus/Views/MainWindow/ServiceSidebarView.swift` — render vertical icons vs
  horizontal tabs; `axis`.
- `Chorus/Views/MainWindow/ServiceTabView.swift` — new folder-tab cell (added to
  the existing target via the asset/compile path; it is a `.swift` file so it
  must be included in `project.yml` sources + `.pbxproj`, per the file-inclusion
  gotcha — or, to avoid that, live inside `ServiceSidebarView.swift`).
- `Chorus/Views/MainWindow/ServiceIconView.swift` — scalable sizing + contrast.
- `Chorus/Views/Settings/SettingsView.swift` — layout picker in General.
- `ChorusTests/ChorusTests.swift` — `RailLayout` parsing test.

## Follow-ups (separate specs)

- B — brand icons from thesvg (preferred over favicons).
- C — Dynamic Type & contrast for the rest of the app.
