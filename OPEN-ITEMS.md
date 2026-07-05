# Open items after 1.2.1

These are the issues and decisions left after the 1.2.1 review, on purpose. Each
was either a risky refactor or a call for Nico to make. This file is the starting
point for a fresh session: read the item, confirm the code still matches (line
numbers drift), then work it behind the build and tests.

Build and test: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`.
Reference commit: 1.2.1 (`ab35d6d`). Wider background lives in the review-backlog
memory.

## Correctness and concurrency

### 1. Dual ownership of the poll tasks

Two places write `NotificationManager.pollTasks` for the same service, so their
order decides whether a service keeps polling.

- Where: `NotificationManager.startPolling`/`stopPolling` (`NotificationManager.swift:36,126`),
  the `WebContentView` load path (stop-then-start), and the pool's
  soft-hibernation callback (`AppState.swift:1015` wiring `onServiceSoftHibernated`
  to `startBackgroundPolling` at `AppState.swift:1050`). `AppState.switchToService`
  (`AppState.swift:239`) calls `webViewPool.webView(for:)` itself, which fires the
  hibernation callback before `WebContentView`'s `onChange` runs.
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

### 2. Swift 6 concurrency: models crossing actor boundaries

`fetchService` hands a SwiftData model out of the main actor to nonisolated
callers, which the compiler flags. This is the one warning left on the build.

- Where: `AppState.fetchService` (`AppState.swift:344`) returns `ServiceInstance?`
  from `MainActor.assumeIsolated`. `WebViewCoordinator` (`WebViewCoordinator.swift:5`)
  is `@unchecked Sendable` instead of `@MainActor`, which papers over the same
  class of problem.
- Approach: reshape `fetchService` to run a closure on the main actor and return
  only Sendable values, so the model never leaves the actor. Update the callers
  (the mute, notify, and show-badge closures). Then look at making the coordinator
  `@MainActor` and dropping `@unchecked Sendable`. Turning on the Swift 6 language
  mode is the goal that proves the work.
- Risk: medium. Concurrency changes are easy to get subtly wrong, so exercise the
  fix with the app running and confirm the behavior beyond a clean build.
- Done when: the build has no warnings and, ideally, compiles under the Swift 6
  language mode.

## Decisions for Nico

### 3. Favicon fallback reaches out to Google

When a service has no icon of its own, the fetcher asks Google for one, which
sends the service host to a third party.

- Where: `FaviconFetcher.swift:35` (`https://www.google.com/s2/favicons?domain=...`).
- Options: drop the Google step and fall back to a generated letter tile, or keep
  it behind a setting that is off by default. Either sits better with a
  privacy-first app than the current always-on behavior.
- Decision needed: which option, and the default.

### 4. Cookie banners are auto-accepted

The injected script accepts cookie-consent dialogs, advertising and tracking
cookies included, on the user's behalf. It is on by default.

- Where: `CookieConsentManager.makeConsentDismissalScript` (`CookieConsentManager.swift:4`);
  default set at `AppState.swift:939` and `AppPreferences.swift:88`.
- Options: reject or dismiss where a site offers the choice, flip the default off,
  or reword the setting so the trade-off is plain.
- Decision needed: the behavior and the default.

## Polish and features

### 5. Snapshot can distort during the load transition

The cached snapshot shown while a page loads uses fill mode, which can crop or
stretch it, and it is not always cleared when the load finishes.

- Where: `WebContentView.swift:45` (`.aspectRatio(contentMode: .fill)`); the
  snapshot is set at `WebContentView.swift:99`.
- Approach: use fit mode or match the web view's size, and clear the snapshot once
  the load completes.
- Risk: low, and visual only.

### 6. Keyboard navigation for the rails

The spaces and services rails support VoiceOver move actions but have no arrow-key
selection or reorder for sighted keyboard users.

- Where: `ServiceSidebarView.swift`, `SpaceStripView.swift`.
- Approach: add focus and arrow-key handling for selection, plus a
  modifier-and-arrow reorder that reuses `ServiceReorder`.
- Risk: low to medium. Scope it as a feature and plan the focus handling up front.
