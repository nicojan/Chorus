# Changelog

All notable changes to Chorus are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed

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

### Added

- **Polling pauses while offline and resumes on reconnect.** `NetworkMonitor`
  connectivity changes now suspend all polling (active, background, hibernated)
  instead of firing doomed requests, and resume promptly when the network
  returns. The same suspend/resume path also covers system sleep/wake, which
  previously left the hibernated-service poller running through sleep.

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
  validation; favicon parsing; and service reorder placement.
- Verified via `xcodebuild test -scheme Chorus -destination 'platform=macOS'`
  (15 tests passing).
