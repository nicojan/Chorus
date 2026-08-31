# Verify by hand — 1.5.19

What scripted input and the test suite cannot check, in the order that finds problems soonest. Run it on a quiet machine: scripted clicks in an earlier pass landed in Finder and MacWhisper because the dev machine was in use, and one `⌘2` reached the installed release copy.

Record the result next to each item. An unrun item is not a passing item.

## Block 1 — the palette's ⌘ digits (run first; it gates a visible claim)

`SpacePaletteView` draws `⌘1`, `⌘2` down the trailing edge of its rows, and nothing has ever confirmed the shortcut fires. `handleKey` reads `Int(press.characters)` with Command held, and whether `characters` carries the digit under a modifier is the open question from build step 4. If it does not fire, 1.5.19 ships an affordance that lies, and the fix is to read `press.key` instead.

1. Open the space header, so the palette is on screen.
2. Press `⌘2`. The second space should be selected and the palette should close.
3. Press `⌘1`. Back to the first.
4. With more than nine spaces, confirm there is no `⌘0` row and the tenth is reachable by arrow and by click.

## Block 2 — the three layouts, by eye

Settings › Appearance, one pass per layout, in both appearances.

5. **Rail on the left.** 240 point rail, space header at the top, rows at an even pitch under it. Never seen since the rebuild.
6. **Bar along the top.** Header at x 80, clear of the traffic lights; divider; tabs; nav buttons and the cup at the far right.
7. **Spaces on the left, services on top.** Strip down the left, tabs along the top, no space header in the bar. The traffic lights sit over the strip.
8. In each, drag an empty part of the top edge. The window should move. In the third layout that includes blank space in the strip itself, which had no drag handle before this release.

## Block 3 — the two name settings

9. Turn **Show service names** off. The left rail should narrow to a column of icons, the space header should collapse to its emoji, and the add button should become a plus that fits the narrow rail.
10. With names off, hover a service. The tooltip should say the name **and** its state — muted, asleep, camera on — because the compact cell has no room to draw those.
11. Turn it back on. Everything should return to the wide rail.
12. In the third layout, turn **Show space names** off and on. The strip should switch between 180 and 52 points, and the tabs beside it should shift to clear the traffic lights when it is narrow.

## Block 4 — the overflowing tab bar

13. In a bar layout, put enough services in one space to overrun the window, then narrow the window to its 800 point minimum.
14. The add button must stay put at the end of the bar. The tabs should scroll under it, and the edge they run past should be soft rather than a tab cut through its icon.
15. Select an off-screen service with `⌘1`–`⌘9`. The bar should scroll it into view.

## Block 5 — the install check (gates publishing)

The one 1.5.18 skipped. Everything about the schema change is verified, including against a copy of a real store, but nothing has run the actual app over the actual store.

16. Put the stapled DMG's app over `/Applications`, replacing the installed copy.
17. Launch it. Confirm the spaces and services all come through, with their names, icons and badges.
18. Delete a space. It should go, its services should stay, and the app should still be running — this is the macOS 15 crash that shipped in five releases.
19. Check About says 1.5.19 and the expected build number.

## Block 6 — before step 6 of DISTRIBUTION.md

20. `main` is where the DMG was built from, or the DMG is rebuilt.
21. The changelog heading `## [1.5.19] - …` carries the day it actually ships.
22. The Homebrew cask carries the new version and the stapled DMG's sha256 (step 9).
