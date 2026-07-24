# Follow-up: make SwiftData migration deterministic (VersionedSchema)

Status: DONE 2026-07-24, on `main`, unreleased — rides with the next release. See
the implementation plan and results in
`docs/superpowers/specs/2026-07-24-versioned-schema-migration-plan.md`.

## Outcome

Implemented with an explicit `VersionedSchema` per shipped shape and a
`SchemaMigrationPlan`, opened in `AppState` (commits `6de8aa4`, `f5535cc`). The
floor is 1.5.11 — from there only `ServiceInstance` changed and only by adding
optional fields, so both stages are `.lightweight`. Verified on macOS 26: the
real 1.5.11 incident store (4 spaces / 13 services) migrated losslessly; the
frozen 1.5.11 shape is byte-identical to tag `v1.5.11`; 136 tests pass, including
a plain-`Schema` production-provenance migration and drift guards over all four
models.

`tryOpen` falls back to plain inferred migration if the versioned-plan open
throws, so the change is non-regressive on any OS — that is what let it ship
without a macOS 14.0 test machine (a real 14.0 pass stays a nice-to-have, not a
blocker). The auto-restore safety net stays as corruption-only defense.

Two things left deliberately open: a real macOS 14.0 device pass (optional), and
pre-1.5.11 stores, which fall to the net rather than a hand-written reshape (the
plan doc's "Known limitation"). The sections below are the original filing, kept
for history.

## Why this exists

1.5.14 added a safety net. If the store opens empty after an update while the
user has had data before, Chorus restores the newest usable pre-update backup
instead of writing the defaults over it. That fixed the symptom, silent data
loss, but not the cause. The cause is that Chorus opens its `ModelContainer` with
a plain `Schema` and lets SwiftData infer the migration. Inferred migration is
not deterministic: on some upgrades the store opens empty without throwing an
error. The safety net catches that. Making the migration itself reliable is the
real fix, and this note is the reminder to do it.

The field incident: a store went from 4 spaces / 13 services to the 2-space /
7-service default seed across the 1.5.11 → 1.5.12 update. 1.5.12 added a single
optional `Bool?` (`stayActiveInBackground`), which should migrate losslessly, so
the wipe was a race in inferred migration, not a schema mistake.

## What to do

Adopt an explicit `VersionedSchema` for each shipped schema plus a
`SchemaMigrationPlan`, and open the container with them. Each version pins its
model shape. Each migration stage becomes a named, tested step: lightweight
where the change only adds optional fields, custom where it reshapes data. The
auto-restore safety net stays; the two work together.

## Steps

- Define `VersionedSchemaV1`, `V2`, … capturing each shipped shape of
  `ServiceInstance`, `Space`, `SpaceServiceLink`, and `AppPreferences`. Take the
  current shape as the latest version; reconstruct earlier versions from git
  history and the shipped stores.
- Write a `SchemaMigrationPlan` listing the stages between consecutive versions.
  An additive optional-property change is a `.lightweight` stage; anything else
  is a `.custom` stage with an explicit transform.
- Open the container with the plan:
  `ModelContainer(for: latestSchema, migrationPlan: plan, configurations: [config])`,
  in `AppState.tryOpen`.
- Add migration tests: seed a store at version N, open it with the plan, and
  assert every row and field survives at version N+1. Cover each real historical
  step; start with 1.5.11 → 1.5.12 (the `stayActiveInBackground` add that caused
  the incident).
- Keep the auto-restore path. Once migration is deterministic it should fire only
  on genuine corruption, not on ordinary upgrades.

## Done when

- Every historical upgrade path preserves all rows and fields, proven by tests.
- No inferred migration remains: the container opens with an explicit plan.
- The `.emptiedWithHistory` branch in `loadContainer` stops firing on normal
  updates (it becomes a corruption-only path).

## References

- Safety-net design: `docs/superpowers/specs/2026-07-24-store-auto-restore-design.md`
- Incident + fix: `CHANGELOG.md` 1.5.14; commits `9a8f5ea` (feature) and
  `1d3cf3b` (never reseed over a usable backup).
- Code: `Chorus/App/AppState.swift` (`loadContainer`, `tryOpen`, `recoveryPlan`),
  `Chorus/App/StoreRepair.swift` (snapshot + restore).
- Models: `Chorus/Models/ServiceInstance.swift`, `Space.swift`,
  `SpaceServiceLink.swift`, `AppPreferences.swift`.
- Tests: `ChorusTests/ChorusTests.swift` (search `loadContainer`, `Snapshot`,
  `RecoveryPlan`).
