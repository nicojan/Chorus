# Service groups

Written 2026-10-25 with Nico. Status: design, not built.

## Why

Nico liked the box that now holds the global services in the space strip (`2e605e9`) more than any divider, and wants people to be able to draw the same box around services that belong together inside a space: Gmail, Calendar and Drive in Work, say. A group does the job a divider does, splitting a space's services into runs, but it reads more clearly.

## What a group is

- A box drawn around a run of services in one space. Every service in it stays visible. It is not an iOS folder: nothing collapses and nothing hides behind one icon.
- It looks like the global-services box: `.railCard()`, padded `ChorusCard.railPadding` on every side, so a row's hover and selection fill sits inside the card's corners. In the top bar it is the same card drawn round a run of tabs.
- A group may have a name or not. It starts with none. When it has one, the name sits above the box in the sidebar and the all-services list, and at the start of the box in the top bar. In the icon-only rail and the narrow strip there is no room, so the name goes in the tooltip and the VoiceOver label only. Chorus never suggests a name.
- A group holds at least two services. When one is left, the group goes, and its name with it.

## Goals

- Group, regroup and ungroup services in every layout: the sidebar (named and icon-only), the hybrid layout's bar along the top, the all-services list, and the space palette if it shows a space's services.
- Make groups by dragging, the iOS way, and also from a right-click menu, so the feature can be found and used without a drag (and by VoiceOver).
- Keep dividers exactly as they are. People already use them, and some will prefer them.
- Let Escape cancel any service drag and put everything back, which service drags cannot do today.

## Non-goals

- Collapsing a group, or a group shown as one icon.
- Groups inside the global-services box. That box is already their group.
- Groups of spaces.
- Colours, icons or badges for a group. A group shows no count of its own; its services show theirs.
- Nesting a group in a group, or a divider inside a group.

## Anti-goals (it fails if it does these, even if it works)

- A drag that groups when you meant to reorder. Moving past services must never group them; only a deliberate pause does.
- A target that slides out from under the pointer so the pause never lands. In the throwaway browser prototype (`.superpowers/brainstorm/…/drag-prototypes.html`, option A), opening the gap above the target pushed the target down, and a pointer held still then fell between rows. The real thing has to follow the target, so that pausing where you can see the service works.
- Signing anyone out, or losing an order or a divider, in the migration.
- Breaking the existing moves: dragging a service to another space, into or out of the global group, or a divider drag.

## How dragging works (Nico chose this)

Nico tried both prototypes and chose A, the iOS feel.

- **Moving past services:** the others slide aside to show where the dragged one will land, as the live reorder does today. Letting go puts it there.
- **Pausing over the middle of a service:** after 500 ms (a guess at iOS's pause, which Apple does not publish; keep it one constant that is easy to tune), that service swells a little and takes an accent outline. Letting go then makes a group of the two, or puts the dragged service into the target's group if it has one. Moving off the target before letting go cancels the swell.
- **Between two services inside a box:** the box takes the accent outline, and letting go puts the service in that group at that place.
- **Out of a box:** a service dropped outside its box leaves its group.
- **Escape:** ends the drag and puts every service, group and divider back as they were when it began.
- **The top bar:** the same, left and right instead of above and below.
- **Another space or the global group:** the moves that exist today keep working. A service that moves to another space leaves its group. Pausing over a service only groups within one space: a drag from another space or from the global box never swells a target.

## The ends of a box, and when the rules run (Claude's calls, from the builder check)

- **The box's outline decides.** A service dropped while its box is lit lands inside the group, at the place the gap shows, including either end. Dropped while no box is lit, it lands outside. So a member can be reordered within its box, and a service that only passes a box joins it only if it is let go while the box is lit.
- **Membership changes once, on drop.** The live reorder still saves the order as the drag goes, but it never changes a service's group. Joining, leaving and dissolving happen in the single write that ends the drag. Otherwise a two-member group would vanish mid-drag, and a service sliding through a run would join it on the way past. While a non-member sits in a run during a drag, the box is drawn round the members only.
- **Launch repairs a broken run.** If a crash ever leaves a group's members split by another service, the launch repair puts the outsider after the group's run, as `StoreRepair.repairDanglingLinks` already tidies links at launch.
- **Move Up / Move Down never change membership.** The VoiceOver actions and the keyboard step move a member within its box, and move a service outside a box past the whole box in one step. Joining and leaving are the menu's job.

## Moving a whole group (Nico asked for this; the details are Claude's calls)

- **Grab it by its name or by the box's edge** (its padding). The rows inside still drag one at a time.
- **Within the space:** the group moves as one, and the other services slide aside, as for a single service.
- **To another space:** dropped on a space in the strip, the sidebar's space list or the all-services list, the group goes there with its services, its name and its box. It asks first, as moving one service does (`pendingRailMove`), and the question lists the services that go. Each service keeps its sign-in, as a single move does.
- **Never into the global box.** Global services have no groups.
- **Escape** puts it back.
- **Right-click** the box or its name: **Move Group to ▸** a space, the same as the drag, and **Ungroup**, which keeps the services where they are and removes the box. Move Group is also a VoiceOver action, and Move Up / Move Down on the box move the whole group past its neighbours.

## Without dragging (Claude's call)

A service's right-click menu gets:

- **Group with ▸** listing the services next to it in that space that are not in its group. Choosing one groups the two (or adds this one to that one's group). The two must be next to each other in the list for a group to stay one run, so the menu lists only neighbours: the service above and the service below.
- **Remove from Group**, shown only for a service in a group. It moves the service just outside the box, below it.
- **Name Group…**, shown only for a service in a group. A small sheet with one field; an empty name removes the name.

The same three are VoiceOver actions on the row. The box's own menu is under "Moving a whole group".

## Data (Claude's call on the direction; details left to the builder)

Groups are a schema change: follow `CLAUDE.md` ("SwiftData schema changes"): freeze the current shape, bump `ChorusSchemaVCurrent.versionIdentifier`, add a stage, pin it in `testCurrentStoredShapeIsPinned`, and migrate a copy of a real store before shipping.

The direction, modelled on `RailDivider`, which avoided relationships on purpose:

- A new `ServiceGroup` entity with no relationships: `id`, `spaceID: UUID` as a plain attribute, `name: String?`, `createdAt`. Moving a group to another space rewrites its `spaceID` and its members' links in one save.
- `SpaceServiceLink` gets an optional `groupID: UUID?`. Optional and additive, so the stage can be lightweight.
- Deleting a space deletes its groups by hand in the same save, as `AppState.deleteSpace` does for dividers.
- A group's members stay one unbroken run in the merged order (`RailOrder`): no other service and no divider between them. Every edit that reorders goes through `RailEdits`, and it is the place that keeps this true: a service dropped inside a run joins the group, a divider can't land inside a run, and a group whose run breaks or drops to one member is dissolved in the same write.
- Setup export and import (`SetupArchive`) carry groups and their names.

## Dragging under the hood (Claude's call)

SwiftUI's `onDrag` never says when or how a drag ends, which is why Escape can't undo a service reorder today and why the divider drag was moved to AppKit (`RailDividerDragSource` in `RailDividerView.swift`). Groups need the end of the drag too: to tell a drop outside the box from a cancelled drag, and to put things back on Escape. So service rows get an AppKit drag source like the divider's, carrying the same `LiveReorder.serviceType` and `globalServiceType` payloads, the box gets one of its own with a new `groupType` payload, and the drop side (`LiveReorderDropDelegate`) learns the middle of a row from its edges and runs the pause timer. All four layouts share that drop handling, so one change reaches them all.

## Constraints

- macOS 14, 15 and 26 behave differently with SwiftData; see `CLAUDE.md`. Run CI on both older systems after each commit.
- Keep SwiftUI `body` chains short (the macOS 15 type-checker limit). New menus and sheets go in a `ViewModifier` of their own.
- Xcode 16.2 rejects some code that Xcode 26 accepts; the known cases are in `CONTRIBUTING.md`.
- Reduce Motion: no swell or slide animation; show the outline only.
- Public text (menu items, the Name Group sheet, What's New, release notes) goes through the humanizer loop.

## Left to the builder

- The exact sizes: how much the target swells, the outline weight, where the middle of a row ends and its edges begin.
- How the pause timer follows a target that moved, and any hysteresis so a pointer resting on a boundary does not flicker.
- How groups draw in the all-services list, where every space is already a card: a box inside the card is the obvious reading.
- Whether to add a What's New entry and a tip in this release.
- Test design, beyond pure tests for the `RailEdits` and `RailOrder` rules (joining, leaving, dissolving, the unbroken run, dividers kept out of runs) and the schema test above.
