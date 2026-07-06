# Open items

Starting point for a fresh session: read the item, confirm the code still
matches (line numbers drift), then work it behind the build and tests.

Build and test: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`.
Reference commit: `37d35f6`. Wider background lives in the review-backlog memory.

## Uncommitted: top-bar drag fix (needs your manual test)

The working tree has an uncommitted change that stops a top-bar tab drag from
moving the window. A driven drag test confirmed it end to end, but it wants your
hands-on check before it lands.

- Files: `ServiceSidebarView.swift`, `ServiceTabView.swift`, `SpaceStripView.swift`,
  `ContentView.swift`.
- What it does: service tabs in the top-bar and hybrid layouts are now icon-only
  (the name shows on hover). A gap fills the strip between the tabs and the nav
  buttons. In those two layouts the OS window drag is off
  (`WindowMovableConfigurator` sets `isMovable = false`), so a tab or chip drag
  reorders instead of moving the window; the gap moves the window through an
  explicit `WindowDragHandle` that calls `performDrag`, and a double-click on the
  gap zooms. The sidebar layout is unchanged.
- Why this shape: the top 32px is the title-bar drag band. A tab sitting there
  was read as a title-bar drag, and the SwiftUI container AppKit hit-tests there
  reports itself as movable; a blocker nested in the `ScrollView` is never
  reached. Turning the OS drag off and adding explicit drag handles is the
  reliable fix, the way Chrome handles its tab strip.
- Test: run the app, switch to Top bars or Hybrid in Settings, then drag a
  service icon (it should reorder, not move the window), drag the gap (it should
  move the window), and double-click the gap (it should zoom).
- Then: commit it if it holds, or drop it with `git checkout --` on the four
  files if it does not.

## Remaining

### 1. Dual ownership of the poll tasks

Two places write `NotificationManager.pollTasks` for the same service, so their
order decides whether a service keeps polling.

- Where: `NotificationManager.startPolling`/`stopPolling`
  (`NotificationManager.swift:36,126`), the `WebContentView` load path
  (stop-then-start), and the pool's soft-hibernation callback
  (`AppState.swift` wiring `onServiceSoftHibernated` to `startBackgroundPolling`).
  `AppState.switchToService` calls `webViewPool.webView(for:)` itself, which fires
  the hibernation callback before `WebContentView`'s `onChange` runs.
- Symptom: on a deep-link switch, the outgoing service is left soft-hibernated
  with no poll task, so its title and DOM badge go stale until it is re-selected
  or evicted. A normal sidebar switch is fine, because there the order is
  stop-then-re-add.
- Approach: give one owner authority over `pollTasks`. Either stop
  `switchToService` from calling `webView(for:)` and let `WebContentView` drive
  it, or have `startPolling`/`stopPolling` reconcile the mode against the pool's
  `activeServiceID` rather than trusting the last writer.
- Risk: medium. It touches the live polling path, so cover it with a test that
  reproduces the deep-link order.
- Done when: after a deep-link switch, the outgoing service holds exactly one
  poll task in the right mode, and the incoming one polls in active mode.

### 2. Swift 6 concurrency: the rest

The model-across-actor warning is fixed. `fetchService` is main-actor only, and
a nonisolated `withService(id:)` runs a closure on the actor and hands back only
Sendable values, so the SwiftData model never crosses the boundary. The build is
warning-free. Two pieces remain:

- `WebViewCoordinator` is `@unchecked Sendable` instead of `@MainActor`
  (`WebViewCoordinator.swift:5`). Its WebKit delegate callbacks run on the main
  thread, so `@MainActor` should fit; dropping `@unchecked Sendable` proves it.
- The Swift 6 language mode is still off. Turning it on is the goal that proves
  the concurrency work. Expect it to surface more to fix.

### 6. Keyboard navigation for the rails

The spaces and services rails support VoiceOver move actions but have no arrow-key
selection or reorder for sighted keyboard users.

- Where: `ServiceSidebarView.swift`, `SpaceStripView.swift`.
- Approach: add focus and arrow-key handling for selection, plus a
  modifier-and-arrow reorder that reuses `ServiceReorder`.
- Risk: low to medium. Scope it as a feature and plan the focus handling up
  front.

## Done this session (for the record)

- **Swift 6 model-across-actor warning** — fixed (see item 2 above). Build is
  warning-free.
- **Cookie-banner setting (was item 4)** — Nico chose to keep the auto-accept
  and reword the setting. It now states the trade-off plainly; behavior is
  unchanged. `SettingsView.swift`.
- **Load-transition snapshot (was item 5)** — fixed. It fills the web view's
  frame instead of aspect-fill, and clears once the page loads.
  `WebContentView.swift`.
- **Favicon fallback to Google (was item 3)** — Nico chose to keep it on by
  default. No change; recorded so it is not re-raised.
