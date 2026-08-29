# Chorus — project instructions

Native macOS app: a WKWebView multi-service browser (a Rambox/Franz alternative),
SwiftUI + SwiftData. Distributed directly — Developer ID-signed, notarized DMG
with Sparkle auto-updates. Not sandboxed, not on the App Store.

## Public-facing writing

Everything a user or the public reads — `README.md`, GitHub release notes, the
appcast and any website copy, in-app strings and error messages,
`release/DISTRIBUTION.md`, and every other doc in this public repo — must meet
two standards:

1. **Pass the mcp-humanizer check.** Draft the text, run `humanizer_check_text`
   on it, fix every finding, and re-run until `prohibitions_clear` is true. Then
   self-attest the manual-review items. Reading the rules alone leaves about half
   the problems in place — the check-then-fix loop is what does the work.

2. **Follow George Orwell's six rules** (from *Politics and the English
   Language*):
   1. Never use a metaphor, simile, or other figure of speech you are used to
      seeing in print.
   2. Never use a long word where a short one will do.
   3. If it is possible to cut a word out, always cut it out.
   4. Never use the passive where you can use the active.
   5. Never use a foreign phrase, a scientific word, or a jargon word if you can
      think of an everyday English equivalent.
   6. Break any of these rules sooner than say anything outright barbarous.

Write plain, direct, active, concrete prose. No marketing gloss, no AI tells.

## Build & test

- Test: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`
- The project is generated from `project.yml` via XcodeGen. When you change build
  settings (for example a version bump), edit both `project.yml` and the
  `.pbxproj` so a later `xcodegen generate` stays consistent.
- **Never add `-configuration Release` to that test command.** `ChorusTests` is
  app-hosted, and `ChorusApp.init` builds an `AppState`, so every test run
  executes the launch path, including `StoreRepair.applyPendingRestore`, which
  writes files. Under Debug that is harmless — the store resolves to
  `Application Support/Chorus-debug` and the defaults domain to
  `com.nicojan.Chorus.debug`. Under Release it would aim that write at the real
  store and the release defaults domain, and this repo has already lost a real
  user's data to a careless run against live data.

## The store path (never go back to the default)

Release builds open `Application Support/Chorus/default.store`, which
`StoreRelocation` moves them to. Never open a store through
`ModelConfiguration(isStoredInMemoryOnly: false)` or any other implicit default.
For an app that is not sandboxed that resolves to
`Application Support/default.store`, a path with no bundle id in it, so every
other non-sandboxed SwiftData app that takes the default opens the very same
file. Whichever app opens it second migrates it to its own model, and Core Data
drops the entities that model does not declare. Chorus shared that file with
Bartender 6 and both apps lost everything, at every launch, until 1.5.18 moved
out. Debug builds sit in `Chorus-debug` for the same reason.

## SwiftData schema changes (read before editing any `@Model`)

The store opens through an explicit `VersionedSchema` + `SchemaMigrationPlan`
(`Chorus/Models/Schema/ChorusSchema.swift`), not inferred migration. Any change
to a **stored** property on `ServiceInstance`, `Space`, `SpaceServiceLink`, or
`AppPreferences` (add, remove, rename, retype) is a new schema version. Before
editing the live model:

1. Freeze the current shape as a new `ChorusSchemaV…` (copy `ChorusSchemaVCurrent`
   into a namespaced enum with the stored properties as they are now).
2. Make the model change, then bump `ChorusSchemaVCurrent.versionIdentifier`.
3. Add a `MigrationStage` for the step — `.lightweight` for additive-optional
   changes, `.custom` for a reshape/rename.
4. Add a migration test (see `testMigratesFrom1_5_11…`) and update the pinned
   sets in `testCurrentStoredShapeIsPinned`. Changing `AppPreferences` also needs
   its frozen copy updated — `testFrozenAppPreferencesMatchesLiveModel` will go
   red until you do.

That last test fails if you skip these steps — treat it as the reminder, not a
nuisance. A lossless-looking test does not prove the migration race is gone; the
auto-restore safety net (`StoreRepair` + `loadContainer`) stays as defense.

**Before shipping a schema change, migrate a copy of a real store.** Synthetic
fixtures only prove the stages are right about stores the test file wrote.
`testMigratesARealStoreCopy` opens a copy through the plan and prints what came
through; write the directory to `/tmp/chorus-real-store-copy` and run it. Copy
all three files — a store without its `-wal` and `-shm` cannot be opened
read-only. Never point it at the live store: it migrates in place.

## SwiftData behaves differently on macOS 14, 15 and 26

The dev machine is the newest of the three and the most forgiving of all three,
so it is the worst place to conclude anything. CI runs the suite on macOS 14 and
15 for this reason; do not delete those jobs to make a red build green.

- **`.cascade` is not a promise.** Deleting a `Space` takes its
  `SpaceServiceLink` rows on 15 and 26. On 14 it leaves them with `space` nulled.
  Delete join rows explicitly rather than leaning on the rule.
- **A to-one relationship that a cascade must clear has to be optional.** While
  `SpaceServiceLink.space` and `.service` were not, macOS 15 trapped with
  "an appropriate default value is not configured" and deleting a space killed
  the app for five releases. macOS 26 allowed it, which is why nobody saw it.
- **Do not double-register a model.** Building a join row wires the inverses, so
  when both ends are in the context the row is already registered and a following
  `insert` is a second registration — fatal on 14, tolerated on 26. Insert only
  when `modelContext == nil`, and never `append` to a relationship the
  initializer already set.
- **Do not wire detached models to each other.** Fabricating a dangling link from
  never-inserted objects crashes 14 several different ways. Make a real link and
  null one end instead.
- **Older SDKs are missing `Sendable` conformances.** `Schema.Version`,
  `UNNotificationSettings` and `NSImage` are all unmarked under Xcode 16, which
  `CONTRIBUTING.md` tells contributors to use.

## Releasing

See `release/DISTRIBUTION.md`. In short: the notarized, stapled `Chorus.app` is placed at
the repo root; package a DMG with `hdiutil`, cut a `gh release`, then sign and
regenerate `docs/appcast.xml`.

Every release also needs the Homebrew cask bumped (step 9 there): put the new
version and the stapled DMG's sha256 into `release/homebrew/chorus.rb`, copy it to
`Casks/chorus.rb` in the `nicojan/homebrew-tap` repo, and check it with
`brew style` / `brew livecheck` / `brew audit --cask --online` before pushing both.
Skipping it leaves `brew` users on the old version; Sparkle still updates them, so
it's cosmetic, not a break.

## Ending a session

When I say I am starting a new session, or ask to wrap up, update the docs first:

1. `docs/internal/OPEN-ITEMS.md`: move anything that shipped or got closed out of
   the open list, and fix any status that has gone stale.
2. `CHANGELOG.md`: add or amend the entry for the work done this session.
3. `.remember/remember.md`: the handoff note. Where things stand, what to pick up
   next, and any gotcha worth carrying over.
4. `CLAUDE.md` and `release/DISTRIBUTION.md`: only when a rule or a release step
   actually changed.

Skip a file when nothing about it changed, and say which ones you skipped.
Public-facing text still goes through the humanizer loop above.
