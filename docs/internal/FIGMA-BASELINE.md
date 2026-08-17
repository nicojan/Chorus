# The Figma baseline

A rebuild of the shipped Chorus interface in Figma, made so the design can be worked on outside Xcode. Built 2026-08-13 against 1.5.18 (build 27).

**File:** `Chorus`, key `3MGhWQwnJQbfN6Egnet42I`. Reach it with the `figma-console` MCP, which talks to the Figma desktop app over a local WebSocket bridge.

This document is the reference for anyone picking the redesign up. The case-study narrative lives on page `00` of the Figma file itself.

## What is in the file

| Page | Holds | Locked |
|---|---|---|
| `00 Case study` | The write-up: why, how, what measuring found, what to change first | no |
| `01 Foundations` | 33 colour variables with Light and Dark modes, 37 primitives, type ramp, radius and spacing scales | yes |
| `02 Components` | Space chips in both readings, service tab, service row, badge | yes |
| `03 Main window` | Three layouts, two appearances each | yes |
| `04 Notice states` | Store, recovery and offline banners, find bar, lock screen | yes |
| `05 Sheets` | Add Service, Edit Service, Space Editor, Quick Switcher | yes |
| `06 Settings` | All four tabs at full scroll height | yes |
| `07 Explorations` | Unlocked copies of the three layouts | no |
| `08 Redesign concepts` | Three concepts (A Tidy, B Recompose, C Rethink), each in three layouts and both appearances, plus shared specimens | no |
| `09 Visual directions` | One screen (C sidebar) restyled six ways: Discord, Glass, Editorial, Brutalist, Soft, Terminal | no |
| `10 Directions × layouts` | The same six directions in `hybrid` and `topBars`, twelve frames | no |
| `11 Sheets and notices` | All six directions: four sheets and five notice states each, thirty frames | no |

Pages `01` through `06` are locked on purpose. They record what ships today. Unlock one only to correct an inaccuracy, never to try an idea. Ideas go on `07`.

## How it was built, and how far to trust it

Two sources. The Swift under `Chorus/Views/**` gave structure. Screenshots of the installed release build gave what code cannot show. Where they disagreed the screenshots won.

Every screenshot was masked before it reached the file. The web view regions held real Slack, Gmail and Instagram content, so they were painted out and only the app chrome kept. The masking script is throwaway and no longer on disk; if you take fresh screenshots, mask them before uploading.

**Trust the geometry.** Every value below was measured off the captures pixel by pixel and cross-checked against the source. An audit pass after the first build found four errors and fixed them: the traffic lights sat 2 points high, the tabs were centred in their rail rather than top aligned, the sidebar service rail started a point early, and three sheets were built at the wrong width.

**Do not trust these.** Service icons are flat tinted squares, since the app ships brand artwork in `Assets.xcassets`. The store banner, recovery banner and lock screen were built from source rather than traced, because producing them needs a damaged database. The offline banner is the same, since catching it needs the network to drop. The `topBars` third space chip was inferred from a partial shot. No automated pixel diff was ever run, so small errors will have survived.

## Measured geometry

Anyone rebuilding or verifying should start from this table rather than re-measuring.

| Value | Points | Where |
|---|---|---|
| Rail width, vertical | 52 | both rails |
| Spaces rail height, horizontal | 34 | `topBars` only |
| Service rail height, horizontal | 38 | `ServiceTabView.height` 30 plus 8 |
| Space chip | 40 by 40, radius 10 | pitch 46, so 6 between |
| Service tab | 34 by 30, radius 7 | icon 18, side padding 8, pitch 39 |
| Service row, sidebar | 52 by 40 | icon 24, pitch 46 |
| Badge | 16 circle | `DC2626`, 9pt semibold white |
| Selection bar | 3 by 20 | centred on the left edge |
| Traffic lights | 14 across, pitch 23 | first at x 9, y 9 |
| Tab position in its rail | y 6 | 6 above, 2 below, not centred |

Content origin per layout, measured from the window corner:

- `hybrid` x 53, y 38
- `topBars` x 0, y 73
- `sidebar` x 106, y 28, with the nav row above it and a divider at y 27

Sheet sizes come from the source, not from screenshots: `AddServiceSheet` 520 by 480, `EditServiceSheet` 420 wide and hugging, `SpaceEditorSheet` 420 by 520, `QuickSwitcherView` 420 wide between 280 and 480 tall. The Settings window is fixed at 520 by 548 and will not resize, so every tab scrolls.

## What the measuring found

Nine colours belong to Chorus. Everything else is a macOS system colour, so both appearances need little extra work. The geometry is where the drift sits.

1. **Eight corner radii**: 1.5, 4, 6, 7, 8, 9, 10, 12. Five sit between 6 and 10, where the eye cannot separate them.
2. **Three selection fills for one state**: `E4F0FF` on a space chip, `E8F3FF` on a service tab, `D2E6FF` on a sidebar row.
3. **Selection drawn three ways at once**: a 3 point bar, a tinted fill, and a 1 point stroke. Chips take a lighter stroke (`70B1FF`) than tabs (`007AFF`).
4. **One text size carries most of the interface**: the caption style does 36 of about 63 jobs, and secondary grey is set 51 times against four uses of primary.
5. **Two banners use raw SwiftUI yellow**, which was never tuned for either appearance. The offline banner goes solid red with white text instead, so the three warnings read as three designs.
6. **The tab rail pads unevenly**: 6 above the tab, 2 below.
7. **Two tap-target sizes** (40 and 44) and six icon sizes. Apple asks for 44 as a floor.

## Starting the redesign

Three concepts now exist on page `08`, answering `docs/internal/UX-AUDIT.md`. That audit found two problems this document's own findings list missed, both above everything in it: in `hybrid` and `sidebar` a service is drawn as an unlabelled 18pt square, so two Slack workspaces are indistinguishable, and a space in the vertical rails is an emoji with its name thrown away. A service also has no state for loading, failed, or signed out.

**`C · Rethink` is the one picked, on 2026-08-16.** A and B stay on the page as the record of what was weighed. The concepts run conservative to radical. `A · Tidy` executes the list below and nothing else. `B · Recompose` adds the labels and a health dot. `C · Rethink` drops to one rail and makes the space a header on it, which reclaims 161 points of chrome and collapses `hybrid` and `topBars` into the same design — the identical pair on that page is the argument, not a mistake. Seventeen new variables prefixed `rd/` carry the proposed values; the baseline tokens are untouched.

Page `09` then asks a separate question: how far can the look move before the structure has to. It takes the C sidebar and restyles it six ways — Discord, Glass, Editorial, Brutalist, Soft, Terminal — off a `Chorus / Directions` collection whose modes *are* the directions, so swapping the mode on a frame changes its character without touching a layer. Each carries a note on what it costs to build.

Terminal has its own collection, `Chorus / Terminal`, because it needed roles the others do not have: a reverse-video pair, a cursor, a hot border. Fourteen roles across five real terminal palettes — ANSI electric, Matrix, Solarized Dark, Dracula, Nord — with a swatch legend beside the frame. Its rows are single monospace strings coloured with `setRangeFills` per character range rather than stacks of boxes, which is what keeps the columns aligned; the equivalent in SwiftUI is an `AttributedString`.

Two things that page settled. `figma.variables.setBoundVariableForPaint` throws away any opacity set on the paint before binding. And `layoutPositioning = 'ABSOLUTE'` throws when the parent has no auto layout, which the plain-frame directions do not.

**Correction, from building page `11`.** The fix recorded here for that first item, writing `fills` again afterwards with the opacity, does not reliably hold. Assigning a bound paint re-binds it and drops the opacity a second time, and it fails silently: the surface renders at full strength with no error. Page 11's banners came out as solid red and orange bars before this was caught. Bind the colour on a child layer and set the opacity on the **layer** instead of on the paint. Every tinted surface on page 11 is built that way.

Page `10` takes all six directions through the other two layouts, so a direction can be judged on more than the screen it was drawn for. In `hybrid` the spaces sit in a narrow rail on the left and the services run along the top; in `topBars` each takes a row of its own. Both hand the service bar the full width of the window, and that is what sorts the six.

A vertical rail hides a width problem that a top bar exposes. Six named services do not fit 1080 points at every scale. Glass and Editorial fit all six, on small type and a 22 point icon or none. Discord and Soft fit five and push the sixth to an overflow chip, because each row carries a 30 point avatar and a badge. Brutalist fits four: it refuses to encode state in colour alone, so a cell has to hold the word LIVE or SIGNED OUT, and clipping one would break its own claim. Terminal fits three, since its rows are padded to fixed column widths, which is what keeps the sidebar's columns aligned and what wastes the most room in a bar. Read that as a ranking of how well a direction scales; a window wider than 1080 moves every count up.

Two elements moved rather than shrank. Brutalist's status line and Terminal's prompt were the last row of a sidebar; with the rail lying down they become a footer along the bottom of the content. Glass keeps its inset card, which now tucks under the bar as well as the rail, so the blur still has something to refract. The frames on `10` were built by cloning each `09` frame and rebuilding its rail, which is what keeps every variable binding intact; a direction rebuilt by hand would have lost them.

Page `11` carries all six directions through four sheets and five notice states each, thirty surfaces. Sizes come from the source, so `AddServiceSheet` is 520 by 480 and the other three are 420 wide. Every sheet sits on a backdrop rather than on blank canvas, since Glass cannot be judged without something under it to refract.

The notices answer the baseline's fifth finding. Three warnings ship today as three unrelated designs: two raw SwiftUI yellows and a solid red bar with white text. All six directions give the three one shape, a tinted strip with a rule under it, and let the tone carry the difference through the icon and the rule rather than through the fill. Editorial's buttons are squared and bordered, Glass's are pills, Brutalist's and Terminal's are square boxes.

Two directions refuse a control the others accept: Brutalist and Terminal write a toggle as `[ on ]` and `[ off ]` rather than drawing a switch, which is the claim both make about words over colour. Terminal draws from its own collection, `Chorus / Terminal`, whose fourteen roles are mapped onto the same slots the other five fill from `Chorus / Directions` — `term/reverse-bg` stands in for `dir/selection`, `term/text-dim` for both secondary and tertiary text, and so on. Case is applied once in the builder rather than string by string.

Glass sits at 88 per cent opacity on its sheets. It started at 62, and at 62 the sheet inherited whatever was under it and its own text disappeared, which is the fault already recorded against Glass on page `09`. A real `NSVisualEffectView` is closer to the higher number, so the sheets are evidence for that fix rather than against it.

The five changes worth trying first, cheapest first:

1. Cut the radius scale from eight values to three. Nothing depends on the values staying distinct, so this is close to free.
2. Give selection one colour and one signal. Pick the bar or the fill, and use one blue.
3. Decide what the caption style is for.
4. Raise 40 point targets to 44, and cut six icon sizes to three.
5. Move the two yellows into variables, then give all three banners one shape.

Items 1, 4 and 6 in the findings list are mechanical. Items 2, 3 and 5 are decisions somebody has to make.

Change values in the variables, not in the layers. A layer holding its own hex will not follow a mode switch, and it will not follow a redesign either.

## Carrying a change back into the app

Layers are named after the Swift type that draws them, with state in brackets: `ServiceTabView [selected]`, `SpaceStripView / rail [vertical]`, `ServiceIconSquare / 18`, `selection bar / 3x20`. A layer name is the file to open.

The colour variables map to two places. The nine Chorus colours live in `ServiceIconPalette` (`Chorus/Views/MainWindow/ServiceIconView.swift`, lines 11 to 23). Everything else resolves to a macOS system colour, so changing it means picking a different `NSColor`, not writing a hex.

One variable has no counterpart in the app. `surface/form-group` is the grey behind Settings rows, which macOS draws itself, so no Swift constant exists for it.

## Conventions to keep

- Colour and size live in variables. Layers hold no fixed values.
- Both appearances come from modes on one set of frames, never duplicated frames.
- Rails are real auto layout, so inspect reports the true spacing rather than someone's arithmetic. Badges and selection bars are absolutely positioned inside their auto-layout parent, because they overhang.
- Every string on a page goes through the humanizer loop and Orwell's six rules, the same as any other public-facing Chorus text. The assembled case study was checked as one document, not section by section.
