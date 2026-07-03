# Changelog

All notable changes to Chorus are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

## [1.0.2] - 2026-07-02

### Fixed

- A service that opens sign-in in a separate window (for example, Gmail) now
  reloads and shows the signed-in page after that window closes.

### Changed

- Chorus now checks for updates automatically on a daily schedule, without
  asking on first launch.

## [1.0.1] - 2026-07-02

### Fixed

- Closing a service's sign-in window (for example, Gmail opening its login in a
  separate window) no longer crashes the app.
- A space icon no longer stays dimmed after you drag it and let go, including
  when you drop it back onto itself.
- An emoji chosen from "More Emoji…" now becomes the space's emoji instead of
  landing in the search field.
- "Check for Updates…" now appears in the Chorus app menu.

## [1.0.0] - 2026-07-02

### Fixed

- **Crash cleaning up orphaned data stores.** Launch-time (and post-delete)
  removal of a deleted service's `WKWebsiteDataStore` ran on a background thread,
  but WebKit's data-store registry is main-thread-only; removing a
  still-registered store trapped inside WebKit and crashed the app. Cleanup now
  runs on the main actor.
- **Badge counts no longer lost when muting/un-muting a service.** `BadgeManager`
  stored `0` for muted or badge-disabled services, destroying the real unread
  count. Un-muting left the badge at `0` until the next poll tick (up to 30s, or
  never for a fully hibernated service), and the adaptive title-poll backoff
  could never reset to fast polling for a muted service. The true count is now
  stored unconditionally and mute/show-badge is applied as a display mask.
- **Deleting a space no longer orphans services or leaks their data.** Services
  that lived only in the deleted space were left behind as invisible records
  whose per-service `WKWebsiteDataStore` leaked on disk forever. Space deletion
  now reclaims orphaned services (web view torn down, record deleted, data store
  scheduled for removal), and a launch-time reaper sweeps any pre-existing
  orphans. Fixed a related lost-update race in the orphaned-data-store cleanup.
- **Duplicate `Cmd-F` binding removed.** A legacy `window.find()` search bar in
  the toolbar bound the same shortcut as the native find bar; the two resolved
  nondeterministically. The native find bar (with match navigation) is now the
  single `Cmd-F` target.
- **Stale active-service pointer after deletion.** Permanently removing a web
  view left `activeServiceID`, pin/never-hibernate sets, and the notification
  script handler dangling, breaking the next keyboard shortcut and leaking
  handlers across create/delete cycles.
- **Eviction could tear down the service you just switched to** if the switch
  happened during the pool's async WebRTC-call check. Eviction now re-validates
  active/pinned/never-hibernate state after that suspension point.
- **`.gitignore` now excludes `xcuserdata` at any depth** (the previous pattern
  was anchored to the repo root, so nested workspace user-state stayed tracked).
- **WebContent crash loop broken.** A page that crashed deterministically was
  reloaded forever; Chorus now backs off after 3 crashes in 30s and shows a
  recovery page. The connection-error page's "Try Again" reloaded `about:blank`
  (it ran `location.reload()` against a `baseURL:nil` document); it now
  loads the actual failing URL, captured from the error.
- **Notification taps are no longer dropped** when they arrive before the
  handler is wired (e.g. a notification launching the app). They're buffered and
  drained, and tapping one now switches to a space that contains the service so
  the selection is visible.
- **Hibernated-poller cookie matching follows RFC 6265** path rules (it no
  longer matches request `/foobar` against cookie `/foo`).
- **Badge counts now surface for services that gate their title on Page
  Visibility** (WhatsApp, Messenger, Discord, …). Preloaded/off-screen web views
  report as visible so their unread count still reaches the badge poller; focus
  is left untouched, so focus-gated desktop notifications keep firing.

### Added

- **Per-service macOS notification control.** A new "macOS Notifications" toggle
  (Settings) lets each service forward its web notifications to macOS Notification
  Center independently of its unread badge. Previously muting was the only way to
  silence a service's banners, which also hid the badge. Mute now stays the master
  override (it silences both and still cascades from spaces), while badge and
  banner are separate standing choices. Stored as an optional flag (defaults to
  enabled) for safe SwiftData lightweight migration.
- **Badges populate immediately on startup and after login.** Unread counts now
  appear the moment a service's page finishes loading (including the post-login
  redirect) instead of waiting up to a poll interval, and a one-shot launch sweep
  fetches counts for services outside the active space so per-space aggregate
  badges are correct right away.
- **Edit a service.** A new Edit Service sheet (service context menu) renames a
  service or changes its URL, and the live web view follows along. It also
  toggles "Keep loaded in the background" (surfacing the previously-unreachable
  never-hibernate flag) and offers "Clear session (log out)", which wipes the
  service's cookies and storage without deleting it or its place in any space.
- **Clearer empty states.** The content area now distinguishes "no spaces", "a
  space with services but none selected", and "an empty space"; the last offers
  an Add Service button.
- **Reveal in Finder** on the store-error banner, so users can back up or remove
  a corrupt data file themselves (Chorus never deletes it for them).
- **Passkey-unavailable notice** in the Add Service sheet. WKWebView can't do
  WebAuthn without the Apple-managed web-browser public-key-credential
  entitlement, so a calm inline note steers users to password + 2FA. Gated by a
  single `AppCapabilities.passkeysSupported` flag to flip once the entitlement
  is granted.
- **Polling pauses while offline and resumes on reconnect.** `NetworkMonitor`
  connectivity changes now suspend all polling (active, background, hibernated)
  instead of firing doomed requests, and resume promptly when the network
  returns. The same suspend/resume path also covers system sleep/wake, which
  previously left the hibernated-service poller running through sleep.

### Performance

- **Per-identifier `WKWebsiteDataStore` caching.** The hibernated poller built a
  fresh store every 60s per service and DataStoreManager rebuilt one per web
  view; both now reuse a cached instance, avoiding churn and macOS-26 WebKit
  fragility.
- **No more whole-table fetches on hot paths.** The mute/show-badge/catalog
  lookups (run per poll tick, and per sidebar row per render) fetched every
  service and scanned by id; they now use a single predicate + `fetchLimit: 1`
  lookup, and the sidebar computes mute state from the in-hand model object.

### Earlier polish (same review pass)

- Custom-service input validation extracted into a tested pure function
  (rejects empty labels, non-`http(s)` schemes, and hostless URLs).
- Drag-to-reorder services now drops before/after the target based on cursor
  position rather than always-before.
- Favicon `<link>` parser hardened: attribute-order independent, resolves
  relative URLs via `URLComponents`, and picks the largest declared icon size.
- Toolbar progress bar slot is height-reserved so the toolbar no longer shifts
  when loading starts/stops; web view state is seeded/reset on attach/detach.
- Dock and per-space chip badges refresh immediately on mute / show-badge
  toggles instead of waiting for the next poll tick.

### Tests

- Added unit coverage for badge mute/un-mute count preservation, masked
  aggregation, and Do-Not-Disturb; orphaned-service detection; custom-service
  validation; favicon parsing; service reorder placement; WebContent crash
  backoff; error-page retry-URL escaping; and RFC 6265 cookie matching.
- Verified via `xcodebuild test -scheme Chorus -destination 'platform=macOS'`
  (21 tests passing), plus a launch smoke test (no startup crash, clean quit).
