# Auto-detect and auto-restore an emptied SwiftData store

Date: 2026-07-24

## Problem

Chorus opens its SwiftData store with fully *inferred* migration (no
`VersionedSchema`/`MigrationPlan`). On some upgrades the store opens **empty**
without throwing. `seedDefaultDataIfNeeded()` gates only on `spaces.isEmpty`, so
it treats the empty store as a fresh install and writes the default seed **over
the user's real data**, then saves it to disk. All existing safety nets
(in-memory fallback, dangling-link fail-closed) fire only on a *thrown* error or
detected corruption — a migration that "succeeds" into an empty store looks
healthy. Confirmed in the field: a store went from 4 spaces / 13 services to the
2-space / 7-service default seed across the 1.5.11 → 1.5.12 update.

The only surviving copy of real data after this happens is the pre-migration
snapshot that `StoreRepair.backupBeforeMigrationIfNeeded` writes before each new
version opens. Recovery today is manual (copy a `.snapshot-*.bak` back).

## Goal

Detect the emptied-store condition at launch on the user's own machine and
automatically restore the newest usable snapshot — no network, no manual steps.
When restore isn't possible, degrade safely (in-memory + banner) and never let a
later launch seed defaults over the loss.

Non-goals (explicitly out of scope): phone-home telemetry; a full
`VersionedSchema`/`MigrationPlan` (separate follow-up that makes migration
*deterministic* — this spec is the safety net around it); any "pick which
backup" UI (auto-pick newest usable).

## Key insight

The pre-open space count only protects the *single launch* where the migration
empties the store. Once SwiftData writes the empty store to disk, every later
launch looks like a fresh install. So the durable signal must live **outside**
the store file, and auto-restore — not the pre-open guard — is the real fix.

## Design

### 1. Durable signal: `chorus.hasEverHadData` (UserDefaults)

Set `true` as soon as we have any evidence the user has had data:
- `spaceCount(at:)` before opening returns `> 0`, **or**
- an opened store has `> 0` spaces, **or**
- defaults were just seeded, **or**
- a restore just succeeded.

It survives the store being emptied (unlike the file). Two consequences:

- `seedDefaultDataIfNeeded` seeds **only when `hasEverHadData == false`** — a
  genuine fresh install. It can never again overwrite an emptied store.
- An opened-empty store while `hasEverHadData == true` (or
  `spacesOnDiskBeforeOpen > 0`) is a **data-loss event** → trigger restore.

Injectable `UserDefaults` for tests (matches `backupBeforeMigrationIfNeeded`).

### 2. Restore mechanism — raw file ops in `StoreRepair`

- `spaceCount(at:) -> Int?` — already shipped. `nil` = unknown (no file / no
  `ZSPACE` table); never a guessed `0`.
- `snapshotHasUsableData(at:) -> Bool` — `PRAGMA integrity_check == "ok"` **and**
  `spaceCount > 0`.
- `newestRestorableSnapshot(for storeURL:) -> RestoreCandidate?` — walk
  `<name>.snapshot-*.bak` siblings newest→oldest (names sort by fixed-width
  Unix-second stamp), return the first that `snapshotHasUsableData`. Parse the
  `version` and `takenAt` from the filename for the banner.
- `restoreFromSnapshot(_ snapshotPrimaryURL:to storeURL:) -> Bool` — move the
  current (bad) triple aside to `<name>.prerestore-<stamp>.bak{,-wal,-shm}`
  (**skip if a `.prerestore-*` already exists** — bounds disk in a
  deterministic-failure loop), then copy the snapshot triple into place. Returns
  success.

### 3. Orchestration — `AppState.loadContainer(schema:config:defaults:) -> StoreLoadResult`

Extract today's inline open logic into one `@MainActor` static function so it is
testable with injected `UserDefaults` and manufactured on-disk states.

```
StoreLoadResult = (container: ModelContainer, outcome: StoreLoadOutcome)

StoreLoadOutcome:
  .openedClean
  .restoredFromSnapshot(version: String?, takenAt: Date?)
  .inMemoryFallback(reason: String)
```

Inner helper releases the failed container before any file op:

```
tryOpen(schema, config, hadHistory) -> TryOpenResult
  TryOpenResult = .usable(ModelContainer) | .emptiedWithHistory | .failed
  - repairDanglingLinks(config.url)   // unchanged, pre-open
  - do { open; if storeHasDanglingLinks → return .failed (container released)
          count = fetchCount(Space)
          if count == 0 && hadHistory → return .emptiedWithHistory (released)
          return .usable(container) }
    catch → .failed
```

`loadContainer`:

```
before   = spaceCount(config.url)            // nil | Int
hadHistory = (before ?? 0) > 0 || defaults.hasEverHadData
if (before ?? 0) > 0 { markHasData(defaults) }

switch tryOpen(hadHistory):
  .usable(c):
     if fetchCount(Space, c) > 0 { markHasData(defaults) }
     return (c, .openedClean)
  .emptiedWithHistory, .failed:
     if let cand = newestRestorableSnapshot(config.url),
        restoreFromSnapshot(cand, config.url),
        case .usable(c) = tryOpen(hadHistory: true)   // ONE retry
     {
        markHasData(defaults)
        return (c, .restoredFromSnapshot(cand.version, cand.takenAt))
     }
     return (inMemoryContainer(schema), .inMemoryFallback(reason))
```

**Loop guard:** at most one restore+retry per launch. A deterministic migration
failure (retry still empty) → in-memory + banner, no data lost (snapshot
preserved, `hasEverHadData` stays true so no seed). This bug is a *race*, so the
retry usually succeeds; the deterministic case is the `VersionedSchema`
follow-up's job.

### 4. Banner (in `AppState` + `ContentView`)

- `.openedClean` → no banner.
- `.restoredFromSnapshot` → **dismissible** info banner: "Chorus recovered your
  data from a backup taken <date>." `storeErrorDismissible = true`;
  `dismissStoreBanner()` sets `storeError = nil`.
- `.inMemoryFallback` → **persistent** warning (today's message), pointing at the
  data folder that holds the automatic backups. Not dismissible — it's an active
  "changes won't be saved" state.

`ContentView` shows the dismiss "×" only when `storeErrorDismissible`.

### 5. Logging

`os_log` (category `DataStore`) at each decision: emptied-with-history detected,
snapshot chosen (name + count), restore succeeded/failed, in-memory fallback.
No network.

### 6. Seed gating

`seedDefaultDataIfNeeded`:
```
if !existingSpaces.isEmpty { selectedSpaceID = first; return false }
guard !defaults.hasEverHadData else { return false }   // empty but had data → leave it
... seed ...; markHasData(defaults); return true
```

## Testing

`loadContainer` is deterministically testable without triggering a real
migration bug, because its restore decision keys off "opened empty + history",
independent of *why* it is empty:

- **Fresh install:** no file, `hasEverHadData=false` → `.openedClean`, seed runs,
  flag set.
- **Emptied + good snapshot + history:** pre-create an empty store, a good
  snapshot sibling, `hasEverHadData=true` → `.restoredFromSnapshot`, container
  has the snapshot's data.
- **Emptied + no snapshot + history:** → `.inMemoryFallback`, seed does NOT run.
- `newestRestorableSnapshot`: skips empty and corrupt snapshots, picks newest
  usable.
- `restoreFromSnapshot`: moves bad triple aside once (skips second time),
  copies good triple in, reopened store has data.
- `spaceCount`: already covered (missing→nil, populated→N, emptied→0,
  alien-schema→nil).

## Files touched

All existing (avoids the "new .swift not auto-compiled" project gotcha):
`Chorus/App/StoreRepair.swift`, `Chorus/App/AppState.swift`,
`Chorus/Views/MainWindow/ContentView.swift`, `ChorusTests/ChorusTests.swift`.

## Known limitations

- A snapshot written by a *newer* schema (user downgrades) may fail to reopen;
  it falls safely to in-memory. Not handled here.
- Does not make migration itself reliable — that is the `VersionedSchema`
  follow-up. This spec guarantees no silent data loss around it.
