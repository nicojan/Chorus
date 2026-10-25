# Service Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let people draw a box round related services in a space, by an iOS-style pause-to-group drag or from the menu, name it or not, and move it as one, in every layout.

**Architecture:** A new `ServiceGroup` entity with no relationships, and an optional `groupID` on `SpaceServiceLink`. The rules (join, leave, dissolve, keep a group one unbroken run, keyboard steps) are pure functions in `GroupRules`, applied to the store by new `RailEdits` operations. Drawing goes through a pure `RailRuns` that turns a list into rows and boxes. Service rows move from SwiftUI's `onDrag` to an AppKit drag source like the divider's, so a drag's end is known; the shared drop delegate learns a row's middle from its edges and runs the pause timer.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSDraggingSource`), SwiftData with `VersionedSchema`, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-25-service-groups-design.md`

## Global Constraints

- Branch: work on `feat/service-groups` off `main`; merge only after the by-hand pass at the end.
- Test command: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`. Never add `-configuration Release`.
- New `.swift` files: run `xcodegen generate` and commit the regenerated `Chorus.xcodeproj/project.pbxproj` with them.
- After every commit pushed, CI must pass on macOS 14 and 15 (`gh run list --workflow test.yml`). Xcode 16.2 rejects code Xcode 26 accepts; known cases are in `CONTRIBUTING.md` (pass main-actor functions to `forEach` in a `for` loop, etc.).
- SwiftData: follow `CLAUDE.md` "SwiftData schema changes" and "SwiftData behaves differently on macOS 14, 15 and 26": no relationships on the new entity, insert a link only when `modelContext == nil`, delete join rows explicitly.
- Keep SwiftUI `body` modifier chains short; new menus, sheets and confirmations go in a `ViewModifier` of their own (see `RailMoveConfirmation`).
- The pause before a target swells: 500 ms, one constant (`GroupDrag.pauseBeforeGrouping`).
- Reduce Motion: no swell and no slide; the outline alone.
- A group holds at least two services. A group never sits in the global box. No nesting, no dividers inside a group.
- Public text (menu items, the Name Group sheet, the move prompt, CHANGELOG, What's New) goes through `humanizer_check_text` until `prohibitions_clear`.
- Never `NSApp.terminate` directly; quits go through `SheetQuit` (not touched here, but the Name Group sheet is a sheet).

## Review Focus

1. **A grouped service leaves its space by a path other than a drag** (Move to Space, Remove from this space, Show in Every Space, Delete service entirely): its group must lose it, and a group left with one member must go. Tests in Task 3.
2. **A store with data the rules forbid** (one-member group, a member separated from its run by another service or a divider, a `groupID` naming a deleted group, from a crash or an older build): drawing must not show a wrong box, and launch must repair it. Tests in Tasks 3 and 5.
3. **Setup import into a space that already exists by name** (the import merges members into it): imported groups must keep their members together and not swallow the existing services. Test in Task 6.
4. **Escape after a drag that crossed a box**: every order and every membership is back as it was, including a group the live reorder passed through. Test in Task 9 (the restore function is pure).
5. **The pointer at rest on a boundary between a row's middle and its edge**, or on a target that just slid: no flicker between swell and gap, and the pause lands on the row the person sees. Pinned by the `GroupDrag.zone` test in Task 10 and checked by hand.

---

### Task 1: Store groups (schema 1.5.30)

**Files:**
- Create: `Chorus/Models/ServiceGroup.swift`
- Modify: `Chorus/Models/SpaceServiceLink.swift` (add `groupID`)
- Modify: `Chorus/Models/Schema/ChorusSchema.swift` (freeze 1.5.29, bump current, add stage)
- Test: `ChorusTests/GroupTests.swift` (new), `ChorusTests/ChorusTests.swift` (`testCurrentStoredShapeIsPinned`)

**Interfaces:**
- Produces: `@Model final class ServiceGroup { @Attribute(.unique) var id: UUID; var spaceID: UUID; var name: String?; var createdAt: Date; init(id: UUID = UUID(), spaceID: UUID, name: String? = nil, createdAt: Date = Date()) }`; `SpaceServiceLink.groupID: UUID?`; `ChorusSchemaV1_5_29` (frozen); `ChorusSchemaVCurrent.versionIdentifier == Schema.Version(1, 5, 30)`, models include `ServiceGroup.self`.

- [ ] **Step 1:** Create the branch: `git switch -c feat/service-groups`.
- [ ] **Step 2: Write the failing tests** in `GroupTests.swift` (same fixtures as `RailTests`: `makeContainer()` and `makeSpace(_:order:services:in:)`, copied, since they are `private` there):

```swift
func testMigratesFrom1_5_29WithNoGroups() throws {
    // Build a ChorusSchemaV1_5_29 store at a temp URL with a space, a service,
    // a link (sortOrder 3) and a RailDivider, as testMigratesFrom1_5_19… does.
    // Reopen at ChorusSchemaVCurrent with ChorusMigrationPlan.
    XCTAssertNil(link.groupID)
    XCTAssertEqual(link.sortOrder, 3)
    XCTAssertEqual(try ctx.fetch(FetchDescriptor<RailDivider>()).count, 1)
    XCTAssertTrue(try ctx.fetch(FetchDescriptor<ServiceGroup>()).isEmpty)
}
```

and in `testCurrentStoredShapeIsPinned` add:

```swift
let group = try entity("ServiceGroup")
XCTAssertEqual(Set(group.attributes.map(\.name)), ["id", "spaceID", "name", "createdAt"])
XCTAssertTrue(group.relationships.isEmpty, "ServiceGroup must not hold relationships")
// and "groupID" joins the SpaceServiceLink attribute set
```

- [ ] **Step 3:** Run the test command. Expected: FAIL (no `ServiceGroup`, no `ChorusSchemaV1_5_29`).
- [ ] **Step 4:** Freeze the current shape as `enum ChorusSchemaV1_5_29: VersionedSchema` (copy `ChorusSchemaVCurrent`'s models into the namespace as `ChorusSchemaV1_5_19` did, with `RailDivider` frozen too, and the comment style above it). Add `ServiceGroup.swift` with a doc comment saying why it has no relationships (copy the reasoning from `RailDivider`). Add `var groupID: UUID?` to `SpaceServiceLink` with a doc comment ("nil: in no group; the group's id is a plain attribute, as `RailDivider.spaceID` is"). Bump `ChorusSchemaVCurrent` to `(1, 5, 30)`, update its comment, add `ServiceGroup.self` to its models, add `ChorusSchemaV1_5_29.self` to `schemas`, and a `.lightweight(fromVersion: ChorusSchemaV1_5_29.self, toVersion: ChorusSchemaVCurrent.self)` stage with a comment ("adds SpaceServiceLink.groupID (optional, nil on every row) and the ServiceGroup entity, which starts empty"). Run `xcodegen generate`.
- [ ] **Step 5:** Run the test command. Expected: PASS, all tests.
- [ ] **Step 6: Commit** `feat: store service groups (schema 1.5.30)` with the new files and `project.pbxproj`.

---

### Task 2: The group rules, pure

**Files:**
- Create: `Chorus/Models/GroupRules.swift`
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Produces:
  - `struct GroupEntry: Equatable { let id: UUID; let groupID: UUID?; let isDivider: Bool }` (a list entry in display order; `groupID` nil for dividers and ungrouped rows)
  - `enum GroupRules`, all `nonisolated static`:
    - `repaired(_ entries: [GroupEntry]) -> [GroupEntry]` — the list with every group made one unbroken run at the place of its first member (outsiders and dividers that sat inside a run move to just after it, in their order), and every group with fewer than two members dissolved (`groupID` nil).
    - `joining(_ dragged: UUID, onto target: UUID, in entries: [GroupEntry], newGroupID: UUID) -> [GroupEntry]` — the drop-on-a-paused-target result: `dragged` moves to just after `target`; both take `target.groupID ?? newGroupID`; then `repaired`.
    - `placing(_ dragged: UUID, at order: [UUID], litGroup: UUID?, in entries: [GroupEntry]) -> [GroupEntry]` — a drop between rows: the list takes `order` (which already holds `dragged` where the gap was), `dragged` takes `litGroup` (nil when no box was lit), then `repaired`.
    - `stepping(_ id: UUID, forward: Bool, in entries: [GroupEntry]) -> [UUID]` — Move Up/Down: a member moves one place within its run and never out of it; a row outside a group steps over a whole run in one step (and over a divider as today); returns the new order, membership untouched.
    - `steppingGroup(_ groupID: UUID, forward: Bool, in entries: [GroupEntry]) -> [UUID]` — the whole run moves past its neighbour (a row, a divider, or another whole run).

- [ ] **Step 1: Write the failing tests** (names and assertions; build ids with `let a = UUID()`… and a helper `e(_ id: UUID, _ g: UUID? = nil, divider: Bool = false)`):
  - `testRepairedDissolvesAOneMemberGroup`: `[e(a,g), e(b)]` → `[e(a), e(b)]`.
  - `testRepairedMovesAnOutsiderAfterTheRun`: `[e(a,g), e(x), e(b,g), e(c)]` → `[e(a,g), e(b,g), e(x), e(c)]`.
  - `testRepairedMovesADividerOutOfTheRun`: `[e(a,g), e(d, divider: true), e(b,g)]` → `[e(a,g), e(b,g), e(d, divider: true)]`.
  - `testJoiningUngroupedMakesANewGroupOfTwo`: dragging `c` onto `a` in `[e(a), e(b), e(c)]` with `newGroupID: n` → `[e(a,n), e(c,n), e(b)]`.
  - `testJoiningAGroupedTargetAddsToItsGroup`: `c` onto `b` in `[e(a,g), e(b,g), e(c)]` → `[e(a,g), e(b,g), e(c,g)]`.
  - `testJoiningLeavesTheOldGroupAndDissolvesIt`: `b` onto `c` in `[e(a,g), e(b,g), e(c)]` with `n` → `[e(a), e(c,n), e(b,n)]`.
  - `testPlacingInsideALitBoxJoinsAtEitherEnd`: `x` to the front of `[a,b]` with `litGroup: g` → `x` first, `groupID == g`; same at the end.
  - `testPlacingWithNoLitBoxLeaves`: member `b` placed after the run with `litGroup: nil` → `b.groupID == nil`, and a two-member group dissolves.
  - `testSteppingAMemberStaysInItsRun`: stepping `b` forward in `[e(a,g), e(b,g), e(c)]` → order unchanged `[a, b, c]`; stepping `a` forward → `[b, a, c]`.
  - `testSteppingAnOutsiderJumpsAWholeRun`: stepping `c` backward in `[e(a,g), e(b,g), e(c)]` → `[c, a, b]`.
  - `testSteppingAGroupPassesItsNeighbour`: `steppingGroup(g, forward: true)` on `[e(a,g), e(b,g), e(c), e(d)]` → `[c, a, b, d]`.
- [ ] **Step 2:** Run. Expected: FAIL (no `GroupRules`).
- [ ] **Step 3:** Implement `GroupRules` in `GroupRules.swift` with the signatures above. Doc comment on the enum: the rules live here, pure, so the tests pin them rather than whichever view last wrote a number (the wording `RailOrder` uses).
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `feat: the rules that keep a service group one run`.

---

### Task 3: Store edits for groups

**Files:**
- Modify: `Chorus/Services/RailEdits.swift` (a new `// MARK: - Groups` section)
- Modify: `Chorus/Views/MainWindow/UnifiedRailView.swift` (`moveService(link:to:followToSpace:)` and `removeFromSpace(link:)` call the tidy-up before saving)
- Modify: `Chorus/App/AppState+Rail.swift` (`deleteServiceEntirely`), `Chorus/App/AppState.swift` (`deleteSpace`)
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Consumes: `GroupRules`, `GroupEntry` (Task 2); `ServiceGroup`, `SpaceServiceLink.groupID` (Task 1).
- Produces, all `@MainActor static` on `RailEdits`, each either saving everything or rolling it all back unless it says "does not save":
  - `groupEntries(inSpace spaceID: UUID, context: ModelContext) -> [GroupEntry]` — `entries(in: .space(spaceID))` with each link's `groupID` (a `groupID` whose `ServiceGroup` row is gone reads as nil).
  - `tidyGroups(inSpace spaceID: UUID, context: ModelContext)` — applies `GroupRules.repaired` (order via `applyOrder`, membership onto the links) and deletes `ServiceGroup` rows with no member left. Does not save.
  - `groupLink(_ draggedLinkID: UUID, onto targetLinkID: UUID, context:) -> Bool`
  - `finishDrag(_ draggedLinkID: UUID, order: [UUID], litGroup: UUID?, inSpace spaceID: UUID, context:) -> Bool` — the one write that ends a within-space drag: applies `GroupRules.placing`, tidies, saves.
  - `removeFromGroup(_ linkID: UUID, context:) -> Bool` — places the link just after its run, `groupID` nil, tidies.
  - `nameGroup(_ groupID: UUID, _ name: String?, context:) -> Bool` — trims; empty means nil.
  - `ungroup(_ groupID: UUID, context:) -> Bool`
  - `deleteGroups(ofSpace spaceID: UUID, context:)` — does not save; `AppState.deleteSpace` calls it beside `deleteDividers`.
  - `moveMembership` and `makeGlobal` now clear the moved link's `groupID` and call `tidyGroups` on the space it left.
  - `ServiceGroup` rows are created only inside `groupLink` (a new id when the target is ungrouped), with `spaceID` of the target's space.

- [ ] **Step 1: Write the failing tests** (in-memory store, `makeSpace`):
  - `testGroupLinkMakesAGroupRowAndSetsBothLinks`: after `groupLink(c, onto: a)`, one `ServiceGroup` with `spaceID == space.id`, `a.groupID == c.groupID == group.id`, order `[a, c, b]`.
  - `testRemovingTheSecondLastMemberDeletesTheGroupRow`: group `[a,b]`, `removeFromGroup(b)` → no `ServiceGroup` rows, both `groupID` nil.
  - Review Focus 1, one test each, all ending with no one-member group and no orphan `ServiceGroup` row: `testMoveMembershipLeavesTheGroup` (`RailEdits.moveMembership`), `testMakeGlobalLeavesTheGroup` (`RailEdits.makeGlobal`), `testRemoveFromSpaceLeavesTheGroup` and `testDeleteServiceEntirelyLeavesTheGroup` (exercise the same `tidyGroups` call the view and `AppState` make: delete the link, then `tidyGroups`, then assert).
  - `testDeleteSpaceDeletesItsGroups`: `deleteGroups(ofSpace:)` then the space's delete in one save → no `ServiceGroup` rows.
  - `testNameGroupTrimsAndClears`: `"  Google "` → `"Google"`; `"   "` → nil.
  - Review Focus 2: `testGroupEntriesTreatsAMissingGroupRowAsNoGroup`: a link with a random `groupID` reads `groupID == nil` in `groupEntries`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement the `RailEdits` functions above, then add the `tidyGroups` call before the save in `UnifiedRailView.moveService` (for the space it left), `removeFromSpace`, `AppState.deleteServiceEntirely` (each space the service was in) and `deleteGroups` in `AppState.deleteSpace`.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `feat: store edits for service groups`.

---

### Task 4: Move a whole group

**Files:**
- Modify: `Chorus/Services/RailEdits.swift`, `Chorus/App/AppState+Rail.swift` (`RailMove`, `prompt(for:)`, the confirmed-move perform, and the wrappers below)
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Produces:
  - `RailEdits.reorderGroup(_ groupID: UUID, order: [UUID], inSpace spaceID: UUID, context:) -> Bool` — the run moved as one; membership untouched; tidies; saves.
  - `RailEdits.moveGroup(_ groupID: UUID, toSpace spaceID: UUID, before beforeID: UUID?, context:) -> Bool` — every member's link moves (as `moveMembership` does, keeping order), the `ServiceGroup.spaceID` changes, both spaces tidied, one save. A member whose service is already in the target space is refused for the whole move (return false, nothing changed), as two links to one service in a space are invalid.
  - `RailMove.groupIntoSpace(groupID: UUID, spaceID: UUID, before: UUID?)` with `id` `"group-space-\(group)-\(space)"`.
  - `AppState.prompt(for:)` for it: title `"Move these services to \(space.name)?"` when the group has no name, `"Move \(name) to \(space.name)?"` when it has one; message lists the services with `AppState.listed` and says each keeps its sign-in; confirm `"Move"`. Run the words through the humanizer before committing.
  - `AppState.moveGroup(_ groupID: UUID, toSpace: UUID, before: UUID?) -> Bool` and `AppState.reorderGroup(…)`, selection handled as `moveGlobalService` handles it (a showing member clears the selection unless the view follows).
- [ ] **Step 1: Write the failing tests:** `testMoveGroupTakesEveryMemberAndTheName` (two members and a name arrive in order in the target, the group row's `spaceID` is the target's, the source keeps its other services); `testMoveGroupIsRefusedWhenAMemberIsAlreadyThere` (nothing changes); `testReorderGroupMovesTheRunAsOne` (`[x, a, b, y]` with `[a,b]` grouped, order `[x, y, a, b]` keeps the group); `testGroupMovePromptNamesTheServices` (the message contains both labels).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `feat: move a service group as one`.

---

### Task 5: Repair at launch, and draw only real groups

**Files:**
- Modify: `Chorus/App/AppState.swift` (next to `reapOrphanedServices()` at launch, ~line 564)
- Create: `Chorus/Views/MainWindow/RailRuns.swift`
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Consumes: `RailEdits.tidyGroups` (Task 3), `RailItem` (`RailItems.swift`).
- Produces:
  - `RailEdits.repairGroups(context:) -> Bool` — `tidyGroups` on every space, one save only when something changed (logged at `.info` with the count). Called once at launch after `reapOrphanedServices()`, under the same "store was damaged/restored/in-memory" skip that reap uses.
  - `enum RailRun: Identifiable { case row(RailItem); case group(id: UUID, name: String?, items: [RailItem]) }` and `enum RailRuns { static func runs(_ items: [RailItem], groupOf: (UUID) -> UUID?, nameOf: (UUID) -> String?) -> [RailRun] }` — consecutive members with the same group become one `.group` only when there are two or more; anything else is a `.row`. A group's `id` is the group id; a split run draws as rows (never two boxes for one group).
- [ ] **Step 1: Write the failing tests:** Review Focus 2 at the store: `testRepairGroupsFixesASplitRunAndAOneMemberGroup` (write the bad data directly, call `repairGroups`, assert order and membership); at the drawing: `testRunsDrawAOneMemberGroupAsARow`, `testRunsDrawASplitGroupAsRows`, `testRunsBoxAWholeRun`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement; run `xcodegen generate` for the new file.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `feat: repair service groups at launch and draw only whole runs`.

---

### Task 6: Setup export and import carry groups

**Files:**
- Modify: `Chorus/Services/SetupArchive.swift`
- Test: `ChorusTests/RailTests.swift` (beside the existing setup-import tests)

**Interfaces:**
- Produces: `SetupArchive.SpaceRecord.groups: [GroupRecord]?` with `struct GroupRecord: Codable, Equatable { var name: String?; var members: [Int] }` (indices into `services`, the same indexing `Member` uses). Optional, so a file from 1.5.29 decodes. `capture` writes the space's whole runs; `apply` recreates them after the space's members are linked, with the group's members kept together (`tidyGroups` after linking). Validation: a member index out of range, or one not a member of that space, fails the import as other bad indices already do.
- [ ] **Step 1: Write the failing tests:** `testSetupRoundTripKeepsGroupsAndNames`; `testSetupFromBefore1_5_30DecodesWithNoGroups`; Review Focus 3: `testImportIntoAnExistingSpaceKeepsTheImportedGroupTogether` (the target space already has services; after import the group's members are one run and no existing service joined it).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `feat: carry service groups in the setup file`.

---

### Task 7: Draw groups in every layout

**Files:**
- Modify: `Chorus/Views/MainWindow/UnifiedRailView.swift` (vertical body, `tabRow`, `allServicesBody`); query `@Query private var allGroups: [ServiceGroup]`
- Create: `Chorus/Views/MainWindow/GroupBox.swift` (the box view, vertical and horizontal)

**Interfaces:**
- Consumes: `RailRuns.runs` (Task 5).
- Produces: `struct GroupBox<Content: View>: View { let name: String?; let axis: Axis; let showsName: Bool; @ViewBuilder let content: Content }` — vertical: optional name above (`ChorusType.label`, bold, `ChorusColor.secondaryText`, as `allServicesHeading`), content padded `ChorusCard.railPadding` on every side in `.railCard()`; horizontal: the card round the tabs with 2 pt vertical padding and the name, if any, leading inside the card. `showsName` false in the icon-only rail and the narrow strip, where the name goes in `.help` and the accessibility label.
- [ ] **Step 1:** Draw `RailRuns.runs(items(in:))` in the vertical rail, the bar and each space card of the all-services list (a box inside the space's card). A row inside a box keeps every modifier it has today.
- [ ] **Step 2:** Build and check by eye in the Debug build in all four layouts, light and dark, named and icon-only, with a group made by hand in the Debug store (`sqlite3` on `Application Support/Chorus-debug/default.store`, app quit first). The fill of a selected row sits inside the box's corners, as in the strip's global box (`2e605e9`).
- [ ] **Step 3:** Run the test command. Expected: PASS.
- [ ] **Step 4: Commit** `feat: draw service groups in every layout`.

---

### Task 8: Menus, naming and keyboard

**Files:**
- Modify: `Chorus/Views/MainWindow/UnifiedRailView.swift` (`serviceContextMenuItems`, `step`, `stepLink`)
- Create: `Chorus/Views/MainWindow/GroupMenus.swift` (the Name Group sheet and the group menu, as a `ViewModifier`)
- Modify: `Chorus/App/AppState+Rail.swift` (wrappers: `func groupLink(_ draggedLinkID: UUID, onto targetLinkID: UUID) -> Bool`, `func removeFromGroup(_ linkID: UUID) -> Bool`, `func nameGroup(_ groupID: UUID, _ name: String?) -> Bool`, `func ungroup(_ groupID: UUID) -> Bool`, each calling the `RailEdits` function of the same name with `modelContainer.mainContext`, inside `withAnimation` at the call site as `reorderRail` is)

**Interfaces:**
- Consumes: Tasks 3 and 4.
- Produces: menu items **Group with ▸** (only the row's neighbours above and below that are not in its group, each `"\(emoji)  \(label)"`), **Remove from Group**, **Name Group…** (a sheet with one field; Return saves; empty clears); on the box and its name: **Move Group to ▸** (eligible spaces, through `RailMove.groupIntoSpace`), **Name Group…**, **Ungroup**. VoiceOver actions with the same names on rows and boxes; "Move up"/"Move down" and Option-arrow use `GroupRules.stepping` for rows and `steppingGroup` for a box.
- [ ] **Step 1: Write the failing test** for the one rule here not covered by Task 2: `testGroupWithListsOnlyTheNeighboursOutsideTheGroup` against a pure helper `GroupRules.groupWithCandidates(for id: UUID, in entries: [GroupEntry]) -> [UUID]` (add it to `GroupRules`).
- [ ] **Step 2:** Run. Expected: FAIL. **Step 3:** Implement the helper and the menus. **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Run the menu and sheet words through the humanizer.
- [ ] **Step 6: Commit** `feat: group, name and move groups from the menu and keyboard`.

---

### Task 9: Service drags from AppKit, with Escape

**Files:**
- Create: `Chorus/Views/MainWindow/RailRowDragSource.swift` (generalised from `RailDividerDragSource` in `RailDividerView.swift`, which then uses it)
- Modify: `Chorus/Views/MainWindow/RailSupport.swift` (`RailDragState`), `UnifiedRailView.swift` (`serviceRow`, `globalRow`: replace `.onDrag` with the source)
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Produces:
  - `struct RailRowDragSource: NSViewRepresentable { let payload: (id: UUID, type: UTType); let image: () -> NSImage; let onDragStart: () -> Void; let onDragEnd: (RailDragEnd) -> Void }` and `enum RailDragEnd: Equatable { case dropped, cancelled, endedOffRail }` with `nonisolated static func classify(dropTaken: Bool, endedByKey: Bool, insideRail: Bool?) -> RailDragEnd` (the divider's `DividerDragEnd` becomes this; `endedOffRail` is what removes a divider and means nothing for a service).
  - `RailDragState` gains `var startSnapshot: [RailScope: [GroupEntry]]` (the lists the drag can touch, taken at the start) and `var pausedTargetID: UUID?`, `var litGroupID: UUID?`.
  - `RailEdits.restore(_ snapshot: [GroupEntry], inSpace spaceID: UUID, context:) -> Bool` — puts back every order and membership; recreates nothing (live moves never change membership, Task 10, so groups never vanish mid-drag).
  - A click on a row still selects it; the drag starts after the same 3 pt threshold the divider uses; the drag image is `ServiceDragPreview`, rendered.
- [ ] **Step 1: Write the failing test** (Review Focus 4): `testRestorePutsBackOrderAndMembership` — snapshot a space with a group, apply a reorder that crossed the box, call `restore`, assert the snapshot's order and every `groupID`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement the source and the restore; wire `serviceRow` and `globalRow`; Escape (`.cancelled`) calls `restore` for each scope in the snapshot.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** By hand in the Debug build: a click selects; a drag reorders as before in all four layouts; a drag to another space and into or out of the global group still asks; Escape mid-drag puts the list back.
- [ ] **Step 6: Commit** `feat: drag services from AppKit so Escape can put them back`.

---

### Task 10: Pause to group, lit boxes, and the drop

**Files:**
- Create: `Chorus/Views/MainWindow/GroupDrag.swift`
- Modify: `Chorus/Views/MainWindow/RailSupport.swift` (`LiveReorderDropDelegate`), `UnifiedRailView.swift` (`memberLanes`, `liveMove`, the row's swell)
- Test: `ChorusTests/GroupTests.swift`

**Interfaces:**
- Produces:
  - `enum GroupDrag { static let pauseBeforeGrouping: Duration = .milliseconds(500); enum Zone { case before, middle, after }; nonisolated static func zone(at offset: CGFloat, length: CGFloat, current: Zone?) -> Zone }` — the middle band with hysteresis: entering the middle needs the pointer inside 30–70 % of the row; leaving it needs it outside 25–75 % (`current` is the zone the pointer was last in). The exact numbers are the builder's (spec), these are the starting point.
  - `LiveReorderDropDelegate.Lane` gains `var pause: ((_ dragged: UUID) -> Void)? = nil` called once the pointer has stayed in a row's middle zone for `pauseBeforeGrouping`, and `var unpause: (() -> Void)? = nil` when it leaves; `dropUpdated` now reads `info.location` against the row's size to track the zone. `move` (the live reorder) only runs in the before/after zones.
  - Live moves (`liveMove`) still save order as they go and never change membership.
  - On drop within the space: a paused target → `AppState.groupLink(_:onto:)` (Task 8); otherwise `RailEdits.finishDrag(…, litGroup: dragState.litGroupID, …)`. A box is lit when the gap sits inside its run, or at either end while the pointer is inside the box's frame.
  - The pause only arms for a drag from the same space (`drag.linkID` whose link is in this space); never for a global service, a service from another space, or a divider.
  - The swell: the paused row scales up a little with an accent outline (sizes are the builder's); Reduce Motion shows the outline only. The target is hit-tested by its current frame each update, so a target that slid is still found where it is drawn.
- [ ] **Step 1: Write the failing test** (Review Focus 5): `testZoneHasHysteresisAtTheMiddleEdge` — at 28 % with `current: .middle` → `.middle`; at 28 % with `current: .before` → `.before`; at 50 % → `.middle`; at 90 % → `.after`.
- [ ] **Step 2:** Run. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** By hand, every layout: moving past services never groups; a pause groups; dropping between two members joins; dropping at either end of a lit box joins; dropping outside leaves and a two-member group goes; Escape puts everything back; a service from another space or a global one never swells a target; the top bar works left and right.
- [ ] **Step 6: Commit** `feat: pause over a service to group it`.

---

### Task 11: Drag a whole group

**Files:**
- Modify: `Chorus/Views/MainWindow/GroupBox.swift` (a `RailRowDragSource` on the name and the box's padding), `RailSupport.swift` (`LiveReorder.groupType = UTType(exportedAs: "com.nicojan.chorus.service-group-id")`, `RailDragState.groupID`), `UnifiedRailView.swift` (group lanes on rows and boxes), `SpaceStripView.swift` and the sidebar's space list (a group dropped on a space asks to move there), `Chorus/Info.plist` (export the new UTType beside the existing ones)

**Interfaces:**
- Consumes: `RailEdits.reorderGroup`, `RailMove.groupIntoSpace` (Task 4), `RailRowDragSource` (Task 9).
- Produces: dragging a box reorders the run live within its space (`reorderGroup`), drops on a space as a confirmed `groupIntoSpace`, is refused over the global box, and Escape restores the snapshot.
- [ ] **Step 1:** Implement. **Step 2:** Run the test command. Expected: PASS.
- [ ] **Step 3:** By hand: drag a group within its space in each layout; drag it to another space in the strip, the sidebar and the all-services list (the question lists the services; Cancel leaves it); over the global box nothing happens; Escape puts it back; the rows inside still drag on their own.
- [ ] **Step 4: Commit** `feat: drag a service group as one`.

---

### Task 12: Docs and the by-hand pass

**Files:**
- Modify: `CHANGELOG.md` (Unreleased → Added), `docs/internal/OPEN-ITEMS.md`, and `Chorus/Views/Tips/WhatsNew.swift` if the release gets a What's New entry (the spec leaves this to the builder; ask Nico before adding one)

- [ ] **Step 1:** CHANGELOG line, through the humanizer loop.
- [ ] **Step 2:** Migrate a copy of the real store with `testMigratesARealStoreCopy` (`CLAUDE.md`: copy all three files to `/tmp/chorus-real-store-copy`, never the live store). Expected: every space, service, link and divider intact, no groups.
- [ ] **Step 3:** Write the by-hand list into OPEN-ITEMS (Tasks 9–11's by-hand steps, plus macOS 14 and 15 if a machine is available) and hand it to Nico.
- [ ] **Step 4: Commit** `docs: service groups`, push the branch, confirm CI green on 14 and 15.
