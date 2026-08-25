# Open items

## Open: memory grows over a long run

Still open, and less settled than it looked. `scripts/sample_memory.sh` writes the series to `~/Library/Logs/chorus-mem.csv`.

Attribution is the first thing to get right. A raw `ps` sum over `WebKit.WebContent` counts every app's helpers, which reads as 5.4 GB when Chorus owns about half of it. Chorus's own helpers hold a file under `~/Library/WebKit/com.nicojan.Chorus`, and the script picks them out with `lsof`. Thirteen WebContent processes for thirteen live services, one apiece, because every service gets its own data store.

**One run of 40 samples, on 2026-08-22, is all the evidence there is.** Three hours and twenty minutes against the shipping 1.5.18 build. The app's own process went 143 MB to 164 MB, a fitted 10 MB an hour in a narrow band with no drops. The WebContent total did not trend: the fitted line said +192 MB an hour, but the series ran between 1.7 GB and 5.2 GB and ended lower than it started, so that slope is one spike dragged through noise.

**The overnight run that was supposed to settle it never happened**, and the reason is worth writing down because it also produced a wrong reading. The sampler was a shell job started by hand, so it died with the machine. What sits in the CSV after that first run is two fragments, 14 samples over an hour and 5 over twenty minutes, each from a different launch of the app. Read as one series they look like a 140 to 179 MB band that climbs and comes back down, which would refute the 10 MB an hour. They are not one series. Three launches concatenated cannot show a trend of any kind, and on 2026-08-24 they were briefly read as though they could. The hour-long fragment on its own fits at -0.7 MB an hour, which is a hint against the climb and nothing more, because an hour is too short to see 10 MB.

Two changes went in so the question can actually be answered. Every row now carries the app's pid, so a launch boundary is visible in the data instead of having to be inferred from `uptime` resetting. And `scripts/install_mem_sampler.sh` loads the sampler as a LaunchAgent with `KeepAlive`, so it survives sleep, logout and reboot. The archived first run is `~/Library/Logs/chorus-mem-2026-08-23.csv`, under the old header.

**What to do next is wait.** Read the curve once it covers a genuine multi-day span within single launches, and split it by pid before fitting anything.

Four findings from the source, none of them inferred from the samples:

- **Auto-hibernation is off by default.** `AppPreferences.autoHibernateIdleEnabledEffective` resolves nil to false, so nothing frees a WebContent process unless the user turned it on. The only ceiling is `WebViewPool.maxLoaded = 15`, and thirteen live services never reach it, so the LRU sweep has never run on this machine.
- **Messaging services are exempt even when it is on.** `notificationCriticalIDs` is filtered out of both sweeps, in `WebViewPool.evictIfNeeded` and `AppState.hibernateIdleServices`. That is deliberate and right for instant alerts, and Slack and Teams are also the pages that grow for days.
- **Nothing recycles a live web view.** There is no reload-after-idle path, so a page that has been up for three days keeps everything its JS heap accumulated. Chorus is not leaking here so much as never letting go.
- **No memory-pressure response.** Nothing subscribes to `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`, so Chorus sheds nothing when the system is squeezed.

**The one leak in the app process is fixed, on 2026-08-24.** `snapshots[id]` holds a window-sized `NSImage` per soft-hibernated service, and it was dropped only in `teardownWebView`, so switching around left one bitmap per service resident for the session. `wakeService` now drops it. The snapshot covers the wake and has done its job by then: `WebContentView.loadWebViewForSelectedService` reads it and holds its own reference before it asks the pool for the web view, so the transition cannot blank. That fix rests on reading the source rather than on the samples. It has no test. `WebViewPool` owns live `WKWebView`s and takes its snapshot through an async `takeSnapshot` that needs a rendered view, so there is no seam to test against without a real window.

The other three wait for data, cheapest first.

1. Default auto-hibernate on at 30 minutes. One line, in the effective getter, and no schema version is needed because no stored property changes.
2. Recycle instead of exempt: reload a notification-critical service idle past a few hours, so it keeps firing alerts without keeping the heap.
3. Add a memory-pressure source.

**None of the three is backed by measurement.** The hibernate default is the biggest win per line of code and also the one the data does not justify, so it is not being made on a hunch about a default every existing user inherits.

## Open: the donation button is built and unreleased

A button 20 points across, in a 28 point target, sits in the top right of the main window and opens `https://buymeacoffee.com/0xff.r4bbit`; the About panel carries the same link in its credits field, through `CommandGroup(replacing: .appInfo)` in `ChorusApp.swift`. Verified by hand in all three layouts and in the panel. `SupportLink.url` in `ContentView.swift` is the single definition both use.

Both things that were open here are now settled, on 2026-08-16.

The paint stays at 20 points and the click target grew to 28. The audit asks for 44 everywhere else and this is a deliberate exception: a permanent request for money that reads as a control is louder than the ask was, and the pointer, not the finger, is what hits it. `SupportButtonVisibility` in `ContentView.swift` holds both sizes and the arithmetic that keeps the chip where it was drawn when the target grows around it.

Settings › General can hide the button. It writes `showSupportButton` to `UserDefaults`, not to `AppPreferences`, because a stored property there is a new schema version and a migration, which button visibility does not earn — see the SwiftData section of `CLAUDE.md`. The cost of that choice is that the setting sits outside the store, so a restore from backup does not carry it, and it is the one General setting not in `AppPreferences`.

The nav buttons in `hybrid` and `topBars` end in the same corner, so `ServiceSidebarView` reserves `SupportButtonVisibility.reservedWidth` (44 points) of trailing padding for the button, and falls back to 10 when the button is hidden. Cut that reserve and the two overlap as soon as the Home button appears.

All three states were verified in the running Debug build on 2026-08-16: the button drawn with the nav buttons clear of it, the corner with the button hidden and the nav buttons moved into the space, and the cup taking its hover colour with the pointer 4 points outside the painted chip, which is what proves the wider target is live.

Charging for the themes was considered and dropped for now. The repo is public and MIT, so a paywall compiled into the binary is a speed bump, and Apollo's model relied on App Store payment infrastructure and a large userbase, neither of which applies here.

## Open: C · Rethink is the structural concept, and the labelled service row is built

Built 2026-08-13, after the baseline below. `docs/internal/UX-AUDIT.md` holds the research and a Nielsen heuristic pass over the shipped screens; page `08 Redesign concepts` in the Figma file holds three answers to it.

The audit's finding is that the baseline's seven items are all real and none of them is the biggest problem. In `hybrid` and `sidebar` a service tab drew an 18pt icon with no label (`ServiceTabView.content`, the `iconOnly` branch), so two Slack workspaces were two identical squares and the name lived only in a tooltip. `SpaceButton.verticalCell` does the same to spaces. A service has no visible state for loading, failed, or signed out, which matters because every service is a web view whose session expires quietly. Severity 4 and 3 against a list of radii and target sizes. **The severity 4 one is fixed on a branch and checked by eye — see the step 3 note below.** The severity 3 one still stands.

Three concepts, conservative to radical, each in three layouts and both appearances. `A · Tidy` executes the baseline list inside the shipped skeleton — a patch. `B · Recompose` adds labels everywhere and a health dot, and costs chrome: its sidebar spends 400 points before content. `C · Rethink` drops to one rail with the space as a header on it, reclaiming 161 points, and in doing so collapses `hybrid` and `topBars` into the same design — evidence that three layouts was an artifact of having two rails rather than a real choice.

**C is picked, on 2026-08-16.** Three things followed from the choice and are now settled rather than open. Two rails become one, so `hybrid` and `topBars` stop being separate designs. A service and a space each carry a readable name in every layout, which is the severity 4 finding and the severity 3 one under it. And the six visual directions on pages `09` to `11` are all drawn on C's sidebar already, so whichever one wins needs no redrawing.

The design that follows from it is written up in `docs/superpowers/specs/2026-08-16-concept-c-rethink-design.md`: the measured geometry off the drawn frames, what each app file has to become, a seven-step build order, and three risks worth reading before any code moves.

**Step 1 of that order is done.** The audit's macOS 26 warning, that an `NSGlassContainerView` inside `NSToolbarView` eats clicks aimed at SwiftUI controls in the title-bar band, does not reach Chorus: the app creates no `NSToolbar`, and a click on a `hybrid` service tab in that band selects the service and leaves the window where it was. Measured in the Debug build on 2026-08-16, on macOS 26.5, against SDK 26.5. So C's horizontal geometry stands as drawn. Dragging in the band is the part that scripted input cannot check, and it needs the by-hand pass once the rail is rebuilt.

**Step 3 is built, seen, and merged to `main` on 2026-08-17. It is not released.** No version has been cut with it, and none should be until step 5 lands, because on its own it costs sidebar chrome (see below). `ServiceRowView` draws one labelled row in both axes and replaces both unlabelled cells: the vertical rail's 32pt icon and the horizontal bar's `iconOnly` tab. Vertical is the drawn 224 by 34 row at 36pt pitch inside a 240pt rail; horizontal is a 32pt tab that hugs its label. The badge, the mute bell, the hibernation moon and the media glyph come off the icon's corners and sit inline on the trailing edge, badge last. `ServiceTabView` and `ServiceIconView` are deleted; the shared parts beside them (`ServiceIconSquare`, `ServiceAccessibility`, `BadgeCountView`, `MediaIndicatorGlyph`) stay. The reorder maths, drag and drop, arrow keys and VoiceOver move actions moved across untouched, and `supportButtonTopInset` is re-measured against the new bar heights (topBars 34 to 36, hybrid 38 to 40). 197 tests, 0 failures.

Three things about it are worth knowing before picking it up.

- **How it looks was checked on 2026-08-17 and it holds.** Debug build, `Chorus-debug` store, all three layouts, both appearances. The drawn geometry is the built geometry: rows stack at a 36pt pitch, a row is 224 wide inside the 240pt rail, the icon sits 8 points in and the label 36. Each trailing accessory was turned on live rather than reasoned about. Muting a service puts the bell on the trailing edge. Hibernating one puts the moon there and drops the row to 60% opacity. A name long enough to overrun the row truncates with an ellipsis, and the bell stays put. Hover fill reads, and so do the selected row's tint fill and border. The screenshots are in the session scratchpad; none of them went into the repo.
- **A tab bar that overflows says nothing about it.** With names on the tabs, five services and a 1000pt window already fill the bar. At the 800pt minimum width the last tab is cut mid-icon and the add button sits off the end. The strip does scroll, through `ScrollView(.horizontal, showsIndicators: false)` in `ServiceSidebarView.tabStrip`, but nothing on screen says so, and a clipped icon reads as broken. That setting predates this step; labelled tabs are what make it easy to reach. Step 5 rebuilds this strip, so the fix belongs there.
- **In `sidebar` this step alone costs chrome.** 52pt space rail plus 240pt service rail is 292 points before content, against today's 104. Step 5 takes the second rail out and lands it at 240, so the cost is an artifact of shipping step 3 on its own. The horizontal layouts have no such cost.
- **The horizontal tab has no width cap, on purpose.** A `maxWidth` only bites when something proposes an unbounded width, which the strip's fallback scroll view does, and there it stretches every short tab to the cap instead of trimming the long ones. `ViewThatFits` already hands overflow to that scroll view, so a long name costs scrolling rather than layout.

Selection and focus were left exactly as they were, `focusEffectDisabled()` included, because the specimen that reshapes them is step 7 and cutting it twice is waste.

**Step 2 (`RailLayout` to two cases) is not started, and it should wait for step 5.** It does not depend on step 3, and the spec called it mechanical with no visual change. The second half of that is wrong, and the spec now carries the correction. Retiring `hybrid` maps its users onto `topBars`, and until one rail draws both layouts those are two different screens: `hybrid` keeps the spaces on a 52pt rail down the left, `topBars` has no left rail and stacks two horizontal strips. Shipping the enum change alone moves every hybrid user to an arrangement they did not pick, then moves them again at step 5.

**All seven build steps of concept C are done, as of 2026-08-17. 215 tests, 0 failures.** Steps 6 and 7 landed after the pass below, so neither has been seen at all.

Step 6 puts a 9 point mark on a service icon's bottom-right corner: nothing when the page is up, a grey ring while it loads, an orange disc when it failed. Three silhouettes rather than three hues, because the drawn frame separated the states by colour alone and that fails a red-green colour-blind user; `ServiceAccessibility.label` says the state in words as well. `WebViewPool` publishes it per service, the way it already publishes media capture state, so a service that broke while you were looking at another one still says so. One trap worth remembering: the error page Chorus paints on a failure is itself a navigation that finishes, so `didFinish` would have reported the service healthy a moment after it broke. `errorPageLoadInFlight` on the coordinator is the guard. Signed-out is drawn and never set, per the spec, and a test pins that no navigation event can produce it.

Step 7 is the baseline's own list. `NoticeStrip` replaces the two raw yellows and the solid red bar with one shape at three severities, carrying the tone in the icon and the rule rather than the fill, and carrying the window-drag handle each notice needs. `ChorusRadius` takes eight radii down to three. `RowMark` splits selection from focus: a fill for one, a ring for the other, which is the reshape the audit asked for rather than the switch-off 1.5.10 did.

**Steps 5 and 2 are built and merged, and half of concept C has now been seen running.** `UnifiedRailView` replaces `ServiceSidebarView` and `SpaceStripView`, both deleted. `RailLayout` is down to two cases. 205 tests, 0 failures.

What the by-eye pass on 2026-08-17 did establish, in the Debug build against `Chorus-debug`:

- **The bar layout is what the frame draws.** One bar, measured at 42 points, the space header at x 80 clearing the traffic lights, a divider after it, then the labelled service tabs, the nav buttons and the coffee cup at the far right. The second bar is gone.
- **The `hybrid` forward-map works on a real store.** That store had been left on `hybrid` the day before. The rebuilt app opened it as the bar layout, which is the case the map sends it to, and not the `.sidebar` fallback.
- **The palette opens from the header and is right.** Both spaces with emoji, name and service count, `⌘1` and `⌘2` down the trailing edge, the current space carrying the tint fill, and the New Space row under a divider. It measured 260 points wide.

What it did not, and why. The dev machine was in active use. Scripted keystrokes and clicks kept landing in whatever app had come forward: a Finder window and MacWhisper both took input meant for the rail. One `⌘2` reached the installed release copy of Chorus, which is harmless, since all it changes is which service is on screen. Driving the UI was stopped there rather than pushed through. So **three things stay unverified**: the sidebar layout with its 240 point rail and the header at y 38, both appearances, and whether `⌘1`–`⌘9` inside the palette actually picks a space — the `KeyPress.characters` question from step 4 is still open. All three want a by-hand pass on a quiet machine, and `docs/internal/VERIFY-BY-HAND.md` is that pass written out step by step, with what to expect at each one.

**Step 4 is built and merged, and none of it has been seen on its own.** `SpaceHeaderView` draws the current space as a 224 by 36 header on the rail, or 150 by 32 in the bar, with the aggregate badge and a pop-up chevron. `SpacePaletteView` is the switcher it opens: a 260 point popover at radius 14, whose rows carry emoji, name, service count, unread badge and the `⌘` digit. 203 tests, 0 failures, six of them new and all on the pure helpers (`SpacePalette`, `SpaceHeader`). Nothing presents either view until step 5, so they compile and run but cannot be reached, and the by-eye pass has to wait for that step.

Three decisions inside it worth not relitigating:

- **Space drag-to-reorder and the per-space context menu moved into the palette**, beyond the two views the spec named. `SpaceStripView` holds them today and step 5 deletes it, so they move into the palette or they disappear. `ServiceReorder` was reused untouched, as the spec demands.
- **The palette reports edit, delete and add upward through closures** instead of presenting the sheets itself. A sheet raised from inside a popover goes down with the popover when it closes. Whoever assembles the rail at step 5 owns those sheets.
- **The header and the palette are not welded together.** The header is a button with an `isPaletteOpen` flag; the owner attaches the `.popover`. Three lines at the call site, and neither view has to know about the other.

Two things about it are unverified by construction. `⌘`-digit resolution reads `KeyPress.characters`, which is untested against a live command-modified keystroke, and the palette takes `focusEffectDisabled()` on its container so the popover does not draw a ring around everything. Step 7 is the specimen that settles focus, and it should look at that.

**The product call that gated step 4 is answered: the digits are palette-local.** The palette on page `08` labels its rows `⌘1` to `⌘4`, and `⌘1`–`⌘9` currently switches services (`KeyboardShortcutManager.swift:16`), an accelerator set the audit rates severity 0 and says to protect. `SpacePaletteView` binds the digits itself while it is open; `KeyboardShortcutManager` is left alone, so nothing shipped breaks. Reassigning them globally was the alternative and it is rejected: it breaks a shipped accelerator to solve a problem nobody reported. Step 4 is unblocked.

**Half of that price was refused on 2026-08-17, and the spaces are back on screen.** It sits on `feat/spaces-presentation` at `b14e53b`, pushed and unmerged; `main` is at `366745a`. Running the build was what settled it: with the header alone, a space you are not looking at can collect unread messages and say nothing, and that was the one thing the old rail did well. Rather than pick a single answer, `SpacesPresentation` offers three and remembers the choice. Spaces listed in the service rail above the services is the new default. Spaces in a rail of their own is `SpaceRailView`: 180 points, and named rows in place of the audit's unlabelled emoji column. The third is the header and its popover, which is what concept C shipped. It stores as a `UserDefaults` key for the same reason `showSupportButton` does: chrome does not earn a schema version, and an `AppPreferences` property is one. The rows, badges, drag-to-reorder and the context menu are one `SpaceListRows` shared by all three, so the palette lost its copy instead of the app gaining a second one.

Seen running in the Debug build on 2026-08-17: the in-rail list in both axes, and the own-rail pair in the sidebar layout. The by-eye pass caught and fixed two things. The spaces list was holding 130 points of empty rail, because a `maxHeight` let the scroll view take everything the rail offered it. The "Spaces" caption sat level with the traffic lights. One change went in after the last screenshot and is **unverified**: in the own-rail sidebar the service rail draws the current space as a caption rather than a header, so the two columns' first rows sit on one line. The horizontal own-rail bar has not been seen at all, and neither has the inverted coffee cup in the light appearance.

The rest of the price stands. A and B are closed. A never answered the severity 4 finding, which is the product's core loop; B answered it and spent 400 points of sidebar before content to do it.

## Open: Editorial is built, and the space list has not caught up

Built 2026-08-24, on `feat/spaces-presentation`. 229 tests, 0 failures. Seen running once in the Debug build, which found a bug and a gap.

`ChorusTheme` holds every role the chrome draws with, plus the geometry a direction is allowed to move, and reaches the views through the environment. `ChorusThemeChoice` picks between `native` and `editorial` and stores in defaults rather than in `AppPreferences`, for the reason `SpacesPresentation` does: a stored property there is a schema version and a migration, which a theme picker does not earn.

A role is either `.system`, where AppKit decides, or `.fixed`, where a direction drew the value. That split is the useful part. **Every `.fixed` text role is measured in the suite**, so the audit's contrast pass of 2026-08-13 is now a test rather than something someone did once: Editorial's tightest is `status-warn` at 4.81 to 1 on the rail, and a role edited to a prettier value fails the build instead of a user's eyes. The native theme is not measured, which is the honest boundary. Apple has already done that arithmetic and this app should not pretend to a second opinion.

What Editorial changes, measured off `Direction · Editorial / sidebar`. The rail goes to 300 points against 240, and a row to 248 by 64 against 224 by 34. Two lines of type where there was one, and no service icon at all. An unread count is a numeral in the accent rather than a red disc, and selection a 3 by 16 rule rather than a fill. The space gets a masthead with its name at 30 points. The web view is inset 20 points at radius 8.

`ServiceRowView` picks between its own row and `EditorialServiceRow` off the theme, so the rail, the drag and drop, the arrow keys and the VoiceOver move actions are untouched and the choice is made in one place.

### The first build was far off the frame, and here is what was wrong

Comparing the running app against `Direction · Editorial / sidebar` side by side, rather than against the notes about it, found six faults. All six were mine, and five of them came from theming the parts I had written and forgetting the parts I had not.

- **The rail was never Editorial's colour.** `UnifiedRailView` painted `.background(.background)`, so the rail stayed system-painted and only the rows changed. In a light appearance that is near enough to white to look plausible, which is why the first pass through it read as fine.
- **No hairline under a row.** The frame gives each row a 1 point bottom stroke in `#E6E6E1`, and half of what makes the rail read as a list rather than floating text is that rule. The `LazyVStack` also spaced rows 2 points apart, which would have broken the rule into a dashed line.
- **No border on the card.** The card is white on a white window, so the hairline is the only thing that makes it a card. Painting the well `dir/content` was wrong twice over: the frame leaves the well unfilled and strokes the card instead.
- **The status colours were wrong on two of four states.** The frame draws Loading orange and Failed red. An earlier version made them agree with the native corner dot, which draws loading grey and failed orange, and the reasoning was that the two presentations must not drift. That was wrong. The dot only appears when something is off, so its scale starts at "in progress"; the words are drawn for every state and grey is spent on Live. Agreeing with the dot made Loading invisible.
- **The masthead never drew.** It was gated on `SpacesPresentation == .switcher`, and the default is `.inRail`. Editorial now leads with the masthead in every presentation, since it is the direction's signature element and the frame draws nothing else at the top of the rail.
- **Rows were vertically centred** rather than sitting at the frame's 13 points of top padding.

The lesson is cheap to state and was expensive to skip: the notes about a design are not the design. Reading `dir/rail` out of the variable collection is not the same as checking that anything paints with it.

### What running it found

**The focus ring swamped the selection rule, and is fixed.** Drawn at the native row's 2 points in the accent, a focused row read as a focused text field and the 3 point selection rule beside it disappeared. It is a 1 point hairline at 45 per cent now. Selection is still a fill-equivalent and focus is still its own mark, which is what `RowMark` argues for; Editorial's version of both is simply quieter.

**The space list is still drawn native.** `SpaceListRows` carries emoji and the system selection fill, so above an Editorial service list it reads as two designs in one rail, which is the fault the audit filed against the shipped banners. It is the most jarring thing in the window.

### The masthead now leads, in every presentation

It used to be gated on `SpacesPresentation == .switcher`, and the default is `.inRail`, so the direction's signature element never drew unless the user had already changed an unrelated setting. Editorial draws it first in all three presentations now. `.switcher` is the arrangement the frame shows and matches it exactly; `.inRail` puts the space list under the masthead, which the frame does not draw but which is coherent, and `spaceHeader` stays non-interactive there so it does not offer a click that would do nothing.

That leaves the space list itself as the last thing out of step, below.

### Still to do

- The notices, sheets, palette and quick switcher all still draw native. `NoticeStrip`, `ChorusRadius` and `RowMark` are the seams.
- The horizontal bar is untouched: `ServiceRowView` only delegates on the vertical axis, so Editorial in the bar layout is native geometry with native colours.
- **Editorial is light only**, because the `Chorus / Directions` collection has no light/dark axis. Its modes are the five directions. `ThemeColorPair` carries both slots and falls back until the dark half is drawn, and Settings says so. Drawing Editorial Dark in Figma drops in with no code change.
- **Two differences from the frame that are not faults, and want a decision.** The card sits about 30 points lower than the frame's 20 point inset, because app chrome the frame does not draw sits above it. And the rail's foot carries an `Add service` bar the frame has no equivalent for. Both are real features rather than mistakes, so neither was changed to chase the drawing.
- One deliberate deviation from the frame: the selection gutter is reserved on every row, so a name does not jump 11 points sideways when clicked. The frames were drawn one row at a time and never showed that transition.

## Decided: Editorial, of six visual directions under one ceiling

Page `09 Visual directions` takes one screen, the C sidebar, and restyles it six ways: Discord, Glass, Editorial, Brutalist, Soft, Terminal. Colour comes from modes, so a direction can be swapped on a frame without touching a layer. Each carries a note on what it costs to build.

**The ceiling matters more than the six.** A direction reaches the rail, the bars and the sheets. The web view stays out of reach. `ServiceInstance.customCSS` is injected as a `WKUserScript` by `UserScriptManager`, and Dark Reader is available per service. But `ServiceCSSDefaults` ships CSS for exactly one service in the catalog, LinkedIn. That single stylesheet needed selectors verified against the live page, a `:has()` trick to scope it to the messaging route, and a comment on why `100vh` cannot be used in a Chorus web view. That is the price of hiding a nav bar. Restyling a service to match a theme sits well past it, and it breaks on the service's next deploy.

So the louder the chrome, the worse the seam where it meets content that will not follow. Discord and Terminal promise a look the content will not honour. Glass and Editorial frame the content instead of competing with it, which is a structural point in their favour rather than a matter of taste. The Terminal frame shows the seam honestly — Slack's own aubergine and white beside the black rail. The other five still draw a neutral placeholder, so treat their content areas as unresolved.

An inset, rounded content card is the partial answer, and it is applied to Glass, Soft and Editorial. It makes the web view read as something the chrome frames rather than a second interface butting against the first. Glass needed care, since an inset card leaves the translucency nothing to refract; its card tucks 24 points under the rail. It is deliberately not applied to Discord, Brutalist or Terminal.

**The palettes were measured for contrast, and the numbers disagreed with what the eye had passed.** `text-dim` was under 4.5 to 1 in five of six directions. Soft failed four ways at once and was not shippable as drawn, with a badge at 2.62. Solarized Dark measured dim text 2.42 and rules at 1.12, so it now uses Solarized's own lighter base variants. Every text role now clears 4.5 to 1 except decorative tertiary in Soft and the hairline rules. Details in `UX-AUDIT.md` section 3b.

**Two things left open here.** Glass sets dark text over a light-tinted blur, so over a dark web page the rail darkens with it and the text disappears; it needs a real `NSVisualEffectView` with `.sidebar` material rather than a fixed tint, and it is untested against dark content. And Soft's pastel tints still break service recognition even with the contrast repaired, which is a design decision rather than a token value.

**All six now run in all three layouts.** Page `10 Directions × layouts` adds `hybrid` and `topBars` for each, twelve frames, so a direction is judged on more than the screen it was drawn for. A vertical rail hides a width problem that a top bar exposes: six named services do not fit 1080 points at every scale. Glass and Editorial fit all six; Discord and Soft fit five and overflow the sixth; Brutalist fits four, because it refuses to encode state in colour alone and a cell has to hold the word SIGNED OUT; Terminal fits three, since its rows are padded to fixed column widths. That is a ranking of how well a direction scales, not a defect list, and a wider window moves every count up. Details and the per-direction reasoning are in `FIGMA-BASELINE.md`.

**Every direction now has sheets and notice states.** Page `11 Sheets and notices` carries all six through Add Service, Edit Service, Space Editor, Quick Switcher, the three banners, the find bar and the lock screen: thirty surfaces. All six give the three warnings one shape, which answers the baseline's fifth finding. Glass's sheets sit at 88 per cent opacity: at the 62 they started on, a sheet inherited whatever was under it and its own text vanished, which is more evidence that Glass needs a real `NSVisualEffectView` rather than a fixed tint.

Brutalist and Terminal write a toggle as `[ on ]` and `[ off ]` rather than drawing a switch, which keeps the claim both directions make, that a word carries the state and a colour never carries it alone. Terminal draws from its own variable collection, `Chorus / Terminal`, whose fourteen roles map onto the same slots the other five fill from `Chorus / Directions`.

**Editorial is picked, on 2026-08-24, without the eighteen-frame content pass.** The pass was going to fill the other five content areas with a drawn service so the six could be judged on the chrome-to-content seam. Drawing it would not have changed the answer, because the seam is already decided by the ceiling above: the web view will not follow any of the six, so a direction is judged on how well it tolerates content that ignores it.

That test ranks the six before a single content frame is drawn. Discord and Terminal promise a look the content will not honour, and Terminal's own frame proves it by putting Slack's aubergine beside a black rail. Brutalist fits four named services in a 1080-point bar, because a cell has to hold the word SIGNED OUT. Soft still breaks service recognition with its pastel tints, and that survived the contrast repair, so it is a design problem rather than a token value.

Which leaves Glass and Editorial, the two the doc already calls structural rather than a matter of taste. **Editorial wins on the one thing Glass cannot currently do.** Glass sets dark text over a light-tinted blur, so a dark web page darkens the rail with it and the text goes. Fixing that needs a real `NSVisualEffectView` with `.sidebar` material rather than the fixed tint the frames use, and even then it is untested against dark content. Chorus's content area is other people's web pages, a good share of them dark, and several of them dark only some of the time. A default whose legibility depends on what Slack shipped this week is not a default. Glass also needed its sheets pushed to 88 per cent opacity to keep their own text, which is the same failure showing up a second time.

Editorial carries none of that. It fits all six services in the top bar at 1080 points, every text role clears 4.5 to 1, and its inset rounded content card is the partial answer to the seam. It frames the web view instead of competing with it, which is the whole argument.

**What would overturn this.** Glass becomes the better answer the moment someone builds the `NSVisualEffectView` version and it holds against a dark page, because translucency does the framing job better than a card does. That is a build rather than a redraw, so it belongs after the rail ships. Staying native is still a live answer too, and it is the cheapest one: Editorial's value over plain SwiftUI is the content card and the type scale, and if those land and the rest reads as noise, take the rest back out.

**Cancel the eighteen frames outright.** Drawing five placeholder content areas to confirm a ranking the ceiling already fixes is work that cannot change its own outcome. If Editorial needs frames, it needs them for its own screens. The comparison is over.

## Reference: the interface baseline in Figma

Built 2026-08-13. The shipped interface is rebuilt in Figma (file `Chorus`, key `3MGhWQwnJQbfN6Egnet42I`), traced from 1.5.18 and measured pixel by pixel. Reference: `docs/internal/FIGMA-BASELINE.md`, which holds the measured geometry table, the file map, and what in the file can and cannot be trusted.

Pages `01` through `06` record what ships today and are locked; page `07` is the empty workspace. The redesign work sits on `08` through `11` and is covered by the open sections above. **Everything below describes the shipped interface, not a proposal.** The one piece of redesign code written so far sits unmerged on `feat/service-row-view`, so `main` still matches these pages.

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

Tracked publicly as issue #24 since 2026-08-24, because the original report left no thread to reply on. That issue asks for the four things the timeline needs.

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

## History — the releases under 1.5.18

Everything below has shipped. **Chorus 1.5.18 (2026-08-06) is the current release**; its own section is above, as is 1.5.17's. This section is the history under them. The 1.5.15 work it builds on: It opens the store through an explicit versioned schema and migration plan, so an older store migrates through named, tested stages instead of leaving SwiftData to infer the mapping at open time. Inference was the cause of the data loss 1.5.14 was built to catch. If the versioned plan cannot open a store, Chorus falls back to inference, so no update is worse off than before. The safety net stays. See `docs/internal/FOLLOWUP-versioned-schema.md` and `docs/superpowers/specs/2026-07-24-versioned-schema-migration-plan.md`.

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
