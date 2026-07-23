# Open items

## Current status — through 1.5.10 (2026-07-22)

Everything below has shipped. **Chorus 1.5.10 is the current release**, a
one-fix patch: the selected space in the sidebar no longer draws a stray system
focus outline on top of its own highlight (a doubled box the narrow strip
clipped). It sits on **1.5.9**: opt-in
auto-hibernation of idle services, a per-service option to open outside links in
a Chorus window, Dark Reader narrowed to a manual per-service On/Off (all
auto-detection, the probe, the theme cache, and the global toggle removed),
reader mode removed entirely, and a round of security and reliability fixes
(link-routing host matching, the favicon-redirect SSRF guard, the chat-stays-live
cap-eviction gap, a Move-to-Space crash guard).

The one genuinely open item is **PR #10** (opt-in spaces hiding, a bottom nav
bar, and a window title), tabled pending a UX pass on the rail/title/service-name
story — the window title does not render on macOS 26 and duplicates the
highlighted rail icon.

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
