# Design: find the most complete store and offer to restore it

Date: 2026-07-29. Status: approved, not yet implemented.

## Why

1.5.14 added an automatic restore for one shape of data loss: the store opens empty, the install has held data before, and a pre-update backup exists. 1.5.15 fixed the cause of that shape, inferred migration. Neither helps in three cases that still lose a user's spaces and services:

1. Part of the store survives. The user has one space where they had four. Nothing looks empty, so no recovery runs.
2. The store was already overwritten with the default seed by a build older than 1.5.14. It holds rows, so it opens clean and no recovery runs. Recovery today means copying files by hand in Terminal.
3. Something outside Chorus replaced the store. Release builds keep it at `~/Library/Application Support/default.store`, SwiftData's unscoped default, which any other non-sandboxed SwiftData app can claim. Tracked separately in `docs/internal/OPEN-ITEMS.md`.

A user hit case 2 or 3 on 1.5.14 and reported losing everything. This design gives them a way back that does not involve Terminal, and gives Chorus a way to notice.

## What it does

Chorus reads the live store and every backup it has kept, works out which one holds the most, and offers it. The user decides. Two entry points, one view:

- **Automatic.** When the live store holds less than Chorus last recorded, or holds nothing of the user's at all, and a backup covers the gap, a banner offers to review the backups.
- **Manual.** A "Restore from a backup" item in Settings opens the same view at any time.

The silent restore from 1.5.14 stays exactly as it is. When the store opens empty or unopenable and a usable backup exists, there is nothing for the user to weigh, and that path already works. The new prompt covers only the cases the silent path leaves alone.

## Rules that decide an offer

Both rules are pure functions over values already read, so the data-safety behavior is testable without having to break a store first. This follows `AppState.recoveryPlan`, which exists for the same reason.

### Suspected loss

`chorus.lastKnownContent` records the spaces, services, and links the store held. Chorus writes it after a clean open and again at termination. A user who deletes two spaces lowers the record on the way out, so the next launch sees no loss. Data that vanishes between launches leaves the record high, which is the signal.

Two conditions have to hold for any offer, and then one of two triggers:

Always required:

- A backup exists holding more than the live store.
- The user has not already declined this same pairing of backup and live state.

Then either trigger:

1. **Below the record.** A recorded count exists and the live store is under it: fewer services, or the same services in fewer spaces. This is the partial-loss case, and the only one where the live store may still hold work worth keeping.
2. **Nothing to lose.** No recorded count exists (or it matches the live store), the live store is empty or matches the untouched seed, and a backup holds more.

Trigger 2 exists because of who this feature is for. Someone who lost their spaces on 1.5.14 or earlier has no recorded count when they first launch a build that writes one, and their store holds the seed, so trigger 1 can never fire for them. Without trigger 2 the feature would miss the person who reported the bug. It is safe on its own terms: a seed-shaped store holds nothing of theirs.

A hard crash mid-session can leave the record higher than the store, which produces one false offer under trigger 1. It is a banner, the user declines, and the decline is remembered. That is the accepted cost of catching partial loss.

### Ranking

Candidates sort by services, then spaces, then links, then by when they were taken. Damaged candidates (those failing `PRAGMA integrity_check`) are excluded from ranking and shown as damaged rather than hidden: a damaged backup may still be the only copy of someone's data, and `repairDanglingLinks` already runs before every open.

Winning the ranking and getting preselected are two different things, and preselection is deliberately narrower:

- Live store empty or holding the untouched default seed: preselect the winner. There is nothing to lose.
- Live store still holding the user's own spaces and services: **preselect nothing.** Show the comparison and make the user choose. Restoring a three-week-old backup over a damaged but current store would discard three weeks of everything else, and only the user knows which they want.
- A `.corrupt-*` backup is never preselected, whatever it holds.

Merging a missing space out of a backup into the live store is out of scope. It is the ideal answer and a much larger feature: identity conflicts, link reconstruction, sort order. Restoring keeps a copy of the current store, so nothing is destroyed by choosing either way.

## Components

### `StoreInventory.swift` (new)

`StoreRepair.swift` is already 413 lines and owns a different job (repair and snapshot). Reading and ranking candidates goes in its own file.

- `StoreCandidate`: url, kind (`live`, `snapshot(version:)`, `prerestore`, `corrupt`), `takenAt`, counts, integrity, and whether the shape matches the untouched seed.
- `inventory(for:)`: enumerates the live store plus the `.snapshot-*`, `.prerestore-*`, and `.corrupt-*` families, and reads each one's counts.
- `bestCandidate(among:)`: the ranking above. Pure.
- `looksLikeUntouchedSeed`: true only when the store is exactly what `seedDefaultDataIfNeeded` writes: two spaces named Personal and Work, those seven services, nothing added or renamed. One added service makes it false.

Reads open the file plain read-only, **without** `immutable=1`. A `.bak` can have a `-wal` sibling holding committed rows, and an immutable open ignores it, which would under-count a backup and could cost it the ranking. Counts that cannot be read stay `nil`, meaning unknown, and an unknown candidate is listed as unreadable rather than ranked as empty. This matches `StoreRepair.spaceCount`, which already opens read-only and treats `nil` as unknown.

Live counts come from the already-open `ModelContainer`, not a second SQLite read.

### Applying a choice

`chorus.pendingRestore` holds the chosen filename. At the next launch, before the container opens, `AppState.init`:

1. Clears the key, so a crash mid-restore cannot loop.
2. Validates the filename as untrusted input: a sibling of the store directory, a known backup prefix, no path separators.
3. Copies the current triple aside with a fresh timestamp. Unconditionally, unlike `restoreFromSnapshot`, which skips when a prior copy exists.
4. Copies the chosen triple into place and validates the result, reverting to the copy it just took if validation fails.

Restoring at launch, before anything opens the store, is the only safe point. Swapping SQLite files under a live container produces the fault-a-deleted-model crash this code exists to prevent.

### Relaunching

Ordering matters, because two Chorus instances on one store is its own hazard. Chorus spawns a detached watcher that waits for its own process to exit and then reopens the bundle, and terminates immediately after. The reopen cannot race the shutdown.

### `StoreRecoveryView.swift` (new)

A sheet listing each candidate with its date, the version it preceded, and what it holds ("4 spaces, 13 services"). The live store is marked Current. Damaged and unreadable candidates are listed and not selectable. Actions: Restore and Relaunch, Cancel, Reveal in Finder.

The automatic case uses the existing yellow banner in `ContentView` with a "Review backups" button. A blocking modal was the alternative and loses: the seed fingerprint can match someone who installed Chorus, never changed the defaults, and has an old backup, and a modal would punish that person at every launch. The banner also already carries Reveal in Finder and a dismiss control.

Settings gets a "Restore from a backup" item opening the same sheet.

## Also fixed here

`snapshotHasUsableData` treats any store with at least one space as usable. The default seed has two, so a snapshot taken after the loss counts as usable, and `pruneSnapshots` can protect that one while the user's real backup ages past the keep-3 window and is deleted. The seed fingerprint fixes it: protect the newest snapshot that is not seed-shaped.

## Testing

Pure functions carry most of it:

- Ranking: most content wins; newest breaks a tie; damaged excluded; `.corrupt-*` never preselected.
- Fingerprint: the exact seed is true; the seed plus one service is false; a renamed space is false.
- Offer rule: **an edited store the user still works in produces no offer even when a fatter backup exists**, the case that protects deliberate deletions. Trigger 1 fires below the record and not at it. Trigger 2 fires with no record and a seed-shaped store, which is the reported user's situation. No offer after a decline.
- Inventory: all three families enumerated, stamps parsed, unparseable names tolerated, WAL rows counted, unreadable candidates marked unknown rather than empty.
- Filename validation: rejects `../`, absolute paths, and unknown prefixes.
- Round trip: fixture stores at 4 spaces / 13 services and a seeded live store, through the restore path, asserting counts.

Fixtures and the scoped debug store only. Never the installed store at `~/Library/Application Support/default.store`: dev builds wiped a working set of spaces and logins once already (`.remember` and the store-isolation fix exist because of it).

The relaunch and the banner need checking by hand in the running app. So does a restore chosen from Settings, end to end.

## Notes for implementation

- New `.swift` files are not in the checked-in `.pbxproj`. Run `xcodegen generate` and keep `project.yml` and the project file in step, per `CLAUDE.md`.
- No `@Model` stored properties change, so no new schema version is needed.
