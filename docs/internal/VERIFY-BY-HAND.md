# Verify by hand — 1.5.19

What scripted input and the test suite cannot check, in the order that finds problems soonest. Run it on a quiet machine: scripted clicks in an earlier pass landed in Finder and MacWhisper because the dev machine was in use, and one `⌘2` reached the installed release copy.

Record the result next to each item. An unrun item is not a passing item.

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

The one 1.5.18 skipped. Everything about the schema change is verified, including against a copy of a real store, but nothing has run the actual app over the actual store.

16. Put the stapled DMG's app over `/Applications`, replacing the installed copy. ✅ 2026-08-31.
17. Launch it. Confirm the spaces and services all come through, with their names, icons and badges. ✅ 2026-08-31 — ran for an hour, no errors in the log, no crash reports.
18. Delete a space. It should go, its services should stay, and the app should still be running — this is the macOS 15 crash that shipped in five releases. ✅ 2026-08-31, a test space created and deleted, no crash. On macOS 26, which cannot show the macOS 15 fault; the green macOS 15 CI job is the only evidence for that one.
19. Check About says 1.5.19 and the expected build number. ✅ 1.5.19 (30).

## Block 6 — before step 6 of DISTRIBUTION.md

20. `main` is where the DMG was built from, or the DMG is rebuilt.
21. The changelog heading `## [1.5.19] - …` carries the day it actually ships.
22. The Homebrew cask carries the new version and the stapled DMG's sha256 (step 9).
