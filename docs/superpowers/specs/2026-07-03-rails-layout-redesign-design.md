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
  `.truncationMode(.tail)`) + unread badge. Tab width clamped
  (min ~120, max ~220) so labels stay readable without any one tab dominating.
- Selected tab: background continuous with the web content (same fill), rounded
  top corners, no divider line beneath it; unselected tabs recessed
  (`Color.primary.opacity` hover/idle, matching the current rail tints).
- Overflow: horizontal `ScrollView(.horizontal)`; the "+" add button is pinned
  after the tab strip, not inside the scroll region. **The strip is wrapped in a
  `ScrollViewReader` and scrolls the selected tab into view on selection change**
  (so ⌘1–9 / quick-switcher selection of an off-screen service reveals it),
  gated on `accessibilityReduceMotion` for the animation.
- Icon comes from one shared resolver (see "Icon source") so sub-project B's
  brand icons appear in tabs with no further tab changes.
- Reuses `ServiceReorder` for drag placement; reuses `serviceContextMenu`.
- Accessibility: `.accessibilityLabel` folds in name + unread + hibernated +
  muted (same string builder as `ServiceIconView`); `.accessibilityAddTraits`
  adds `.isButton` and `.isSelected`.

## Icon source (shared)

Both `ServiceIconView` (vertical) and `ServiceTabView` (horizontal) resolve their
image through the same helper — custom icon → (later, brand asset) → fetched
favicon → letter tile. Centralizing it now means sub-project B swaps in bundled
brand icons in one place and both the rail and the tabs pick them up.

## Sidebar light refresh (contrast-first; the rails' share of C)

macOS exposes little runtime Dynamic Type, and the rails are geometry-tight
(52pt), so aggressive `@ScaledMetric` scaling is risk without much payoff and can
clip the rail. The rails' real accessibility win is **contrast**:

- Letter-tile fallback: replace the hashed `[.blue, .purple, …]` palette (several
  fail 4.5:1 on white) with a contrast-checked set — Tailwind-700-class shades,
  each ≥4.5:1 against white:
  `#1D4ED8, #6D28D9, #15803D, #C2410C, #BE185D, #0F766E, #4338CA, #B91C1C`.
- Badge: `#DC2626` (~4.6:1 with white) instead of pure system red (~3.9:1).
- Keep the accent selection pill; selection is also carried by the `.isSelected`
  trait, so it isn't color-only.
- Fonts: leave the rail geometry fixed; only the horizontal tab **labels** use a
  semantic/scalable font (they have room to grow). No forced scaling of the
  52pt icon cells. Broader Dynamic Type is sub-project C.

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
- `Chorus/Views/MainWindow/ServiceTabView.swift` — new folder-tab cell. It's a
  `.swift` file, so confirm how `project.yml` lists sources: if the `Chorus`
  group is a directory glob, `xcodegen generate` picks it up (then keep
  `.pbxproj` in sync per CLAUDE.md); if files are listed individually, add it
  there too. Verify a clean build includes it before relying on it.
- `Chorus/Views/MainWindow/ServiceIconView.swift` — shared icon resolver +
  contrast-safe tile palette / badge.
- `Chorus/Views/Settings/SettingsView.swift` — layout picker in General.
- `ChorusTests/ChorusTests.swift` — `RailLayout` parsing test.

## Follow-ups (separate specs)

- B — brand icons from thesvg (preferred over favicons).
- C — Dynamic Type & contrast for the rest of the app.
