# Open items

## Open: the donation button is built and unreleased

A 20 point button sits in the top right of the main window and opens `https://buymeacoffee.com/0xff.r4bbit`; the About panel carries the same link in its credits field, through `CommandGroup(replacing: .appInfo)` in `ChorusApp.swift`. Verified by hand in all three layouts and in the panel. `SupportLink.url` in `ContentView.swift` is the single definition both use.

Two things to weigh before release. The button is 20 points, well under the 44 the audit asks for everywhere else, because the ask was for something very small; it is a mouse-only target in a Mac app, which is the argument for allowing it. And there is no way to hide it, which is the usual complaint about a standing donation button. A toggle in Settings would answer that and does not exist.

The nav buttons in `hybrid` and `topBars` end in the same corner, so `ServiceSidebarView` reserves 36 points of trailing padding for the button. Cut that reserve and the two overlap as soon as the Home button appears.

Charging for the themes was considered and dropped for now. The repo is public and MIT, so a paywall compiled into the binary is a speed bump, and Apollo's model relied on App Store payment infrastructure and a large userbase, neither of which applies here.

## Open: the redesign has three concepts, and needs one picked

Built 2026-08-13, after the baseline below. `docs/internal/UX-AUDIT.md` holds the research and a Nielsen heuristic pass over the shipped screens; page `08 Redesign concepts` in the Figma file holds three answers to it.

The audit's finding is that the baseline's seven items are all real and none of them is the biggest problem. In `hybrid` and `sidebar` a service tab draws an 18pt icon with no label (`ServiceTabView.content`, the `iconOnly` branch), so two Slack workspaces are two identical squares and the name lives only in a tooltip. `SpaceButton.verticalCell` does the same to spaces. A service has no visible state for loading, failed, or signed out, which matters because every service is a web view whose session expires quietly. Severity 4 and 3 against a list of radii and target sizes.

Three concepts, conservative to radical, each in three layouts and both appearances. `A · Tidy` executes the baseline list inside the shipped skeleton — a patch. `B · Recompose` adds labels everywhere and a health dot, and costs chrome: its sidebar spends 400 points before content. `C · Rethink` drops to one rail with the space as a header on it, reclaiming 161 points, and in doing so collapses `hybrid` and `topBars` into the same design — evidence that three layouts was an artifact of having two rails rather than a real choice.

**Nothing is decided and no app code changed.** The next step is picking one, which is a product call. If C wins, the loss to weigh is that always-visible per-space badges and drag-to-reorder move into a palette.

## Open: six visual directions, and a ceiling on all of them

Page `09 Visual directions` takes one screen, the C sidebar, and restyles it six ways: Discord, Glass, Editorial, Brutalist, Soft, Terminal. Colour comes from modes, so a direction can be swapped on a frame without touching a layer. Each carries a note on what it costs to build.

**The ceiling matters more than the six.** A direction reaches the rail, the bars and the sheets. The web view stays out of reach. `ServiceInstance.customCSS` is injected as a `WKUserScript` by `UserScriptManager`, and Dark Reader is available per service. But `ServiceCSSDefaults` ships CSS for exactly one service in the catalog, LinkedIn. That single stylesheet needed selectors verified against the live page, a `:has()` trick to scope it to the messaging route, and a comment on why `100vh` cannot be used in a Chorus web view. That is the price of hiding a nav bar. Restyling a service to match a theme sits well past it, and it breaks on the service's next deploy.

So the louder the chrome, the worse the seam where it meets content that will not follow. Discord and Terminal promise a look the content will not honour. Glass and Editorial frame the content instead of competing with it, which is a structural point in their favour rather than a matter of taste. The Terminal frame shows the seam honestly — Slack's own aubergine and white beside the black rail. The other five still draw a neutral placeholder, so treat their content areas as unresolved.

An inset, rounded content card is the partial answer, and it is applied to Glass, Soft and Editorial. It makes the web view read as something the chrome frames rather than a second interface butting against the first. Glass needed care, since an inset card leaves the translucency nothing to refract; its card tucks 24 points under the rail. It is deliberately not applied to Discord, Brutalist or Terminal.

**The palettes were measured for contrast, and the numbers disagreed with what the eye had passed.** `text-dim` was under 4.5 to 1 in five of six directions. Soft failed four ways at once and was not shippable as drawn, with a badge at 2.62. Solarized Dark measured dim text 2.42 and rules at 1.12, so it now uses Solarized's own lighter base variants. Every text role now clears 4.5 to 1 except decorative tertiary in Soft and the hairline rules. Details in `UX-AUDIT.md` section 3b.

**Two things left open here.** Glass sets dark text over a light-tinted blur, so over a dark web page the rail darkens with it and the text disappears; it needs a real `NSVisualEffectView` with `.sidebar` material rather than a fixed tint, and it is untested against dark content. And Soft's pastel tints still break service recognition even with the contrast repaired, which is a design decision rather than a token value.

**All six now run in all three layouts.** Page `10 Directions × layouts` adds `hybrid` and `topBars` for each, twelve frames, so a direction is judged on more than the screen it was drawn for. A vertical rail hides a width problem that a top bar exposes: six named services do not fit 1080 points at every scale. Glass and Editorial fit all six; Discord and Soft fit five and overflow the sixth; Brutalist fits four, because it refuses to encode state in colour alone and a cell has to hold the word SIGNED OUT; Terminal fits three, since its rows are padded to fixed column widths. That is a ranking of how well a direction scales, not a defect list, and a wider window moves every count up. Details and the per-direction reasoning are in `FIGMA-BASELINE.md`.

**Every direction now has sheets and notice states.** Page `11 Sheets and notices` carries all six through Add Service, Edit Service, Space Editor, Quick Switcher, the three banners, the find bar and the lock screen: thirty surfaces. All six give the three warnings one shape, which answers the baseline's fifth finding. Glass's sheets sit at 88 per cent opacity: at the 62 they started on, a sheet inherited whatever was under it and its own text vanished, which is more evidence that Glass needs a real `NSVisualEffectView` rather than a fixed tint.

Brutalist and Terminal write a toggle as `[ on ]` and `[ off ]` rather than drawing a switch, which keeps the claim both directions make, that a word carries the state and a colour never carries it alone. Terminal draws from its own variable collection, `Chorus / Terminal`, whose fourteen roles map onto the same slots the other five fill from `Chorus / Directions`.

**Nothing is decided.** All six now cover the same ground, in three layouts and on every sheet and notice, so the choice is open on the evidence rather than narrowed by what happens to be drawn.

## Reference: the interface baseline in Figma

Built 2026-08-13. The shipped interface is rebuilt in Figma (file `Chorus`, key `3MGhWQwnJQbfN6Egnet42I`), traced from 1.5.18 and measured pixel by pixel. Reference: `docs/internal/FIGMA-BASELINE.md`, which holds the measured geometry table, the file map, and what in the file can and cannot be trusted.

Pages `01` through `06` record what ships today and are locked; page `07` is the empty workspace. The redesign work sits on `08` through `11` and is covered by the open sections above. **No app code has changed for the redesign** — everything below describes the shipped interface, not a proposal.

Measuring turned up seven things worth fixing, ranked by cost. Eight corner radii where three would do, five of them between 6 and 10. Three different fills for one selected state (`E4F0FF`, `E8F3FF`, `D2E6FF`). Selection drawn three ways at once, with a lighter stroke on chips than on tabs. One text size doing 36 of about 63 jobs, against four uses of primary colour. Two banners on raw SwiftUI yellow while the third goes solid red, so the three warnings read as three designs. A tab rail padded 6 above and 2 below. Two tap-target sizes and six icon sizes, with 40 sitting under Apple's floor of 44.

The radius collapse, the target sizes and the icon sizes are mechanical. The selection signal, the caption style and the banner shape are decisions somebody has to make first.

**What the file does not cover.** The store banner, recovery banner and lock screen were built from source rather than traced, because producing them needs a damaged database. The offline banner is the same, since catching it needs the network to drop. Service icons are tinted placeholders. No automated pixel diff was run against the captures.

## Shipped in 1.5.18 (2026-08-06): the store left the shared default path

Released: tag `v1.5.18`, build 27, DMG notarized and stapled, appcast live at the `SUFeedURL`, Homebrew cask bumped here and in the tap (`brew style`, `brew livecheck` and the online cask audit all clean). 197 tests, 0 failures.

**Verified live on the dev machine.** 1.5.18 was installed from the stapled DMG over `/Applications` and launched: the store moved into `Application Support/Chorus`, the old path was left with nothing, and the 4 spaces and 14 services came through intact.

Release builds opened SwiftData's implicit store path, `Application Support/default.store`, which carries no bundle id. Bartender 6 added a SwiftData `WidgetSettings` model on 2026-07-30 and took the same default, so both apps opened the same file and each migration dropped the other's tables. Proof rather than inference: `lsof` showed Bartender holding the file, the file's only entity was `ZWIDGETSETTINGS`, and the binary carries `_TtC11Bartender_614WidgetSettings`. Three hand-restores followed in a week, and every `.prepick-` aside from those restores holds Bartender's schema. A crash report caught it mid-flight, with a save on app deactivate faulting a row whose table had been redefined under the open connection.

The move only takes what reads back as Chorus's own store, so another app's file at the old path is left alone; the backup families move either way, since after a collision they are the only way back. Once the new path has a store the old one is never read again, so an older build run in between cannot overwrite newer data with older.

Four more fixes went out with it, from the review that followed. Chat services outside the active space are now preloaded, because a service with no live web view posts no notification banners at all. Data-store tombstones are reconciled against the services that exist, so a restore that rolls the store back past a deletion no longer wipes a live service's cookies. Neither the orphan reap nor the new sweep runs on a launch where the store arrived damaged or was restored. Website data stores no service points at are reclaimed, which is what was leaving stranded sessions behind. The `Notification` shim keeps its prototype and statics and now covers `ServiceWorkerRegistration.showNotification`.

**Two things stay open.** The push path is still out of reach: a notification raised inside a service worker runs where no page script can go. And the window-drag fix for the notice bars has not been checked by hand; AppKit hit-testing is not reachable from the test suite. Testing it needs a banner on screen, which is awkward for the store one. The offline bar carries the same handle, so turning Wi-Fi off for a few seconds puts a notice up that proves the same code.

**The Pages deploy did not fire on its own.** The `docs/**` push to `main` matched the workflow's path filter and the workflow was active, but GitHub dispatched nothing, so the appcast stayed on 1.5.17 and `brew livecheck` read the old version. `gh workflow run pages.yml --ref main` published it. Watch for this on the next release: check `gh run list` after pushing the appcast rather than assuming it deployed.

## Shipped in 1.5.17 (2026-07-31): the Gmail badge counted Spam

Released: tag `v1.5.17`, build 26, DMG notarized and stapled, appcast live at the `SUFeedURL`, Homebrew cask bumped here and in the tap (`brew style`, `livecheck`, `audit --cask --online` all clean).

**Verified live, in the app, against the reporter's own Gmail.** 1.5.17 was installed from the stapled DMG over `/Applications` before publishing, and the badge was watched through the sequence that produces the bug: fresh inbox 2, open Spam 2 (the old code reads 99+ in that view), back to the inbox with Spam's rows still mounted 2. That last reading is the one that used to show 99+.


Reported from a screenshot: the Gmail icon read 99+ over an inbox holding two unread. The catalog's `badgeJS` was `document.querySelectorAll('tr.zA.zE').length`, a **document-wide** count, and Gmail keeps a visited label's list mounted after you navigate away. Measured in the reporter's own Gmail: back in the inbox, `all=101 visible=2`, with Spam's 99 unread rows still in the page. Above 99 the icon clamps to `99+`.

The evidence run also killed the two obvious alternatives. `document.title` is view-dependent (`"Spam (161)"` while browsing Spam), and counting only visible rows reports 99 whenever Spam is the visible list. The one source that held steady across inbox, Spam, and back — with the sidebar collapsed, which is how the reporter runs it — was Gmail's own nav label, `aria-label="Inbox 2 unread"`.

So the badge now reads that label, falls back to unread rows inside the *visible* `div[role=main]` when the label is missing and the hash is the inbox, and otherwise yields `null`, which `pollBadge` drops without writing — a missing reading leaves the last good badge rather than clearing it to 0.

**This is the second attempt at this symptom.** 1.5.6 (`7f3e3c3`) moved *off* a nav count, `.aim .bsU`, because it read 99+ over an empty inbox, and left a test forbidding any aria-label read. That diagnosis was half right: the fault was *positional* matching — first count bubble in the document, which in this account is Spam's 161 — not the idea of reading the nav. The new expression names its target (`/^Inbox\b/`), and the old test's ban is gone with the reasoning recorded in its replacement.

**Two semantics worth knowing.** The nav count is *Primary* unread, so mail sitting unread under Promotions or Updates (203 and 1,987 in the reporter's account) no longer reaches the badge. That matches the report, but it is a real change from "every unread row on screen". And the row-counting fallback leans on `offsetParent`, which is layout-dependent; a `.zero`-frame web view like `HibernatedBadgePoller`'s cannot use it. That path is covered: a test pins that the label path still reads the count in a zero-frame view, which is the configuration the offscreen fetcher actually uses.

Verified: 182 tests. Two run the catalog expression through JavaScriptCore against a stub DOM (cached rows, browsing Spam, `1,987` parsing, empty inbox clearing to 0, the fallback, and the withhold case); two run it through real WebKit and `NotificationManager.pollNow`, one asserting the fixture really does hold 101 rows while the badge lands on 2.

**A note on how to verify this class of bug live.** A fresh Gmail load reads the right number under *both* the old and the new expression, so a screenshot after launch proves nothing. Only the round trip separates them: visit another label, come back, then read the badge.

## Open: Slack notifications arrive late — leading cause fixed in 1.5.18, not yet confirmed

Reported 2026-07-31. The most likely cause was found in the 2026-08-06 review and fixed: a service with no live web view posts no banners at all, because the banner path is the `chorusNotification` handler and only the active space was ever preloaded. "A workspace I was not in" fits that exactly. Chat services in every space are preloaded now, capped at five.

**Still worth confirming with a real measurement**, because one path remains uncovered: a notification raised inside a service worker (the push path) runs where no page script can reach, so if Slack delivers that way the fix does not help it. Get a timeline before assuming it is closed — when the message was sent, when the banner arrived, whether that service was open, and its hibernation setting.

The rest of the original notes still apply as places to look.

Start by pinning down what is being reported: one Slack web client only runs the workspace it has loaded, so "a workspace I wasn't in" could mean a second Slack *service* in Chorus or a second workspace inside one already there — different bugs, different fixes. Then get a timeline: when the message was sent, when the banner arrived, whether that service was open, and its hibernation setting.

Candidates, cheapest first. Hibernation is the obvious suspect for a service that goes quiet — per-service policy (followGlobal/never/immediate/after) crossed with `isNotificationCritical`, which is what keeps chat apps live; check what Slack actually resolves to. Notifications reach the app through the `chorusNotification` handler, which `HibernatedBadgePoller.makeTransientWebView` deliberately omits, so a hibernated service posts nothing at all while it is down. Poll cadence is a separate path (it moves the badge, not the banner) but worth knowing: `runActivePoll` steps 5s → 30s after runs of unchanged polls, `runBackgroundPoll` is flat 30s.

Note the dev-machine caveat in `.remember/remember.md`: notification authorization for `com.nicojan.Chorus` has been wedged to `.denied` on this machine before, which can look like lateness when it is really a permission state.

## Shipped in 1.5.16 (2026-07-30): the store recovery picker

On `main`, hand-verified, released: tag `v1.5.16`, build 25, DMG notarized and stapled, appcast published, Homebrew cask bumped in both this repo and the tap. Design: `docs/superpowers/specs/2026-07-29-store-recovery-picker-design.md`. Plan: `docs/superpowers/plans/2026-07-29-store-recovery-picker.md`, whose closing section records the by-hand pass. Task-by-task progress, rulings, and deferred findings: `.superpowers/sdd/2026-07-29-store-recovery-picker/progress.md` (git-ignored scratch in the worktree, so read it before deleting the worktree).

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

## Current status — through 1.5.17 (2026-07-31)

Everything below has shipped. **Chorus 1.5.17 is the current release**, and the section above covers what it added. The 1.5.15 work it builds on: It opens the store through an explicit versioned schema and migration plan, so an older store migrates through named, tested stages instead of leaving SwiftData to infer the mapping at open time. Inference was the cause of the data loss 1.5.14 was built to catch. If the versioned plan cannot open a store, Chorus falls back to inference, so no update is worse off than before. The safety net stays. See `docs/internal/FOLLOWUP-versioned-schema.md` and `docs/superpowers/specs/2026-07-24-versioned-schema-migration-plan.md`.

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
