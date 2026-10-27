# Global services placement — design

_2026-10-26. Approved in conversation with Nico; mockup at `.superpowers/brainstorm/56725-1793061878/content/placement.html` (not committed)._

## Why

The global ("universal") services live in a box at one fixed spot: the top of the space strip in the "Spaces on the left, services on top" layout (`RailLayout.hybrid`), and the start of the single rail or bar in the other three layouts. Nico wants his spaces at the top of the rail and the global services at the bottom, and wants every user to be able to pick the spot that suits them.

## Goals

- A setting for where the global services box sits.
- Moving the box by dragging it to any allowed spot, with the allowed spots shown while dragging.
- The choice survives relaunch and carries sensibly between layouts.

## Non-goals

- Changing what the global group is or how a single global service moves in or out of it. Dragging an icon inside the box keeps working as today (reorder, or move into a space with a confirmation).
- Placing the box in the middle of a list, or between two spaces.
- Changing the order of global services in the menu bar menu or the Quick Switcher.

## Anti-goals (a failure even if it works)

- Any change to a SwiftData `@Model`. The setting must not need a schema version.
- Dragging the box makes it harder to drag a single global service out of it, or a service into it.
- A layout where the box sits at the end but the rail no longer scrolls, or the box covers the add-space button or the last space.
- Breaking the macOS 14 or 15 CI builds (Xcode 16.2), or growing a SwiftUI `body` modifier chain past what the macOS 15 runner can type-check (see CLAUDE.md).

## Decided

### The spots

| Layout | Spots |
|---|---|
| Spaces on the left, services on top (`hybrid`) | 1. Above the spaces in the space strip (today, the default). 2. Below the spaces, pinned to the bottom of the strip. 3. Left end of the services bar. 4. Right end of the services bar, pinned to the right edge. |
| Rail on the left (`sidebar`), All services on the left (`allServices`) | Top of the rail (today, the default), or bottom of the rail, pinned to the bottom. |
| Bar along the top (`topBars`) | Left end of the bar (today, the default), or right end, pinned to the right edge. |

"Pinned" means the box sits at the far edge with empty space between it and the last item, as in the mockup, not directly after the last item.

### What is stored

Two values in `UserDefaults` via `@AppStorage`, the way `SpaceStripMetrics.defaultsKey` and `ServiceNameVisibility.defaultsKey` are stored, not in `AppPreferences`:

- **Edge:** start or end. Start = top of a vertical rail or left of a horizontal bar.
- **Bar (two-bar layout only):** the space strip or the services bar.

The four hybrid spots are (strip, start), (strip, end), (services bar, start), (services bar, end). The one-bar layouts read only the edge. So "below the spaces" becomes "bottom of the rail" after switching to "Rail on the left", and "right end of the services bar" becomes "bottom of the rail" too. Defaults: start, and the space strip, which is today's arrangement, so nobody's window changes on update.

### Settings

In Settings → Appearance, directly under the Layout picker, a picker named "Global services". Its choices depend on the current layout: four in the two-bar layout, worded as in the table above; two in the others, worded for that layout ("Top of the rail" / "Bottom of the rail", or "Left end of the bar" / "Right end of the bar"). It shows even when there are no global services, so a user can set it before adding any (my call).

### Dragging

- The box is dragged by its border area: the padding between and around the icons, not an icon. An icon inside still starts the single-service drag it starts today.
- In "Rail on the left" and "Bar along the top" the global services are drawn today as plain rows or tabs set off by a rule, with nothing to grab. In every layout the global services get a box of their own, like the `.railCard()` the space strip and the all-services rail already use, so there is always a border to grab. The mockup Nico approved showed a box in every layout (my call, grounded in that).
- While the box is being dragged, every allowed spot for the current layout shows a drop target (highlight or insertion bar in the style the rail already uses for drops). Dropping on one sets the stored values; dropping anywhere else leaves the box where it was.
- No confirmation dialog: moving the box changes nothing about which services are global.
- The box's drag needs its own type, alongside the existing ones in `LiveReorder` (`RailSupport.swift`), declared in `Chorus/Info.plist` the way `com.nicojan.chorus.service-group-id` is.
- Other drop targets refuse the box (a space, a service list, a group lane), the way the global lanes already refuse a group.
- The box sits in the hidden title bar band in the top-bar layouts, where a mouse-down can drag the window instead of the box. Use the fix the tabs already use there (memory `swiftui-window-drag-titlebar`: `isMovable = false` plus `performDrag` handles) and check that dragging the box never moves the window.

### Menu on the box

Right-clicking the box's border opens a menu with a "Move Global Services" submenu listing the current layout's spots, the current one checked. It is the same choice as the Settings picker, reachable where the box is, and it gives VoiceOver and keyboard users a way to move the box, since nobody can drag without a pointer (my call, added in review). Right-clicking an icon inside the box keeps its own service menu.

### Order everywhere else

Keyboard navigation follows the order on screen: when the box is at the end, its services come after the space's. That covers the arrow keys (`UnifiedRailView.navigationStops`) and, as Nico decided, ⌘1–9 and ⌘[ / ⌘], which today come from `AppState.railServices(forSpace:)` and, in the all-services layout, `getAllServiceDestinations()` (`KeyboardShortcutManager.swift`). So the placement has to reach those functions and the `Commands` that use them, not only the views, with tests for both orders. `railServices` also sets the preload order and launch restore; letting those follow the same order is fine (my call: one order, not two). The menu bar menu and the Quick Switcher keep their current order.

## Left to the builder

- How the space strip and the services bar are restructured to draw the box at either end, and how much of `UnifiedRailView` (2,167 lines) should move into a new file while doing it. Splitting is welcome.
- The exact look of the drop targets, as long as it matches the rail's existing drop feedback.
- The names of the stored keys and the enum or struct that resolves (layout, edge, bar) to a spot. That resolver should be a plain value type with unit tests covering every layout and stored combination.
- Where the box sits relative to the add buttons. My call: at the end of a vertical rail or strip, the box goes directly above the "+" button, which stays the last thing there. At the right end of a horizontal bar, the add-service "+" stays with the space's tabs, and the box sits after the scrolling tab row and before the back/forward/home buttons and the space kept for the donation button. When the bar overflows, the tabs scroll; the box and the buttons never do.

## Done means

- Unit tests for the resolver and for any move logic; the full suite green; CI green on macOS 14 and 15.
- Checked in a Debug build, in all four layouts: each spot draws correctly, the Settings picker and the box's menu move the box, dragging the box to each spot works, dragging the box never moves the window, dragging a single service in and out of the box still works in every spot, and ⌘1 opens the first service on screen.
- The setup export leaves the new setting out, as it leaves out "show names" and the other display settings stored the same way.
- CHANGELOG entry and a What's New entry for the next release, both through the humanizer check (CLAUDE.md).
