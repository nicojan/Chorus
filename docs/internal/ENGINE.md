# ChorusEngine

ChorusEngine is Chorus's WebKit layer, pulled out into a Swift package so a second app can build on it. It holds the web view pool, navigation and pop-ups, permissions, hibernation, sign-in stores, user scripts, content blocking, Dark Reader, downloads and the network monitor. Chorus's own UI and its data model stay in the app. They never reach the package.

## Where it lives

`Package.swift` sits at the repo root and declares one library, `ChorusEngine`. Its sources are in `ChorusEngine/Sources/ChorusEngine` and its tests in `ChorusEngine/Tests/ChorusEngineTests`.

SwiftPM reads a manifest only from the root of a git repo, so the root is the one place another app can depend on it by URL. A separate repo would turn each engine change into two changes in two repos.

Folders:

- `Web/`: the pool, the navigation and UI delegate, tabs, pop-ups, the in-app browser window, the SwiftUI host view, page state, service health and `WebSurface`.
- `Services/`: sign-in stores, user scripts and the notification bridge, cookie banners, Dark Reader, downloads, the network monitor, and the content blocker.
- `Utilities/`: the logger, the user agent, a deadline helper and the IndexedDB write tracker used at quit.
- `Resources/`: `hagezi-light.json`, `fanboy-annoyance.json`, `darkreader.js`, `THIRD_PARTY_NOTICES.md` and `licenses/` (GPL-3.0, CC BY 3.0, Dark Reader's MIT).

## The boundary

Nothing in the package may import or name anything from Chorus's model layer: `ServiceInstance`, `Space`, `AppState`, `AppPreferences`, SwiftData, or the service catalog. The engine knows a page only as a `WebSurface`.

```swift
public struct WebSurface: Sendable, Equatable {
    public enum DataStore: Sendable, Hashable { case persistent(UUID) }
    public let id: UUID
    public let url: String
    public let dataStore: DataStore
    public let userAgent: String?
    public let css: String?
    public let darkThemed: Bool
    public let keepsLoaded: Bool
    public let staysActiveInBackground: Bool
    public let label: String
}
```

The app resolves every value before it hands a surface over. `css` is the effective CSS, and each Bool is the policy the app applies, after defaults and legacy flags. A surface is a snapshot built at the call: the engine never holds a model object and never reads one later.

## How Chorus wires it up

`project.yml` names the root as a local package (`ChorusEngine: path: .`) and the Chorus target depends on it. Run `xcodegen generate` after you change it. A second run must leave `project.pbxproj` unchanged.

`AppState.init` builds the engine objects (`DataStoreManager`, `UserScriptManager`, `ContentBlockerManager`, `WebViewPool`, `DownloadCenter`, `NetworkMonitor`) and wires their callbacks: link routing, notification checks, which services must stay live, hibernation events. That code did not change in the move.

The app side of the seam is `Chorus/Views/WebView/WebViewPool+Services.swift`:

- `ServiceInstance.webSurface` builds a surface. The store comes from `dataStoreIdentifier`, never the service's own id, because services share sign-in stores. `WebSurfaceTests` pins each mapping.
- `webView(for:)`, `preload(_:)`, `preloadAll(_:)`, `applyDarkState(isDark:services:)` and `refreshDarkMode(for:)` keep their service-shaped names, so `AppState` and the views call them as before.
- The checks that need the live model stay here: a deleted service, a Mac-app service, and the staggered `preloadAll` loop, which reads each service only when its turn comes.

`DarkReaderSupport.injection(mode:appDark:)` and the rail's health dot (`ServiceHealthDot.swift`) are Chorus extensions on engine types.

Notifications and badges (`NotificationManager`, `BadgeManager`, `HibernatedBadgePoller`) stay in Chorus. They carry app policy: the Dock badge, Do Not Disturb, mute, and the catalog's badge scripts. The engine's part is `NotificationMessageHandler`, which takes a web page's notification and posts it to macOS.

## Resources

Files in the package load through `Bundle.module`, which resolves to `ChorusEngine_ChorusEngine.bundle` inside the host app's `Contents/Resources`. A missed lookup does not crash: blocking turns off, or dark theming stops. Tests guard both sides:

- `BundledResourceTests` (package) loads every bundled file from the module bundle.
- `testBundledListsLoadFromThePackageBundleInsideTheApp` and `testDarkReaderLibraryLoadsFromThePackageBundleInsideTheApp` (app-hosted) load them from inside `Chorus.app`.

`scripts/convert_blocklist.sh` and `scripts/fetch_darkreader.sh` write straight into `ChorusEngine/Sources/ChorusEngine/Resources/`.

Licenses: the notices and license texts for the lists and Dark Reader are package resources, so any app using the engine ships them. `Chorus.app` still ships its own `LICENSE`, `THIRD_PARTY_NOTICES.md` and `licenses/` at the top of `Contents/Resources`, which Settings opens.

## Tests and CI

- App-hosted tests that touch engine internals use `@testable import ChorusEngine` next to `@testable import Chorus`. Debug builds the package with testability.
- `swift test` at the root runs the package tests. CI runs it in the "Engine package tests" step on macOS 14 and 15. Locally, give SwiftPM a scratch folder outside the repo so `.build` stays out of it (it is ignored anyway).
- CI's "Every Swift file belongs to a target" step scans only `Chorus` and `ChorusTests`. The package needs no such check: SwiftPM compiles every Swift file under the target folder.
- `Package.swift` stays at tools version 6.0, because CI's macOS 14 job builds with Xcode 16.2, which reads nothing newer.

## Public API

Public means Chorus calls it, or a WebKit or AppKit protocol requires it. Nothing is public for an app that might exist later. Delegate methods that WebKit requires to be public are left out of this list.

- `WebSurface`: the struct above, its `DataStore`, and an explicit `init` with the fields in order.
- `WebViewPool`:
  - `init(dataStoreManager:userScriptManager:contentBlocker:)`.
  - Building pages: `webView(for:)`, `preload(_:)`, `hasWebView(for:)`, `liveWebView(for:)`, `displayedWebView(for:)`, `allWebViews(for:)`, `tabs(for:)`, `snapshot(for:)`, `liveServiceIDs`, `liveWebViews`, `loadedCount`, `activeServiceID`.
  - Lifecycle: `removeWebView`, `recreateWebView`, `deactivateActiveService`, `closeTab`, `navigate`, `setUserAgent`, `forgetSuspendedURL`.
  - Hibernation: `hibernate`, `hibernateIfStillIdle`, `isHibernated`, `idleCandidates(now:)`, `pin`, `unpin`, `setNeverHibernate`.
  - Media and memory: `isPlayingAudio`, `pauseAudio`, `muteAllMicrophones`, `mediaCaptureStates` with `MediaCaptureState`, and `memoryReadings(now:)` with `MemoryReading`, `wouldRebuild`.
  - Appearance and blocking: `applyDarkState(isDark:surface:)`, `refreshDarkMode(for:)`, `reattachContentBlocker()`, `health(for:)`.
  - Callbacks the app sets: `onServiceHibernated`, `onServiceSoftHibernated`, `onServiceSoftWoke`, `onServiceRemoved`, `onServiceTornDown`, `onServicePreloaded`, `onNavigationFinished`, `isNotificationCritical`, `externalLinkHandler`, `serviceOwnsURL`, `mediaCapturePolicyProvider`, `downloadCenter`.
- `WebViewCoordinator` (statics only): `shouldOpenInAppBrowser`, `openExternally`, `reload(_:fallbackURL:)`, `looksLikeSignIn`, `belongsToService`, `isAuthHost`.
- `ServiceTabs` and `ServiceTab`: `tabs`, `selectedID`, `selectedTab`, `isEmpty`, `tab(for:)`, `add`, `select`, `selectOffset`, `remove`, `removeAll`; a tab's `id`, `webView`, `title`.
- `WebViewState`: `init()`, `attach(to:)`, `detach()`, `canGoBack`, `canGoForward`, `isLoading`, `currentURL`, `title`, `webView`.
- `WebViewContainer`: `init(webView:cornerRadius:)`. `WebViewHostView` is public because `WebViewContainer` returns it.
- `InAppBrowserWindow`: `open(_:)`.
- `ServiceHealth`: `live`, `loading`, `failed`, `signedOut`, `Event`, `next(_:)`.
- `DataStoreManager`: `init()`, `dataStore(for:)`, `dataStore(forIdentifier:)`, `evict(identifier:)`.
- `UserScriptManager`: `init()`, `isServiceMuted`, `isServiceNotifyingOS`, `isDoNotDisturbActive`, `serviceLabel`, `autoDismissCookieBanners`, and the statics `makeVisibilityOverrideScript()`, `quitReleaseJS`, `pendingWritesJS`.
- `NotificationMessageHandler`: `shouldPostOSNotification(isMuted:notifyOS:doNotDisturb:)`.
- `DarkReaderSupport`: `world`, `DarkInjection`, `injection(themed:appDark:)`.
- `ContentBlockerManager`: `init(adResource:annoyanceResource:isEnabled:annoyanceEnabled:)`, `isEnabled`, `annoyanceEnabled`, `onReady`, `enabledLists()`, `start()`.
- `DownloadCenter`: `init()`, `items` with `Item` and `State`, `serviceName`, `hasRunning`, `overallFraction`, `finish`, `cancel`, `clearFinished`, `reveal`, `open`.
- `NetworkMonitor`: `init()`, `isOnline`, `onChange`.
- `AppLogger`: `general`, `dataStore`, `webView`, `notifications`, `favicon`, `badges`, `ui`.
- `UserAgentProvider`: `safariDefault`, `mobileSafari`.
- `withDeadline(seconds:fallback:_:)`, `WriteSettle` (`init(quietWindow:)`, `observe(pending:stamp:at:)`), and `IndexedDBFiles` (`Stamp`, `storeDirectory(for:bundleID:)`, `stamp(under:)`).

## Using it from another app

Depend on this repo by URL and pin one release with `exact:`:

```swift
dependencies: [
    .package(url: "https://github.com/nicojan/Chorus.git", exact: "1.5.32"),
],
targets: [
    .target(name: "Browser", dependencies: [
        .product(name: "ChorusEngine", package: "Chorus"),
    ]),
]
```

The package is named after the repo, `Chorus`, so `.product` names `package: "Chorus"`. SwiftPM clones the whole repo, about 7 MB.

Pin `exact:`, not `upToNextMinor` or `from:`. Engine versions are Chorus's release tags, and a Chorus patch release can change the engine API. Read the list below before you move the pin.

A spike checked this end to end. A package outside the repo, depending on the engine by path and by `file://` URL, built a web view through `WebViewPool` on a persistent store and ran. It imported nothing but `ChorusEngine` and WebKit.

To make a page, build a `WebSurface` and ask the pool for it. The engine does not yet build a page on a throwaway store: `WebSurface.DataStore` has only `.persistent`. A browser's throwaway container tabs need a `.nonPersistent` case first.

## Tags and versions

Engine versions are Chorus's own release tags, `v1.5.32` and on. SwiftPM reads `v`-prefixed semver tags as versions, so the app tags serve the engine too. Tags such as `engine-1.0.0` do not work: SwiftPM rejects them as "Invalid semantic version string", which leaves pinning by commit as the only way to use them. An app-only release moves the engine's version without changing it, and that does no harm.

## Engine API changes by release

List every change to the public API here, under the release that ships it, including additions. Another app reads this before moving its pin.

- **1.5.32**: First release as a package. The API above is the starting point. Before it, the same code lived in the app target and took `ServiceInstance` where it now takes `WebSurface`.

## Names to parameterize for other apps

These still say Chorus. They were left as they are so Chorus does not change in the move. Another app sees them until each becomes a parameter.

- **User-facing text.**
  - `WebViewCoordinator.swift`: the failed-reload message ("Chorus stopped reloading it automatically to avoid a loop…") and the pop-up window title fallback (`"Chorus"`).
  - `InAppBrowserWindow.swift`: the window title fallback (`"Chorus"`).
- **The logger.** Subsystem `com.nicojan.Chorus`, categories General, DataStore, WebView, Notifications, Favicon, Badges and UI. Another app's log lines would land under Chorus's subsystem. The log recipes in these docs filter on it.
- **JavaScript globals.** `__chorusActiveCall`, `__chorusCallFrames`, `__chorusPendingWrites` and `__chorusReleaseForQuit` sit in the page's own content world, so every page can see them. `__chorusCoverDismiss` sits in Dark Reader's isolated world, and pages cannot see it.
- **The message handler.** `chorusNotification` is visible to pages as `window.webkit.messageHandlers.chorusNotification`.
- **Element ids** the engine puts in pages: `chorus-custom-css`, `chorus-dr-antiflash` and `chorus-retry`.
- **The content world** `ChorusDarkReader`.
- **The rule-list ids.** They are named after the list files: `hagezi-light-<n>-<hash>` and `fanboy-annoyance-<n>-<hash>`. `ContentBlockerManager` removes stale lists by those prefixes from WebKit's default rule-list store. That store is per app, so two apps do not touch each other's lists. Changing a prefix strands the old compiled lists on disk.

Changing any of these in Chorus itself also changes Chorus's behavior. The quit path calls `__chorusPendingWrites` and `__chorusReleaseForQuit`, and the docs filter on the logger subsystem. Treat each change as a feature and test it.
