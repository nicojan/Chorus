# UX audit — Chorus 1.5.18

Internal working document. Written 2026-08-13 against build 27, from the Swift under `Chorus/Views/**` and the measured Figma baseline (`docs/internal/FIGMA-BASELINE.md`). Not public-facing, so it skips the humanizer loop that `CLAUDE.md` requires of shipped text.

Companion to the Figma file `Chorus` (key `3MGhWQwnJQbfN6Egnet42I`), page `08 Redesign concepts`.

## 1. Where the category is

Rambox, Ferdium, Franz, Shift and Station all ship the same shape settled around 2016: a left rail of service icons, one web view, a preferences window. The comparison writeups rank them on service count, memory use and price — never on interaction. Nobody in the category is competing on the interface.

What users complain about is notifications. Ferdium threads are dominated by badges, sounds and system banners failing to fire; Rambox reviews cluster on performance and the move to freemium. Layout barely appears. Two readings of that are possible: either the layout is solved, or nobody has shown people an alternative. Arc suggests the second.

Arc's sidebar is the feature its users name as the reason they stayed, and the mechanism is switching speed — Spaces flip in well under half a second where a Chrome profile switch costs two to three. That friction drop is what makes people actually keep work and personal apart instead of mixing them. The lesson transfers directly: the value is not that contexts exist, it is that moving between them is cheap and legible.

Chorus already has spaces. It does not dramatize them. Switching space re-tints a 40 by 40 emoji tile and swaps the service rail; nothing else in the window acknowledges that the user changed context.

## 2. What macOS 26 changed

Relevant because the deployment target will move eventually and because the dev machine already runs it.

- Sidebars went edge-to-edge instead of floating, and sidebar icons got their colour back — the system is moving toward *more* identity in the rail, not less.
- Toolbars unified across apps, and windows share one corner radius.
- Toolbar, Sidebar, menu bar and Dock pick up Liquid Glass automatically on a recompile with Xcode 26. Chorus would inherit some of this for free.

One landmine. Since macOS 26 beta 1 an `NSGlassContainerView` inside `NSToolbarView` intercepts mouse events, so SwiftUI controls overlaid on the title-bar band stop receiving clicks. Chorus puts its draggable tab strip in exactly that band (`ContentView.mainLayout` hides the title bar and reserves 28 by 72 for the traffic lights; `WindowMovableConfigurator` turns the OS drag off there). Any redesign that keeps chrome in the title-bar band needs this tested before it ships.

## 3. Heuristic evaluation

Nielsen's ten, severity 0 (not a problem) to 4 (usability catastrophe).

### Severity 4

**Recognition rather than recall — services are unidentifiable.** In `hybrid` and `sidebar`, service tabs render icon-only: `ServiceIconSquare` at 18pt with no label (`ServiceTabView.content`, the `iconOnly` branch). The user's own `instance.label` is drawn only in the horizontal branch. Two Slack workspaces, two Gmail accounts, or any two instances of one service are two identical squares distinguishable only by position. The name exists solely in a `.help()` tooltip, which costs a hover and a delay to read.

This is the product's core loop. Chorus exists to put many services in one window; in two of its three layouts it will not tell you which service you are looking at.

### Severity 3

**Match to the real world — spaces lose their name too.** `SpaceButton.verticalCell` draws `space.emoji` and nothing else. The user names a space in `SpaceEditorSheet` and that name then appears only in a tooltip and in the `topBars` layout. Emoji carry no reliable semantics: two spaces both marked with a briefcase are two identical tiles.

**Visibility of system status — no service health.** Hibernation has a state on the tab. Loading, failed-to-load, and signed-out do not. A service whose session expired looks exactly like one with nothing new. Given that the whole app is web views that silently lose auth, this is a real gap.

**Consistency — selection is drawn three ways in three blues.** Confirmed by measurement, not inference. A selected item gets a 3 by 20 bar, a tinted fill, and a stroke, all at once. `SpaceButton.verticalCell` strokes at `.tint.opacity(0.55)`, 1pt; `SpaceButton.horizontalTab` strokes at full `.tint`, 1.5pt; `ServiceTabView` fills at `.tint.opacity(0.10)` where the chip fills at `0.12`. Measured off the running app the fills are `E4F0FF`, `E8F3FF` and `D2E6FF` — three colours for one state. Eight corner radii are in play (1.5, 4, 6, 7, 8, 9, 10, 12), five of them between 6 and 10 where the difference is invisible.

**Aesthetic and minimalist design — inverted.** The problem is not clutter, it is flatness. One caption style does 36 of roughly 63 typographic jobs, and secondary grey is set 51 times against four uses of primary. Nearly everything is the same size in the same grey, so nothing can be emphasised. There is no hierarchy left to spend.

**Help and documentation — no first run.** Nothing under `Views/` handles a first launch. A new user gets seeded spaces and services and has to infer the space-to-service model from the result. The two-rail arrangement is not self-explaining.

**Error recovery — three warnings, three designs.** `ContentView` draws the store banner and the recovery banner on `Color.yellow.opacity(0.15)`, a raw SwiftUI yellow never tuned for either appearance, and the offline banner on solid `ServiceIconPalette.badgeRed` with white text. The visual weight is inverted against the actual severity: offline is transient and harmless and shouts; a damaged store is serious and whispers.

**Accessibility and HIG.** 40pt tap targets against Apple's 44 floor. Six icon sizes. Both rails call `focusEffectDisabled()` and substitute the app's own indicator — but that indicator is also the selection indicator, so a keyboard user cannot see where focus is when it differs from selection. The suppression was a deliberate fix for a doubled box on the narrow strip (see 1.5.10); the fix removed the signal instead of reshaping it.

### Severity 2

**Error prevention — uneven weight on destructive acts.** Deleting a space confirms, with a message clarifying that member services survive. Deleting a service and clearing website data both destroy a logged-in session and do not warn with equal force.

### Severity 0

**Flexibility and accelerators — strong.** 28 keyboard shortcuts, a quick switcher, drag reorder in both rails, arrow-key navigation with ⌥ to reorder, and VoiceOver move actions on every cell. This is better than anything else in the category and should be protected by whatever the redesign does.

## 3a. The ceiling on any visual direction

A redesign can style the rail, the bars and the sheets. It cannot style the web view, which is whatever Slack, Gmail or Figma renders.

Chorus is not powerless here. `ServiceInstance.customCSS` is injected as a `WKUserScript` by `UserScriptManager`, and Dark Reader is available per service. But the ceiling is low, and the code shows how low: `ServiceCSSDefaults.css(forCatalogID:)` returns non-nil for exactly one service in the whole catalog, LinkedIn. That single stylesheet needed selectors verified against the live page, a `:has()` trick to scope it to the messaging route, and a comment explaining why `100vh` cannot be used in a Chorus web view at all. That is the cost of hiding a nav bar and filling the window. Restyling a service to match a theme is far past it, and it breaks on the service's next deploy.

The consequence is a real constraint on the exploration rather than a matter of taste. The louder the chrome, the harder the seam where it meets content that will not follow, and the seam lands in the middle of the window. It argues for quiet chrome that frames the content over loud chrome that competes with it.

## 3b. What measuring the visual directions found

The six directions on page `09` were measured for contrast rather than judged by eye, and the eye had been wrong.

One systemic fault: `text-dim` sat under 4.5 to 1 in five of six directions. Soft failed four ways at once — body text 3.75, tertiary 2.16, accent 2.29, and a badge at 2.62 that could not be read. Pastel on warm cream has nowhere to go. Two terminal themes needed repair rather than adjustment: Solarized Dark measured dim text at 2.42, error at 2.81, and rules at 1.12, which is invisible. It now uses Solarized's own `base2` and brighter accent variants, so it stays Solarized and becomes legible. Nord had the same fault more mildly.

Every text role now clears 4.5 to 1, except decorative tertiary in Soft at 3.84 and the hairline rules, which are meant to be faint. Brutalist measured best throughout, 10.04 for body text.

Two faults came from inspection rather than measurement. Glass sets dark text over a light-tinted blur, so over a dark web page the rail darkens with it and the text disappears — a fixed tint cannot work, it needs a real `NSVisualEffectView` with `.sidebar` material so the system adapts it. And Discord's 44pt rows earn their height in Discord, which has thirty channels; at six services the rail is simply tall.

**The inset content card** was applied to Glass, Soft and Editorial. It is not only polish: an inset, rounded, shadowed web view reads as a card the chrome frames, which is the answer to the seam in section 3a — the two interfaces stop butting against each other. Glass needed care, since an inset card starves the translucency of anything to refract; its card's left edge tucks 24 points beneath the rail so the blur still has content under it. It was not applied to Discord, which reads as Discord partly by being edge to edge, nor to Brutalist or Terminal, where rounding contradicts the premise.

The build cost is small but real: the host `NSView` needs `wantsLayer`, `layer.cornerRadius` and `masksToBounds`, a fixed-position element in a page corner gets clipped, and the inset costs content width.

## 4. What this means for the redesign

The baseline's seven findings are all real, and all of them are token and geometry work: radii, selection colour, target sizes, banner shape. Cheap, mechanical, worth doing.

But they are not the biggest problem. The two severity-3-and-up findings — services and spaces identified by a picture alone — sit above them, and no amount of radius collapsing touches either. A redesign that only executes the baseline list makes a tidier version of an interface that still will not tell you which Slack you are in.

Ranked by payoff over cost:

1. Give services and spaces a readable identity in every layout.
2. Give a service a health state, so a dead session is visible.
3. Collapse the token drift (radii, selection, targets, icon sizes, banners).
4. Rebuild hierarchy: decide what the caption style is for and stop spending secondary grey on everything.
5. Separate focus from selection without reintroducing the doubled box.
6. Add a first run.

## 5. Sources

- <https://pickuma.com/for-dev/arc-browser-review/>
- <https://blakecrosley.com/guides/design/arc>
- <https://onepanel.it/alternatives>
- <https://alternativeto.net/software/ferdium/about/>
- <https://www.macrumors.com/2026/06/09/macos-golden-gate-liquid-glass/>
- <https://dev.to/diskcleankit/liquid-glass-in-swift-official-best-practices-for-ios-26-macos-tahoe-1coo>
