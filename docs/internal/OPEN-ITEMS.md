# Open items

## Shipped in 1.5.27: tabs for pages a service opens for itself

A user reported on 2026-10-04 that opening a design in Canva opened a separate window. A Debug probe of `createWebViewWith` showed why. Canva opens a design with an unsized `window.open` to `canva.com/design/editor/shell?designId=…`, and its Google sign-in with a `window.open` to `canva.com/oauth/authorize/GOOGLE` asking for 580 by 700. A script-opened window to the same service always fell through to a popup window, because returning nil from `window.open` reads as "popup blocked" to a sign-in flow.

`WebViewCoordinator.opensAsTab` now turns an unsized, same-service `window.open` from the service page (not from a popup) into a tab, unless the URL looks like a sign-in. The check runs `looksLikeSignIn`, then a looser `pathMentionsSignIn` substring test that catches Figma's `/start_google_sso`. The coordinator still returns a real web view, so `window.opener` keeps working, and shows it in `ServiceTabStrip` above the page. The model is `ServiceTabs` and `ServiceTab` (`Views/WebView/ServiceTabs.swift`), in memory only, with no schema change.

How tabs behave:

- They report no health or badge. They share the service's camera, mic and sound state, Mute All and Pause Audio, through `WebViewPool.allWebViews(for:)` and the tab watchers.
- They get the quit save handoff, plus half a second to save when closed by hand. They reload with crash backoff.
- They close on `window.close()` (which also schedules the deferred reload of the service page), and once a download starts in a tab that opened only to fetch a file.
- They keep the service out of the idle and memory hibernation sweeps, and close on a manual hibernation or rebuild.
- A popup a tab opens never reloads anything when it closes (`ServicePopup.reloadsOpener`).

The menu and buttons:

- ⌘W replaces File > Close (`CommandGroup(replacing: .saveItem)`). It closes the tab only when the key window holds that tab, and otherwise closes the front window.
- ⌘⇧[ and ⌘⇧] cycle through the page and its tabs. Home goes back to the service page. Reload and Find act on the tab on screen; zoom applies to all of the service's pages.
- Identical notifications within 3 s now post once (`NotificationMessageHandler.isDuplicate`), because a chat open in a tab fires each one twice.

A qa-reviewer pass found one High and six Medium issues, all fixed before merge. CI passed on 14 and 15. Checked live in Debug with Canva:

- a design opens as a tab and Chorus keeps one window;
- switching tabs by click and by ⌘⇧], and leaving the service and coming back, keep the tab;
- ⌘W and the × close the tab and leave the window;
- Home returns to the page;
- Canva's Google sign-in still opens as its own window, closes itself and signs in.

Released 2026-10-05 as 1.5.27: build 40, tag `4ab767f`, DMG 10,520,614 bytes, sha256 `05de6b7f…0bcf`. Appcast `84c6cad`, cask `ea2e820` here and `51d3dcc` in the tap. It has a What's New entry, "Pages open as tabs".

### Still open

- The stock "Close All" (⌥⌘W) is gone, because `.saveItem` was replaced.
- A Dark Reader toggle reaches an open tab only on its next load (`applyDarkState` and `refreshDarkMode` touch the page only).
- A tab whose first load fails shows a blank page, with no error page or Try Again. Reload in a tab with no URL falls back to the service home URL.
- The ⌘W item reads "Close Tab" even while Settings or a popup is in front. It still closes the right window.
- A window opened at `about:blank` and pointed somewhere later stays a window. Canva doesn't do this; others may.
- Not tried: Figma, Notion, Miro and Drive opening files; the tab strip on macOS 14 and 15 (CI compiles and tests only); ⌘⇧[ and ⌘⇧] on a non-US keyboard.
- Tabs add no automated test for the branch order in `createWebViewWith`, for `closeTabOrWindow`, or for the tab and popup opener interplay.

## Open: three contributor PRs sent back for changes (#35, #36, #37)

Reviewed on 2026-10-05. Each has a "request changes" review on GitHub listing what to fix. Re-review against that list when the author pushes, and approve the CI run on #35 and #37, which have not run it yet.

- **#37, Gmail actions survive hide and switch (jpagh).** Merges cleanly onto 1.5.27. The fix runs on every switch, reload and quit for every service. On the branch the tab strip covers the top 32pt of the page, Reload waits about 2s, and quit takes about 3s longer. Element fullscreen may also break, which nobody has checked. Asked to hold the old page only when the pointer is over it, and to put the Safari 27 user agent in its own commit, since it goes to every service.
- **#35, mailto links through Chorus (jpagh).** Based eight releases back; conflicts only in `project.pbxproj`. Blocking: mail links clicked inside a service no longer reach the system mail app, a page can claim mail links with no prompt, and a hidden Chrome-UA probe loads every service. The schema stage checks out field by field. Suggested opening compose as a service tab rather than a separate window.
- **#36, rebuild a page that keeps growing.** Conflicts only in `CHANGELOG.md`. The ten-minute guard reads `lastAccessTimes`, which only records activation. A rebuild also closes open tabs, skips the `quitReleaseJS` save, and reloads the home URL. Asked for a log-only release first, which would also test the plateau finding under the memory item below. The author's point stands: read `webcontent_mb` one process at a time, because the sum hides a single page that climbs.

## Open: sign-in groups (services sharing cookies), explored, not built

Asked on 2026-10-05 and parked for its own session. No code exists yet. The exploration found:

- **No schema change is needed.** A service points at its store through `ServiceInstance.dataStoreIdentifier`, and `DataStoreManager` keeps one `WKWebsiteDataStore` per identifier. Two services with the same identifier share cookies and storage, and keep their own user agent, scripts and zoom.
- **Deleting one member is already safe.** `cleanUpOrphanedDataStores` drops a tombstone that a live service still claims.
- **`clearSession` is the one unsafe path.** It wipes the shared store but reloads only one service, so it needs a warning that names the other members, and it should reload them all.
- **Export and import skip the identifier** (`SetupArchive`), so imported services come in unshared.
- **Recommended model: groups chosen per service, not per space.** A service can sit in several spaces, and two accounts of one service, such as work and personal Gmail, is a core use. Google also keeps all signed-in accounts in one jar, so two Gmail services sharing a store would both open the default account.
- **The proposed UI:**
  - "Share sign-in with…" in Edit Service. Joining adopts the other service's session and tombstones this one's old store; leaving gives it a fresh identifier.
  - "Use your sign-in from Gmail" in Add Service, for a matching site.
  - Optionally, a per-space shortcut that only fills a group.
- **Before shipping,** check two live web views on one store on macOS 14, 15 and 26.

## Shipped in 1.5.26: Mac apps in the rail, feature tips, What's New, and the ⌘K fixes

Asked for on 2026-10-02 so LINE, which has no web version, can live in the rail. macOS has no way to put another process's window inside ours, so a Mac-app service is a launcher that docks the app's own window over the card. The app is stored as `url = chorus-app://<bundle id>` (`NativeApp` in `Services/NativeAppSupport.swift`), which needs no schema version. Pieces: `NativeAppDocker` moves and sizes the window through the Accessibility API, following `ScreenFrameReporter` in `WebContentView`; it hides the app on switch-away, minimize, close and ⌘H, and brings it back when Chorus returns unless the click landed on Chorus's own controls. `NativeAppBadgeReader` reads the Dock's `AXStatusLabel` every 3 s. The pool, the transient badge sweep and the favicon fetcher all skip these services. The Edit sheet shows only name, mute and badge for one.

The user tried docking with LINE in a Debug build on 2026-10-02 and it worked well, the second pass too. A code review the same evening found and fixed: the outgoing web service stayed "active" in the pool while a Mac app was selected (no badge poll, media kept playing, ⌘R and camera went to it); one Mac app to another left the first window behind; the Accessibility prompt fired at every launch (now only when a Mac app is added); export dropped Mac apps; Chorus could be added as its own Mac app; badge writes every 3 s redrew the rail. The user checked the switch-away and ⌘-Tab/⌘Q fixes live the same evening; CI green on `70b0dc7`.

Released 2026-10-03 as 1.5.26 (build 39, tag `680e83c`, DMG 9,653,131 bytes, sha256 `cbb21013…3bc5`). The same release adds TipKit tips (`Views/Tips/FeatureTips.swift`) and a What's New sheet keyed by version in `WhatsNew.releases`; add an entry there for any later release that should show one. Not yet seen on a real install: the sheet after an actual update from 1.5.25, tips on macOS 14 and 15, and Accessibility trust on the signed release build.

### Still open

- ⌘-Tab to Chorus with a Mac app selected now shows the panel and leaves the app behind, so ⌘Q quits Chorus. A click on the panel, or a click on the card from another app, brings the app back.
- Closing the Chorus window hides the app, and it stays hidden until it is clicked again, quitting Chorus included.
- The app trails a frame or two behind a window drag. It can't join Chorus in full screen, and an app with a minimum size larger than the card hangs over the edge.
- Setup export and import carry Mac apps (fixed after review; before, export dropped them). Not tried on a Mac without the app, where it shows grey.
- Debug builds can lose Accessibility trust on rebuild; toggle the entry in System Settings.
- In Debug, `debugMockBadges` puts made-up counts on Mac apps too. The first "wrong count" report was this.

## Open: Instagram drawn in a thin strip at the top of the page

The user saw this on 1.5.25 on 2026-10-01, in Instagram's messages. The whole app (the left icons, the chat list and the message box) sat in a strip about 155 px tall at the top of the page area, and the rest of the page was empty. The page scrollbar ran the full height, and the user could scroll up without end. The user could not make it happen again, and nobody checked whether resizing the window or reloading would have fixed it. Release builds are not inspectable, so nothing was measured.

The suspect is `077a9d4`, the Gmail fix in 1.5.25. It made two changes, and either could hand a page the wrong height. First, the pool now makes web views at `WebViewHostView.lastSize`, which every layout of the page area writes to, including the passing sizes of a resize or an animation. Second, `nudgeLayout(of:)` now sends a synthetic `resize` when a load finishes, so a page may measure again while its frame is still moving. Instagram's own code could also be at fault.

If it comes back: first ask whether a window resize or a reload clears it. If a resize clears it, the page kept a stale size, so look at those two changes. If neither does, sign in to Instagram in a Debug build and inspect it in Safari's Web Inspector: compare `innerHeight` with the web view's bounds, and find which element sets the page's height.

## Shipped in 1.5.26: the quick switcher's first row, and its jumping field

Found while recording demo clips on 2026-09-30: type a filter into ⌘K and the first row kept the service it showed before. The cause was `.id(index)` in `QuickSwitcherView.resultsList`; rows now take `.id(result.id)`, and "gm" was checked live to show Gmail first. On 2026-10-02 the user also reported the field moving as results changed: the switcher was a sheet, which macOS keeps centred. It is now an overlay in `ContentView.quickSwitcherLayer`, with the field about a fifth of the way down and only the list changing height. Focus is set again 50 ms after appearing, because the first request is dropped while the overlay joins the window.

## Shipped in 1.5.25: Gmail's top bar at launch, and a fade on the rail

**Shipped on 2026-10-01 as `v1.5.25`, build 38, tag on `19868be`. The DMG is 9,504,327 bytes, and both feeds and the cask serve it.**

The user saw Gmail open at launch with its top bar above the visible area, until they moved the window. `WebContentView` sends a synthetic `resize` 250 ms after a service is selected, so that Gmail measures again. A Debug probe showed that at launch this event reaches a blank page, before the service has started loading, so Gmail never got it. The same probe found the page's `innerWidth` and `innerHeight` matching the web view's bounds, so WebKit had the size right. Two changes: `nudgeLayout(of:)` runs again when a load finishes, and the pool makes web views at `WebViewHostView.lastSize` instead of 0 by 0.

The rail cut its last row in half where the list ran under Add service. `FadingVerticalScrollView` in `RailSupport.swift` fades the top or bottom edge while more of the list lies past it. Both the all-services rail and the single-list rail use it. Checked in a Debug build at the window's smallest height, scrolled to each end.

### Still open

- Nobody has seen the Gmail fix work. The Debug store's Gmail is signed out, and the bug did not show on every launch. If Gmail opens without its top bar on 1.5.25, the cause is somewhere else.
- No one checked 1.5.25 by hand on real data before it went out.

## Merged: a Debug-only remote for demo recordings (`b4f8c1e`)

A Debug build now listens for two commands from a script: `bumpBadge <label>` raises a made-up count, and `setRailLayout <layout>` switches the layout. A `debugMockTickerOff` default stops the random six-second ticker. Release builds compile none of it. The recording scripts and the clips live outside this repo, in `~/dev/chorus-demo`.

## Shipped in 1.5.24: Figma's Google sign-in and the catalog logos

**Shipped on 2026-09-30 as `v1.5.24`, build 37, tag on `ab4274a`. The DMG is 10,251,402 bytes, and both feeds and the cask serve it.**

Figma's sign-in page opens `/start_google_sso` in a popup, then checks every 250 ms for a cookie, `__Host-google_sso_temp`, that the popup writes before it closes. Once it finds the cookie, it posts the token and goes to the files page. Chorus reloaded the opener the moment the popup closed, which killed that script, so the page stayed on the form. The reload now waits three seconds (`openerReloadDelay`) and is dropped if the page has moved or is loading (`shouldRunDeferredOpenerReload`). The user signed in to Figma with Google in a Debug build and landed on the file browser.

The Add Service grid drew only the fetched favicon, and Figma's file browser serves a teal loading glyph. The grid now draws `brand-<id>` first, as the rail does.

Debug builds now let Safari's Develop menu attach to service pages and popups (`isInspectable`, `b3287dc`). That is how the Figma sign-in was confirmed.

### Still open

- Nobody has watched a popup sign-in on a service that already worked, such as Gmail or Slack, since the reload became deferred. If one starts staying on its sign-in page after a popup, look here first.
- A page whose own sign-in takes longer than three seconds after the popup closes still gets reloaded in the middle of it.

## Shipped in 1.5.23: live reorder, a resizable rail, Notes-style counts

**Shipped on 2026-09-30 as `v1.5.23`, build 36, tag on `c43abe2`. The DMG is 9,534,338 bytes, and both feeds and the cask serve it.**

The user asked for each piece by hand in this session and tried each one in the Debug build. Spaces and services reorder live as a drag crosses them (`LiveReorder`); moving a service into another space waits for the drop, so a cancelled drag leaves it where it was. The service rail can be dragged from 150 to 300 points wide and gives up its names below 100, taking them back above 125 (`RailWidth`, UserDefaults `railNamedWidth`). With names, a count is a grey number, as in Notes; without them, a red badge on the corner. A count that goes up flashes, and pulses red until its service is opened, once the first minute after launch has passed (`BadgeManager.attentionIDs`). The all-services rail has a card per space; the other left rails sit on the window. Buttons have hover and press marks (`ChromeButtonStyle`), the focus ring waits for the keyboard (`FocusVisibility`), and the web card's corners follow the scroll bar.

Two reviews read the branch before release and every finding was fixed. CI's Xcode 16.2 then rejected four things the local Xcode 26 accepts; see `CLAUDE.md`.

### Still open

- Nobody has checked on macOS 14 or 15 how the resize, the pulse or the per-space cards look, since CI builds and tests there but no one looks.
- The space strip still has only two widths, and the bar's tabs keep red badges. Both were offered to the user and left as they are.
- Debug builds can show made-up counts: `defaults write com.nicojan.Chorus.debug debugMockBadges -bool true`. One goes up every six seconds, and the pulses start after the settling minute.

## Shipped in 1.5.22 as well: Trello sign-in, more sign-in pages, the whole of LinkedIn, Pause Audio

These went into 1.5.22 after the redesign merge. Trello signs in inside Chorus: `routesClickedLinkOut` and `isSignInRoundTrip` keep a clicked sign-in link that returns to the service. About thirty more sign-in pages are known, including Zoho's regional ones and company providers such as Okta (`authTenantDomains`). The catalog has the whole of LinkedIn (`linkedin-feed`) beside LinkedIn Messaging. Pause Audio holds on a service in the background. The user signed in to Trello with Google in the Debug build.

## Shipped in 1.5.22: the window redesign (`feat/paguro-look`), all 7 steps built

**Shipped on 2026-09-29 as `v1.5.22`, build 35, tagged on `d85610f`, and both feeds serve it while the cask is bumped here and in the tap. The DMG is 9,394,169 bytes.**


**Merged into `main` on 2026-09-29 as `fd59831`, with the findings branch merged just before it.** Full screen on macOS 26 is now checked: the View menu took the window in and out, and the lights came back to the centre of the band. The lights on macOS 14 and 15 still want a look before 1.5.22 ships.

**Started 2026-09-29.** Branch `feat/paguro-look`, cut from `fix/paguro-findings` (not from `main`, because that branch is not merged yet; rebase onto `main` once it is). Commit `dc77885`, pushed, CI green on macOS 14 and 15 (run 36653665480), 278 tests pass locally. `CHANGELOG.md` has a "Changed" line under Unreleased.

Takes Paguro's look, not its code. Decisions made from a trends survey on 2026-09-29: selection is a neutral ink fill with a primary label and the accent kept for the focus ring; glass is Off by default, Off below macOS 26 and under Reduce Transparency, and both glass styles keep a heavy canvas tint (0.62 Clear, 0.78 Regular); the web view is an inset card in every layout, with no gutter on the edge a top bar sits on; spaces keep the header and palette (the Arc/Slack model), and the all-services separators are to become 12pt headings.

Built: `ChorusColor` / `ChorusType` / `ChorusMotion` / `ChorusCard` in `ChorusStyle.swift`, `WindowBackdrop.swift` (frost + `NSGlassEffectView` + tint, `UserDefaults` key `windowGlassStyle`), and the inset web card (`contentCard()`, `WebViewHostView` layer clip).

### Still open

- **Step 4, the rail card, is built** (2026-09-29). The two left rails and the hybrid strip of spaces now sit on an inset card with a hairline edge (`railCard()`, `railCardFrame`). Its fill is ink at 3.5 percent, not an opaque grey, so it reads as EC / 20 on the flat canvas and lets the frost through when glass is on. Rows are 28 points tall with 18 point icons. The all-services rail sets each space as a 12 point heading; without names, it keeps an emoji between two short rules. Both cards in the left layouts start under a 32 point band (`ChorusCard.topBand`), so their tops line up. The divider beside the hybrid strip is gone, and so is the donation button's own fill, which showed as a dark square on glass. Checked live in all four layouts, light and dark, with names on and off, and with glass Clear and Regular. A throwaway test rendered one row with every mark on; nobody has seen the marks on a live page. Nobody has seen the download button live either, because it only shows once a download exists.
- **Step 5, the 52 point header, is built** (2026-09-29). Every layout has a 52 point band along its top (`ChorusCard.topBand`), and the bars, the nav row and both cards line up on it. The traffic lights sit on the band's centre line, 26 points in and 26 down. A real toolbar would centre them, but its view takes the clicks in the band, where the bar layouts keep their tabs. So `TrafficLightsPositioner` grows the title bar's container to 52 points and moves the buttons, as Electron does, then moves them again whenever AppKit puts them back. The nav buttons are 28 point circles with a hairline edge (`navCircle()`), Liquid Glass on macOS 26 and a material below it. Without the hairline the circles vanished on the Regular backdrop in dark mode. The download glyph lost its own circle. Seen live on macOS 26 in all four layouts and both appearances, with names on and off and every glass style. A click on a tab in the band still selects it, and hovering the lights shows their glyphs where they now sit. Two things are not checked. A script could not put the window in full screen, so nobody has seen the lights come back after it. And on macOS 14 and 15 CI has built the lights but nobody has looked at them.
- **Step 6, the glass picker, is built** (2026-09-29). Settings has Window glass (Off, Clear, Regular) under Appearance on macOS 26, and a build made without the 26 SDK hides it too. Picking Clear in Settings frosted the running window at once.
- **Step 7, the notice cards, is built** (2026-09-29). The window's three notices and the passkey notice are now cards in one stack between the band and the web card (`WindowNotices`). They started as cards floating over the page, and a review sent them back into the flow: two of them cannot be dismissed, a floating card hid the top of every site and the find bar, and the passkey card drew under the others. The storage warning now wraps in full, because its last sentence says changes won't be saved. Nobody has seen a notice in the running app, since none can be raised here without cutting the network; a test rendered the three cards in light and dark.
- **The rail's reorder now springs, and only a reorder does**: a space switch brings different rows, and `ReorderKey` treats that as no change. Reduce Motion turns the spring off. Nobody has dragged a row to watch it.
- **The review also hardened the traffic-light code.** It waits for AppKit's pass before moving the lights, stays out of the way while full screen comes and goes, and watches the close button's frame. Window tabs are off. Idle, it ran twice in two minutes.
- **Before release:** items 9 to 12 of the by-hand block in `VERIFY-BY-HAND.md`, above all the lights on macOS 14 or 15 and full screen on 26. The Settings captions are 10 points. They use `.caption` like every other caption there, and the redesign set its 12 point floor for the window's chrome only, so Settings kept its own.
- ~~The live shots of steps 1–3 show a blank web card.~~ Closed 2026-09-29: with the Debug build allowed in Little Snitch, the page loads inside the rounded card, and the corners clip cleanly.
- ~~A keyboard-focus ring lands on the first rail row at launch.~~ Fixed in 1.5.23: the ring waits for the keyboard (`FocusVisibility`).

## Shipped in 1.5.22: fixes and features found in Paguro (`fix/paguro-findings`)

**Built on 2026-09-29.** Branch `fix/paguro-findings`, pushed, CI green on macOS 14 and 15. Not merged and not released. `CHANGELOG.md` has the entry under Unreleased.

[Paguro](https://github.com/anguria-studio/Paguro) is an MIT fork of Chorus by Tommaso Laterza, taken at `43d590f` on 2026-08-19. It fixed bugs that Chorus still had. The branch rewrites those fixes for Chorus and adds four features: background audio with a speaker mark, a download list, one setting for outside links, and setup export and import. It also ships the license texts, and the source of the GPL blocklist, that Chorus had been missing. Two reviews found real bugs in the first pass, and the branch fixes all of them.

### Still open

- ~~Merge the branch into `main`.~~ Merged 2026-09-29 as `ffea72e`.
- The by-hand block at the top of `VERIFY-BY-HAND.md` has not been run. The one that matters most is WhatsApp across a quit: the handoff runs, but nobody has seen a real session survive it.
- `_isPlayingAudio` is private WebKit. A probe proved it on macOS 26 only. On 14 and 15 it is unchecked, though the `responds(to:)` guard makes the failure harmless.
- If a setup import's second save fails, the import deletes what it added, and no test forces that failure.
- The visual redesign that Paguro suggested is under way on `feat/paguro-look`; see the section above.

## Shipped in 1.5.21: Gmail sign-in, the all-services rail, and the traffic lights

**Shipped on 2026-09-29** as `v1.5.21`, build 34, tag on `a8aa893`. Both feeds serve it and the cask is bumped here and in the tap.

**Gmail sign-in landed in a popup.** Signed out, Gmail's service URL ends on the marketing page at `workspace.google.com/gmail/`, and its Sign in link is `<a target="_blank">` to `accounts.google.com`. Case 4 of `decidePolicyFor` let the click through as an auth host, but `createWebViewWith` only loaded a new window in place when it belonged to the same service. So the sign-in opened in a popup, Gmail loaded there, and the service stayed on the marketing page. `shouldLoadNewWindowInPlace` now also folds a clicked link to an auth host into the opener. `window.open` popups keep their window, because OAuth popups report back to the page that opened them. Checked in a Debug build with a control: the old code opened a second window titled "Sign in - Google Accounts", and the new code keeps one window with the sign-in page in the service. Signing in all the way through was not tested, because there is no test account to use.

**The popup ran on WebKit's default user agent.** `customUserAgent` belongs to the web view, not to the configuration the popup inherits, so Gmail in a popup showed "This browser version is no longer supported". Popups now copy the opener's agent. This was checked by reading the code, not live.

**PR #34 merged.** MazzMat's fourth layout, `allServices`. It is a raw-string enum case, so no schema version. It moves a link between spaces the same way the existing `moveService` does, and CI passed on macOS 14 and 15.

**The nav row sat under the traffic lights on a narrow rail.** That was true of Rail on the left with names off before #34, and #34 made it common. `WebContentView.trafficLightsOverhang` pads the nav row and the passkey banner with the same `barLeadingInset` rule the bars use. Checked live in both left-rail layouts.

### Still open

- The reporter has not confirmed the Gmail fix on her machine yet.
- Installing build 34 restarted the release app, so the snapshot-memory measurement from 1.5.20 starts over from 2026-09-29 01:00.
- Nobody has dragged a service between spaces in the new rail by hand. The reorder logic has unit tests and CI passed, but the drag itself is unchecked.
- MazzMat has not been thanked on PR #34.

## Shipped in 1.5.20: counting how many people run Chorus

**Shipped in 1.5.20 on 2026-09-23.** Merged (`3033b9a`), released as `v1.5.20` on build 33, appcast live on both feeds, cask bumped. **The user-agent question is closed**: the first real pings parsed, and `stats.sh` reads `1.5.20 5` within the hour of release. Nothing about the counter is outstanding except watching the numbers. Watch the version row on the first real ping: no genuine Sparkle build has checked in yet, and if its user-agent does not parse, every version reads `unknown` and only the daily total survives.

There was no way to tell how many people use Chorus. The daily Sparkle check is one request per installation per day, but it went to GitHub Pages, which keeps no request logs, so every one of them was thrown away. Release asset download counts were the only signal, and they mix new installs with Sparkle updaters pulling the same DMG.

`release/appcast-worker` is a Cloudflare Worker at `updates.nicojan.com`, deployed and live. It passes the same `docs/appcast.xml` through — releasing does not change — and stores one KV key per installation per day, hashed from the address, user-agent, date and a secret salt, expiring after 48 hours. A cron at 00:15 UTC rolls each day up. `release/appcast-worker/stats.sh` prints the table. Counting can never block an update: the KV work runs after the response is on its way and swallows its own errors.

`SUFeedURL` moves to the Worker in this branch. **The Pages URL must stay up forever** — every build up to 1.5.19 asks it for updates and always will. Settings gains a switch to turn the daily check off, which is what makes the README's claim true, and the README now says what the request carries.

**Two bugs found and fixed by testing rather than reasoning, both worth knowing:**

- A dual-stack machine counted twice, because the whole address went into the hash. The deeper problem behind it: IPv6 privacy extensions rotate the host half of an address roughly daily, which is exactly Sparkle's cadence, so one laptop would have looked like a new user on every rotation and drifted the count upward for no reason. Only the `/64` prefix is hashed now, pinned by `release/appcast-worker/test/address.test.mjs` and confirmed live — six IPv6 requests, one key.
- KV listings are eventually consistent, so a ping takes up to a minute to appear in today's `partial` record. A check run seconds after a request under-reports and looks exactly like a broken counter. It cost ten minutes before the cause was clear.

### Still open

- ~~**The Sparkle user-agent is confirmed only against a synthetic one.**~~ **Closed 2026-09-23.** Real builds check in and parse: `stats.sh` shows `1.5.20 5` on release day. A handful of `unknown` rows are `curl` requests made while verifying the feed, which is what an unparseable agent looks like — worth knowing, since it means `unknown` is not automatically a bug.
- **Known skew, not a defect to fix.** Machines sharing a `/64` or an IPv4 address count once; a machine that uses IPv4 one day and IPv6 the next counts twice. Closing that needs an identifier for the installation across both, which is the thing this design deliberately does not have. A daily total is good to a few percent.
- **Free-tier ceiling of 1,000 distinct machines a day**, that being Cloudflare's KV write limit. Past it, extra machines go uncounted silently. 1.5.18 has 52 downloads, so this is far off; the fix when it arrives is Workers Paid and Analytics Engine.
- **Numbers will read low for weeks and it is not a bug.** Only 1.5.20 and later report. Early growth is people updating, not new users.


## Shipped in 1.5.20: the share menu

Built 2026-09-22, released in 1.5.20 on 2026-09-23. `WebNavButtons` in `Chorus/Views/MainWindow/WebToolbarView.swift` gained a fifth control after Home: a `square.and.arrow.up` menu holding Copy Link, Open in Browser and Share. Share is a SwiftUI `ShareLink`, which presents the system sheet without needing an AppKit anchor view. The address comes from `webViewState.currentURL`, falling back to `webView.url` when the observer has not caught up, and the whole menu disables itself when both are nil. Build clean, 244 passed / 1 skipped / 0 failures on 2026-09-22.

It started as a single copy-link button. Two things changed it. Open in Browser closes a real gap — `NSWorkspace.shared.open` appears twice in the app and both are outbound link routing, so nothing ever handed the page you are on to a real browser. And a menu keeps the cluster at five controls rather than seven, which matters for the overlap below.

**A layout bug turned up on the way and is fixed here.** Swapping an SF Symbol for one of a different width re-lays the whole `HStack` out and shifts every button beside it. The copy button showed it first (`link` for `checkmark`), but the reload button has had it since the cluster was written: `arrow.clockwise` for `xmark` on every navigation. Every glyph in the row now sits in a fixed 16 by 14 box, which fixes both.

**Checked in the running app on 2026-09-22, and it holds.** Debug build, `hybrid` at the 800 point window minimum: five nav buttons and the donation cup with clear air between them. The menu opens with all three items drawn, and Copy Link put the exact address of the page on screen onto the pasteboard — a Teams sign-in redirect, which is the awkward case worth knowing about (see below). `topBars` was not captured separately and does not need to be: `UnifiedRailView` is the two layouts collapsed into one view, and `hybrid` is the tighter of the two because it also spends width on the strip of spaces down the left.

The geometry argument behind it, which is what makes the single capture enough: `UnifiedRailView.swift:227` reserves `SupportButtonMetrics.reservedWidth` — 44 points — as trailing *padding on the whole nav group*, not as a width budget the group spends. So a fifth button grows the cluster leftward into the `Spacer(minLength: 40)` and cannot eat the cup's clearance at all. The reserve being "sized for four buttons" was the wrong way to read it.

**What a copied link is worth is a separate question.** On a service mid-sign-in the address is the OAuth redirect, which is the page you are on and useless to send anyone. Correct behaviour, and not obviously the behaviour a user wants. Nothing to do about it without the service knowing its own canonical URL, which most do not expose.

**No test covers it.** `currentPageURL`, `copyCurrentURL()` and `openInDefaultBrowser()` are private members of the view, so nothing can reach them. Lifting the URL choice into a testable helper would cover the fallback and the nil case; about ten minutes, and it is the difference between a green suite and a green suite that says anything about this feature.

## Open: memory grows over a long run — it ramps for a day, then flattens

Measured 2026-09-22 against `~/Library/Logs/chorus-mem.csv`: 1,689 rows across 15 launches, collected 2026-08-24 to 2026-09-03. Split by pid, which is the trap that produced the wrong reading last time. Three runs are long enough to say anything:

| run | span | main process | slope |
|---|---|---|---|
| pid 74112 | 33.1h | 157 → 266 MB | +3.3 MB/h |
| pid 1607 | 56.9h | 181 → 291 MB | +2.2 MB/h |
| pid 88262 | 17.9h | 172 → 256 MB | +3.6 MB/h |

The 57 hour run carries the finding, being the only one long enough to show a shape. In six-hour means the main process climbs 173 → 258 MB over the first day and then holds: 258, 260, 265, 265, 273 MB across hours 24 to 60. That is a ramp to a steady state around 260–270 MB rather than the unbounded climb this was filed as. The old 10 MB/h figure came from a single 3 hour sample that sat entirely inside the ramp.

`webcontent_mb` shows no trend at all. It swings between 0.8 and 7.8 GB with what is open, and the sign of its slope flips from run to run — that is page content, not a leak. **Superseded as a reading of single pages, 2026-10-01:** the sum hides one page that climbs; see the memory watch note below.

**A candidate for the ramp, found in the code on 2026-09-22.** `WebViewPool.softHibernateService` (`WebViewPool.swift:456`) calls `takeSnapshot(with: nil)`, which means the full view bounds at backing scale — roughly 2160 by 1520 by 4 bytes, about 13 MB, for a 1080 point window on a 2x display. The image goes into `snapshots[id]` and only `teardownWebView` ever removes it, so every service you switch away from leaves one resident for the life of the process.

It fits the curve. `web_procs` is flat from the first sample of the 57 hour run — every service is already live inside the first hour — so the ramp is not services loading. The main process climbs about 90 MB across a day and stops, against 16 services you would visit at least once in that day. That is 6 to 13 MB a service.

**It is a hypothesis with a good fit, not a measurement**, so what went in on 2026-09-22 both bounds the cost and measures it:

- **`wakeService` releases the snapshot.** This is `b2ef7c3`'s change from `feat/spaces-presentation`, never merged until now. The ordering it relies on still holds: `WebContentView.swift:145` reads the snapshot before line 146 asks the pool for the web view, and holds its own reference until the load finishes, so dropping it on wake cannot blank the transition. PR #33 reworked that area without breaking the assumption.
- **A cap of three**, oldest dropped first, through `storeSnapshot` / `dropSnapshot` and the pure `WebViewPool.snapshotEvictions(order:cap:)`, which two tests cover. Worst case goes from one bitmap per service ever visited to three.
- **A debug log line** at every capture: how many snapshots are held and roughly what they cost, via `approximateBytes`. That is the discriminating measurement — if the plateau falls by about what the log says the snapshots were, the hypothesis is confirmed; if it does not, this was the wrong suspect and the next run says so.

**Two further reductions deliberately not taken.** Capturing at half width through `WKSnapshotConfiguration.snapshotWidth` is four times less memory, but the image is drawn full-size over a loading page and half-resolution text upscales visibly — that is a real cost to a user, not a free win, and the cap already bounds the total. Holding JPEG data and decoding on reveal is the bigger saving and the bigger change; it is worth doing only if the measurement says three full-size snapshots are still too much.

**The far bigger number is `webcontent_mb`, and there is no cheap lever on it.** It runs 2 to 7 GB across 15 to 17 live WebContent processes. `autoHibernateIdleEnabledEffective` (`AppPreferences.swift:208`) defaults to false, so the auto-idle hibernation shipped in 1.5.9 is off for almost everyone, and turning it on by default looks like free memory. It is not. **Do not make that change in its current shape**; an earlier draft of this section recommended it and was wrong.

A fully hibernated service is torn down, so no page script runs and it fires no notifications at all — only the badge moves, on the poller's sweep (`ServiceInstance.swift:284` says so). The exemption that is supposed to protect against this is `isNotificationCritical`, and it is one catalog category, `Messaging`: 13 of the 74 catalog services. **Email is not in it.** Neither is Productivity nor Developer. So defaulting the setting on would silence Gmail, Outlook, Fastmail, ProtonMail, every calendar reminder, every Figma comment, every Sentry alert and every GitHub mention, an hour after you last looked at them. A mail service that stops reporting mail is a broken mail service, and a badge that catches up on the next sweep is not the same product.

Two further edges in the same rule, both live in shipped code:

- **A service added by typing its address is never exempt.** `isNotificationCritical` returns false when `catalogEntryID` is nil, so a self-hosted Mattermost, a second Slack added by hand, or any chat app outside the 74 hibernates like any other page and goes quiet. Anyone who turned the setting on has been silencing those with nothing to tell them: the reassuring "chat apps stay loaded" note in `EditServiceSheet` only draws for catalog services. **A caption for the custom case is added on `main` as of 2026-09-22**, which is the honest minimum; it does not make the behaviour right, it stops it being silent.
- **The rule is over-inclusive too.** LinkedIn and Zoom sit in `Messaging`, so they stay resident for the life of the process whatever you set, which is memory spent for very little alert value.

What would make a default-on defensible is a behavioural exemption rather than a categorical one: the app already sees every notification a page posts through the `chorusNotification` handler, so "this service actually pushed something in the last week" is a fact it can hold, and it covers custom services, which no category ever will. That needs the data collected first and is not 1.5.20 work.

And soft hibernation does not help here. It suspends media and lets WebKit drop GPU and compositor resources while the WebContent process stays up, so the multi-GB figure is untouched. The page has to stop running for that memory to come back, and a page that has stopped running cannot notify you. That trade is real and cannot be designed away.

**A memory watch, log only (PR #36).** The sum above hides one page that climbs, and reading one WebContent process at a time shows it. On 2026-10-01 a single Chorus WebContent process went from 154 MB at 18:00 to 1.6 GB at 18:28 and 2.2 GB at 18:30, 1.5 GB of it `WebKit Malloc` (`footprint -p`) and 41 MB of WebAssembly. That is one process on one evening on macOS 27, and the service is a guess: the WebKit logs hide URLs, and WhatsApp Web is only the likeliest of the six. The WhatsApp app sat at about 460 MB on the same machine.

So PR #36 measures before it acts. Every five minutes `AppState.logMemoryWatch` logs each page's footprint, read with `proc_pid_rusage` on the pid from `_webProcessIdentifier` (SPI, probed), under the service's catalog id. It also logs when a page would be rebuilt (`WebViewPool.wouldRebuild`): past both 1.5 GB and twice its baseline, out of sight for ten minutes counted from when the user left it (`ServiceVisits`), and not on screen, pinned, Keep Loaded, capturing, audible or holding tabs. When a page counts, its footprint becomes its new baseline, standing in for the rebuild, so a page that settled heavy counts once rather than every pass. Nothing is rebuilt. Read it back with `log show --predicate 'subsystem == "com.nicojan.Chorus" AND eventMessage BEGINSWITH "Memory watch"'`.

If the logs show the climb, turning the rebuild on needs, from the review of #36: one service per pass; skip while offline and just after wake; skip when `hasOpenTabs`, checked before and after the call probe; run the `quitReleaseJS` save step and wait, as quit and tab close do, since WhatsApp saves its session when the page goes hidden; and reload `webView.url`, not `instance.url`, so the open chat survives. Then test it on a release build against a signed-in WhatsApp over hours.

**Still open:**

- **The plateau is 36 hours of evidence from one run.** Confirm it holds past 60 hours before closing this.
- **The sampler has been dead since 2026-09-03 at 00:58, and the cause is now known.** `launchctl list` reports exit 127 and `~/Library/Logs/chorus-mem-sampler.err` says `/bin/zsh: can't open input file: /Users/nicojan/dev/Chorus/scripts/sample_memory.sh`, repeated. The script was never on `main`: it and `install_mem_sampler.sh` live only on `feat/spaces-presentation`, so checking `main` out deleted them from the working tree while the LaunchAgent kept firing at the absolute path. Both scripts were restored to `main` on 2026-09-22 and the agent is loaded again (`launchctl list` shows it running, exit 0). No data for the 19 days between, and none will appear until the release app runs — the sampler only samples `/Applications/Chorus.app`.
- **Two short runs read +83 and +93 MB/h** (pids 71512 and 2287, 2.2h and 4.6h). Both sit inside the first hours of a launch, so they are the ramp seen close up rather than a second phenomenon, but neither ran long enough to prove that.

This supersedes the "Open: memory grows over a long run" section on `feat/spaces-presentation`, which predates the multi-day data.

## Merged: the click-swallowing snapshot, and the favicon after a redirect (PR #33, verified on build 32)

Reported on 2026-08-31 against 1.5.19: TD EasyWeb added by custom URL showed its login screen and accepted no clicks, and it drew a letter tile rather than TD's icon. Two separate causes, both fixed on `fix/td-login-click-swallow`.

`WebContentView` stacks a cached snapshot over the live web view while a page loads. It carried no `allowsHitTesting(false)`, so it swallowed every click for as long as a navigation ran. Worse, the only thing that cleared it was an `isLoading` transition, and switching to an already-loaded service starts no navigation — so the snapshot sat in state until the page's *next* load put it back on screen. `retainedSnapshot` now drops a snapshot that has no load behind it, and the image never takes hit tests.

`FaviconFetcher.fetchFromHTMLLinks` resolved a page's relative icon `href` against the requested URL rather than the one the response came from. `easyweb.td.com` 302s every path to a generic error page, so all six direct candidates fail, and the HTML fallback then resolved `href="favicon.ico"` against `easyweb.td.com` when the document was `authentication.td.com/uap-ui/`. `fetchURL` returns the final URL alongside the body now and `resolvedIconLinks` uses it. Verified against the live site: `https://authentication.td.com/uap-ui/favicon.ico`, 200, a valid ICO. It is 16×16, which is all TD publishes on either host — checked all six candidate paths against both — so the icon will look soft and there is nothing better to fetch.

**Closed by hand on build 32.** TD was added from scratch, left for over five minutes on another service, and still took clicks on the login fields when it came back — the path that matters, because five minutes is long enough to soft-hibernate the view and store the snapshot. Its icon is TD's own mark in the top bar, not a letter tile.

The freeze was never reproduced *before* the fix, which is the caveat worth carrying. The TD login page loads clean in a harness carrying Chorus's user scripts, the Hagezi list and the Safari user agent: `isLoading` settles to false, no full-viewport overlay appears, and every field hit-tests and takes input. So this went in on its reasoning, not on a red-to-green observation, and the by-hand pass confirms the symptom is gone rather than that this was its only cause.

One trap for the next person testing a click bug: adding the service from scratch and clicking straight away proves nothing. A service created seconds earlier has no stored snapshot, so `transitionSnapshot` is nil and no image is ever drawn. The first pass did exactly that and read as a pass.

Rounded squares stay. The reporter asked about circular icons and then chose to keep the current shape, because a circle clips the corners off square brand marks like Slack and Gmail.

**This superseded the build-31 DMG.** Build 32 is what shipped.

## Merged: PR #23, and five contributor PRs, all riding in 1.5.19

Five PRs from `marcioviniciusspiridigliozzi-dot` were merged to `main` on 2026-08-19 (`366745a` to `43d590f`): the store-fixture race (#15), the badge sweep's SSO approval storm (#16), ITP off per data store so an SSO service can read its session from its provider's frame (#17), a real window for a same-service `window.open` (#18), and a link popup no longer reloading the service behind it (#21).

**PR #23 merged on 2026-08-29** at `0a55562`, closing issues #20 and #19. It gives a stuck install a way out of temporary storage — automatically when Chorus can prove there is nothing to lose, and by a `Start fresh` button when it cannot — and adds Google Keep with a real vector from thesvg. `hasAnyPreservedCopy` excludes the `.reset-` family on purpose: counting it would let a user's own earlier fresh start veto the automatic fix.

Blocks 1 and 2 of `docs/internal/VERIFY-BY-HAND.md` passed by hand on 2026-08-29 and hold the evidence, down to the pid change proving the terminate went through the sheet and the hash the older aside kept across a second fresh start.

### Still open, not blocking

- ~~**Nothing reaps the `.reset-` family.**~~ Closed on 2026-08-29 by `pruneResetAsides`, which bounds it the way `prunePickAsides` bounds its own: the newest three plus the single oldest. The family is live recovery material — `StoreInventory` lists it, which is what makes undoing a fresh start one click — so a purely-recency rule would have reaped a candidate the picker was offering, and the oldest aside is the store as it stood before the user started over at all.
- **#17 is still one-tenant.** The contributor has a single Entra tenant and said so. Nobody has confirmed it elsewhere; issue #14's reporter is on Teams and was responsive once.
- **#15's flake never reproduced here.** Twelve full-suite runs on the branch and twelve on `main` as a control both came back clean, so it went in on its reasoning rather than a measurement. Test-only, so the downside is bounded.

**Gotcha for whoever runs `build_brand_icons.py` next:** `--write` also reclassifies `brand-notion` and `brand-mattermost` as template-rendering, and both are set to `original` on purpose. Revert those two after any run.

## Merged: the two-rail layout is back, and the names can be turned off

Built on `feat/hybrid-layout-and-name-visibility` on 2026-08-29, from three notes taken while testing the held 1.5.19 by hand. Merged to `main` as PR #31, and it rides in 1.5.19. All three layouts have now been looked at by eye on build 32 — see blocks 2 and 3 of `docs/internal/VERIFY-BY-HAND.md`, where the only thing left unrun is the tooltip with service names off.

`RailLayout` has three cases again, under the raw value it always had. Retiring `hybrid` never reached anyone: no tag contains `5e01986`, so no store was ever rewritten, and a store still holding that value belongs to someone who picked the layout and never left it. The forward-map `resolving(_:)` carried while the case was gone is deleted, along with the test that pinned it.

`SpaceStripView` is restored from `5e01986^` rather than rewritten, because the reorder maths, drag and drop, arrow keys and VoiceOver move actions are what the audit rated severity 0. Only the vertical arrangement comes back; `UnifiedRailView` draws spaces-along-the-top now, so the axis parameter and about a third of the restored code went with it. Its delete already routed through `AppState.deleteSpace`, which is what keeps the macOS 15 crash from riding back in with it. It also gains a `WindowDragHandle` it never had: the OS window drag is off in this layout, so the strip was the one part of the window's top edge that could not move it.

The strip has two widths and a toggle to pick between them. A drag handle was built first and thrown away after a by-hand test: the strip is 40-odd points of chrome, the useful range between its ends is short, and a live gesture spent on a two-answer choice felt bad in the hand. The toggle sits beside the service-names one and lands on the right width every time.

The traffic lights stay the strip's problem. The retired hybrid gave the service bar `lightsWidth - railWidth` of leading inset so the lights could overhang a 52 point strip; `SpaceStripMetrics.barLeadingInset` is that same arithmetic, now that the width has two values.

Turning service names off narrows the vertical rail to 52 and collapses the space header to its emoji, because a 224 point header cannot sit above a column of icons. The horizontal bar has the room and keeps its name, so the rule is geometry rather than preference. Nothing becomes unreachable: the compact cell's tooltip speaks the full accessibility label, including the moon, the bell and the media glyph it has no room to draw.

Both settings live in defaults rather than `AppPreferences`, for the reason the donation button's used to: a stored property there is a schema version and a migration, which chrome visibility does not earn. The cost is the same one, that a restore from backup does not carry them.

Three things came in with it that 1.5.19 was being held for. The top bar's add button is pinned outside the scrolling row now, where the vertical rail has always kept it, and the overflow branch softens its trailing edge. `pruneResetAsides` bounds the `.reset-` family. `project.yml` asks for Xcode 16, which is what the object format needs and what `CONTRIBUTING.md` already told contributors to install.

Part of it has now been seen by eye, on 2026-08-31, against the stapled build 30 over `/Applications`. `docs/internal/VERIFY-BY-HAND.md` carries the result item by item. The short version: the bar layout and the two-rail layout are right in both appearances, service names off gives the narrow rail and the collapsed header as designed, and creating and deleting a space did not crash.

**Block 1 failed, and the digits are gone.** The palette drew `⌘1` and `⌘2` and pressing them switched *services*. The cause was not the `KeyPress.characters` question this file had been carrying since step 4 — `KeyboardShortcutManager.swift:16` binds `⌘1`–`⌘9` as menu command key equivalents, and the menu dispatches those before the event reaches the first responder, so `SpacePaletteView`'s `.onKeyPress` was never asked and `press.key` would have changed nothing. The labels, the two helpers and their two unit tests are removed. Both tests had passed the whole time, over arithmetic nothing called, which is the lesson worth keeping: a green test on a pure helper says nothing about whether the feature is reachable.

**Still unseen, and the first is the default:** the 240 point rail with service names *on*, the 180 point space strip with names on, dragging the window by the top edge in each layout, and all of block 4 — the tab bar overrunning at the 800 point minimum.

## Shipped in 1.5.19: the donation button

Released in 1.5.19 on 2026-09-03. A button 20 points across, in a 28 point target, sits in the top right of the main window and opens `https://buymeacoffee.com/0xff.r4bbit`; the About panel carries the same link in its credits field, through `CommandGroup(replacing: .appInfo)` in `ChorusApp.swift`. Verified by hand in all three layouts and in the panel. `SupportLink.url` in `ContentView.swift` is the single definition both use.

Both things that were open here are now settled, on 2026-08-16.

The paint stays at 20 points and the click target grew to 28. The audit asks for 44 everywhere else and this is a deliberate exception: a permanent request for money that reads as a control is louder than the ask was, and the pointer, not the finger, is what hits it. `SupportButtonMetrics` in `ContentView.swift` holds both sizes and the arithmetic that keeps the chip where it was drawn when the target grows around it.

**The switch that hid it is gone, as of 2026-08-29.** It was one 20 point chip that only takes colour under the pointer, and the switch cost every layout a second code path for a hole where the button would have been. `showSupportButton` and its Settings toggle are deleted, and `SupportButtonVisibility` is now `SupportButtonMetrics`, which is all it ever was once the key came out. The two settings that replaced it — the service names and the space names — sit in defaults for the reason this one did.

The nav buttons in `hybrid` and `topBars` end in the same corner, so `UnifiedRailView` reserves `SupportButtonMetrics.reservedWidth` (44 points) of trailing padding for the button. The fallback to 10 went with the toggle. Cut that reserve and the two overlap as soon as the Home button appears.

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
- **A tab bar that overflows says nothing about it.** *(Fixed 2026-08-29, in the two-rail work above: the add button is pinned outside the scrolling row and the overflow branch softens its trailing edge.)* With names on the tabs, five services and a 1000pt window already fill the bar. At the 800pt minimum width the last tab is cut mid-icon and the add button sits off the end. The strip does scroll, through `ScrollView(.horizontal, showsIndicators: false)` in `ServiceSidebarView.tabStrip`, but nothing on screen says so, and a clipped icon reads as broken. That setting predates this step; labelled tabs are what make it easy to reach. Step 5 rebuilds this strip, so the fix belongs there.
- **In `sidebar` this step alone costs chrome.** 52pt space rail plus 240pt service rail is 292 points before content, against today's 104. Step 5 takes the second rail out and lands it at 240, so the cost is an artifact of shipping step 3 on its own. The horizontal layouts have no such cost.
- **The horizontal tab has no width cap, on purpose.** A `maxWidth` only bites when something proposes an unbounded width, which the strip's fallback scroll view does, and there it stretches every short tab to the cap instead of trimming the long ones. `ViewThatFits` already hands overflow to that scroll view, so a long name costs scrolling rather than layout.

Selection and focus were left exactly as they were, `focusEffectDisabled()` included, because the specimen that reshapes them is step 7 and cutting it twice is waste.

**Step 2 (`RailLayout` to two cases) is not started, and it should wait for step 5.** It does not depend on step 3, and the spec called it mechanical with no visual change. The second half of that is wrong, and the spec now carries the correction. Retiring `hybrid` maps its users onto `topBars`, and until one rail draws both layouts those are two different screens: `hybrid` keeps the spaces on a 52pt rail down the left, `topBars` has no left rail and stacks two horizontal strips. Shipping the enum change alone moves every hybrid user to an arrangement they did not pick, then moves them again at step 5.

**All seven build steps of concept C are done, as of 2026-08-17. 215 tests, 0 failures.** Steps 6 and 7 landed after the pass below, so neither has been seen at all.

Step 6 puts a 9 point mark on a service icon's bottom-right corner: nothing when the page is up, a grey ring while it loads, an orange disc when it failed. Three silhouettes rather than three hues, because the drawn frame separated the states by colour alone and that fails a red-green colour-blind user; `ServiceAccessibility.label` says the state in words as well. `WebViewPool` publishes it per service, the way it already publishes media capture state, so a service that broke while you were looking at another one still says so. One trap worth remembering: the error page Chorus paints on a failure is itself a navigation that finishes, so `didFinish` would have reported the service healthy a moment after it broke. `errorPageLoadInFlight` on the coordinator is the guard. Signed-out is drawn and never set, per the spec, and a test pins that no navigation event can produce it.

Step 7 is the baseline's own list. `NoticeStrip` replaces the two raw yellows and the solid red bar with one shape at three severities, carrying the tone in the icon and the rule rather than the fill, and carrying the window-drag handle each notice needs. `ChorusRadius` takes eight radii down to three. `RowMark` splits selection from focus: a fill for one, a ring for the other, which is the reshape the audit asked for rather than the switch-off 1.5.10 did.

**Steps 5 and 2 are built and merged, and half of concept C has now been seen running.** `UnifiedRailView` replaces `ServiceSidebarView` and `SpaceStripView`, both deleted. `RailLayout` went down to two cases here and back to three on 2026-08-29, before either shipped — see the two-rail section above. 205 tests, 0 failures.

What the by-eye pass on 2026-08-17 did establish, in the Debug build against `Chorus-debug`:

- **The bar layout is what the frame draws.** One bar, measured at 42 points, the space header at x 80 clearing the traffic lights, a divider after it, then the labelled service tabs, the nav buttons and the coffee cup at the far right. The second bar is gone.
- **The `hybrid` forward-map works on a real store.** That store had been left on `hybrid` the day before. The rebuilt app opened it as the bar layout, which is the case the map sends it to, and not the `.sidebar` fallback.
- **The palette opens from the header and is right.** Both spaces with emoji, name and service count, `⌘1` and `⌘2` down the trailing edge, the current space carrying the tint fill, and the New Space row under a divider. It measured 260 points wide.

What it did not, and why. The dev machine was in active use. Scripted keystrokes and clicks kept landing in whatever app had come forward: a Finder window and MacWhisper both took input meant for the rail. One `⌘2` reached the installed release copy of Chorus, which is harmless, since all it changes is which service is on screen. Driving the UI was stopped there rather than pushed through. So **three things stay unverified**: the sidebar layout with its 240 point rail and the header at y 38, both appearances, and whether `⌘1`–`⌘9` inside the palette actually picks a space — the `KeyPress.characters` question from step 4 is still open. All three want a by-hand pass on a quiet machine.

**Step 4 is built and merged, and none of it has been seen on its own.** `SpaceHeaderView` draws the current space as a 224 by 36 header on the rail, or 150 by 32 in the bar, with the aggregate badge and a pop-up chevron. `SpacePaletteView` is the switcher it opens: a 260 point popover at radius 14, whose rows carry emoji, name, service count, unread badge and the `⌘` digit. 203 tests, 0 failures, six of them new and all on the pure helpers (`SpacePalette`, `SpaceHeader`). Nothing presents either view until step 5, so they compile and run but cannot be reached, and the by-eye pass has to wait for that step.

Three decisions inside it worth not relitigating:

- **Space drag-to-reorder and the per-space context menu moved into the palette**, beyond the two views the spec named. `SpaceStripView` holds them today and step 5 deletes it, so they move into the palette or they disappear. `ServiceReorder` was reused untouched, as the spec demands.
- **The palette reports edit, delete and add upward through closures** instead of presenting the sheets itself. A sheet raised from inside a popover goes down with the popover when it closes. Whoever assembles the rail at step 5 owns those sheets.
- **The header and the palette are not welded together.** The header is a button with an `isPaletteOpen` flag; the owner attaches the `.popover`. Three lines at the call site, and neither view has to know about the other.

Two things about it are unverified by construction. `⌘`-digit resolution reads `KeyPress.characters`, which is untested against a live command-modified keystroke, and the palette takes `focusEffectDisabled()` on its container so the popover does not draw a ring around everything. Step 7 is the specimen that settles focus, and it should look at that.

**The product call that gated step 4 is answered: the digits are palette-local.** The palette on page `08` labels its rows `⌘1` to `⌘4`, and `⌘1`–`⌘9` currently switches services (`KeyboardShortcutManager.swift:16`), an accelerator set the audit rates severity 0 and says to protect. `SpacePaletteView` binds the digits itself while it is open; `KeyboardShortcutManager` is left alone, so nothing shipped breaks. Reassigning them globally was the alternative and it is rejected: it breaks a shipped accelerator to solve a problem nobody reported. Step 4 is unblocked.

> **Overtaken by events, 2026-08-31.** "`SpacePaletteView` binds the digits itself while it is open" is not something `.onKeyPress` can do. A menu command key equivalent is dispatched before the first responder sees the key, so the palette never got the event and `⌘1` kept switching services. The digits were removed rather than reworked. The decision above is still the right one on its merits — do not reassign the accelerator globally — but making the palette borrow the digits would have to happen inside `KeyboardShortcutCommands.switchToService(at:)`, branching on a palette-open flag, not in the palette.

The price, accepted with the pick: always-visible per-space badges and drag-to-reorder move into a palette. A and B are closed. A never answered the severity 4 finding, which is the product's core loop; B answered it and spent 400 points of sidebar before content to do it.

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

**The placeholder pass was parked on 2026-08-16, and the pick released it the same day.** Filling the other five content areas with a drawn service the way Terminal does would take eighteen frames. It was held back because the concept pick gated everything and is independent of the skin. That pick is made, so the direction is now the open question, and the seam between chrome and content is what separates the six. Draw the content before choosing between them. Rejecting all six and staying native is still a live answer.

## Reference: the interface baseline in Figma

Built 2026-08-13. The shipped interface is rebuilt in Figma (file `Chorus`, key `3MGhWQwnJQbfN6Egnet42I`), traced from 1.5.18 and measured pixel by pixel. Reference: `docs/internal/FIGMA-BASELINE.md`, which holds the measured geometry table, the file map, and what in the file can and cannot be trusted.

Pages `01` through `06` record what ships today and are locked; page `07` is the empty workspace. The redesign work sits on `08` through `11` and is covered by the open sections above. **Everything below describes the shipped interface, not a proposal.** The one piece of redesign code written so far sits unmerged on `feat/service-row-view`, so `main` still matches these pages.

Measuring turned up seven things worth fixing, ranked by cost. Eight corner radii where three would do, five of them between 6 and 10. Three different fills for one selected state (`E4F0FF`, `E8F3FF`, `D2E6FF`). Selection drawn three ways at once, with a lighter stroke on chips than on tabs. One text size doing 36 of about 63 jobs, against four uses of primary colour. Two banners on raw SwiftUI yellow while the third goes solid red, so the three warnings read as three designs. A tab rail padded 6 above and 2 below. Two tap-target sizes and six icon sizes, with 40 sitting under Apple's floor of 44.

The radius collapse, the target sizes and the icon sizes are mechanical. The selection signal, the caption style and the banner shape are decisions somebody has to make first.

**What the file does not cover.** The store banner, recovery banner and lock screen were built from source rather than traced, because producing them needs a damaged database. The offline banner is the same, since catching it needs the network to drop. Service icons are tinted placeholders. No automated pixel diff was run against the captures.

## Shipped: 1.5.20, published 2026-09-23

Build 33 went out as `v1.5.20`. The release carries `Chorus-1.5.20.dmg`, sha256 `ca8c7dd436c35cb3241c15b45ee36c169a6e0f3cee4308da5faf277de24a82c6`, 8,932,297 bytes. The tag sits on `4eee4e8`, and `project.yml` at that tag reads 1.5.20 and build 33. Both feeds serve the new item and the Homebrew cask is on 1.5.20 here and in the tap.

Four changes: the appcast feed counter (merged from `feat/appcast-feed-counting`, with the Settings switch that turns the daily check off), the share menu, the snapshot cap, and the caption warning that a hand-added service goes quiet when it hibernates.

**The counter's one unknown closed on release day.** Real Sparkle builds check in and parse — `stats.sh` read `1.5.20 5` within the hour. The `unknown` rows alongside them were `curl` requests made while verifying the feed, which is what an unparseable agent looks like; `unknown` is not by itself a broken parser.

**What could not be checked, and it is not the cask's fault.** `brew style`, `brew livecheck` and `brew audit` all died in `bundle install`, timing out on rubygems.org while `curl` to that host returned 200 in 0.4 seconds. That gap is the local-firewall signature rather than a network fault. The cask was verified directly instead: the published asset downloads and hashes to the sha256 in the file, its size matches the enclosure length, and `ruby -c` parses it. Re-run the three commands once portable-ruby is allowed out, and note the trap in `release/DISTRIBUTION.md`.

## Shipped: 1.5.19, published 2026-09-03

Build 32 went out as `v1.5.19` on 2026-09-03. The release carries `Chorus-1.5.19.dmg`, sha256 `ec276f7b…dbb73`, 8,883,765 bytes. The tag sits on `6833544`, and `project.yml` at that tag reads 1.5.19 and build 32. Both feeds serve the new item and the Homebrew cask is on 1.5.19 in this repo and in the tap.

Steps 6 to 9 ran in order, each against a check:

- **Step 6.** `main` pushed first, then `gh release create`. The tag landed on `6833544`, which was remote HEAD at the time. That is the check 1.5.11 and 1.5.15 both failed.
- **Step 7.** `sign_update` on the stapled image printed `length="8883765"`, the same size as the uploaded asset.
- **Step 8.** The Pages run for the appcast commit was missing from `gh run list` on the first look, which is what 1.5.18 looked like when its feed stayed on the old version. Here it was in progress rather than absent. Poll for it, and do not touch the cask until a `curl` of the feed shows the new version.
- **Step 9.** `brew style` clean, `brew livecheck` reads 1.5.19, and the online cask audit exits 0.

**`sed -i ''` in step 9 does not work on this machine.** `sed` on the PATH is GNU sed 4.10 from `gnu-sed`, not BSD sed, so it reads the empty string as the script and the `s///` expression as a filename, prints "can't read", and changes nothing. The runbook's command is written for BSD sed. Edit the cask with `python3` or `perl -pi -e`. This is the same class of surprise as `ls` being `eza` here.

Next is 1.5.20, which is `feat/appcast-feed-counting`. It was held off `main` only until this shipped, and it is the first build that reports a user count.

Six builds existed, all 1.5.19. Build 32 is the one that shipped:

| Build | Commit | What it is |
|---|---|---|
| 28 | `c5af295` on `main` | The original hold. `build/Chorus-1.5.19.dmg`, sha256 `9a912a9e…6390e`. |
| 29 | `4c32087` on the two-rail branch | The first test build of the layout work. Superseded. |
| 30 | `c2598f6` on the two-rail branch | `build/Chorus-1.5.19-b30.dmg`, sha256 `e27b30c4…575bc`. Superseded. |
| 31 | `bc45237` on `main` | The palette fix. Superseded, kept as `build/Chorus-1.5.19-b31-stale.dmg`. |
| **32** | **`eeaec53` on `main`** | **`build/Chorus-1.5.19.dmg`, sha256 `ec276f7b…dbb73`, 8,883,765 bytes. Signed, notarised, stapled, Gatekeeper-accepted, installed, and the one the by-hand pass now runs against.** |

The marketing version stayed at 1.5.19 across all six, and only build 32 was ever published. The build number moves so the About panel can tell them apart. Builds 29 and 30 were branch builds; everything is merged now, and build 32 is cut from `main`.

The test builds are named `Chorus-1.5.19-bNN.dmg` so they cannot overwrite the held `Chorus-1.5.19.dmg`, and they are packaged with the `hdiutil` fallback rather than `create-dmg`, which drives Finder with AppleScript and takes the screen while it does. The published artifact should still be built the documented way.

239 tests at build 28, 0 failures on macOS 26.6 locally, on macOS 15 under Xcode 26.3, and on macOS 14 under Xcode 16.2. 244 at build 30, locally only — CI runs on pull requests and pushes to `main`, and the branch has had neither.

**The macOS 14 pass `CLAUDE.md` asks for is done, by CI rather than by hand.** It was written off at first on the assumption the `macos-14` runner image only carries Xcode 15.4, which cannot open a project in object format 77. It also carries 16.1 and 16.2, and the workflow already picks the newest installed, so the only obstacle was the assumption. `testMigratesFrom1_5_13PreservingLinkEnds` is the test that pass was really about, and it runs there now.

**The real store migrates too.** `testMigratesARealStoreCopy` (skipped unless `/tmp/chorus-real-store-copy` names a directory) ran against a copy of this machine's live 1.5.18 store: 4 spaces, 15 services, 15 links, every link keeping both ends. That is the check synthetic fixtures cannot make, since they only prove the stages are right about stores the test file wrote. The original was untouched; the copy is what migrates.

**Steps 2 to 5 of `release/DISTRIBUTION.md` are done, on build 32.** `build/Chorus-1.5.19.dmg` is signed, notarised (`Accepted`) and stapled — the app on its own first, then the image — and the stapled app sits at the repo root where the doc expects it. Mounted and checked: the app inside reports 1.5.19 (32), the staple validates, and `spctl` reads `source=Notarized Developer ID`.

    sha256  ec276f7b38269a1f379d2f5d009b920557d1b12db455b00e025d323da30dbb73

**Eject before you check a mounted image.** A build-31 image left at `/Volumes/Chorus` took a scripted check meant for build 32: `hdiutil` mounted the new one at `/Volumes/Chorus 1` and said so only in its own output, so the check read the stale volume, answered build 31, and looked for a moment like a bad build. Read the mount point out of `hdiutil attach` rather than assuming `/Volumes/Chorus`.

The 1.5.18 app that used to be at the repo root was moved to `/tmp/chorus-app-1.5.18-*.app` rather than deleted, because the guard blocks a recursive delete there. It ages out on its own.

The by-hand pass is complete. Build 32 went over `/Applications` on 2026-08-31 and has been in ordinary use since, with nine services across four spaces answering clicks and drawing badges. Block 4 and the tooltip in item 10 both passed on 2026-09-03; item 25 is closed on the code rather than on a click, and `docs/internal/VERIFY-BY-HAND.md` records why.

### That DMG goes stale the moment `main` moves

It is built from `eeaec53`. Any commit after that makes it a build of something that is no longer what 1.5.19 means, and the danger is not that publishing fails — it is that publishing *works* and ships code nobody reviewed as the release. As of the end of 2026-08-31 the commits after it touch only `docs/internal/`, so the binary still stands; check again before step 6.

So before step 6, either confirm `main` has not moved since the build, or rebuild. Rebuilding is cheap: steps 2 to 5 took a few minutes, most of it waiting on the notary service. The version and build numbers do not need touching, since nothing was published under them; the sha256 changes, which matters only because the Homebrew cask carries it.

Check the changelog's date too. The heading reads `## [1.5.19] - 2026-08-31`, which is right only if it ships that day. It is a public file, so a heading a week wrong is a heading users read.

### What the release is for

**Deleting a space quit the app on macOS 15**, and had since 1.5.13. `Space.serviceLinks` and `ServiceInstance.spaceLinks` both cascade, so deleting either end has to clear the link's reference, and both references were non-optional with nothing to clear them to. macOS 26 permits the same delete, which is exactly why this machine never saw it in five releases. Two paths reached it: `AppState.deleteSpace` and the rail's `deleteService`.

Both ends of `SpaceServiceLink` are optional now. The old shape is frozen as `ChorusSchemaV1_5_13`, the current identifier is `(1,5,19)`, and the stage between them is `.lightweight` because it only drops a constraint. `liveSpace`, `liveService` and `liveEnds` replace eight hand-rolled dangling-link guards.

Reordering the deletes was tried first and reverted: the trap moved to the other end of the link, so the order was never the problem.

### `.cascade` means three different things, so stop using it

macOS 15 and 26 take a space's links with the space. **macOS 14 does not** — the rows survive with `space` nulled, which is the dangling state `reapDanglingLinks` exists for. `deleteSpace` deletes the links itself now. Worth remembering before leaning on any other delete rule here.

### The thing that found all of it

`.github/workflows/test.yml` runs the suite on macOS 14 and macOS 15 for every pull request and every push to `main`. Until it existed the only workflow published the appcast, and five contributor pull requests had been merged with nothing checking them.

It has earned its keep twice. It found the macOS 15 crash on its first build that reached the tests. Then macOS 14 turned up four build errors on the Xcode 16 SDK — which `CONTRIBUTING.md` tells contributors to use, so nobody on Xcode 16 could build this at all — and five latent test bugs that had been wrong all along while macOS 26 stayed forgiving. The pattern across all of them: detached or double-registered `@Model` objects, tolerated on the newest OS and fatal on the oldest.

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

## Closed: Slack notifications arrive late (issue #24)

Closed on 2026-10-05 as not planned. Nobody added to #24 in the six weeks after it opened, and nine releases have shipped since the 1.5.18 fix. If it comes back, reopen #24 and start from the notes below.

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

### Closed: the store sat on a shared path — shipped in 1.5.18

The release build passes `ModelConfiguration(schema:isStoredInMemoryOnly:)` with no URL (`AppState.swift`), and SwiftData does not scope that default to the bundle. Verified with `lsof` against the installed 1.5.14: the running app holds `~/Library/Application Support/default.store` — the top level of the shared folder, not `…/Application Support/com.nicojan.Chorus/`. Every non-sandboxed SwiftData app that skips an explicit URL claims the same filename, so another app can open, migrate, or recreate Chorus's store, and anyone tidying Application Support sees a `default.store` belonging to no visible app. The DEBUG path is already scoped (`Chorus-debug`); only the shipping path is exposed.

This is the one mechanism found so far that empties the store with no Chorus update involved, which is why it survives the 1.5.15 migration fix. Fixing it means moving the store into a bundle-scoped directory, and the move has to be a move: open the old path, copy the triple across, and never let the seed run against the new empty location. Snapshot names and the recovery banner path change with it.

**Done, and released in 1.5.18 on 2026-08-06** (`StoreRelocation`). The section above it carries the shipped account; this one is kept for the diagnosis, which is the part worth re-reading if the store ever moves again.

### Closed: PR #10

**PR #10** (opt-in spaces hiding, a bottom nav bar, and a window title) was closed on 2026-08-19. It had gone CONFLICTING across eight files, and `feat/spaces-presentation` answers the hide-the-spaces-rail half three ways instead of one. Rebasing it would have cost the contributor an evening for a result mostly thrown away.

Three things in it are worth having, and the closing comment invites each as its own small PR:

- **The window title.** Two findings that are not guessable: `.windowStyle(.hiddenTitleBar)` hides the title but keeps the bar, and AppKit draws that bar over SwiftUI content, so a SwiftUI title in that strip renders nothing at all. And it has to be per-layout, since `.topBars` and `.hybrid` already put chips and tabs there.
- **`WindowChrome`.** Extracting the traffic-light metrics so a rail and the view beside it cannot drift apart. There is no `WindowChrome` on `main` today.
- **The rails' vertical rules cutting through the traffic-light strip.** Reported from a screenshot, not re-checked on `main` since, so confirm before fixing.

The bottom toolbar position was declined: a third layout axis on top of the three the spaces work already adds, and too many combinations to check by hand.

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
