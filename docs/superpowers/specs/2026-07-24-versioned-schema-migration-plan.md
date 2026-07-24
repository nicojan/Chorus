# Plan: deterministic SwiftData migration via VersionedSchema

Status: implemented 2026-07-24 (floor 1.5.11, all-lightweight). Code landed in
`Chorus/Models/Schema/ChorusSchema.swift`, wired in `AppState`, covered by
migration + plan-shape tests. Validated three ways on macOS 26: in-process
fixtures; a real 1.5.11 field store (the incident's own store, 4 spaces / 13
services) migrated losslessly through the plan; and `git`-diff of the frozen
1.5.11 shape against tag `v1.5.11` (byte-identical). Adversarial review findings
addressed — `AppPreferences` frozen in the historical namespaces (#4), a
plain-`Schema` production-provenance test added (#1), the drift guard extended to
all four models + relationships (#4), the 1.5.11 test now sets every field (#5).
**Outstanding: the pre-ship macOS 14.0 device/VM validation pass** — the dev
machine is macOS 26, so the true 14.0 migration race is not yet exercised.
Targets the follow-up in `docs/internal/FOLLOWUP-versioned-schema.md`.

## The problem, restated

`AppState.init` builds a plain `Schema([ServiceInstance, Space,
SpaceServiceLink, AppPreferences])` and hands it to `ModelContainer`. SwiftData
then infers the migration from the store's on-disk shape to that schema at open
time. Inference is not deterministic: on some upgrades the store opens empty
without throwing (the 1.5.11 → 1.5.12 incident). The 1.5.14 auto-restore net
catches the symptom. This plan removes the cause by pinning every schema shape
and every step between them.

## How an explicit plan fixes it

With a `VersionedSchema` per shipped shape plus a `SchemaMigrationPlan`,
SwiftData no longer invents a mapping at open time. It matches the store's
stored schema against the declared versions, finds its version, and applies the
named stages in order to reach the latest. The mapping is pinned in code, tested
before shipping, and identical on every machine and OS build. Additive-only
steps become `.lightweight` stages; a reshape becomes a `.custom` stage with an
explicit transform we write and test.

Honest caveat, and it is a big one. A `.lightweight` stage does not run our code
— it hands the step back to SwiftData's own inference between two *known* shapes.
So the determinism win is narrow and specific: the plan removes the "reconstruct
the source shape from stored metadata" step by matching the store to a declared
version, then applies a small, fixed, pre-declared delta per stage. Whether that
eliminates the field *race* (the auto-restore doc's own diagnosis) is **plausible
but unproven** — and Chorus deploys to **macOS 14.0**, where SwiftData's
migration machinery is at its buggiest. We therefore make two commitments up
front:

- The retained auto-restore net is **load-bearing, not optional garnish.** We do
  not delete or weaken it on the strength of this change.
- We do not claim "deterministic" on the basis of a green test suite. See the
  "What the tests can and cannot prove" note under Testing — a passing migration
  test proves our stage *mapping* is correct (no field silently dropped), not
  that the race is gone.

## The one real decision: how far back to reconstruct

This is the fork worth settling before anything else, because it sets the whole
size and risk of the work.

The models have shipped in roughly 17 shapes since Phase 1. Reconstructing all
of them is a large, error-prone job: each reconstructed version must byte-match
its historical `@Model` (names, types, optionality, `.unique`, relationships) or
SwiftData won't recognize a field store as that version. And most of those old
shapes no longer exist in the field — they migrated forward through intermediate
releases long ago.

The history splits cleanly:

- **Everything from the dark-mode rework onward is additive-optional.** New
  fields were added as optionals precisely so lightweight migration would
  succeed (see the comments on `pageZoom`, `osNotificationsEnabled`,
  `stayActiveInBackground`, etc.). The incident field `stayActiveInBackground`
  (commit `3e6ef0f`, 1.5.12) is one of these — confirming the doc's "race, not
  schema mistake" reading.
- **The genuine reshapes are older and cluster around the dark-mode work:**
  - `ServiceInstance.darkMode: String?` → `darkModeRaw: String?` — a rename
    (`d11cb57`, "auto dark mode with background detection").
  - `Space.isMuted: Bool` → `Bool?` — a non-optional-to-optional change
    (`99a402e`).
  - Removals: `ServiceInstance.detectedLacksDarkTheme`,
    `ServiceInstance.contentBlockingDisabled`, `AppPreferences.autoDarkModeEnabled`
    (all removed during the dark-mode simplifications; column drops).

**Recommendation — baseline at the field floor, reconstruct forward from there.**
Pick the oldest schema shape a real user could still be running (the "field
floor"), declare it as the baseline `VersionedSchema`, and add one stage per
shipped shape from the floor up to the current shape. If the floor is set at or
after the dark-mode rework, every stage is `.lightweight` and no `.custom`
transform is needed — the reshapes stay behind the floor, already migrated in the
field. This is exactly the doc's "start with 1.5.11 → 1.5.12" instinct,
generalized: cover the live upgrade paths, not archaeology.

Rejected alternatives:

- **Full history (V1…V17).** Correct in the limit, but pays for reshape/rename
  custom stages and a dozen exact reconstructions to cover stores that no longer
  exist. High effort, high error surface, little real coverage gained.
- **Baseline at current shape only.** Cheapest, and it makes all *future*
  changes deterministic — but it does nothing for a store still at 1.5.11,
  because reaching the baseline would still fall to inference. Fails the incident
  it's meant to fix.

**Decision (settled 2026-07-24, revised after scrutiny): floor at 1.5.11.**
The goal set was "maximize coverage without adding bugs/mistakes." My first pass
read that as "widest all-lightweight window" and put the floor just after the
`darkMode` → `darkModeRaw` rename (`d11cb57`, ~1.5.4 era). Scrutiny changed the
answer, because "without adding mistakes" cuts two ways and the second cut
dominates:

- **Migration-stage risk** is avoided by staying at or above the rename (no
  `.custom` stage, so no `.unique`-in-custom-migration gotcha). 1.5.11 clears
  this — everything from 1.5.11 forward is additive fields plus one non-optional→
  optional widen, all `.lightweight`.
- **Fixture-build risk** is the one I missed, and it *grows* the further back the
  floor goes. Every historical version below the current shape needs a store
  fixture, and the only way to make a faithful one is to build the app at that
  old commit — old commits fight the current toolchain (Swift 6, current SDK) and
  each reconstruction is a fresh chance to get a shape subtly wrong. That is
  precisely "adding mistakes."

Balancing the two: **1.5.11 is the sweet spot.** It is all-lightweight (zero
stage risk), it is the documented incident's source version, and it needs only
**one** historical reconstruction — real 1.5.12/1.5.13/1.5.14 store snapshots
already exist on disk to validate the forward shapes (see Testing). Reaching
back to the rename would add several more old-build reconstructions to cover an
install base that a fast-shipping, Sparkle-auto-updating app has almost certainly
already moved off. That trades real, near-term mistake risk for coverage of
stores that likely no longer exist — the opposite of the goal.

Anything older than 1.5.11 is out of scope: it falls to the auto-restore net or
a fresh start, never a hand-written reshape we could get wrong.

**Known limitation (accepted): pre-1.5.11 stores.** A store older than the floor
matches no declared version. With an explicit plan, SwiftData may not
inference-migrate it the way it used to — it could open empty or throw, routing
the user through the safety net to an in-memory session (data preserved on disk,
banner shown) rather than a clean migration. The net prevents data *loss*, but
such a user is stranded on temporary storage. This is judged acceptable because a
Sparkle-auto-updated app is very unlikely to have a live pre-1.5.11 store, and no
pre-1.5.11 store exists to test against. If one ever surfaces, either widen the
floor or restore inference as the fallback for unknown-version stores. Flagged by
the adversarial review (finding #3); not resolved, deliberately deferred.

**Concretely, three versioned schemas and two stages:**

- `ChorusSchemaV1_5_11` — frozen shape before `stayActiveInBackground`.
- `ChorusSchemaV1_5_12` — adds `stayActiveInBackground` (the incident field).
- `ChorusSchemaVCurrent` — the current classes (adds the per-service hibernation
  fields; 1.5.13 and 1.5.14 share this shape, so they are one version).

Stages: `1.5.11 → 1.5.12` and `1.5.12 → current`, both `.lightweight`.

## Type and file structure

SwiftData needs a distinct model type per version when shapes differ. The
standard pattern, and the one to use:

- One file per historical version under `Chorus/Models/Schema/`:
  `ChorusSchemaV1_5_11.swift` and `ChorusSchemaV1_5_12.swift`. Each is an `enum`
  conforming to `VersionedSchema` with `versionIdentifier` and `models`, and
  nests its four `@Model` classes (`ServiceInstance`, `Space`,
  `SpaceServiceLink`, `AppPreferences`) frozen to that version's shape. Nesting
  keeps the entity name (`ServiceInstance`) while giving each version a unique
  Swift type. Only **two** historical type-sets exist — the floor decision keeps
  this small.
- **The current version reuses the current top-level classes** — it does not
  re-declare them. `ChorusSchemaVCurrent.models = [ServiceInstance.self, …]`
  referencing the real classes in `Chorus/Models/`. Today's model files stay the
  single source of truth for the shipping shape; only the two historical shapes
  get frozen copies.
- Version numbering: `Schema.Version(1, 5, 11)`, `(1, 5, 12)`, `(1, 5, 13)` (the
  current shape; 1.5.14 shares it), so a stage reads as "1.5.11 → 1.5.12" in
  code.
- Project inclusion: new `.swift` files are not auto-compiled unless the target
  globs their folder. Confirm `project.yml`'s source rules cover
  `Chorus/Models/Schema/` (add it if not) and run `xcodegen generate`, keeping
  `project.yml` and the `.pbxproj` consistent per the repo's build note.

Confirm during build (Q2): that nesting `@Model` in an `enum` resolves the
entity name to the bare class name on the **macOS 14.0** target. Verify by
opening a real 1.5.12 snapshot as `ChorusSchemaV1_5_12` before committing to the
layout — if the names don't match, fall back to distinct type names plus an
explicit entity name.

## Migration plan and per-stage classification

`ChorusMigrationPlan: SchemaMigrationPlan`:

- `schemas`: the versioned schemas from floor to latest, in order.
- `stages`: one `MigrationStage` between each consecutive pair.

With the floor at 1.5.11, **both stages are `.lightweight` — there are no
`.custom` transforms in scope.** The stages, to be finalized against the
fixtures:

| From → To | Change | Stage |
|-----------|--------|-------|
| 1.5.11 → 1.5.12 | adds `stayActiveInBackground: Bool?` (the incident field) | `.lightweight` |
| 1.5.12 → 1.5.13 (current) | adds `hibernationPolicyRaw: String?`, `hibernateAfterMinutes: Int?` | `.lightweight` |

Every field added across these steps is an optional, so no default-value or
back-fill transform is needed. Because nothing is `.custom`, the
`.unique`-in-custom-migration gotcha does not apply — it stays on the risk list
only as a guard against ever pulling the floor back past the `darkMode` rename.

## Wiring changes in AppState

Minimal and localized:

- `AppState.init`: replace the `Schema([...])` + `ModelConfiguration(schema:)`
  with the latest versioned schema, and pass the plan through to open.
- `loadContainer(schema:config:)` → `loadContainer(schema:migrationPlan:config:)`
  (or bundle both into a small `StoreSchema` struct to keep signatures tidy).
- `tryOpen` and `inMemoryContainer`: thread the plan into
  `ModelContainer(for: schema, migrationPlan: plan, configurations: [config])`.
  The in-memory fallback uses the same latest schema; it never migrates, so the
  plan is a no-op there but keeps one construction path.
- Nothing in `recoveryPlan`, `StoreRepair`, or the outcome/banner logic changes.
  `StoreRepair` reads raw SQLite and is schema-version-agnostic; leave it.

## Interaction with the safety net (keep it)

The 1.5.14 auto-restore stays exactly as is. As migration grows more reliable,
the `.emptiedWithHistory` branch in `loadContainer` should fire less on normal
upgrades and, ideally, only on genuine corruption. But we cannot prove it stops
firing (the trigger is a race), so the net stays as the corruption-only path and
defense against any residual OS-level lightweight bug on the 14.0 target. Its
presence is a permanent part of the design, not scaffolding this change removes.

### What the tests can and cannot prove

State this plainly so a green suite is not misread. The field failure is a
*race* in SwiftData's migration; it does not reproduce on demand. A migration
test that seeds version N and opens it at current will almost certainly pass
today, with or without this change. So:

- The tests **prove mapping correctness**: that our declared stages carry every
  row and every field from N to current with nothing dropped or defaulted wrong.
  That is a real, worth-having guarantee — a hand-written stage that forgot a
  field would fail here.
- The tests **do not prove the race is gone.** Nothing in a unit test can, short
  of the OS-level fix. The race-reduction argument rests on the architecture
  (pinned version match, fixed per-stage delta) plus the retained safety net —
  not on the suite going green.

Do not let this change delete or weaken the auto-restore net.

### Fixtures — synthetic only, never the user's real store

Real 1.5.12/1.5.13/1.5.14 store snapshots exist on the dev machine, but they hold
the user's **real personal data** and must never be committed as fixtures. Use
them read-only, locally, for the Q2 entity-name check — never destructively (a
past dev build wiped the user's real store; treat those files as untouchable).

Committed fixtures are **synthetic**, generated deterministically:

- 1.5.12 and current: build the fixture with the frozen versioned type
  (`ChorusSchemaV1_5_12` / `ChorusSchemaVCurrent`) inside the test target — seed
  one non-default row of every model, every field set to a non-default value,
  write to a temp store, copy into `ChorusTests/Fixtures/stores/`. No old build
  needed; the frozen type *is* the historical shape.
- 1.5.11: same approach with `ChorusSchemaV1_5_11`. The frozen 1.5.11 type is the
  only thing that must match history exactly — validate it once by opening the
  real 1.5.12 snapshot through the 1.5.11→current plan locally and confirming it
  reads (the real snapshot is a superset shape; a faithful floor type migrates it
  cleanly). Document the shape's provenance (commit `3e6ef0f` minus
  `stayActiveInBackground`) in the file.

### The tests

1. **Fixture migration tests (core).** Open each synthetic fixture (1.5.11,
   1.5.12) through `loadContainer` with the plan; assert counts, ids, and every
   attribute survive at current — including accessor-resolved ones (`darkMode`,
   `hibernationPolicyEffective`, `isMutedEffective`, `staysActiveInBackgroundEffective`).
   Start with the incident path (1.5.11 → 1.5.12).
2. **Plan-shape unit tests.** `versionIdentifier`s strictly increase; `stages`
   connect every consecutive pair with no gap; `ChorusSchemaVCurrent.models`
   matches the current top-level classes (guards "added a field, forgot to
   version it").
3. **macOS 14 validation gate (pre-ship, manual).** Because 14.0 is the risky
   target and CI may run newer, before shipping: run the migration tests on a
   14.0 destination, and open the real local 1.5.12 snapshot through the built
   app on 14.0 once, confirming all rows appear and the `.emptiedWithHistory`
   branch does not fire. This is the closest we get to exercising the real path.

Existing tests to keep green: the `loadContainer`, `Snapshot`, and
`RecoveryPlan` suites in `ChorusTests.swift` — they should be unaffected, which
is itself a signal the wiring change is clean.

## Ongoing discipline (the part that prevents the next incident)

Add a short checklist to `CLAUDE.md` / the release steps: any change to a
`@Model` stored property is a new schema version — bump
`ChorusSchemaVCurrent`'s identifier, freeze the prior shape as a new
`ChorusSchemaV(n)`, add the stage, and add its fixture + test. The plan-shape
unit test above turns "forgot to do this" into a red test rather than a field
data-loss bug.

## Risks and gotchas

- **macOS 14.0 is the target, and its SwiftData migration is the buggiest.**
  This is the top risk and the reason for the honest-caveat framing throughout:
  the explicit plan may not fully cure a 14.0-specific race. Mitigations: keep
  the safety net; run the pre-ship 14.0 validation gate; do not ship on the
  strength of tests that ran only on newer macOS.
- **Reconstruction fidelity of the 1.5.11 floor type.** If the frozen 1.5.11
  shape doesn't match history, a real 1.5.11 store won't be recognized as that
  version and falls back to inference (or fails). Only one type must be exact;
  validate it against the real 1.5.12 snapshot locally.
- **Entity-name resolution under enum nesting** — verify per Q2 before committing
  the layout, on the 14.0 target specifically.
- **`migrationPlan:` initializer on 14.0** — available since macOS 14, but pin
  the exact call shape against the 14.0 SDK.
- **`@Attribute(.unique)` in custom stages** — not in scope (all stages are
  lightweight), listed only as the reason never to pull the floor back past the
  `darkMode` rename without revisiting this.

## Sequencing

1. Q2: open a real local 1.5.12 snapshot through a trial `ChorusSchemaV1_5_12`
   to confirm enum-nested entity names resolve on 14.0. (Q1 settled: floor 1.5.11.)
2. Add the two `ChorusSchemaV1_5_*` frozen types, `ChorusSchemaVCurrent`, and
   `ChorusMigrationPlan`; confirm `project.yml` globs the new folder.
3. Add a synthetic-fixture generator in the test target; write fixtures for
   1.5.11 and 1.5.12.
4. Write the fixture migration tests (RED), then wire `AppState` to the plan
   (GREEN). Keep existing store suites green.
5. Add plan-shape unit tests and the CLAUDE.md discipline note.
6. Run the pre-ship macOS 14.0 validation gate.

## References

- Follow-up: `docs/internal/FOLLOWUP-versioned-schema.md`
- Safety net: `docs/superpowers/specs/2026-07-24-store-auto-restore-design.md`
- Code: `Chorus/App/AppState.swift` (`init`, `loadContainer`, `tryOpen`,
  `inMemoryContainer`), `Chorus/App/StoreRepair.swift`
- Models: `Chorus/Models/{ServiceInstance,Space,SpaceServiceLink,AppPreferences}.swift`
- Tests: `ChorusTests/ChorusTests.swift`
</content>
</invoke>
