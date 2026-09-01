# Verify by hand — 1.5.19

What scripted input and the test suite cannot check, in the order that finds problems soonest. Run it on a quiet machine: scripted clicks in an earlier pass landed in Finder and MacWhisper because the dev machine was in use, and one `⌘2` reached the installed release copy.

Record the result next to each item. An unrun item is not a passing item.

## Start here: what is left before 1.5.19 can be published

Where it stands at the end of 2026-08-31. `main` carries everything, through PR #33. Nothing is published: no tag, no GitHub release, no appcast item, no cask bump, and the newest release anywhere is still v1.5.18. The suite is green on macOS 14 and 15.

**There is no artifact yet.** The build-31 DMG at `build/Chorus-1.5.19.dmg` predates PR #33, so it holds the click-swallowing snapshot and must not be published. The project is bumped to build 32; the signed, notarised, stapled DMG for it still has to be cut. Every tick against builds 30 and 31 below is against a different binary from the one that ships.

Do these in order.

1. Eject the mounted Chorus disk image if one is still there. Build 30's was left at `/Volumes/Chorus`, and dragging from it puts the old build back without saying so.
2. Cut the build-32 DMG (steps 1 to 5 of `release/DISTRIBUTION.md`), install it over `/Applications`, launch it, and check About says 1.5.19 (32). Items 16, 17 and 19 below are ticked against build 30, so run them again.
3. Item 5, then item 11. The 240 point rail with service names on. This is the layout most people will be in and nobody has looked at it.
4. Item 12's other half: the 180 point space strip with space names on.
5. Item 10, then item 8, then all of block 4.
6. Block 7, then block 6, then steps 6 to 9 of `release/DISTRIBUTION.md`.

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

5. **Rail on the left.** 240 point rail, space header at the top, rows at an even pitch under it. ❌ STILL UNSEEN — every screenshot from the 2026-08-31 pass had service names off, so the wide rail, which is the default, has never been looked at.
6. **Bar along the top.** Header at x 80, clear of the traffic lights; divider; tabs; nav buttons and the cup at the far right. ✅ 2026-08-31, both appearances.
7. **Spaces on the left, services on top.** Strip down the left, tabs along the top, no space header in the bar. The traffic lights sit over the strip. ✅ 2026-08-31, both appearances, with space names off.
8. In each, drag an empty part of the top edge. The window should move. In the third layout that includes blank space in the strip itself, which had no drag handle before this release. ❌ NOT RUN.

## Block 3 — the two name settings

9. Turn **Show service names** off. The left rail should narrow to a column of icons, the space header should collapse to its emoji, and the add button should become a plus that fits the narrow rail. ✅ 2026-08-31, both appearances.
10. With names off, hover a service. The tooltip should say the name **and** its state — muted, asleep, camera on — because the compact cell has no room to draw those. ❌ NOT RUN.
11. Turn it back on. Everything should return to the wide rail. ❌ NOT RUN — see item 5.
12. In the third layout, turn **Show space names** off and on. The strip should switch between 180 and 52 points, and the tabs beside it should shift to clear the traffic lights when it is narrow. ⚠️ HALF — the 52 point strip is confirmed, the 180 point one is not.

## Block 4 — the overflowing tab bar

13. In a bar layout, put enough services in one space to overrun the window, then narrow the window to its 800 point minimum.
14. The add button must stay put at the end of the bar. The tabs should scroll under it, and the edge they run past should be soft rather than a tab cut through its icon.
15. Select an off-screen service with `⌘1`–`⌘9`. The bar should scroll it into view.

## Block 5 — the install check (gates publishing)

**Ticked against build 30. The artifact is build 31, so items 16, 17 and 19 are owed again.**

The one 1.5.18 skipped. Everything about the schema change is verified, including against a copy of a real store, but nothing has run the actual app over the actual store.

16. Put the stapled DMG's app over `/Applications`, replacing the installed copy. ✅ 2026-08-31.
17. Launch it. Confirm the spaces and services all come through, with their names, icons and badges. ✅ 2026-08-31 — ran for an hour, no errors in the log, no crash reports.
18. Delete a space. It should go, its services should stay, and the app should still be running — this is the macOS 15 crash that shipped in five releases. ✅ 2026-08-31, a test space created and deleted, no crash. On macOS 26, which cannot show the macOS 15 fault; the green macOS 15 CI job is the only evidence for that one.
19. Check About says 1.5.19 and the expected build number. ⚠️ 1.5.19 (30) was confirmed. The artifact is now build 31.

## Block 7 — the click-swallowing snapshot (new, unverified)

The TD EasyWeb report: added by custom URL, the login screen showed and took no clicks. Chorus was holding a picture of the page past the load it stood in for, and it came back over the live page on the next navigation. It never took hit tests either. Both are fixed and a unit test pins the retention rule, but nobody has reproduced the freeze itself — the login page loads clean in a harness carrying Chorus's user scripts, blocklist and user agent, and every field on it hit-tests and accepts input. So this one needs a person.

23. Add `https://easyweb.td.com/` as a custom service. The login screen should come up.
24. Switch to another service and back, then click a field and the Login button. Both must respond. This is where the page went dead.
25. While a page is genuinely loading, click through the covering image. The click should reach the page under it.
26. Check the TD service's icon in the rail. It should be TD's own icon, not a letter tile. TD publishes nothing bigger than 16×16, so expect it to look soft.

## Block 6 — before step 6 of DISTRIBUTION.md

20. `main` is where the DMG was built from, or the DMG is rebuilt.
21. The changelog heading `## [1.5.19] - …` carries the day it actually ships.
22. The Homebrew cask carries the new version and the stapled DMG's sha256 (step 9).
