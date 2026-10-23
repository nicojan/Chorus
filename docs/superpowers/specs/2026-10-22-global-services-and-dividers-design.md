# Global services and rail dividers

_2026-10-22. Asked for by Nico. Nico asked to skip the questions, so the design calls below are Claude's, and each one is marked for review._

Two features that both change what the rail lists:

1. **Global services.** A service that belongs to no space and shows in the rail whatever space you are in.
2. **Dividers.** A thin line you can put between services, and another kind you can put between spaces. Both are dragged to move, and dragging one off the rail and letting go removes it.

## Why

A service such as a calendar or a password manager is wanted in every space. Today the only way is to add it to each space, which gives one sign-in per copy and one badge per copy. Dividers let a long rail be split into groups without making more spaces.

## Goals

- A global service is one service with one sign-in, one web view and one badge, shown in every space.
- With no global services and no dividers, the rail looks exactly as it does now.
- Dividers behave like the rows around them: they reorder live under a drag, keep their place across launches, and go away when dragged off.
- No data is lost by any of it: making a service global, moving it back into a space, deleting a space, or upgrading the store.

## Non-goals

- Dividers in the setup export file. An imported setup has no dividers; nothing else is lost.
- A divider with a label or a colour.
- Moving a service divider from one space to another. It stays in the list it was made in.
- A "global" option in Add Service. A service is made global from its context menu or by dragging it into the global group (Claude's call, to keep the sheet as it is; easy to add later).

## Data model

Both features change the stored shape, so this is a new schema version (1.5.29) with a lightweight stage, following the steps in `CLAUDE.md`.

### Global services

`ServiceInstance` gains two optional attributes:

- `isGlobal: Bool?`: nil reads as false.
- `globalSortOrder: Int?`: its place in the global group.

A global service has **no** `SpaceServiceLink` rows. That is the invariant every path keeps: making a service global deletes its links in the same save; moving it into a space inserts one link and clears `isGlobal` in the same save.

Claude's call, over the alternative of a hidden "global" `Space` that global services link to. The hidden space would have let the link-based reorder code be reused. But about 25 places list spaces: the palette, the strip, the quick switcher, the menu bar, shortcuts, setup export and the store-completeness checks. Missing one filter would show a ghost space, or count it in a recovery decision. A flag on the service fails safer: a place that forgets globals just doesn't list them.

The launch reaper `reapOrphanedServices` deletes every service with no links. It must skip global services, or the first relaunch deletes them and their sign-in data. A test pins this.

### Dividers

A new entity, `RailDivider`:

| Attribute | Meaning |
|---|---|
| `id: UUID` | unique |
| `kindRaw: String` | `"services"` (between services) or `"spaces"` (between spaces) |
| `spaceID: UUID?` | for a services divider, the space it is in; nil means the global group. Always nil for a spaces divider. |
| `sortOrder: Int` | its place, in the same numbering as the rows around it |
| `createdAt: Date` | tie-break |

`spaceID` is a plain attribute, not a relationship. A relationship to `Space` would change `Space`'s stored shape and bring in the cascade differences between macOS 14, 15 and 26 described in `CLAUDE.md`. Deleting a space deletes its dividers explicitly, in the same save.

### One order for rows and dividers

A divider sits between rows, so it shares their numbering: a services divider shares `SpaceServiceLink.sortOrder` within its space (or `globalSortOrder` within the global group); a spaces divider shares `Space.sortOrder`. The list on screen is rows and dividers merged and sorted by `sortOrder`, ties broken rows first, then dividers by `createdAt`.

Every write that reorders must renumber the merged list, not the rows alone, or a renumbered row lands on a divider's number. So the reorder code in the rail, the strip and the palette goes through one pure helper (`RailOrder`) that takes the merged ids and returns the new numbering. Appending (a new service, a new space, a move into a space) takes one past the highest number in the merged list.

Anchoring a divider to a neighbour instead ("after service X") was ruled out: drag X across the divider and the divider goes with it, which is not what a line between groups should do.

## How it looks and behaves

### Global services

- **Rail on the left:** the global group sits at the top, under the traffic lights, above the space header, with a hairline under it. Then the space header and the space's services as now.
- **Bar along the top, and the hybrid bar:** global tabs come first, then a short vertical rule, then the space header (top bar only) and the space's tabs.
- **All services on the left:** a "Global" group heading (🌐) comes first, above the first space.
- With no global services, none of this is drawn.

Selecting a global service leaves the current space as it is. Switching space while a global service is showing selects the new space's first service, as switching does today; a global service does not count as "in" the new space for that check (Claude's call: switching space is a request to see that space).

⌘1–⌘9 and the arrow keys follow the rail's visible order, so globals come first.

Context menu on a space's service: **Show in Every Space** makes it global (Claude's name for it: it says where the service goes, where "Make Global" says what it becomes). Its memberships in every space are removed in the same save; its sign-in, settings and web view are kept.

Context menu on a global service: **Move to Space ▸** moves it into the chosen space (or a new one) and it stops being global. There is no "Remove from this space". **Delete service entirely** works as for any service.

Dragging: a service dropped on the global group becomes global; a global service dropped into a space moves there. As with moves between spaces today, nothing changes until release, so a cancelled drag leaves things where they were.

Elsewhere:

- **Badges.** A global service has its own badge. A space's total does not include it. The Dock total does.
- **Notifications.** Clicking one from a global service selects it and stays in the current space.
- **Quick switcher and menu bar.** Globals are listed under "Global".
- **Loading.** Global services preload at launch with the current space, and hibernate under the same rules as any service.
- **Mute.** Muting a space does not mute globals.
- **Setup export.** A global service exports and imports as global.

### Dividers

- **Services divider:** a hairline row 11 points tall across the rail, or a short vertical rule between tabs in the bar. It shows wherever that space's (or the global group's) services show.
- **Spaces divider:** a hairline row between spaces in the all-services rail, the hybrid strip and the space palette. The single-space header has nothing to put it between, so it doesn't show there.
- **Adding:** context menu **Add Divider Below** (**Add Divider After** in the bar) on a service; **Add Divider Below** on a space in the strip, the palette and the all-services heading.
- **Moving:** drag it. It reorders live among its own list, like a service does. Dropped anywhere else on the rail, nothing happens.
- **Removing:** drag it off the rail and let go. While it is off the rail the pointer shows the system's disappearing-item cursor, the puff the Dock shows, and on release the divider is gone and the rows close up. Also **Remove Divider** in its context menu and as a VoiceOver action, since not everyone can drag.

### Dragging off the rail

SwiftUI's `onDrag` gives no callback when a drag ends, so the divider's drag is started from AppKit (`NSDraggingSource`). It carries one pasteboard type, `com.nicojan.chorus.divider-id`, which nothing outside Chorus accepts. Each rail, the strip and the palette mark their area (`railDropZone()`), and the rule is: a drag that ends with no operation, at a point outside that area or over another window, removes the divider. A drop a row took is a move, and a release over a gap in the rail, or Escape over it, keeps the divider. Pressing Escape off the rail removes it, as letting go there would.

The animated puff (`NSShowAnimationEffect`) has been deprecated since macOS 14, the deployment target, so it is not used; the disappearing-item cursor during the drag gives the same cue (Claude's call).

The live reorder rows read the same "what is being dragged" state the services use, set when the AppKit drag starts.

## Constraints

- Stores must migrate losslessly from 1.5.19's shape. Migration test plus a run against a copy of a real store, as `CLAUDE.md` asks.
- Must build with Xcode 16.2 for the macOS 14 CI job, and behave on 14, 15 and 26.
- No `-configuration Release` test runs. Live checks happen in a Debug build, whose store is `Chorus-debug`.

## Left to the builder

Spacing and exact sizes of the divider rows and the global group, the drag preview's look, and the order of the context-menu items, matched to what is there.
