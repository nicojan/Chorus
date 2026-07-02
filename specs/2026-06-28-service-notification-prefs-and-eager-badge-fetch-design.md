# Per-service notification preferences + eager badge fetch

**Date:** 2026-06-28
**Status:** Approved design (pending spec review)

## Summary

Two related improvements to Chorus's badge/notification system:

1. **Eager badge fetch on startup and login.** Today a freshly-launched or
   just-logged-in service shows no unread badge until the next poll tick (up to
   30s for preloaded services, 60s for hibernated ones, and non-active-space
   services aren't polled at all at launch). Make unread counts appear promptly:
   immediately after a page finishes loading, and across all spaces at startup.

2. **Per-service control over badges and OS notifications.** Let the user choose,
   per service, whether it shows an unread **badge** and whether it posts
   **macOS notifications** — as two independent switches, with the existing
   **Mute** acting as a master override.

This builds on existing machinery (`BadgeManager`, `NotificationManager`,
`HibernatedBadgePoller`, `UserScriptManager`) rather than replacing it.

## Goals

- Unread badges appear within ~1-2s of a service finishing load (startup *and*
  post-login), not after a full poll interval.
- Badges populate for services in **all** spaces at launch, so per-space
  aggregate badges in the space strip are correct immediately.
- A per-service "Send macOS notifications" toggle, independent of the badge
  toggle and of mute.
- Backward compatible: existing `isMuted` / `showBadge` behavior and the
  space→service mute cascade are unchanged.

## Non-goals

- Replaying missed notification *banners* for messages that arrived while the
  app was closed. Chorus only sees notifications live via the injected
  `window.Notification` hook; there is no missed-message history to replay. This
  feature is about unread **counts → badges**, not banners.
- Changing how unread counts are detected (title `(N)` parsing + per-service
  `badgeJS`) — that stays as-is.
- Per-service *sound* selection or notification styling.

## Current state (as built)

- **`ServiceInstance`** already has `isMuted: Bool` and `showBadge: Bool`.
- **`BadgeManager`** stores the true unread count per service and applies mute /
  `showBadge` as a non-destructive display *mask* (`maskedIDs`). The badge path
  already honors `showBadge` — no change needed there.
- **OS notifications** are produced by `UserScriptManager`, which injects a
  `window.Notification` hook; intercepted notifications go to
  `NotificationMessageHandler`, which posts to macOS Notification Center. It is
  gated on `!isServiceMuted && !DoNotDisturb`, where `isServiceMuted`
  (`AppState.swift:72`) is **effective** mute (own flag OR any parent space
  muted). There is **no** independent "notify OS" control — muting is the only
  way to silence OS notifications, and muting also hides the badge.
- **Polling** has three modes (`NotificationManager`): `active` (adaptive
  5s→30s, on-screen service), `background` (flat 30s, preloaded/soft-hibernated),
  and the separate `HibernatedBadgePoller` (60s URLSession title fetch for fully
  hibernated services; only updates when count > 0, never resets to 0).
- **Launch path:** `AppState` reaps orphans, restores window state, then
  `preloadActiveSpaceServices()` preloads only the **active space**. Preloaded
  services start a 30s background poll (`onServicePreloaded`). Services in other
  spaces get a `HibernatedBadgePoller` track only via `onServiceHibernated`
  (i.e. after they've been live and then hibernated) — so on a cold launch they
  have **no** polling and **no** badge.
- **`WebViewCoordinator`** is the `WKNavigationDelegate` (one per webview, also
  the delegate for OAuth popup webviews). It implements policy/decision, failure,
  and process-termination callbacks but **no `didFinish`**, and carries **no**
  instance identifier.

## Design

### 1. Data model: add `osNotificationsEnabled`

Add one field to `ServiceInstance`, stored **optional** with an effective
accessor — matching the codebase's established migration-safe pattern (`pageZoom`
/ `zoomLevelEffective`), so SwiftData lightweight migration succeeds on existing
rows without a custom migration plan:

```swift
/// Whether this service forwards its web notifications to macOS Notification
/// Center. Stored optional so SwiftData lightweight migration succeeds on
/// existing rows; nil is treated as enabled (the prior default behavior).
var osNotificationsEnabled: Bool?

/// nil → true (preserves the pre-feature behavior where any unmuted service
/// posted OS notifications).
var notifiesOSEffective: Bool { osNotificationsEnabled ?? true }
```

`init` gains `osNotificationsEnabled: Bool? = nil`. `isMuted` and `showBadge`
are untouched.

### 2. Decouple OS notifications from mute

Add an independent gate on the OS-notification path, leaving the badge path
alone.

- **`UserScriptManager`** gains a closure
  `var isServiceNotifyingOS: (@Sendable (UUID) -> Bool)?`, mirroring the existing
  `isServiceMuted` closure.
- **`NotificationMessageHandler`** gains a `notifyOSCheck: @Sendable (UUID) -> Bool`
  and a new guard in `userContentController(_:didReceive:)`, alongside the
  existing mute/DND guards:
  ```swift
  guard !isMutedCheck(serviceID) else { return }       // existing (effective mute)
  guard notifyOSCheck(serviceID) else { return }        // NEW
  guard !isDoNotDisturbCheck() else { return }          // existing
  ```
- **`AppState`** wires `userScriptManager.isServiceNotifyingOS` to read
  `notifiesOSEffective` for the service (same `MainActor.assumeIsolated` +
  fetch pattern as the existing `isServiceMuted` closure). A small
  `isServiceNotifyingOS(_:) -> Bool` helper mirrors `isServiceShowingBadge`.

Note: `notifyOS` is a **per-service** policy and is deliberately *not* part of
the space cascade — mute remains the cascading master override.

### Effective behavior

| Outcome | Rule |
|---|---|
| Badge visible | `showBadge && !effectivelyMuted` *(unchanged)* |
| macOS notification fires | `notifiesOSEffective && !effectivelyMuted && !DoNotDisturb` *(new gate)* |

`effectivelyMuted` = own `isMuted` OR any parent space muted (unchanged).

### 3. Eager badge fetch on startup and login

Four pieces:

**3a. `NotificationManager.pollNow(for:webView:isMuted:showBadge:catalogEntry:)`**
A one-shot immediate poll factored from the existing private `pollTitle` /
`pollBadge` logic: read `document.title` (and `badgeJS` if the catalog entry has
one) once and update `BadgeManager`. Does not start or alter the recurring poll
task.

**3b. `WebViewCoordinator` learns its instance + a finish callback**
- Add `var instanceID: UUID?` and
  `var onNavigationFinished: ((UUID) -> Void)?`.
- Implement `webView(_:didFinish:)`:
  - Ignore OAuth popups: `guard webView !== popupWebView`.
  - `guard let instanceID else { return }`
  - `onNavigationFinished?(instanceID)`
- `WebViewPool` sets `coordinator.instanceID` and `coordinator.onNavigationFinished`
  in **both** `webView(for:)` (line ~118) and `preload(_:)` (line ~161). The
  callback routes to `AppState`, which calls `notificationManager.pollNow(...)`
  for that instance's live webview with the live mute/showBadge closures.

This single mechanism fixes the primary complaint (badge missing right after
sign-in: the login redirect's `didFinish` triggers an immediate poll) **and**
the active/preloaded startup latency (badge appears on load completion instead of
after the 5s/30s tick).

Known acceptable edge: `didFinish` also fires after the in-webview error/recovery
page loads (`loadHTMLString`); polling its title yields 0, which the live poll
path already does today. Rare and self-correcting on the next real load.

**3c. `HibernatedBadgePoller` immediate first pass**
Today `ensurePolling()` sleeps a full `pollInterval` (60s) before the first
`pollAllTrackedServices()`. Fire one pass immediately when polling starts /
when a service is first tracked, guarded by `!isPaused` (so we don't fire while
offline or asleep). Existing "only update when count > 0, never reset to 0 /
respect showBadge" guards remain.

**3d. Launch tracking sweep (cross-space)**
After `preloadActiveSpaceServices()`, register every service that will **not**
have a live webview (i.e. not in the active space / not preloaded) with
`HibernatedBadgePoller` (with its current effective-mute / showBadge state), so
their badges populate at launch and feed the per-space aggregate badges. Stagger
registration (mirroring `preloadAll`'s 500ms spacing) to avoid a request burst.
When such a service is later opened, the existing `onServiceWoke` untracks it and
the live/background poll takes over (no double-polling).

### 4. UI

- **`SettingsView.swift`** — in the per-service section, add a **"Send macOS
  notifications"** toggle bound to `service.osNotificationsEnabled` (writing
  `true`/`false`), placed next to the existing **"Show unread badge"** toggle.
  Saving follows the existing `save("...")` pattern. Both represent the standing
  per-service policy.
- **`ServiceSidebarView.swift`** context menu — keep **"Mute Notifications"** as
  the quick master override (unchanged). Granular toggles live in Settings only,
  to avoid context-menu clutter.

## Migration

SwiftData lightweight migration only: `osNotificationsEnabled` is an optional
attribute with no default required on existing rows (nil → treated as enabled).
No `SchemaMigrationPlan` needed. Matches the `pageZoom` precedent.

## Testing

**Unit (no SwiftData / WebKit needed where possible):**
- Effective-rule truth table: for every combination of `showBadge`,
  `osNotificationsEnabled` (true/false/nil), `isMuted`, parent-space muted, and
  DND — assert badge-visible and OS-notify-fires match the table above.
- `notifiesOSEffective`: nil → true, false → false, true → true.
- `NotificationMessageHandler` gating: with a stub `notifyOSCheck` returning
  false, `didReceive` posts nothing; returning true (and unmuted, no DND) posts.
- `pollNow` updates `BadgeManager` exactly once for a given title (reuse the
  existing `extractBadgeCount` tests; assert no recurring task is created).

**Manual:**
- Cold launch with several signed-in services across multiple spaces → badges
  appear within ~1-2s on the active space's icons and on the space-strip
  aggregates for other spaces.
- Sign into a service → badge appears immediately on `didFinish` (not after 5s).
- Toggle "Send macOS notifications" off for a service → its badge still updates,
  but no banner appears; toggle on → banner returns.
- Mute (service or its space) → both badge and banner suppressed; unmute →
  both restored instantly.
- DND on → no banners regardless of per-service notifyOS; badges follow existing
  DND behavior.

## File-by-file change list

| File | Change |
|---|---|
| `Chorus/Models/ServiceInstance.swift` | Add `osNotificationsEnabled: Bool?` + `notifiesOSEffective`; init param. |
| `Chorus/Services/UserScriptManager.swift` | Add `isServiceNotifyingOS` closure; `NotificationMessageHandler` gains `notifyOSCheck` + guard. |
| `Chorus/App/AppState.swift` | Wire `isServiceNotifyingOS`; add `isServiceNotifyingOS(_:)` helper; route `onNavigationFinished` → `pollNow`; launch tracking sweep. |
| `Chorus/Services/NotificationManager.swift` | Add `pollNow(for:webView:isMuted:showBadge:catalogEntry:)`. |
| `Chorus/Services/HibernatedBadgePoller.swift` | Immediate first pass on track / poll start (guarded by `isPaused`). |
| `Chorus/Views/WebView/WebViewCoordinator.swift` | Add `instanceID` + `onNavigationFinished`; implement `webView(_:didFinish:)` (guard popups). |
| `Chorus/Views/WebView/WebViewPool.swift` | Set `coordinator.instanceID` + `onNavigationFinished` in `webView(for:)` and `preload(_:)`. |
| `Chorus/Views/Settings/SettingsView.swift` | Add "Send macOS notifications" per-service toggle. |
| `ChorusTests/...` | Effective-rule truth table, `notifiesOSEffective`, gating, `pollNow`. |

## Risks & decisions

- **Launch request burst (3d):** registering all non-active services at once
  could fire many URLSession requests. Mitigated by staggering and the existing
  ephemeral-session + task-group design; the poller is already paused when
  offline/asleep.
- **`didFinish` on error pages** can momentarily poll a 0 count on the live path
  (pre-existing behavior); accepted, self-corrects on next real load.
- **Scope call (3d):** cross-space startup population is the one expansion beyond
  the literal "active service" complaint; included because per-space aggregate
  badges are otherwise stale at launch. Can be deferred without affecting 1-3.
