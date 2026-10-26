# Service Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let people draw a box round related services in a space, by an iOS-style pause-to-group drag or from the menu, name it or not, and move it as one, in every layout.

**Architecture:** A new `ServiceGroup` entity with no relationships, and an optional `groupID` on `SpaceServiceLink`. The rules (join, leave, dissolve, keep a group one unbroken run, where a new entry may land, keyboard steps) are pure functions in `GroupRules`, applied to the store by `RailEdits`. Drawing goes through a pure `RailRuns`. Service drags get a known end (Task 0 settles how), and exactly one store write happens per drag, in the drag-end handler.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSDraggingSource`), SwiftData with `VersionedSchema`, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-25-service-groups-design.md`

**Revision 2 (2026-10-25):** reworked after an independent review of revision 1: one write per drag (Task 10), the all-services layout on the new drag (Task 9), a live reorder that no longer swaps a row away from the pointer (Task 10), the lit-box lifecycle (Task 10), dividers and cross-space drops kept out of runs (Tasks 2–3), groups that cannot leak into another space (Task 3), fetches that need not see unsaved changes (Task 3), and smaller fixes marked where they land.

## Global Constraints

- Branch `feat/service-groups` off `main`, with a draft pull request opened in Task 0. CI (`test.yml`) runs only on pushes to `main` and on pull requests, so the draft PR is what makes every push run CI on macOS 14 and 15. Merge only after the by-hand pass in Task 12.
- Test command: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`. Never add `-configuration Release`.
- New `.swift` files: run `xcodegen generate` and commit the regenerated `Chorus.xcodeproj/project.pbxproj` with them.
- Xcode 16.2 (CI's macOS 14 job) rejects code Xcode 26 accepts; the known cases are in `CONTRIBUTING.md`.
- SwiftData: follow `CLAUDE.md` ("SwiftData schema changes", "SwiftData behaves differently on macOS 14, 15 and 26"). No relationships on the new entity; insert a link only when `modelContext == nil`; delete join rows explicitly; never rely on a fetch seeing an unsaved insert or delete (pass what changed, as `applyOrder`'s `extra` does).
- A group belongs to one space. Anywhere a link's group is read, a `groupID` whose `ServiceGroup` row is missing **or whose `spaceID` is not the link's space** reads as no group.
- Exactly one store write ends a drag, made in the drag-end handler for every end but Escape. Live moves during a drag save order only and never change membership.
- Keep SwiftUI `body` modifier chains short; new menus, sheets and confirmations go in a `ViewModifier` of their own (see `RailMoveConfirmation`).
- The pause before a target swells: 500 ms, one constant (`GroupDrag.pauseBeforeGrouping`).
- Reduce Motion: no swell and no slide; the outline alone.
- A group holds at least two services. Never in the global box, no nesting, no divider inside a run.
- Public text (menu items, the Name Group sheet, the move prompt, accessibility labels, CHANGELOG, What's New) goes through `humanizer_check_text` until `prohibitions_clear`.
- Tasks 9–11 follow Task 0's written outcome, not this plan's first guess at the drag source.

## Review Focus

1. **A grouped service leaves its space by a path other than a drag** (Move to Space, Remove from this space, Show in Every Space from a service in two spaces, Delete service entirely): its group loses it, a group left with one member goes, and no group follows it into another space. Tests in Task 3, calling the real code paths.
2. **A store with data the rules forbid** (one-member group, a run split by a service or a divider, a `groupID` naming a deleted group or another space's group, a group whose space is gone): drawing shows no wrong box, and launch repairs it, damaged and restored stores included. Tests in Tasks 3 and 5.
3. **Something lands in the middle of a run from outside**: a divider (added, dragged or stepped), a service from another space, a global service moved in, a setup import into an existing space. It lands after the run and never splits it. Tests in Tasks 2, 3 and 6.
4. **A drag that ends anywhere**: over a gap, a box's padding, the add button, the web view, a cancelled cross-space prompt, or by Escape. One write, the right membership, and Escape restores order and membership exactly. Tests in Tasks 9 and 10; by hand in Task 10.
5. **The pointer at rest by a target**: the row next to the dragged one can be paused on, a boundary does not flicker, and a stale lit box does not pull a service back in. Tests in Task 10; by hand in Task 10.

---

### Task 0: Spike: a service drag whose end is known

Throwaway. The divider drags from AppKit (`DividerDragView`, `RailDividerView.swift`), but that view takes the mouse and right-click for itself and builds its own menu. A service row cannot give those up: a click selects it, right-click shows the large SwiftUI `.contextMenu`, hover draws the hover fill, it takes keyboard focus, and VoiceOver reads it. And with boxes (Task 7) a row that moves between a box and the top level is rebuilt mid-drag, which would remove an `NSView` that is the drag's source.

**Files:** a scratch branch `spike/row-drag-source` off `main`, never merged.

- [ ] **Step 1:** Create `feat/service-groups` from `main`, push it, open a draft PR: `gh pr create --draft --title "Service groups" --body "Plan: docs/superpowers/plans/2026-10-25-service-groups.md"`.
- [ ] **Step 2:** On the spike branch, try in order; stop at the first that passes every check in Step 3:
  1. An AppKit overlay on the row that starts a drag past a 3 pt move and otherwise hands events on: a click to the SwiftUI row underneath (`hitTest` returning nil until a drag begins, or forwarding to `nextResponder`), right-click to the hosting view so the SwiftUI menu shows, and no tracking area that hides hover. The session's source is a long-lived object (`RailDragSession.shared`, an `NSObject` conforming to `NSDraggingSource`), not the row's view, so the session outlives a rebuilt row.
  2. SwiftUI `.onDrag` kept, with the end learned separately: while a drag is live, watch `NSEvent.pressedMouseButtons` for the release, and catch Escape (a local `keyDown` monitor, or `NSApp.currentEvent?.type == .keyDown` when the drop delegate sees the drag leave).
- [ ] **Step 3:** The checks, Debug build, sidebar and top bar: a click selects; right-click shows the full service menu; hover draws; Tab focus and the focus ring work; VoiceOver reads the row and its actions; a drag reorders; the app learns when the drag ended and whether Escape ended it; **the end still arrives when the dragged row is removed from its parent and recreated elsewhere mid-drag** (simulate by toggling a wrapper view on the row during the drag).
- [ ] **Step 4:** Write the outcome into this plan as a "Spike outcome" paragraph at the top of Task 9 (approach, what it took to keep clicks/menus/hover, how the end is learned), commit it on `feat/service-groups`, delete the spike branch.
- [ ] **Step 5: If neither passes,** stop and tell Nico. The fallback keeps `.onDrag` and decides membership in `performDrop` on rows and boxes; Escape cannot restore a service drag and a release outside every row writes nothing. That drops a spec goal and needs his say.

---

### Task 1: Store groups (schema 1.5.30)

**Files:**
- Create: `Chorus/Models/ServiceGroup.swift`
- Modify: `Chorus/Models/SpaceServiceLink.swift`, `Chorus/Models/Schema/ChorusSchema.swift`
- Test: `ChorusTests/GroupTests.swift` (new), `ChorusTests/ChorusTests.swift` (`testCurrentStoredShapeIsPinned`)

**Interfaces:**
- Produces: `@Model final class ServiceGroup { @Attribute(.unique) var id: UUID; var spaceID: UUID; var name: String?; var createdAt: Date; init(id: UUID = UUID(), spaceID: UUID, name: String? = nil, createdAt: Date = Date()) }`; `SpaceServiceLink.groupID: UUID?`; frozen `ChorusSchemaV1_5_29`; `ChorusSchemaVCurrent.versionIdentifier == Schema.Version(1, 5, 30)` with `ServiceGroup.self` in its models.

- [ ] **Step 1:** Work on `feat/service-groups`.
- [ ] **Step 2: Write the failing tests.** In `GroupTests.swift` (copy `RailTests`' private `makeContainer()` and `makeSpace(_:order:services:in:)`): `testMigratesFrom1_5_29WithNoGroups` — a `ChorusSchemaV1_5_29` store at a temp URL with a space, a service, a link (`sortOrder` 3) and a `RailDivider`, reopened at current through `ChorusMigrationPlan`: `link.groupID == nil`, `link.sortOrder == 3`, one divider, no `ServiceGroup`. In `testCurrentStoredShapeIsPinned`: `ServiceGroup` attributes `["id", "spaceID", "name", "createdAt"]`, no relationships; `"groupID"` joins `SpaceServiceLink`'s set.
- [ ] **Step 3:** Run. Expected: FAIL.
- [ ] **Step 4:** Freeze the current shape as `ChorusSchemaV1_5_29` (namespace copies of `ServiceInstance`, `Space`, `SpaceServiceLink`, `RailDivider`; reuse `ChorusSchemaV1_5_11.AppPreferences` as V1_5_19 does). Add `ServiceGroup.swift` (doc comment: no relationships, for `RailDivider`'s reasons) and `SpaceServiceLink.groupID` (doc comment: nil is no group; a plain id, as `RailDivider.spaceID` is). Bump current to `(1, 5, 30)` with its comment, add the schema to `schemas`, and a `.lightweight` stage from `ChorusSchemaV1_5_29` with a comment. `xcodegen generate`.
- [ ] **Step 5:** Run. Expected: PASS. **Step 6: Commit** `feat: store service groups (schema 1.5.30)`, push, CI green.

---

### Task 2: The group rules, pure

**Files:**
- Create: `Chorus/Models/GroupRules.swift`
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Produces:
  - `struct GroupEntry: Equatable { let id: UUID; let groupID: UUID?; let isDivider: Bool }` — one list entry in display order; `groupID` nil for dividers and ungrouped rows.
  - `enum GroupRules`, all `nonisolated static`:
    - `repaired(_ entries: [GroupEntry]) -> [GroupEntry]` — every group one unbroken run at the place of its first member (outsiders and dividers inside a run move to just after it, in their order); a group with fewer than two members dissolves.
    - `joining(_ dragged: UUID, onto target: UUID, in entries: [GroupEntry], newGroupID: UUID) -> [GroupEntry]` — `dragged` takes `target.groupID ?? newGroupID` and lands **next to the target on the side it was on** (before the target when it was below it, after when above), then `repaired`.
    - `placing(_ dragged: UUID, in entries: [GroupEntry], litGroup: UUID?) -> [GroupEntry]` — `entries` is the list as it stands after the live moves (it already holds `dragged` where the drag left it); `dragged` takes `litGroup` **only if `dragged` sits inside or at either end of that group's run**, else nil; then `repaired`.
    - `landingAnchor(before beforeID: UUID?, in entries: [GroupEntry]) -> UUID?` — for anything arriving from outside the list (a divider being added, a service from another space, a global service): when `beforeID` is a member that is not the first of its run, the entry after the run instead, so nothing lands inside a run. Nil means the end.
    - `stepping(_ id: UUID, forward: Bool, in entries: [GroupEntry]) -> [UUID]` — Move Up/Down: a member moves one place within its run and never out; a row or a divider outside a run steps over a whole run in one step; membership untouched.
    - `steppingGroup(_ groupID: UUID, forward: Bool, in entries: [GroupEntry]) -> [UUID]` — the whole run passes its neighbour (a row, a divider, or another whole run).
    - `groupWithCandidates(for id: UUID, in entries: [GroupEntry]) -> [UUID]` — the rows directly above and below `id` that are not dividers and not in `id`'s group.

- [ ] **Step 1: Write the failing tests** (ids `let a = UUID()`…, helper `e(_ id: UUID, _ g: UUID? = nil, divider: Bool = false)`):
  - `testRepairedDissolvesAOneMemberGroup`: `[e(a,g), e(b)]` → `[e(a), e(b)]`.
  - `testRepairedMovesAnOutsiderAfterTheRun`: `[e(a,g), e(x), e(b,g), e(c)]` → `[e(a,g), e(b,g), e(x), e(c)]`.
  - `testRepairedMovesADividerOutOfTheRun`: `[e(a,g), e(d, divider: true), e(b,g)]` → `[e(a,g), e(b,g), e(d, divider: true)]`.
  - `testJoiningFromBelowLandsBeforeTheTarget`: `c` onto `a` in `[e(a), e(b), e(c)]` with `newGroupID: n` → `[e(a,n), e(c,n), e(b)]`… **from above**: `a` onto `c` → `[e(b), e(a,n), e(c,n)]`.
  - `testJoiningAGroupedTargetAddsToItsGroup`: `c` onto `b` in `[e(a,g), e(b,g), e(c)]` → `[e(a,g), e(b,g), e(c,g)]`.
  - `testJoiningLeavesTheOldGroupAndDissolvesIt`: `b` onto `c` in `[e(a,g), e(b,g), e(c)]` → `[e(a), e(b,n), e(c,n)]`.
  - `testPlacingAtEitherEndOfALitRunJoins`: `[e(x), e(a,g), e(b,g)]` with `litGroup: g` → `x.groupID == g`; `[e(a,g), e(b,g), e(x)]` likewise.
  - `testPlacingIgnoresAStaleLitGroup`: `[e(a,g), e(b,g), e(y), e(x)]` with `litGroup: g` → `x.groupID == nil` (it does not touch the run).
  - `testPlacingWithNoLitBoxLeavesAndDissolves`: `[e(a,g), e(c), e(b,g)]`, dragged `b`, `litGroup: nil` → `b` and `a` ungrouped.
  - `testLandingAnchorSkipsPastARun`: anchor before `b` in `[e(a,g), e(b,g), e(c)]` → `c`; before `a` → `a`; before `b` in `[e(a,g), e(b,g)]` → nil.
  - `testSteppingAMemberStaysInItsRun`, `testSteppingAnOutsiderJumpsAWholeRun`, `testSteppingADividerJumpsAWholeRun`, `testSteppingAGroupPassesItsNeighbour` (as revision 1, plus the divider case).
  - `testGroupWithCandidatesAreTheOutsideNeighbours`: for `c` in `[e(a,g), e(b,g), e(c), e(d, divider: true), e(f)]` → `[b]`; for `x` in `[e(w), e(x), e(y)]` → `[w, y]`.
- [ ] **Step 2:** Run. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `feat: the rules that keep a service group one run`, push.

---

### Task 3: Store edits for groups

**Files:**
- Modify: `Chorus/Services/RailEdits.swift` (`// MARK: - Groups`, and the existing edits listed below)
- Modify: `Chorus/Views/MainWindow/UnifiedRailView.swift` (`moveService`, `removeFromSpace` call `RailEdits`), `Chorus/App/AppState+Rail.swift` (`deleteServiceEntirely`), `Chorus/App/AppState.swift` (`deleteSpace`)
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Consumes: Task 2.
- Produces, `@MainActor static` on `RailEdits`; each saves everything it changed or rolls it all back, unless marked "does not save":
  - `groupEntries(inSpace spaceID: UUID, context: ModelContext, knownGroups: [UUID: UUID] = [:], removedLinks: Set<UUID> = []) -> [GroupEntry]` — the space's merged entries with each link's group. `knownGroups` maps group id → space id for groups inserted in this unsaved edit; `removedLinks` are links deleted in it. A `groupID` with no row (fetched or known) or whose `spaceID` differs reads as nil.
  - `tidyGroups(inSpace spaceID: UUID, context: ModelContext, knownGroups: [UUID: UUID] = [:], removedLinks: Set<UUID> = []) -> Bool` — applies `GroupRules.repaired` (order through `applyOrder`, membership onto the links) and deletes `ServiceGroup` rows of this space with no member left; returns whether it changed anything. Does not save.
  - `groupLink(_ draggedLinkID: UUID, onto targetLinkID: UUID, context:) -> Bool` — refused (false, nothing changed) when either link is gone or they are in different spaces. Creates the `ServiceGroup` (target's space) when the target is ungrouped, passing it in `knownGroups`.
  - `finishDrag(_ draggedLinkID: UUID, inSpace spaceID: UUID, litGroup: UUID?, context:) -> Bool` — the write that ends a within-space drag: reads the list from the store (never from the view), applies `GroupRules.placing`, tidies, saves.
  - `removeFromGroup(_ linkID: UUID, context:) -> Bool`, `nameGroup(_ groupID: UUID, _ name: String?, context:) -> Bool` (trimmed; empty is nil; at most `SetupArchive.Limit.textLength` characters), `ungroup(_ groupID: UUID, context:) -> Bool`.
  - `leaveSpace(_ linkID: UUID, context:)` — deletes the link and tidies its space with `removedLinks`. Does not save. `UnifiedRailView.removeFromSpace` calls it in place of its own delete.
  - `forgetService(_ serviceID: UUID, context:)` — tidies every space the service's links are in, with those links in `removedLinks`. Does not save. `AppState.deleteServiceEntirely` calls it before its delete.
  - `deleteGroups(ofSpace spaceID: UUID, context:)` — does not save; `AppState.deleteSpace` calls it beside `deleteDividers`.
  - Changed existing edits: `moveMembership` clears the link's `groupID`, places it with `GroupRules.landingAnchor`, and tidies **both** spaces; `moveIntoSpace` places with `landingAnchor` and tidies the target; `makeGlobal` tidies **every** space it removed a link from, with those links in `removedLinks`; `addDivider` places with `landingAnchor` (the anchor is the entry after `afterID`).
  - `UnifiedRailView.moveService` stops writing `link.space` itself and calls `RailEdits.moveMembership` (keeping its selection handling).

- [ ] **Step 1: Write the failing tests** (in-memory store; every Review Focus test calls the real function, not a re-creation of its steps):
  - `testGroupLinkMakesAGroupRowAndSetsBothLinks`; `testGroupLinkRefusesLinksInDifferentSpaces`.
  - `testFinishDragReadsTheOrderFromTheStore`: live-reorder with `RailEdits.reorder`, then `finishDrag` with a lit group → the reordered order stands.
  - `testRemovingTheSecondLastMemberDeletesTheGroupRow`.
  - Review Focus 1: `testMoveMembershipLeavesTheGroup`; `testMoveServiceFromTheMenuDoesNotCarryTheGroup` (a two-member pair of a four-member group moved by `moveMembership` one at a time: both arrive with `groupID == nil`); `testMakeGlobalTidiesEverySpaceItLeaves` (a service grouped in two spaces); `testLeaveSpaceLeavesTheGroup`; `testForgetServiceLeavesItsGroups`.
  - Review Focus 2: `testGroupEntriesIgnoresAMissingOrForeignGroup`.
  - Review Focus 3: `testMoveMembershipBeforeAMidRunMemberLandsAfterTheRun`; `testMoveIntoSpaceBeforeAMidRunMemberLandsAfterTheRun`; `testAddDividerAfterAMidRunMemberLandsAfterTheRun`.
  - `testDeleteSpaceDeletesItsGroups`; `testNameGroupTrimsClearsAndCaps`.
- [ ] **Step 2:** Run. Expected: FAIL. **Step 3:** Implement and rewire the view and `AppState` paths named above. **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `feat: store edits for service groups`, push, CI green.

---

### Task 4: Move a whole group

**Files:**
- Modify: `Chorus/Services/RailEdits.swift`, `Chorus/App/AppState+Rail.swift`
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Produces:
  - `RailEdits.reorderGroup(_ groupID: UUID, order: [UUID], inSpace spaceID: UUID, context:) -> Bool` — the run moved as one; membership untouched; tidies; saves.
  - `RailEdits.moveGroup(_ groupID: UUID, toSpace spaceID: UUID, before beforeID: UUID?, context:) -> Bool` — every member's link moves, in order, landing per `landingAnchor`; `ServiceGroup.spaceID` changes; both spaces tidied; one save. Refused with nothing changed when any member's service is already in the target space.
  - `RailEdits.eligibleSpaces(forGroup groupID: UUID, context:) -> [UUID]` — spaces other than the group's own that hold none of its members' services.
  - `RailMove.groupIntoSpace(groupID: UUID, spaceID: UUID, before: UUID?)`, `id` `"group-space-\(group)-\(space)"`; `AppState.prompt(for:)` for it: title `"Move these services to \(space.name)?"` without a name, `"Move \(name) to \(space.name)?"` with one; message lists the services (`AppState.listed`) and says each keeps its sign-in; confirm `"Move"`. Humanizer before commit.
  - `AppState.moveGroup(_ groupID: UUID, toSpace spaceID: UUID, before beforeID: UUID?, follow: Bool = false) -> Bool` — selection as `moveGlobalService` handles it: with `follow` the view goes to the space; without, a showing member clears the selection. `AppState.reorderGroup(_ groupID: UUID, order: [UUID], inSpace spaceID: UUID) -> Bool`.
- [ ] **Step 1: Write the failing tests:** `testMoveGroupTakesEveryMemberAndTheName`; `testMoveGroupIsRefusedWhenAMemberIsAlreadyThere`; `testEligibleSpacesLeaveOutSpacesHoldingAMember`; `testReorderGroupMovesTheRunAsOne`; `testGroupMovePromptNamesTheServices`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5: Commit** `feat: move a service group as one`, push.

---

### Task 5: Repair at launch, and draw only real groups

**Files:**
- Modify: `Chorus/App/AppState.swift` (launch, beside `reapOrphanedServices()`)
- Create: `Chorus/Views/MainWindow/RailRuns.swift`
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Produces:
  - `RailEdits.repairGroups(context:) -> Bool` — `tidyGroups` on every space, deletes `ServiceGroup` rows whose space no longer exists, saves only when something changed (logs the count at `.info`). Runs at every launch, **including damaged, restored and in-memory stores** (it touches no sign-in, unlike the reap it sits beside).
  - `enum RailRun: Identifiable { case row(RailItem); case group(id: UUID, name: String?, items: [RailItem], holdsDragged: Bool) }`; `enum RailRuns { static func runs(_ items: [RailItem], groupOf: (UUID) -> UUID?, nameOf: (UUID) -> String?, dragged: UUID? = nil) -> [RailRun]; static func litGroup(in runs: [RailRun]) -> UUID? }` — consecutive members of one group make a `.group` only when there are two or more; anything else is a `.row`. `dragged`, the row being dragged (it sits in the list itself during a live drag), is drawn inside a box when it lies between two of that box's members, without splitting it; then `holdsDragged` is true. A run split by anything else draws as rows. `groupOf` is the caller's, and must already treat a missing or foreign group as nil.
- [ ] **Step 1: Write the failing tests:** `testRepairGroupsFixesASplitRunAndAOneMemberGroup`; `testRepairGroupsDeletesAGroupWhoseSpaceIsGone`; `testRunsDrawAOneMemberGroupAsARow`; `testRunsDrawASplitGroupAsRows`; `testRunsBoxAWholeRun`; `testRunsKeepTheBoxRoundADraggedRowInsideIt` (`[a, x, b]`, dragged `x` → one `.group`, `holdsDragged`, `litGroup == g`).
- [ ] **Step 2:** FAIL. **Step 3:** Implement; `xcodegen generate`. **Step 4:** PASS. **Step 5: Commit** `feat: repair service groups at launch and draw only whole runs`, push.

---

### Task 6: Setup export and import carry groups

**Files:**
- Modify: `Chorus/Services/SetupArchive.swift`
- Test: `ChorusTests/RailTests.swift` (beside the setup-import tests)

**Interfaces:**
- Produces: `SetupArchive.SpaceRecord.groups: [GroupRecord]?`, `struct GroupRecord: Codable, Equatable { var name: String?; var members: [Int] }` (indices into `services`, as `Member` uses). Optional, so a 1.5.29 file decodes.
  - `capture`: each whole run of two or more exported members; a member `ServiceRecord(exporting:)` skips is left out, and a group left with fewer than two is not written.
  - `validate` rejects: an index out of range; an index that is not a member of that space; an index in two groups of one space; an index also in `globalServices`; a group of fewer than two; a name longer than `Limit.textLength`.
  - `apply`: after the space's members are linked, each group's links take a new `ServiceGroup` (known to `tidyGroups` through `knownGroups`) and are made one run at the end of the space, then `tidyGroups`.
- [ ] **Step 1: Write the failing tests:** `testSetupRoundTripKeepsGroupsAndNames`; `testSetupFromBefore1_5_30DecodesWithNoGroups`; `testSetupRejectsBadGroups` (each rule above, one assertion apiece); Review Focus 3: `testImportIntoAnExistingSpaceKeepsTheImportedGroupTogether`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5: Commit** `feat: carry service groups in the setup file`, push.

---

### Task 7: Draw groups in every layout

**Files:**
- Modify: `Chorus/Views/MainWindow/UnifiedRailView.swift` (vertical body, `tabRow`, `allServicesBody`; `@Query private var allGroups: [ServiceGroup]`)
- Create: `Chorus/Views/MainWindow/GroupBox.swift`
- Modify: `Chorus/Views/MainWindow/ServiceIconView.swift` (`ServiceAccessibility` and its tests)

**Interfaces:**
- Consumes: `RailRuns` (Task 5).
- Produces: `struct GroupBox<Content: View>: View { let name: String?; let axis: Axis; let showsName: Bool; let isLit: Bool; @ViewBuilder let content: Content }` — vertical: optional name above (`ChorusType.label`, bold, `ChorusColor.secondaryText`, as `allServicesHeading`), content padded `ChorusCard.railPadding` on every side in `.railCard()`; horizontal: the card round the tabs, 2 pt vertical padding, the name leading inside the card; `isLit` adds an accent outline. `showsName` is false in the icon-only rail and the narrow strip, where the name goes in `.help` and the accessibility label. A member's accessibility label ends ", in Google" (named) or ", in a group with Calendar and Drive" (unnamed); extend `ServiceAccessibility` and its tests.
- [ ] **Step 1:** Write the failing `ServiceAccessibility` tests for the two label endings. Run: FAIL.
- [ ] **Step 2:** Implement the label and draw `RailRuns.runs(…)` in the vertical rail, the bar, and each space card of the all-services list (a box inside the card). Rows inside a box keep every modifier they have.
- [ ] **Step 3:** Run. Expected: PASS. (The by-eye check waits for Task 8, which adds a way to make a group; never write `ServiceGroup` rows into the Debug store with `sqlite3`.)
- [ ] **Step 4: Commit** `feat: draw service groups in every layout`, push.

---

### Task 8: Menus, naming and keyboard

**Files:**
- Modify: `Chorus/Views/MainWindow/UnifiedRailView.swift` (`serviceContextMenuItems`, `step`, `stepLink`, the divider's step)
- Create: `Chorus/Views/MainWindow/GroupMenus.swift` (the Name Group sheet and the box's menu, as a `ViewModifier`)
- Modify: `Chorus/App/AppState+Rail.swift`

**Interfaces:**
- Consumes: Tasks 2–4, 7.
- Produces: `AppState` wrappers `groupLink(_ draggedLinkID: UUID, onto targetLinkID: UUID) -> Bool`, `removeFromGroup(_ linkID: UUID) -> Bool`, `nameGroup(_ groupID: UUID, _ name: String?) -> Bool`, `ungroup(_ groupID: UUID) -> Bool`, each calling `RailEdits` with `modelContainer.mainContext`, animated at the call site as `reorderRail` is.
  - Service menu: **Group with ▸** (`GroupRules.groupWithCandidates`, each `"\(emoji)  \(label)"`; joining keeps the row on its side, so a row grouped with the one below stays above it), **Remove from Group**, **Name Group…** (a sheet with one field; Return saves; empty clears). Box and name menu: **Move Group to ▸** (`RailEdits.eligibleSpaces(forGroup:)`, through `RailMove.groupIntoSpace`), **Name Group…**, **Ungroup**. The same as VoiceOver actions on rows and boxes.
  - Move Up/Down and Option-arrow: rows use `GroupRules.stepping`, boxes `steppingGroup`, **and a divider's step uses `GroupRules.stepping` too**.
- [ ] **Step 1:** Implement; humanizer on every new string.
- [ ] **Step 2:** Run the test command. Expected: PASS.
- [ ] **Step 3: By eye**, Debug build, all four layouts, light and dark, named and icon-only: make a group from the menu, name it, rename it, clear the name, step rows and the box with Option-arrow, ungroup. The selected row's fill sits inside the box's corners (as in `2e605e9`).
- [ ] **Step 4: Commit** `feat: group, name and move groups from the menu and keyboard`, push.

---

### Task 9: Service drags with a known end, and Escape

*(Task 0 writes a "Spike outcome" paragraph here. Follow it where it differs from the steps below.)*

**Files:**
- Create: `Chorus/Views/MainWindow/RailDragSession.swift`
- Modify: `RailSupport.swift` (`RailDragState`), `RailDividerView.swift` (the divider uses the same end classification), `UnifiedRailView.swift` (`serviceRow`, `globalRow` **and `allServicesRow`**)
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Produces:
  - `enum RailDragEnd: Equatable { case dropped, cancelled, endedOffRail }` with `nonisolated static func classify(dropTaken: Bool, endedByKey: Bool, insideRail: Bool?) -> RailDragEnd` (the divider's `DividerDragEnd` becomes this; `endedOffRail` removes a divider and is treated as `.dropped` for a service).
  - `RailDragState` gains `var startSnapshot: [RailScope: [GroupEntry]]` (taken at drag start for every list the drag can touch), `var pausedTargetID: UUID?`, `var litGroupID: UUID?`, `var zones: [UUID: GroupDrag.Zone]`, `var pauseTask: Task<Void, Never>?`, and `func reset()` clearing every drag field.
  - `@MainActor protocol RailDragEnding { func dragEnded(_ end: RailDragEnd) }`: the rail registers one handler; the drag source calls it exactly once per drag. Task 10 fills in its grouping logic; in this task it does Escape and `reset()`.
  - `RailEdits.restore(_ snapshot: [RailScope: [GroupEntry]], context:) -> Bool` — puts back every order (spaces and global) and every membership in the snapshot.
- [ ] **Step 1: Write the failing test** (Review Focus 4): `testRestorePutsBackOrderAndMembership` — snapshot two scopes (a space with a group, and `.global`), then reorder both **and change a membership with `removeFromGroup`**, `restore` → the snapshot's order in both and every `groupID`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement per the spike outcome; wire `serviceRow`, `globalRow` and `allServicesRow`; `.cancelled` restores, every end calls `reset()`. **Step 4:** PASS.
- [ ] **Step 5: By hand,** Debug build, all four layouts: a click selects, right-click shows the menu, hover draws, focus works, a drag reorders, cross-space and global moves still ask, Escape mid-drag puts the list back.
- [ ] **Step 6: Commit** `feat: service drags know their end, so Escape puts them back`, push.

---

### Task 10: Pause to group, lit boxes, and the one write

**Files:**
- Create: `Chorus/Views/MainWindow/GroupDrag.swift`
- Modify: `RailSupport.swift` (`LiveReorderDropDelegate`, `LiveReorder`), `UnifiedRailView.swift` (`memberLanes`, the all-services row lanes, `liveMove`, the row swell, a box-level lane on `GroupBox`), the `RailDragEnding` handler from Task 9
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Produces:
  - `enum GroupDrag { static let pauseBeforeGrouping: Duration = .milliseconds(500); enum Zone { case before, middle, after }; nonisolated static func zone(at offset: CGFloat, length: CGFloat, current: Zone?) -> Zone; nonisolated static func reordered(_ dragged: UUID, over target: UUID, zone: Zone, in ids: [UUID]) -> [UUID]? }`.
    - `zone`: entering the middle needs the pointer within 30–70 % of the row; leaving it needs it outside 25–75 % (`current` is the row's last zone). Starting numbers; the spec leaves the exact values to the builder.
    - `reordered`: `.before` puts `dragged` directly before `target`, `.after` directly after; nil when nothing would change or for `.middle`. So the edge of a neighbour that `dragged` is already next to does nothing, and the row the pointer reaches stays under it. Replaces `LiveReorder.moving` for service rows.
  - `LiveReorderDropDelegate` gets the row's length along the list's axis (the row reports it with `onGeometryChange`, passed in the lane) and:
    - `Lane.move` becomes `(_ dragged: UUID, _ zone: GroupDrag.Zone) -> Void`; `dropUpdated` computes the zone from `info.location` and the length, stores it in `RailDragState.zones[rowID]`, calls `move` for `.before`/`.after`, and in `.middle` starts `RailDragState.pauseTask` (if the row is not already the paused target) which, after `pauseBeforeGrouping`, sets `pausedTargetID`. Leaving the middle or the row (`dropExited`, now implemented) cancels the task and clears `pausedTargetID`.
    - The pause arms only for a drag of a service of the same space (`drag.linkID` whose link is in this space); never for a global service, a service of another space, a divider or a group.
  - The lit box: `RailDragState.litGroupID` is set from `RailRuns.litGroup` on each render during a drag, or by the box-level lane while the pointer is inside the box's frame with the dragged row at either end of its run; cleared when the pointer leaves the box (`dropExited`) and by `reset()`. `GroupBox.isLit` reads it.
  - **The one write**, in the `RailDragEnding` handler, for every end but `.cancelled`: `pausedTargetID != nil` → `AppState.groupLink(dragged, onto: pausedTargetID)`; otherwise, for a service of a space, `RailEdits.finishDrag(dragged, inSpace:, litGroup: litGroupID, …)`; a cross-space or global drop that a row took goes on to its confirmation as today (no group write). Then `reset()`. No `performDrop` writes membership.
  - A divider's drag end calls `RailEdits.tidyGroups` for its space.
  - The swell: the paused row scales up a little with an accent outline (sizes are the builder's); Reduce Motion shows the outline only.
- [ ] **Step 1: Write the failing tests** (Review Focus 5): `testZoneHasHysteresisAtTheMiddleEdge` (28 % with `current: .middle` → `.middle`; with `.before` → `.before`; 50 % → `.middle`; 90 % → `.after`); `testReorderedLeavesANeighbourInPlaceAtItsNearEdge` (`[d, t]`, `d` over `t` at `.before` → nil; at `.after` → `[t, d]`; `[t, d]`, `d` over `t` at `.after` → nil, at `.before` → `[d, t]`).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5: By hand** (Review Focus 4 and 5), every layout: moving past services never groups; a pause groups, including on the row right next to the dragged one; dropping between members joins; at either end of a lit box joins; a member dragged 4 pt and let go inside its box stays; dropped outside leaves, and a two-member group goes with its name; let go over a gap, the box padding, the add button and the web view: one write, the box right; a cross-space drop whose prompt is cancelled leaves everything as it was; Escape restores; a service from another space or a global one never swells a target; the top bar works left and right.
- [ ] **Step 6: Commit** `feat: pause over a service to group it`, push.

---

### Task 11: Drag a whole group

**Files:**
- Modify: `GroupBox.swift` (a drag source on the name and the padding, per the spike outcome), `RailSupport.swift` (`LiveReorder.groupType = UTType(exportedAs: "com.nicojan.chorus.service-group-id")`, `RailDragState.groupID`), `UnifiedRailView.swift` (group lanes on rows and boxes, all-services space headings), `SpaceStripView.swift` (space cells), `SpacePaletteView.swift` (its space rows: the sidebar layout's spaces live in this popover), `Chorus/Info.plist` (export the UTType beside `com.nicojan.chorus.divider-id`)

**Interfaces:**
- Consumes: `RailEdits.reorderGroup`, `RailEdits.eligibleSpaces(forGroup:)`, `RailMove.groupIntoSpace` (Task 4); the drag source and `RailDragEnding` (Task 9).
- Produces: dragging a box reorders the run live within its space (`steppingGroup`-shaped moves through `reorderGroup`, saved as it goes), a drop on an eligible space asks (`groupIntoSpace`), the global box and ineligible spaces refuse it, Escape restores. If the box's padding is an AppKit view, it builds the box's menu itself (`menu(for:)`, as `DividerDragView` does: Move Group to ▸, Name Group…, Ungroup), since a SwiftUI `.contextMenu` beneath it will not see the right-click.
- [ ] **Step 1:** Implement. **Step 2:** Run the test command. Expected: PASS.
- [ ] **Step 3: By hand:** drag a group within its space in each layout; to another space in the strip, the space palette and the all-services list (the question lists the services; Cancel leaves it); over the global box and a space that already has a member, nothing; Escape puts it back; the rows inside still drag on their own; right-click on the padding shows the box's menu.
- [ ] **Step 4: Commit** `feat: drag a service group as one`, push.

---

### Task 12: Docs and the by-hand pass

**Files:**
- Modify: `CHANGELOG.md` (Unreleased → Added), `docs/internal/OPEN-ITEMS.md`; `Chorus/Views/Tips/WhatsNew.swift` only if Nico wants a What's New entry (ask; the spec leaves it open)

- [ ] **Step 1:** CHANGELOG line through the humanizer loop.
- [ ] **Step 2:** Migrate a copy of the real store with `testMigratesARealStoreCopy` (all three files into `/tmp/chorus-real-store-copy`; never the live store). Expected: every space, service, link and divider intact, no groups.
- [ ] **Step 3:** Write the by-hand list (Tasks 9–11's by-hand steps) into OPEN-ITEMS and hand it to Nico.
- [ ] **Step 4: Commit** `docs: service groups`, push, CI green on 14 and 15, then mark the PR ready.
