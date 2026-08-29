# Verify by hand

Five things are built, merged or pushed, and have never been looked at. Each one needs eyes rather than a test, and the last attempt on 2026-08-17 failed because scripted clicks kept landing in whatever app had come forward. Do these on a quiet machine, with Finder and everything else out of the way.

**Blocks 1 and 2 passed on 2026-08-29, and PR #23 is merged.** They are kept below as the record of what was checked, and because the same steps are what to re-run if the fresh-start path ever changes. Blocks 3 to 5 are still open.

The three that remain sit on `feat/spaces-presentation`.

One lesson from the pass worth carrying: quit the installed release copy first. Both builds run a process called `Chorus`, so `System Events` will drive whichever it finds, and that is the likeliest way for a scripted click to go somewhere you did not mean.

## Never point any of this at the real store

The Debug build resolves its store to `~/Library/Application Support/Chorus-debug` and its defaults domain to `com.nicojan.Chorus.debug`. The release app uses `~/Library/Application Support/Chorus`. Every command below names `Chorus-debug` in full. A dev build has already destroyed a user's spaces and logins on this machine once, on 2026-07-22, so read each path before running it.

Nothing here deletes anything. The throwaway store is moved aside and moved back, which is the same discipline the app itself follows.

Quit both copies of Chorus first, the Debug one and the installed release one. A second process holding the store open will make everything below behave oddly for reasons that have nothing to do with what is being tested.

---

## 1. The `Start fresh` button, and the launch straight after it

**PASSED 2026-08-29. Was the gate on merging PR #23, now merged at `0a55562`.**

What the run showed: the banner carried `Start fresh…` and no `Review backups…`, the confirmation appeared before anything moved, and the restart went through the sheet rather than being dropped — the process id went 75746 to 76517, which is the evidence, since the recovery picker's version of this was where AppKit swallowed the terminate. The launch after it offered nothing to restore. The `.reset-` aside was 14 bytes, the same file that went in, and Review backups listed it as `can't be read` while `Your data now` held `Current`.

The button needs a store that fails to open. `Chorus-debug` currently holds several good `.snapshot-*.bak` files, and `newestRestorableSnapshot` would find one and restore from it silently, so the banner would never appear. Start from an empty directory.

```
SUPPORT=~/Library/Application\ Support

# Park the whole debug directory, including its snapshots.
mv $SUPPORT/Chorus-debug $SUPPORT/Chorus-debug.parked

# A directory holding one store that is not a database, and nothing else.
mkdir -p $SUPPORT/Chorus-debug
printf 'not a database' > $SUPPORT/Chorus-debug/default.store
```

Then, in the Debug build:

1. Launch. **Expect** the temporary-storage banner, carrying a `Start fresh…` button. If instead the app comes up with data, the directory was not empty; check for `.bak` files and start over.
2. Click `Start fresh…`. **Expect** a confirmation before anything happens.
3. Confirm. The move is deferred to the next launch, the same way a restore is, because the store cannot move while a container holds it open. **Expect** the app to say so and to want a relaunch. Watch that quitting actually works here: AppKit drops a terminate request made through an attached sheet, which is how the recovery picker's version of this was found the hard way.
4. Quit and relaunch.

**This next launch is the gate.** Before the fix, `StoreInventory.best` ranked the `.reset-` aside like any other backup, and the preselection fires exactly when the live store is the untouched seed, which is the state a fresh start leaves. So the app would have greeted you with an offer to restore the very store you just chose to leave.

5. **Expect no banner offering to restore anything.** A working app on an empty store, nothing more.
6. Open Review backups. **Expect** the `.reset-` aside listed there, so undoing a fresh start is one click. Listed but never proposed is the whole claim.

## 2. Starting fresh twice

**PASSED 2026-08-29, straight after block 1.** This is what changed on 2026-08-24, and until that run it had only ever been checked by test.

What the run showed: the second corruption reproduced the first exactly, `haveBackup=false` in the log with a `.reset-` aside sitting right beside the store, and two `.reset-*.bak` files afterwards. The older one was compared by hash rather than by eye and came back `b2affd46b0aac8fbf277baa19dddc00745884881` both times.

One thing the run turned up that is not a failure. The second aside came out at 262144 bytes though the file corrupted was 14, because a 432 KB `default.store-wal` was still beside it and SQLite most likely replayed the log onto the corrupt file at open. Nothing was lost. It does mean an aside can be bigger than the file that was damaged, which is worth knowing if a size in the picker ever looks wrong.

`hasAnyPreservedCopy` now stops an automatic fresh start on a `.prepick-`, `.prerestore-` or `.corrupt-` sibling, where before it saw only `.snapshot-`. `.reset-` is excluded on purpose, so a second run of issue #20 gets fixed rather than landing back on the button.

```
printf 'not a database' > $SUPPORT/Chorus-debug/default.store
```

7. Launch, and go through the button again.
8. **Expect** it to work exactly as it did the first time. If the banner offers no button, or the button refuses, the `.reset-` exclusion has broken and PR #23 should not merge.
9. **Expect** two `.reset-*.bak` asides in the directory afterwards, the older one untouched. `ls $SUPPORT/Chorus-debug/` will say.

When both blocks are done, put the debug directory back. The throwaway goes to `/tmp`, where it ages out on its own:

```
mv $SUPPORT/Chorus-debug /tmp/chorus-debug-throwaway-$(date +%s)
mv $SUPPORT/Chorus-debug.parked $SUPPORT/Chorus-debug
```

---

## 3. The sidebar layout at 240 points

**Branch: `feat/spaces-presentation`.** Never seen. The 2026-08-17 pass got through the bar layout and the palette, then lost its input to Finder and MacWhisper.

10. Switch to the sidebar layout, spaces in the service rail, which is the new default.
11. **Expect** a 240-point rail, the space header at y 38, rows at a 36-point pitch, the icon 8 points in and the label at 36.
12. Do it again in the other appearance. Both, because the frames were drawn for both and only one has been seen.

## 4. `⌘1`–`⌘9` inside the palette

**Same branch.** Unverified by construction: the palette resolves the digit through `KeyPress.characters`, which has never been tried against a live command-modified keystroke. The rest of the app binds those digits to services, and the palette is supposed to take them only while it is open.

13. Open the palette from the space header.
14. Press `⌘2`. **Expect** the second space to be picked.
15. Close the palette and press `⌘2` again. **Expect** the second *service*, unchanged from what ships today. That accelerator is rated severity 0 in the audit and the palette must not have eaten it.

## 5. The horizontal own-rail bar, and the cup in light

**Same branch.** Neither has been on screen.

16. Switch spaces to their own rail, then to a horizontal layout. **Expect** the spaces bar and the services bar to read as two strips rather than one crowded one.
17. In the own-rail sidebar, **expect** the service rail to draw the current space as a caption rather than a header, so the two columns’ first rows sit on one line. This one changed after the last screenshot and has never been seen at all.
18. Switch to the light appearance and look at the coffee cup in the top right. **Expect** it inverted and legible. Hover it: the chip should take its hover colour with the pointer about 4 points outside the painted 20-point chip, which is what proves the 28-point target is live.

---

## What to do with the results

A block that passes needs one line in `docs/internal/OPEN-ITEMS.md` moving from unverified to seen, with the date. A block that fails needs the screenshot and the step number. Blocks 1 and 2 gate the merge of PR #23; blocks 3 to 5 gate nothing, but they are the difference between "built" and "known to work".
