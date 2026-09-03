# Verify by hand — 1.5.19

What scripted input and the test suite cannot check, in the order that finds problems soonest. Run it on a quiet machine: scripted clicks in an earlier pass landed in Finder and MacWhisper because the dev machine was in use, and one `⌘2` reached the installed release copy.

Record the result next to each item. An unrun item is not a passing item.

## Start here: what is left before 1.5.19 can be published

Where it stands on 2026-09-03. Block 4 is the only unrun item; everything else in this file has passed or is closed. `main` carries everything, through PR #33. Nothing is published: no tag, no GitHub release, no appcast item, no cask bump, and the newest release anywhere is still v1.5.18. The suite is green on macOS 14 and 15.

The artifact is `build/Chorus-1.5.19.dmg`: 1.5.19, build 32, signed, notarised, stapled, Gatekeeper-accepted, sha256 `ec276f7b38269a1f379d2f5d009b920557d1b12db455b00e025d323da30dbb73`, 8,883,765 bytes. It is the first build carrying PR #33, so builds 30 and 31 both hold the click-swallowing snapshot and every tick below against either of them is a tick against a different binary. The build-31 DMG is kept as `build/Chorus-1.5.19-b31-stale.dmg`.

Do these in order.

1. Eject any mounted Chorus disk image before installing. This is not hypothetical twice over: build 30's was left at `/Volumes/Chorus` and dragging from it puts the old build back without saying so, and on 2026-08-31 a build-31 image still mounted there sent a scripted check for build 32 to the stale volume, which reported build 31 and looked like a broken build. `hdiutil attach` mounts the second image at `/Volumes/Chorus 1` and says so only in its own output.
2. Install `build/Chorus-1.5.19.dmg` over `/Applications`, launch it, and check About says 1.5.19 (32). Items 16, 17 and 19 below are ticked against build 30, so run them again.
3. ~~Item 5, then item 11~~ both passed on build 32.
4. ~~Item 12's other half~~ passed on build 32.
5. ~~Item 10~~, ~~item 8~~ both passed. **Block 4 is the one thing left**, and it needs six or more services in one space before it tests anything — see the note on that block.
6. ~~Block 7~~ passed on build 32, item 25 closed on the code. Then block 6, then steps 6 to 9 of `release/DISTRIBUTION.md`.

If something fails, write it next to the item before fixing it.

## Block 1 — the palette's ⌘ digits — RUN 2026-08-31, FAILED, FIXED

`SpacePaletteView` drew `⌘1`, `⌘2` down the trailing edge of its rows. Pressing them switched **services**, not spaces.

The cause was not the one this block guessed. `KeyboardShortcutManager.swift:16` binds `⌘1`–`⌘9` to service switching as menu command key equivalents, and the menu dispatches a key equivalent before the event reaches the first responder — so the palette's `.onKeyPress` was never asked, and reading `press.key` instead of `Int(press.characters)` would have changed nothing. Borrowing the digits while the palette is open cannot be done from `.onKeyPress` at all. It would have to be done in the menu command, which is where the key lands.

The digits and their two unit tests are gone (both tests passed the whole time, over arithmetic nothing called). Arrows, Return, Escape and click are the ways through the palette. If the affordance is wanted back, the fix is a branch in `KeyboardShortcutCommands.switchToService(at:)` on a palette-open flag in `AppState`.

1. Open the space header. The rows carry no ⌘ labels. ✅
2. Arrow down, Return. The highlighted space is selected and the palette closes.
3. Escape closes it without switching.

## Block 2 — the three layouts, by eye

Settings › Appearance, one pass per layout, in both appearances.

5. **Rail on the left.** 240 point rail, space header at the top, rows at an even pitch under it. ✅ 2026-08-31, build 32, dark. Nine rows at a 36 point pitch, icons and labels aligned, nothing truncated, the space header clear above them with its badge and chevron, and the accessories right-aligned: badges on WhatsApp and Gmail, a sleep moon on Reddit, a moon and a mute bell on TikTok. The one combination not on screen is a hibernated service that also carries a badge, which `HibernatedBadgePoller` makes a real state; it cannot collide, because the label is `lineLimit(1)` with tail truncation behind a `Spacer`, so the name gives way first.
6. **Bar along the top.** Header at x 80, clear of the traffic lights; divider; tabs; nav buttons and the cup at the far right. ✅ 2026-08-31, both appearances.
7. **Spaces on the left, services on top.** Strip down the left, tabs along the top, no space header in the bar. The traffic lights sit over the strip. ✅ 2026-08-31, both appearances, with space names off.
8. In each, drag an empty part of the top edge. The window should move. In the third layout that includes blank space in the strip itself, which had no drag handle before this release. ✅ 2026-08-31, build 32, all three layouts.

## Block 3 — the two name settings

9. Turn **Show service names** off. The left rail should narrow to a column of icons, the space header should collapse to its emoji, and the add button should become a plus that fits the narrow rail. ✅ 2026-08-31, both appearances.
10. With names off, hover a service. The tooltip should say the name **and** its state — muted, asleep, camera on — because the compact cell has no room to draw those. ✅ 2026-09-03, build 32. Behaved as expected.
11. Turn it back on. Everything should return to the wide rail. ✅ 2026-09-03, build 32.
12. In the third layout, turn **Show space names** off and on. The strip should switch between 180 and 52 points, and the tabs beside it should shift to clear the traffic lights when it is narrow. ✅ 2026-08-31, build 32. The 180 point strip carries four space names with their badges, the traffic lights sit over it, and the tabs start clear of them. The 52 point strip was confirmed earlier.

## Block 4 — the overflowing tab bar — ATTEMPTED 2026-09-03, OVERFLOW NEVER REACHED

A first pass on 2026-09-03 never reached the overflow. Three services in the space at 800 points fit, so `ViewThatFits` picked `tabRow`, the hugging row, and there was empty draggable bar left over. Nothing in that state exercises this block: no scroll, no gradient, and the add button follows the last tab instead of holding the right edge. Tabs with names are 120 points wide (`ServiceRowView.tabTypicalWidth`) and the header and nav buttons take the rest, so about four fit at the 800 point minimum. **Six or more services in one space.** The tell that the path has flipped is the soft trailing edge, and the add button parting company with the last tab.

13. In a bar layout, put enough services in one space to overrun the window, then narrow the window to its 800 point minimum. ❌ NOT RUN — the 2026-09-03 attempt fit three tabs and never overran.
14. The add button must stay put at the end of the bar. The tabs should scroll under it, and the edge they run past should be soft rather than a tab cut through its icon. ❌ NOT RUN — what was looked at on 2026-09-03 was the hugging row, which has neither behaviour.
15. Select an off-screen service with `⌘1`–`⌘9`. The bar should scroll it into view. ❌ NOT RUN — nothing was off screen on 2026-09-03.

## Block 5 — the install check (gates publishing)

**Items 16 and 19 are ticked against build 32, the shipping artifact. Item 17 is against build 30 and item 18 against build 31, so both are owed again — 17 in particular, since it is the hour-long run that would surface a launch or store fault.**

The one 1.5.18 skipped. Everything about the schema change is verified, including against a copy of a real store, but nothing has run the actual app over the actual store.

16. Put the stapled DMG's app over `/Applications`, replacing the installed copy. ✅ 2026-08-31, build 32.
17. Launch it. Confirm the spaces and services all come through, with their names, icons and badges. ✅ 2026-08-31 — ran for an hour, no errors in the log, no crash reports.
18. Delete a space. It should go, its services should stay, and the app should still be running — this is the macOS 15 crash that shipped in five releases. ✅ 2026-08-31, a test space created and deleted, no crash. On macOS 26, which cannot show the macOS 15 fault; the green macOS 15 CI job is the only evidence for that one.
19. Check About says 1.5.19 and the expected build number. ✅ 2026-08-31, 1.5.19 (32), on the installed stapled DMG.

## Block 7 — the click-swallowing snapshot — RUN 2026-08-31 ON BUILD 32, PASSED

The TD EasyWeb report: added by custom URL, the login screen showed and took no clicks. Chorus was holding a picture of the page past the load it stood in for, and it came back over the live page on the next navigation. It never took hit tests either. Both are fixed and a unit test pins the retention rule. The freeze was never reproduced before the fix — the login page loads clean in a harness carrying Chorus's user scripts, blocklist and user agent, and every field on it hit-tests and accepts input — so the fix went in on its reasoning rather than on a red-to-green observation.

A first pass on build 32 added TD from scratch and clicked straight away, which proves nothing: a service created seconds earlier has no stored snapshot, so `transitionSnapshot` is nil, no image is drawn, and that path was never broken. The pass that counts is item 24.

23. Add `https://easyweb.td.com/` as a custom service. The login screen should come up. ✅ 2026-08-31, build 32, a service created from scratch.
24. Switch to another service and back, then click a field and the Login button. Both must respond. This is where the page went dead. ✅ 2026-08-31, build 32, away for over five minutes and still responding on return.
25. While a page is genuinely loading, click through the covering image. The click should reach the page under it. ✅ CLOSED 2026-09-03 on the code rather than on a click. `.allowsHitTesting(false)` sits unconditionally on the only branch that draws the image (`WebContentView.swift:65`); no path draws it without the modifier. A click test cannot tell a passed-through click from an image that was never drawn, which is the blind spot that made the first build-32 pass read as a pass. Reaching the overlay at all now needs a soft-hibernated service still mid-load on return: every switch-away soft-hibernates and keeps a snapshot but starts no load, while the policy timers call `hibernate(_:)`, whose `teardownWebView` drops the snapshot (`WebViewPool.swift:576`) and reloads from the URL. So a service left to hibernate on its policy comes back grey and then paints. That was observed on 2026-09-03 with the policy set to switch-away, and it is correct for that path. The grey is not new either: the snapshot removal dates to `061a047`, Phase 6. Item 24's five-minute absence remains the passing observation.
26. Check the TD service's icon in the rail. It should be TD's own icon, not a letter tile. TD publishes nothing bigger than 16×16, so expect it to look soft. ✅ 2026-08-31, build 32, TD's green mark in the top bar, and it holds up better at that size than the 16×16 source suggested.

## Block 6 — before step 6 of DISTRIBUTION.md

20. `main` is where the DMG was built from, or the DMG is rebuilt.
21. The changelog heading `## [1.5.19] - …` carries the day it actually ships.
22. The Homebrew cask carries the new version and the stapled DMG's sha256 (step 9).
