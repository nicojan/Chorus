# Design: C · Rethink, one rail with the space as its header

Date: 2026-08-16. Status: approved in concept, not yet implemented. No app code has changed.

Source of truth for what this looks like: page `08 Redesign concepts` in the Figma file `Chorus` (key `3MGhWQwnJQbfN6Egnet42I`), frames `C · Rethink / …`. Research behind it: `docs/internal/UX-AUDIT.md`. What the measuring found: `docs/internal/FIGMA-BASELINE.md`.

## Why

The audit found two problems above everything on the baseline's list of seven. In `hybrid` and `sidebar` a service is drawn as an 18 point square with no label, so two Slack workspaces are two identical tiles and the name lives only in a tooltip (`ServiceTabView.content`, the `iconOnly` branch). A space in a vertical rail is an emoji with its name thrown away (`SpaceButton.verticalCell`). Severity 4 and severity 3. A service also has no state for loading, failed, or signed out, which matters in an app that is entirely web views whose sessions expire without saying so.

Three concepts answered that audit. C is the one picked, on 2026-08-16. A executed the token list and left the severity 4 finding standing. B answered it and spent 400 points of sidebar before content.

## What C is

One rail holds the current space's services. The space itself is a header on that rail: it names where you are, and clicking it opens a palette to switch. The second rail is gone and its width goes to content.

The consequence is the argument for it. With one rail, `hybrid` and `topBars` become the same design. The two frames on page `08` are identical on purpose. Three layouts existed because two rails can be arranged three ways. Remove a rail and the choice collapses to a real one: rail on the left, or bar along the top.

### Measured off the drawn frames

Vertical (`C · Rethink / sidebar`):

| Element | Value |
|---|---|
| Rail width | 240 (was 52 + 52 + 2 dividers) |
| Space header | 224 by 36, at y 38, radius 8 |
| Service row | 224 by 34, radius 8, pitch 36 |
| Service icon | 20 |
| Row contents | icon at x 8, label at x 36, badge trailing at x 200 |
| Add service | pinned to the bottom, 224 by 30 |

Horizontal (`C · Rethink / hybrid` and `/ topBars`, byte for byte the same):

| Element | Value |
|---|---|
| Rail height | 42, one divider under it |
| Space header | 150 by 32, at x 80, which clears the traffic lights |
| Divider after the header | 1 by 20 |
| Service tab | 32 tall, width hugging the label |

Both drop the second rail entirely. The vertical case reclaims 161 points of chrome; the horizontal case reclaims a whole 34 point bar.

### The three specimens every concept inherits

Drawn once on page `08` and used by all of C:

- **One notice shape, three severities.** Replaces two raw SwiftUI yellows and a solid red bar. A tinted strip with a rule under it; the tone carries the difference through the icon and the rule, not the fill.
- **Service health.** A 9 point dot on the icon's bottom-right corner. Live draws no dot. Loading is grey `8E8E93`, failed is orange `FF9F0A`, signed out is red `FF3B30`.
- **Selection against focus.** One fill for selection, a ring for keyboard focus, never the same mark. This answers the audit finding that `focusEffectDisabled()` removed the focus signal rather than reshaping it.
- **Radius.** Eight values down to three: 4 for icons, 8 for chips, tabs and rows, 14 for sheets and palettes.

## What has to change in the app

### `RailLayout` goes from three cases to two, with no schema version

`railLayoutRaw` on `AppPreferences` is a `String?` and stays one, so **this is not a SwiftData schema change** and needs no frozen copy, no migration stage, and no update to the pinned sets. That is worth stating plainly because the enum change looks like a model change and is not.

There is a trap in it. `AppPreferences.railLayout` reads `railLayoutRaw.flatMap(RailLayout.init(rawValue:)) ?? .sidebar`. Retire the `hybrid` case and every user who chose it silently lands on `sidebar`, the layout furthest from what they picked. The accessor has to map the retired value forward to the bar layout explicitly, and a test has to pin that (`ChorusTests.swift` already has the four `railLayout` round-trip assertions at lines 2022 to 2026; this adds a fifth).

Naming: the two survivors are the rail on the left and the bar on the top. `sidebar` keeps its raw value. The new horizontal case should take `topBars` as its raw value so the larger existing population keeps its choice byte for byte, and `hybrid` maps onto it.

**Correction, 2026-08-17: this step is not free before step 5, and the build order below is wrong to call it so.** The forward-map is only invisible once one rail draws both layouts. Today `hybrid` puts the spaces on a 52pt rail down the left and the services in a bar on top, while `topBars` stacks two horizontal strips and has no left rail at all. Both were screenshotted side by side on 2026-08-17. So a `hybrid` user who takes this step on its own does not keep their arrangement: they lose the left rail and gain a second strip. That is a different screen wearing the old choice's name. Land the enum change with step 5, or accept that hybrid users get moved twice. The trap in the accessor stands either way.

### One rail view replaces two

`SpaceStripView` (467 lines) and `ServiceSidebarView` (790 lines) both draw a rail in two axes. C needs one view that draws one rail in two axes, with the space as a header on it. Neither existing file is the right thing to bend into that shape, and per the file-organization rule in the global instructions a 1,257 line merge would be the wrong answer anyway.

Proposed shape, small files, one job each:

- `UnifiedRailView`: the rail, header, service list, add button, both axes.
- `SpaceHeaderView`: the space header and its click target.
- `SpacePaletteView`: the switcher.
- `ServiceRowView`: one service, labelled, in both axes. Absorbs what `ServiceTabView` and `ServiceIconView` do at their call sites.
- The reorder maths (`ServiceReorder`), the drag and drop plumbing, the arrow-key handlers and the VoiceOver move actions all move across unchanged. They are tested and they are the part the audit rated severity 0. **Do not rewrite them.**

`ContentView.mainLayout` loses its third branch. `supportButtonTopInset` loses a case and the other two need re-measuring against the new bar heights (36 and 42, against today's 32, 34 and 38). `ServiceSidebarView`'s trailing reserve for the donation button carries over as is. `SupportButtonVisibility.reservedWidth` and the `targetOverhang` subtractions are load-bearing and documented; leave the arithmetic alone.

`WebContentView` keys its nav-button row off `railLayout == .sidebar`. That still works with two cases, but check it reads correctly rather than assuming.

### Service health is the part that is not free

Three states, three different costs, and they are not equal. This is the one place the spec should not pretend.

- **Loading.** Already there. `WebViewState.isLoading` is observed per attach. It is per *active* web view, though, and the rail needs it per service, so the state has to be published per service id rather than read off the one attached view.
- **Failed.** Reachable. `WebViewCoordinator.webView(_:didFailProvisionalNavigation:withError:)` already catches exactly this and paints an error page into the view. Publishing a per-service failed flag from that same handler is a small change to code that already runs.
- **Signed out. Not solved, and not solvable generically.** Nothing in the app detects it today, and there is no general signal: every service signs you out to its own URL with its own markup. The catalog's per-service JavaScript hooks (`badgeJS`) are the only precedent, and `ServiceCSSDefaults` is the standing warning about how that scales. It ships CSS for exactly one service out of the whole catalog. That one stylesheet needed its selectors verified against the live page, and it breaks on the service's next deploy.

  Recommendation: **ship live, loading and failed; leave signed-out drawn but unimplemented**, and do not let it block the rest. If it is wanted later, the cheap approximation is a per-catalog-entry signed-out probe for the few services that matter, priced per service and accepted as breakable. It would not be a general mechanism, and should not be sold as one.

### The palette

The space switcher is new surface: a list of spaces with emoji, name, service count and aggregate badge. `QuickSwitcherView` (257 lines) is the closest existing thing and its list, filter and keyboard handling are worth reading before writing this.

Two things move into it and are lost from the always-visible rail, which is the price recorded with the pick:

- Drag-to-reorder for spaces. `SpaceStripView`'s drop handling and `ServiceReorder` still apply, so the capability survives inside the palette; what is lost is reordering without opening it.
- Always-visible aggregate badges for every space. The header shows the current space's count; the rest are one click away.

### The digits are palette-local, decided 2026-08-17

The palette frame labels its rows `⌘1` through `⌘4`. Today `⌘1`–`⌘9` switches **services** within the current space (`KeyboardShortcutManager.swift:16`), and the audit rates the accelerator set severity 0 and says explicitly it should be protected by whatever the redesign does.

Two readings, and the frame supports either:

1. **Palette-local.** `⌘1`–`⌘N` picks a space only while the palette is open; the global `⌘1`–`⌘9` keeps switching services. Nothing shipped breaks.
2. **Reassigned.** `⌘1`–`⌘N` becomes global space switching, and service switching moves to another modifier.

**Reading 1 is the call.** It costs nothing and the rest of this spec already assumes it, while reading 2 breaks a shipped accelerator to solve a problem nobody reported. So `SpacePaletteView` binds the digits itself while it is open, and `KeyboardShortcutManager` is not touched. Step 4 is unblocked.

## Risks

**The macOS 26 landmine: tested on 2026-08-16, and it does not apply to Chorus.** The audit flagged that since macOS 26 beta 1 an `NSGlassContainerView` inside `NSToolbarView` intercepts mouse events, so SwiftUI controls overlaid on the title-bar band stop receiving clicks. C's horizontal layout puts the space header and every service tab in that band, so this was the risk worth settling before anything else got built.

Three things answer it, and the last one is the one that counts.

1. Chorus creates no `NSToolbar` at all. It takes `.windowStyle(.hiddenTitleBar)` and draws its own content into the band. The reported fault needs an `NSToolbarView` to live in.
2. The preconditions that could have applied are present, so this is not a case of the risk being out of reach. The app builds against SDK 26.5 under Xcode 26.6, which opts it into the new look, and the dev machine runs macOS 26.5.
3. Measured in the running Debug build. In the `hybrid` layout, whose service tabs already sit in the band exactly where C puts its own, a click at the tab's coordinates selected that service and swapped the web content, and the window did not move.

So the horizontal geometry stands as drawn, and step 1 of the build order is done.

**What that test did not cover: dragging inside the band.** A synthetic drag through `cliclick` left the drag preview stuck in the strip and completed no reorder, which is a limit of driving `NSDraggingSession` with synthetic events rather than a finding about the app. The strip recovered on its own and the order was unchanged. Reordering by drag in the band is shipped behaviour that `WindowMovableConfigurator` exists to protect, so it works today; it needs a by-hand pass rather than a scripted one once the rail is rebuilt.

**Health by colour alone fails the app's own standard.** The drawn dot separates loading, failed and signed out by hue and nothing else, at 9 points. That is exactly the claim the Brutalist direction makes against the others, and it fails for a red-green colour-blind user. The dot needs a second channel, either a shape difference or a glyph, and the accessibility label has to carry the state in words. `ServiceAccessibility.label` already folds badge, hibernation, mute and media state into one spoken string, so this is an addition to a pattern that exists.

**Focus against selection has a history.** 1.5.10 fixed a doubled box by suppressing the system ring on the narrow strip, and the audit's finding is that the fix removed the signal instead of reshaping it. The rail is 240 points wide now rather than 52, so the box that did not fit has room. Do not simply re-enable `focusEffectDisabled()`'s opposite and assume it looks right. The specimen draws a specific ring.

**Scope.** This is a rebuild of both rail views, the layout switch, a new palette, and new per-service state. It is a major release rather than a patch. The pieces that are already tested (reorder maths, drag and drop, arrow keys, VoiceOver actions, the donation button geometry) should move across untouched, and that is what keeps the risk in the new surface rather than spread through the app.

## Out of scope

- The six visual directions on pages `09` to `11`. C is the structure; the skin is a separate, later decision, and rejecting all six and staying native is still live. The directions are all drawn on C's sidebar already, so nothing needs redrawing whichever way that goes.
- The first-run experience (audit item 6). Real, and independent of this.
- Signed-out detection, per the reasoning above.

## Build order

Each step leaves the app shippable, and the risky thing is first on purpose.

1. ~~**Prove the title-bar band on macOS 26.**~~ **Done on 2026-08-16**, and it needed no throwaway build: the shipped `hybrid` layout already puts tabs where C puts its header, and a click there works. See the risks section. The horizontal geometry stands as drawn.
2. `RailLayout` to two cases, with the `hybrid` forward-map and its test. Mechanical, and the code change is small, but **"no visual change" was wrong**: see the correction above. Hold it until step 5, or move hybrid users twice on purpose.
3. ~~`ServiceRowView`: a labelled row in both axes, replacing the `iconOnly` branch.~~ **Built on 2026-08-16**, on the branch `feat/service-row-view` (`6ad81f5`), unmerged and unpushed. It closes the severity 4 finding. 197 tests, 0 failures; nothing checked by eye, because the display was held by a fullscreen app and the Debug window would not come forward. Two notes carried into `OPEN-ITEMS.md`: in `sidebar` this step on its own puts 292 points of chrome before content until step 5 removes the second rail, and the horizontal tab is deliberately left without a width cap.
4. `SpaceHeaderView` and `SpacePaletteView`.
5. `UnifiedRailView`: assemble, move the tested plumbing across, delete what it replaces.
6. Health state for loading and failed, with the second visual channel and the spoken label.
7. The notice shape, the radius collapse, and the selection-against-focus specimen. Cheap, mechanical, and they were already the baseline's list.

## Verifying

`xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`, Debug only. Never add `-configuration Release`, for the reason in `CLAUDE.md`.

Tests cannot reach the two things most likely to break here: AppKit hit-testing in the title-bar band, and how any of this looks. Both need the by-hand pass, in the Debug build against `Chorus-debug` so no real data is touched. That is the discipline recorded in `.remember/remember.md` and paid for on 2026-07-22.

New tests worth writing: the `hybrid` forward-map, per-service health state transitions (loading to live, loading to failed), and the accessibility label with each health state folded in. The reorder and arrow-key tests already exist and should keep passing untouched. If they need editing, the plumbing was rewritten when it should have been moved.
