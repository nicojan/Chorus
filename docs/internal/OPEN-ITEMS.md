# Open items

Nothing is open. The deferred work from the last handoff is done and on `main`.

Build and test: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`.
Reference commit: `7d33387`. Wider background lives in the review-backlog memory.

## Done this session

- **Top-bar tab drag (was uncommitted)** — kept. A tab drag reorders, the gap
  moves the window, a double-click on the gap zooms. Committed once tested by
  hand. `ServiceSidebarView`, `ServiceTabView`, `SpaceStripView`, `ContentView`.
- **Poll-task dual ownership (item 1)** — fixed. On a deep-link switch the
  outgoing service kept exactly one poll in background mode instead of going
  silent. `WebContentView` reconciles against the pool's `activeServiceID`
  (`NotificationManager.shouldStopOutgoingPoll`) rather than trusting the last
  writer. Covered by a unit test.
- **Swift 6 (item 2)** — done. `WebViewCoordinator` is `@MainActor`, and the
  language mode is on (`SWIFT_VERSION` 6.0 for both targets, in `project.yml`
  and the `.pbxproj`). Everything it surfaced is cleared: async `decidePolicyFor`
  and download-destination delegate methods, a Sendable-safe popup-title KVO
  read, `ServiceCatalog: Sendable`, a region-checker-safe `hasActiveCall`,
  `@MainActor` on `UserScriptManager` / `AppPresenceManager` /
  `NotificationCenterDelegate.retained`, and a `@MainActor` test class. A clean
  build and 48 tests pass with no warnings.
- **Rail keyboard navigation (item 6)** — added. Arrow along the rail's axis
  selects; ⌥+arrow reorders, reusing the VoiceOver move helpers. Both the
  spaces rail and the services rail. `ServiceSidebarView`, `SpaceStripView`.

## Standing product decisions (not open — recorded so they aren't re-raised)

- **Google favicon fallback** — kept on by default (`FaviconFetcher`).
- **Cookie-consent auto-accept** — kept on by default, with the setting reworded
  to state the trade-off plainly (`SettingsView`).
