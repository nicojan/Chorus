# Open items

## Merged, ready to release: the store recovery picker (1.5.16)

On `main`, hand-verified, not yet released. Design: `docs/superpowers/specs/2026-07-29-store-recovery-picker-design.md`. Plan: `docs/superpowers/plans/2026-07-29-store-recovery-picker.md`, whose closing section records the by-hand pass. Task-by-task progress, rulings, and deferred findings: `.superpowers/sdd/2026-07-29-store-recovery-picker/progress.md` (git-ignored scratch in the worktree, so read it before deleting the worktree).

What it does: reads the live store and every backup Chorus keeps, works out which holds the most, and offers to restore it. Automatic banner when the live store is below a recorded content count or holds nothing of the user's; a "Restore from a backup" item in Settings at any time. The user picks; the restore applies at the next launch, before the store opens, and the current store is copied aside first. 1.5.14's silent auto-restore stays as-is for the unambiguous case.

All eleven tasks are done, along with the whole-branch review that followed them and the by-hand pass that followed that (179 tests, up from 136 when the branch started).

**The by-hand pass found a blocker the tests could not.** "Restore and Restart" wrote the pick and armed the relaunch, then never quit: AppKit refuses to terminate while a sheet is attached and drops the request instead of deferring it. The app stayed up, the relaunch poller expired against its own bound, and the restore landed only when the app was next opened by hand. Command-Q is inert in the same state, which is what pinned it down. Arming and quitting are now separate: the pick arms while the sheet is up, so a failure to spawn the poller can still be reported there, and the quit runs from the sheet's `onDismiss`. Steps 4 and 8 were then run again against the fixed build, and the app restarted itself once each time.

The whole-branch review had already found four things the per-task reviews could not, because each of those saw only one task: the restore overwrote the live store without checking its own safety copy had worked; the one list of backup families that was not compiler-checked; a record that could erase the evidence of a loss; and the picker listing backups in family-alphabetical order, so the damaged family sat directly under "Current" while the newest snapshot sat at the bottom. That last one was a defect in the plan rather than the code — the design spec stated the ordering as a ranking rule and the plan never restated it for the UI task.

The first fix for the safety copy was itself wrong, and the follow-up review caught it: it asked whether the copy it had set aside was *readable*, and a faithful copy of a corrupt store is a corrupt file — so it refused to restore in exactly the situation the picker exists for. It now asks whether the copy *succeeded*, and asks for readability only when what it copied was readable. The by-hand pass confirmed that path end to end: with the live store unreadable, the restore works and the unreadable store is kept as an aside.

There are four backup families, not three: `.snapshot-` (taken before an update), `.prerestore-` (the automatic recovery's way back), `.corrupt-`, and `.prepick-` (the copy set aside when a user picks a restore from the sheet). `.prepick-` needed its own family rather than reusing `.prerestore-`: writing it there disarmed the sentinel `restoreFromSnapshot` reads to decide whether to take its own safety copy, which would have silently turned off the automatic recovery's safety copy after a single use of the picker.

**A bug in shipped code turned up on the way and is fixed here.** A WAL-mode store copied without its `-wal`/`-shm` siblings cannot be opened read-only at all (`SQLITE_CANTOPEN`), and that state is reachable in production: `StoreRepair.snapshot` copies only the suffixes that exist, and SQLite deletes `-wal`/`-shm` on a clean close, so a snapshot taken after a clean shutdown is main-file-only. `spaceCount` and `snapshotHasUsableData` both used a plain read-only open, so `newestRestorableSnapshot` could judge exactly those snapshots unusable — meaning 1.5.15's auto-restore can fail to see a perfectly good backup. All the readers now share one opener that retries with `immutable=1` only when no `-wal` sibling exists, which is the one case where nothing can be hidden.

**The open behavior question is decided: keep the offer.** When the live store is unreadable and there is no recorded count, Chorus still offers a restore. Unknown counts as nothing-to-lose, because the outcome is a banner the user can decline, never an automatic write.

**Still worth doing before the release goes out to everyone.** The deployment target is macOS 14.0 and this work changes recovery behavior that already shipped in 1.5.15; the by-hand pass ran on macOS 26.5, which is far newer. A pass on a real macOS 14 machine remains untried.

**A shipped string breaks the writing rule.** The in-memory fallback banner in `AppState` reads "running with temporary storage — changes won't be saved", and an em-dash is a hard prohibition under the humanizer rule in `CLAUDE.md`. It predates this work (it has been there since Phase 6 and shipped in 1.5.15), so it was left alone rather than changed under a build that was already notarized. One string, no logic.

**One follow-up left deliberately undone.** `StoreRepair.copyTriple` throws away the result of removing a destination file, so an unremovable `-wal` sitting beside a main file it copied successfully still reports success — the foreign-WAL pairing that function's own comment says it prevents. Reaching it needs an immutable flag or a delete-denying ACL on that sibling, which would already have broken ordinary writes, and nothing is destroyed when it happens: the aside has been proved a faithful copy by then, the chosen backup is untouched, and `.prepick-` copies are themselves offered in the picker. The closing readability check catches the single-sibling case and misses the case where a `-wal` and `-shm` survive as a consistent pair. The fix is one line — treat a surviving destination file as a failure — plus a test, and its blast radius is `applyPendingRestore` alone, since `restoreFromSnapshot` rolls its own copy loops and does not call `copyTriple`.

## Current status — through 1.5.15 (2026-07-29)

Everything below has shipped. **Chorus 1.5.15 is the current release.** It opens the store through an explicit versioned schema and migration plan, so an older store migrates through named, tested stages instead of leaving SwiftData to infer the mapping at open time. Inference was the cause of the data loss 1.5.14 was built to catch. If the versioned plan cannot open a store, Chorus falls back to inference, so no update is worse off than before. The safety net stays. See `docs/internal/FOLLOWUP-versioned-schema.md` and `docs/superpowers/specs/2026-07-24-versioned-schema-migration-plan.md`.

It went out because a user reported losing all their spaces and services while running 1.5.14, which had the net but not this fix.

It sits on **1.5.14**, the safety net itself. If an update ever left your saved data unreadable, Chorus used to treat the empty store as a first launch and write the default spaces and services over it, losing what you had. Now it checks at startup whether the store came up empty after holding data. When it did, Chorus restores your spaces and services from the backup it takes before every update and shows a banner saying so. When nothing can be restored, it runs on temporary storage and points you to the backup folder rather than overwriting anything. A marker kept outside the store records that you have had data, so an empty store is never mistaken for a fresh install again.

It sits on **1.5.13**, which turns
per-service hibernation into a setting with four choices, replacing the single
"Keep loaded" toggle. A service can follow the global hibernate setting,
hibernate when you switch to another service, hibernate after an idle time you
set, or never hibernate. Chat services stay loaded whatever you pick, so their
messages still arrive at once. Services that were set to "Keep loaded" migrate
to the "Never" choice.

It sits on **1.5.12**, which adds
a per-service "Always appear active" setting: turn it on for Microsoft Teams and
Chorus reports the page as focused while it sits in the background, so Teams
stops marking you away when you work in other apps. Chorus offers to turn it on
when you add Teams, and it is off by default because faking focus can make a
service hold back some notifications. This answers issue #14, which I closed as
fixed on 2026-07-26. The reporter never came back, so the fix has still never been
checked against a live Teams account over a full away timer; I cannot sign into
one. If anyone reopens the issue saying Teams still marks them away, the fallback
is a periodic synthetic-activity ping.

It sits on **1.5.11**, a one-fix patch: on the top-bar and hybrid layouts, a
service's unread badge no longer hides under the tab's selection outline or
presses against the top edge of the window. That sits on **1.5.10** (the sidebar
space chip no longer draws a stray system focus outline on top of its own
highlight — a doubled box the narrow strip clipped) and **1.5.9**: opt-in
auto-hibernation of idle services, a per-service option to open outside links in
a Chorus window, Dark Reader narrowed to a manual per-service On/Off (all
auto-detection, the probe, the theme cache, and the global toggle removed),
reader mode removed entirely, and a round of security and reliability fixes
(link-routing host matching, the favicon-redirect SSRF guard, the chat-stays-live
cap-eviction gap, a Move-to-Space crash guard).

### Open: the store sits on a shared path

The release build passes `ModelConfiguration(schema:isStoredInMemoryOnly:)` with no URL (`AppState.swift`), and SwiftData does not scope that default to the bundle. Verified with `lsof` against the installed 1.5.14: the running app holds `~/Library/Application Support/default.store` — the top level of the shared folder, not `…/Application Support/com.nicojan.Chorus/`. Every non-sandboxed SwiftData app that skips an explicit URL claims the same filename, so another app can open, migrate, or recreate Chorus's store, and anyone tidying Application Support sees a `default.store` belonging to no visible app. The DEBUG path is already scoped (`Chorus-debug`); only the shipping path is exposed.

This is the one mechanism found so far that empties the store with no Chorus update involved, which is why it survives the 1.5.15 migration fix. Fixing it means moving the store into a bundle-scoped directory, and the move has to be a move: open the old path, copy the triple across, and never let the seed run against the new empty location. Snapshot names and the recovery banner path change with it. Not started.

### Open: PR #10

**PR #10** (opt-in spaces hiding, a bottom nav bar, and a window title), tabled pending a UX pass on the rail/title/service-name story — the window title does not render on macOS 26 and duplicates the highlighted rail icon.

The **1.5.4** section below still describes the old auto-detection dark path (the
probe, an "Auto" mode, and the "Re-detect dark theme" button). **1.5.9 removed
all of that** — dark theming is now a per-service On/Off you set by hand. Kept
here as history.

## Shipped in 1.5.6: launch badges and per-service inbox counts

Notification badges stayed blank at launch for any service the user was not
looking at. The cause: the old launch fetch pulled each page over URLSession and
parsed the unread count from the `<title>`, but modern web apps write that count
with JavaScript after the page loads; the server HTML never carries it. So the
fetch read zero for everything. Gmail redirected to a login host, WhatsApp
returned an empty shell, Facebook a "Redirecting..." stub, Slack and Discord
titles carried no number. Because the services spread across several spaces,
almost everything fell in this path.

The URLSession poller is gone, replaced by `TransientBadgeFetcher` (still in
`HibernatedBadgePoller.swift` to keep the file in the build). For each service
with no live web view it renders a short-lived offscreen web view against the
service's own logged-in data store, waits for the count to show up in the title
or a DOM selector, reads it, and tears the view down. It runs one sweep a few
seconds after launch, then every three minutes, at most three at a time,
staggered. A hung `evaluateJavaScript` cannot stall the sweep: each fetch is
bounded by a watchdog. Writes are raise-only, so a transient read of zero never
clears a badge, since an offscreen view cannot tell an empty inbox from a page
that did not finish loading. The live poll clears the badge when you open the
service.

Two badge-source refinements sit on top. First, when a catalog entry defines a
`badgeJS` selector, that selector is now the only source of its count, and the
title is never read for it. This stops a title count for the wrong view from
overriding the intended number. Second, Gmail counts unread conversation rows in
the current inbox view (`tr.zA.zE`), matching what you see. The earlier version
read the "Inbox N unread" aria-label, but that sums unread across every inbox
category and section, so a visibly clean inbox still showed 99+ when Promotions,
Updates and the like held unread. Counting rows drops those. Gmail renders only the
current page of conversations into the DOM (10 rows for a "1-10 of 49" inbox), so
the count reflects unread among the rendered rows, not unread on later pages.
Like LinkedIn's selector, the row count is proven on the live path but not
offscreen: the zero-size launch view may read 0 until you open Gmail, and
raise-only writes keep a launch-time 0 from clearing anything. LinkedIn shows
unread message threads, by counting unread conversations in the list, rather than
the tab title's global notification count.

State: shipped in 1.5.6. The Gmail row-count selector
(`tr.zA.zE`) was verified live: on the reported inbox it read `tr.zA`=10 rendered
rows, `tr.zA.zE`=0 unread, so the badge cleared to 0 (was 99+). Files touched:
`HibernatedBadgePoller.swift`, `NotificationManager.swift`,
`UserScriptManager.swift`, `AppState.swift`, `ServiceCatalog.json`,
`ChorusTests.swift`.

Left as follow-ups, on purpose:

- Not committed, and no version bump yet.
- The DOM selectors are fragile. If Gmail or LinkedIn change their markup, the
  selector returns zero and needs re-deriving. Re-derive with a temporary in-app
  probe against the logged-in page.
- The LinkedIn selector is proven on the live path. Only Gmail's is proven on the
  offscreen launch path. If an out-of-space LinkedIn shows a stale count at
  launch, check whether its conversation list renders offscreen.
- Raise-only means an out-of-space badge can sit high until you open the service
  and the live poll clears it.

Background lives in the transient-badge-fetch memory.

## Shipped: 1.5.4 (2026-07-18)

Fixed the washed, slow load when Gmail opens in dark mode. Gmail runs light, so
Chorus inverts its whole layout on every fresh load, and the page showed that
half-themed state for three to five seconds. Shipped:

- A load cover: an opaque dark overlay with a small spinner sits over the view
  while the theme applies, then reveals the page once it settles. On the probe
  path no theme is baked in yet. There the cover waits for the theme to turn on
  before it starts to reveal, so the light page never flashes through. The cover
  is click-through (`pointer-events:none`), so a page that settles before the
  probe verdict lands stays usable underneath instead of having its input
  swallowed.
- A "Re-detect dark theme" button in a service's settings, for Auto services.
  The detection verdict was cached for good, so a service you later switched to
  its own dark theme kept getting darkened on top. The button clears the verdict
  and reloads, which drops the extra theming once the service runs dark on its
  own.
- Notification permission is now requested after launch (from the root view's
  `.task`) rather than during `App.init`, so the first-run prompt reaches macOS
  reliably.

Left as follow-ups, on purpose:

- The live app-wide Light-to-Dark toggle still re-themes an open page without a
  cover. The page is already on screen, so it is lower stakes.
- If a service never reports a detection verdict, the cover reveals the page
  after a ten-second failsafe.
- On the themed path, if Dark Reader's first mutation lags the 400 ms quiet
  window a brief untinted flash is possible; narrow in practice.

Verify by hand, since screenshots are blocked in this setup: open Gmail in dark
mode and confirm the screen stays cleanly dark while it loads. The cover timings
(400 ms quiet, 6 s settle cap, 10 s failsafe) are one-line values in
`DarkReaderSupport.antiFlashScript`. All 100 tests pass. Background lives in the
dark-reader-load-cover memory.

## Shipped: 1.5.3 (2026-07-14)

Camera and microphone support, first-party call-vendor capture trust, 24 more
catalog services, the native-dark Dark Reader skip, and the 1.5.2 review-backlog
hardening all shipped in 1.5.3. Merged to `main`, notarized DMG on the
`v1.5.3` GitHub release, appcast signed and live. Verified by hand: Meet (camera,
mic, screen share), Discord voice, Teams call (first-party cross-domain path).

Still worth exercising by hand at some point (low stakes): the ⇧⌘M "Mute All
Microphones" command and a per-service Camera or Microphone set to Deny.

## Camera/microphone trust boundary: both cases handled

Fixed: the capture check now uses
`WebViewCoordinator.captureOriginBelongsToService`, which treats a curated set of
multi-tenant hosting suffixes (`github.io`, `web.app`, `vercel.app`, and more) as
public suffixes. Two owners on the same shared suffix no longer count as one site,
so a service pinned to Allow can no longer hand its grant to another site there.
Same registrable domain still matches, so `*.slack.com` workspaces keep working. A
test covers it.

Cross-domain calls: trust is anchored to a service's home host, so a call service
whose live capture host differs by registrable domain would be denied. Two things
now handle this. First, a `firstParty` flag on six curated catalog entries
(Messenger, Facebook, WhatsApp, Teams, Google Meet, Google Chat). For a flagged
service pinned to Allow, a capture request from its own main frame is granted even
on a foreign domain, the way the vendor's native app behaves. The accepted risk is
bounded: user-clicked foreign links already open in the browser, a subframe never
qualifies, the service must be pinned to Allow, and the flag drops the moment the
user edits the service URL off the vendor's site. Second, a vendor still on Ask,
and every service without the flag, gets a per-origin prompt that names the real
origin ("Allow messenger.com to use your microphone?") and isn't saved. Confirm by
hand: on a flagged vendor pinned to Allow the call should just work; on Ask it
should prompt naming the real origin rather than failing silently.

WhatsApp is single-host, so the flag never fires for it today. It is kept because
it was named as a service to trust and because an inert flag costs nothing.

Rejected: a per-service capture-host allowlist, a maintained list of trusted hosts
per catalog entry. The first-party flag covers the same cases with a boolean
instead of a hand-kept, security-sensitive host list that mis-trusts if it goes
stale. A full Public Suffix List would still generalise the suffix handling.

## Close the test gaps

Unit tests cover the policy resolver, the asked-field gating, and the capture
origin-trust check. Still untested: the prompt-queue rules (answer-by-id, drain on
delete or teardown), `muteAllMicrophones` target selection, and the `captureKind`
mapping. Pulling a couple more pure helpers out would make them reachable.

## Try the rest by hand

Not yet exercised: the ⇧⌘M "Mute All Microphones" command (the mic dot should turn
orange and the far end should see you muted) and a per-service Camera or Microphone
set to Deny.

Build and test: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`.
Background lives in the camera-mic-permissions and review-backlog memories.
