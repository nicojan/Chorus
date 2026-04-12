# Chorus — Architecture Document v2

> **Purpose**: This document is the complete specification for building Chorus, a macOS app that unifies web-based services (Gmail, Slack, Outlook, social media, etc.) into a single window with fully sandboxed, persistent sessions per account. It leverages WebKit for Safari-grade memory efficiency on Apple Silicon.
>
> **Target audience**: Claude Code (or any developer) implementing the app from scratch.

---

## 1. Product Overview

### What Is Chorus?

Chorus is a native macOS application — a Rambox/Franz alternative — that uses `WKWebView` (WebKit) instead of Chromium. Each service instance runs in its own sandboxed web session with isolated cookies, localStorage, and credentials. Users can run multiple accounts of the same service simultaneously (e.g., two Gmail accounts, three Slack workspaces) without them interfering with each other.

### Why WebKit?

On Apple Silicon, WebKit processes share optimization with Safari: unified memory architecture, efficient content blockers, and lower baseline memory per tab compared to Electron/Chromium. A user running 10+ services will see meaningfully lower memory usage.

### Core Value Proposition

- **One app, all accounts** — Gmail ×2, Slack ×3, Outlook, Twitter, Discord, all in one sidebar.
- **Each account is fully isolated** — own cookies, own login, own session. No cross-contamination.
- **Native macOS citizen** — notifications, keyboard shortcuts, menu bar support, App Store distribution.
- **Lightweight** — WebKit on Apple Silicon, not Chromium.

---

## 2. Technical Requirements

| Requirement         | Value                              |
|---------------------|------------------------------------|
| Platform            | macOS 14.0+ (Sonoma)               |
| Architecture        | Apple Silicon (arm64), Intel (x86_64) via Universal Binary |
| UI Framework        | SwiftUI                            |
| Web Engine          | WKWebView (WebKit)                 |
| Data Persistence    | SwiftData                          |
| Distribution        | Mac App Store                      |
| Sandboxing          | Required (App Sandbox entitlement) |
| Language            | Swift 5.9+                         |
| Minimum Xcode       | 15.0+                              |

---

## 3. Architecture Overview

### 3.1 High-Level Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                          Chorus.app                              │
│                                                                  │
│  ┌────────┐ ┌──────────┐ ┌────────────────────────────────────┐  │
│  │ Space  │ │ Service  │ │         Content Area               │  │
│  │ Strip  │ │ Sidebar  │ │  ┌──────────────────────────────┐  │  │
│  │        │ │          │ │  │     WKWebView Instance       │  │  │
│  │  🏢   │ │ [Gmail]  │ │  │  (WKWebsiteDataStore A)      │  │  │
│  │  🏠   │ │ [Slack]  │ │  │  (WKProcessPool A)           │  │  │
│  │  🎮   │ │ [Outlook]│ │  │                               │  │  │
│  │        │ │          │ │  │  Isolated: cookies, storage, │  │  │
│  │  [+]  │ │          │ │  │  IndexedDB, cache, processes  │  │  │
│  │        │ │          │ │  └──────────────────────────────┘  │  │
│  └────────┘ └──────────┘ │                                    │  │
│   ~44px      ~60px       │  ┌──────────────────────────────┐  │  │
│                          │  │  Toolbar: ← → ↻  ▓▓▓░░ 🔍   │  │  │
│                          │  └──────────────────────────────┘  │  │
│                          └────────────────────────────────────┘  │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │                    Services Layer                            ││
│  │  NotificationManager · BadgeAggregator · WebViewPool ·      ││
│  │  ServiceCatalog · KeyboardRouter · AppPresenceManager        ││
│  └──────────────────────────────────────────────────────────────┘│
│                                                                  │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │                  SwiftData Persistence                       ││
│  │  ServiceInstance · Space · SpaceServiceLink · AppPreferences  ││
│  └──────────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────┘
```

### 3.2 Two-Tiered Navigation Model

The UI uses a **Discord/Slack-style** two-column navigation:

1. **Space Strip** (far left, ~44px wide): A narrow vertical strip of system emoji icons. Each emoji represents a user-defined "Space" (e.g., 🏢 Work, 🏠 Personal, 🎮 Gaming). A `[+]` button at the bottom creates a new space.

2. **Service Sidebar** (second column, ~60px wide): Shows the service icons belonging to the currently selected space. Clicking a service icon loads its `WKWebView` in the content area.

3. **Content Area** (remaining width): The active `WKWebView`, with a minimal toolbar above it.

**Key behavior**: A `ServiceInstance` can appear in **multiple spaces** as an alias. The underlying web view and data store are shared — selecting "Work Gmail" in 🏢 and "Work Gmail" in 🏠 shows the exact same session. Spaces are organizational views, not isolation boundaries.

### 3.3 Module Decomposition

```
Chorus/
├── App/
│   ├── ChorusApp.swift              # @main entry, Scene definitions
│   ├── AppDelegate.swift            # NSApplicationDelegate for menu bar, dock control
│   └── AppSettings.swift            # Global preferences
│
├── Models/                          # SwiftData models
│   ├── ServiceInstance.swift         # A single account/service (URL, data store ID, etc.)
│   ├── Space.swift                   # A named space with a system emoji
│   ├── SpaceServiceLink.swift        # Many-to-many: which services appear in which spaces
│   ├── ServiceCatalogEntry.swift     # Curated service definition
│   └── AppPreferences.swift          # Persisted user preferences
│
├── Views/
│   ├── MainWindow/
│   │   ├── ContentView.swift         # Root: space strip + sidebar + detail
│   │   ├── SpaceStripView.swift      # Far-left emoji column
│   │   ├── ServiceSidebarView.swift  # Service icons for selected space
│   │   ├── ServiceIconView.swift     # Individual icon + badge overlay
│   │   └── WebContentView.swift      # Toolbar + WKWebView container
│   │
│   ├── WebView/
│   │   ├── WebViewContainer.swift    # NSViewRepresentable — returns pre-existing WKWebView
│   │   ├── WebViewCoordinator.swift  # WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler
│   │   └── WebViewPool.swift         # Owns all WKWebView instances, manages lifecycle
│   │
│   ├── AddService/
│   │   ├── AddServiceSheet.swift     # Modal: catalog browser + custom URL input
│   │   └── CatalogGridView.swift     # Grid of curated services with search
│   │
│   ├── SpaceEditor/
│   │   ├── SpaceEditorSheet.swift    # Create/edit space: pick emoji + name
│   │   └── EmojiPickerView.swift     # System emoji grid picker
│   │
│   ├── Settings/
│   │   ├── SettingsView.swift        # Preferences window root
│   │   ├── GeneralSettingsView.swift     # Dock/menu bar mode, launch at login
│   │   ├── NotificationSettingsView.swift # Per-service mute toggles
│   │   └── ServiceSettingsView.swift     # Per-service: user agent override
│   │
│   └── MenuBar/
│       └── MenuBarView.swift         # Menu bar extra with quick-switch menu
│
├── Services/
│   ├── DataStoreManager.swift        # Creates/manages WKWebsiteDataStore per instance
│   ├── ProcessPoolManager.swift      # Creates/manages WKProcessPool per instance
│   ├── NotificationManager.swift     # Polling + legacy API bridge, muting logic
│   ├── BadgeManager.swift            # Extracts badge counts, aggregates for dock
│   ├── KeyboardShortcutManager.swift # ⌘1–⌘9 switching, custom shortcuts
│   ├── ServiceCatalog.swift          # Bundled JSON catalog + icon assets
│   ├── UserScriptManager.swift       # Notification/badge injection scripts (internal only)
│   └── AppPresenceManager.swift      # Dock/menu bar visibility toggling
│
├── Utilities/
│   ├── FaviconFetcher.swift          # Downloads and caches favicons for custom URLs
│   └── UserAgentProvider.swift       # Provides appropriate user agent strings
│
└── Resources/
    ├── ServiceCatalog.json           # Curated service definitions
    ├── Assets.xcassets/              # App icon, curated service icons
    └── NotificationScripts/          # Built-in JS for notification/badge detection
```

---

## 4. Data Models (SwiftData)

### 4.1 ServiceInstance

The core entity. Each instance has its own isolated web session.

```swift
@Model
final class ServiceInstance {
    @Attribute(.unique) var id: UUID
    var label: String                    // User-facing name, e.g. "Work Gmail"
    var url: String                      // Starting URL, e.g. "https://mail.google.com"
    var customIconData: Data?            // User-uploaded icon (optional)
    var catalogEntryID: String?          // Reference to curated catalog entry (if applicable)
    var isMuted: Bool                    // Notification mute toggle
    var userAgent: String?              // Override user agent (nil = Safari default)
    var dataStoreIdentifier: UUID        // Maps to WKWebsiteDataStore(forIdentifier:)

    // Reverse relationship for space links
    @Relationship(inverse: \SpaceServiceLink.service)
    var spaceLinks: [SpaceServiceLink]

    var createdAt: Date
    var lastAccessedAt: Date
}
```

### 4.2 Space

A named organizational container with a system emoji.

```swift
@Model
final class Space {
    @Attribute(.unique) var id: UUID
    var name: String                     // e.g. "Work", "Personal"
    var emoji: String                    // System emoji, e.g. "🏢", "🏠", "🎮"
    var sortOrder: Int                   // Position in the space strip

    @Relationship(deleteRule: .cascade)
    var serviceLinks: [SpaceServiceLink]

    var createdAt: Date
}
```

### 4.3 SpaceServiceLink

Many-to-many join entity. A service can appear in multiple spaces.

```swift
@Model
final class SpaceServiceLink {
    @Attribute(.unique) var id: UUID
    var sortOrder: Int                   // Position of this service within the space

    @Relationship var space: Space
    @Relationship var service: ServiceInstance

    // Convenience: when deleting a space, links are cascade-deleted.
    // When deleting a service, links are also removed, but this must be
    // set up via the ServiceInstance side as well.
}
```

**Key invariant**: Deleting a `SpaceServiceLink` only removes the alias — it never deletes the `ServiceInstance` or its data store. Deleting a `ServiceInstance` removes all its links and wipes its `WKWebsiteDataStore`.

### 4.4 AppPreferences

```swift
@Model
final class AppPreferences {
    var id: UUID                         // Singleton — only one row
    var appPresenceMode: AppPresenceMode // .dock, .menuBar, .both
    var launchAtLogin: Bool
    var globalKeyboardShortcutsEnabled: Bool
    var showBadgeCountInDock: Bool
    var selectedSpaceID: UUID?           // Restore last-selected space on launch
    var selectedServiceID: UUID?         // Restore last-selected service on launch
}

enum AppPresenceMode: String, Codable {
    case dock
    case menuBar
    case both
}
```

---

## 5. Core Subsystems — Detailed Design

### 5.1 Session Isolation — Data Store + Process Pool (CRITICAL)

**This is the most important subsystem. Isolation correctness is non-negotiable.**

Each `ServiceInstance` gets two dedicated resources:

1. **`WKWebsiteDataStore(forIdentifier:)`** (macOS 14+) — isolates cookies, localStorage, IndexedDB, HSTS, cache, and service workers.
2. **Its own `WKProcessPool`** — isolates web content processes, preventing same-origin cross-talk (e.g., `BroadcastChannel`, `SharedWorker`) between two instances of the same service.

```swift
final class DataStoreManager {
    func dataStore(for instance: ServiceInstance) -> WKWebsiteDataStore {
        return WKWebsiteDataStore(forIdentifier: instance.dataStoreIdentifier)
    }

    func deleteDataStore(for instance: ServiceInstance) async throws {
        try await WKWebsiteDataStore.remove(forIdentifier: instance.dataStoreIdentifier)
    }
}
```

```swift
final class ProcessPoolManager {
    private var pools: [UUID: WKProcessPool] = [:]

    /// Returns a dedicated process pool for a service instance.
    /// Each instance gets its own pool to guarantee full isolation,
    /// even when two instances load the same origin (e.g., two Gmails).
    func processPool(for instanceID: UUID) -> WKProcessPool {
        if let existing = pools[instanceID] { return existing }
        let pool = WKProcessPool()
        pools[instanceID] = pool
        return pool
    }

    func removePool(for instanceID: UUID) {
        pools.removeValue(forKey: instanceID)
    }
}
```

**Memory impact**: Per-instance process pools cost ~30–50 MB each. With 10 services, expect 600–900 MB RSS total. This is still significantly lower than Chromium (typically 1.5–2 GB for the same workload).

**App Sandbox note**: `WKWebsiteDataStore(forIdentifier:)` stores data in `~/Library/WebKit/WebsiteDataStore/<UUID>/`, which is outside the app container. WebKit manages access transparently under App Sandbox, but this must be verified during TestFlight testing before App Store submission.

### 5.2 WebView Pool & Lifecycle

**Critical SwiftUI constraint**: `NSViewRepresentable.makeNSView()` can be called multiple times by SwiftUI when view identity changes. If the WKWebView is created inside `makeNSView`, SwiftUI can destroy and recreate it, losing the user's logged-in session, scroll position, and in-progress work.

**Solution**: The `WebViewPool` owns all WKWebView instances. The `NSViewRepresentable` never creates a WKWebView — it only retrieves a pre-existing one from the pool.

```swift
@Observable
final class WebViewPool {
    private var webViews: [UUID: WKWebView] = [:]  // instanceID → WKWebView
    private var lastAccessTimes: [UUID: Date] = [:]
    private let maxLoaded: Int = 15

    /// Returns existing or creates new WKWebView for a service instance.
    /// The web view is owned by the pool, not by SwiftUI.
    func webView(for instance: ServiceInstance,
                 dataStoreManager: DataStoreManager,
                 processPoolManager: ProcessPoolManager,
                 userScriptManager: UserScriptManager) -> WKWebView {
        if let existing = webViews[instance.id] {
            lastAccessTimes[instance.id] = Date()
            return existing
        }

        let config = makeConfiguration(for: instance,
                                        dataStoreManager: dataStoreManager,
                                        processPoolManager: processPoolManager,
                                        userScriptManager: userScriptManager)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = instance.userAgent
        // Only set pageZoom if user has configured it (future enhancement)

        webViews[instance.id] = webView
        lastAccessTimes[instance.id] = Date()

        // Load the service URL
        if let url = URL(string: instance.url) {
            webView.load(URLRequest(url: url))
        }

        evictIfNeeded()
        return webView
    }

    /// Evicts least-recently-used web views when count exceeds maxLoaded.
    /// Evicted views are destroyed; they will be recreated (and reloaded) on next access.
    private func evictIfNeeded() {
        guard webViews.count > maxLoaded else { return }
        let sorted = lastAccessTimes.sorted { $0.value < $1.value }
        let toEvict = sorted.prefix(webViews.count - maxLoaded)
        for (id, _) in toEvict {
            webViews.removeValue(forKey: id)
            lastAccessTimes.removeValue(forKey: id)
        }
    }

    /// Called when a service is deleted. Removes its web view permanently.
    func removeWebView(for instanceID: UUID) {
        webViews.removeValue(forKey: instanceID)
        lastAccessTimes.removeValue(forKey: instanceID)
    }
}
```

**NSViewRepresentable wrapper** — does NOT create the WKWebView:

```swift
struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView  // Pre-existing, owned by WebViewPool

    func makeNSView(context: Context) -> WKWebView {
        return webView  // Return the existing instance — never create a new one
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No-op. The web view manages its own state.
    }
}
```

### 5.3 Notification Detection (Hybrid Approach)

**Important limitation**: Web Push (Push API + Service Workers) does **not** work in `WKWebView`. Apple restricts Web Push to Safari and Home Screen web apps. This means services that rely on the Push API (Gmail, Slack, Discord, etc.) cannot send native push notifications through their standard mechanism.

**Chorus uses a three-layer detection strategy:**

#### Layer 1 — Title Polling (Most Reliable)

Most web apps update `document.title` with unread counts: `(3) Inbox - Gmail`, `Slack | 2 new items`. A timer polls the title and extracts counts via regex.

```swift
/// Runs every 5 seconds for each loaded web view.
func pollTitle(for webView: WKWebView, instanceID: UUID) {
    webView.evaluateJavaScript("document.title") { result, _ in
        guard let title = result as? String else { return }
        // Extract (N) pattern from title
        let pattern = /\((\d+)\)/
        if let match = title.firstMatch(of: pattern),
           let count = Int(match.1) {
            self.updateBadge(for: instanceID, count: count)
        }
    }
}
```

#### Layer 2 — DOM Badge Extraction (Curated Services)

For curated services, service-specific JavaScript extracts badge counts from known DOM elements. These selectors are defined in `ServiceCatalog.json` and can be updated remotely in future versions.

```swift
/// Runs every 10 seconds. Falls back to title polling if DOM extraction fails.
func pollBadge(for webView: WKWebView, catalogEntry: ServiceCatalogEntry) {
    guard let badgeJS = catalogEntry.badgeJS else { return }
    webView.evaluateJavaScript(badgeJS) { result, _ in
        if let count = result as? Int, count > 0 {
            self.updateBadge(for: catalogEntry.id, count: count)
        }
    }
}
```

#### Layer 3 — Legacy Notification API Interception

For sites that still use the legacy `new Notification()` API (not Push API), inject a script that intercepts construction and forwards to native macOS notifications. The interception script is injected as a `WKUserScript` at document start.

```javascript
// Injected by UserScriptManager — NOT user-editable
(function() {
    const OrigNotification = window.Notification;

    window.Notification = function(title, options) {
        window.webkit.messageHandlers.chorusNotification.postMessage(
            JSON.stringify({
                title: title,
                body: (options && options.body) || '',
                icon: (options && options.icon) || '',
                tag: (options && options.tag) || '',
                serviceID: '__SERVICE_ID__'
            })
        );
        return new OrigNotification(title, options);
    };

    Object.defineProperty(window.Notification, 'permission', {
        get: function() { return 'granted'; }
    });
    window.Notification.requestPermission = function(cb) {
        if (cb) cb('granted');
        return Promise.resolve('granted');
    };
})();
```

**Note**: The `__SERVICE_ID__` placeholder is replaced with the actual UUID string when the script is created per-instance. The value is serialized via `JSON.stringify` in the script (not template literals) to prevent injection.

**Swift-side handler:**

```swift
func userContentController(_ controller: WKUserContentController,
                           didReceive message: WKScriptMessage) {
    guard message.name == "chorusNotification",
          let jsonString = message.body as? String,
          let data = jsonString.data(using: .utf8),
          let payload = try? JSONDecoder().decode(NotificationPayload.self, from: data)
    else { return }

    guard !isServiceMuted(payload.serviceID) else { return }

    let content = UNMutableNotificationContent()
    content.title = payload.title
    content.body = payload.body
    content.userInfo = ["serviceID": payload.serviceID]

    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
}
```

**Muting**: Each `ServiceInstance.isMuted` flag gates notification forwarding. The Settings UI exposes a per-service mute toggle.

**Notification click → switch to service**: Implement `UNUserNotificationCenterDelegate.didReceive(_:)`. Extract `serviceID` from `userInfo`, set the selected service, and bring the window to front. Handle the **cold launch case** by storing the pending service ID in `AppDelegate` and applying it after SwiftData and the UI have initialized.

### 5.4 Badge Count Aggregation

`BadgeManager` combines badge counts from all non-muted services and displays the total on the dock icon.

```swift
@Observable
final class BadgeManager {
    private var counts: [UUID: Int] = [:]  // instanceID → unread count

    var totalCount: Int {
        counts.values.reduce(0, +)
    }

    func updateBadge(for instanceID: UUID, count: Int, isMuted: Bool) {
        counts[instanceID] = isMuted ? 0 : count
        NSApp.dockTile.badgeLabel = totalCount > 0 ? "\(totalCount)" : nil
    }
}
```

**Extraction priority** (per service):
1. Title regex `\((\d+)\)` — works for most services, survives UI redesigns.
2. Curated DOM selector from `ServiceCatalog.json` — more precise when working.
3. `MutationObserver` on notification-related DOM nodes — for services with neither.

**Badge selectors are fragile**: DOM class names like `.aim .bsU` (Gmail) change without notice. Title-based extraction is the primary method. DOM selectors are best-effort supplements. In post-v1, the catalog JSON should be remotely updatable so selectors can be fixed without an app update.

### 5.5 Two-Tiered Navigation (Spaces + Services)

#### Space Strip (Far Left)

```swift
struct SpaceStripView: View {
    @Query(sort: \Space.sortOrder) var spaces: [Space]
    @Binding var selectedSpaceID: UUID?
    @State private var showingAddSpace = false

    var body: some View {
        VStack(spacing: 8) {
            ForEach(spaces) { space in
                Button {
                    selectedSpaceID = space.id
                } label: {
                    Text(space.emoji)
                        .font(.title2)
                        .frame(width: 36, height: 36)
                        .background(
                            selectedSpaceID == space.id
                                ? Color.accentColor.opacity(0.2)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(space.name)  // Tooltip on hover
                .contextMenu {
                    Button("Edit Space...") { /* show editor */ }
                    Button("Delete Space", role: .destructive) { /* delete */ }
                }
            }
            .onMove { source, destination in
                // Persist reordered sortOrder values
            }

            Divider()

            Button { showingAddSpace = true } label: {
                Image(systemName: "plus")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 44)
        .padding(.vertical, 8)
    }
}
```

#### Service Sidebar (Second Column)

Shows services for the selected space, sourced via `SpaceServiceLink`.

```swift
struct ServiceSidebarView: View {
    let spaceID: UUID
    @Binding var selectedServiceID: UUID?
    @Query var links: [SpaceServiceLink]  // Filtered by spaceID

    var filteredLinks: [SpaceServiceLink] {
        links.filter { $0.space.id == spaceID }
             .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(filteredLinks) { link in
                    ServiceIconView(
                        instance: link.service,
                        isSelected: selectedServiceID == link.service.id
                    )
                    .onTapGesture {
                        selectedServiceID = link.service.id
                    }
                }
            }
        }
        .frame(width: 60)
    }
}
```

#### Drag-and-Drop Behaviors

- **Reorder services within a space**: update `SpaceServiceLink.sortOrder`.
- **Reorder spaces**: update `Space.sortOrder`.
- **Add a service to a space**: create a new `SpaceServiceLink` (alias, not move).
- **Remove a service from a space**: delete the `SpaceServiceLink`. If it was the last link for that service, prompt the user: "This service is no longer in any space. Delete it entirely?"

### 5.6 Minimal Browser Toolbar

Each service gets a thin toolbar above the web view with essential navigation controls:

```swift
struct WebToolbarView: View {
    @ObservedObject var webViewState: WebViewState  // Observes WKWebView KVO properties

    var body: some View {
        HStack(spacing: 12) {
            // Back / Forward
            Button(action: { webViewState.webView?.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!webViewState.canGoBack)

            Button(action: { webViewState.webView?.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!webViewState.canGoForward)

            // Reload
            Button(action: {
                webViewState.webView?.reload()
            }) {
                Image(systemName: webViewState.isLoading ? "xmark" : "arrow.clockwise")
            }

            // Progress bar
            if webViewState.isLoading {
                ProgressView(value: webViewState.estimatedProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }

            // Current URL (truncated, non-editable)
            Text(webViewState.currentURL?.host ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
```

**`WebViewState`**: An `@Observable` class that uses KVO to observe `WKWebView.canGoBack`, `.canGoForward`, `.isLoading`, `.estimatedProgress`, `.url`, and `.title`.

### 5.7 Error & Offline Handling

When a `WKWebView` fails to load (network error, DNS failure, SSL error), display an inline error page instead of a blank white screen:

```swift
func webView(_ webView: WKWebView,
             didFailProvisionalNavigation navigation: WKNavigation!,
             withError error: Error) {
    let html = """
    <html><body style="display:flex;justify-content:center;align-items:center;
        height:100vh;font-family:-apple-system;color:#888;text-align:center;">
        <div>
            <h2>Unable to connect</h2>
            <p>\(error.localizedDescription)</p>
            <button onclick="location.reload()"
                style="padding:8px 16px;font-size:14px;cursor:pointer;">
                Try Again
            </button>
        </div>
    </body></html>
    """
    webView.loadHTMLString(html, baseURL: nil)
}
```

### 5.8 OAuth Pop-up Handling (CRITICAL)

Many services (Google, Microsoft, Slack) use pop-up windows for OAuth login flows. `WKWebView` does not open pop-ups by default.

**Implementation**: When `WKUIDelegate.createWebViewWith(configuration:)` fires, create a **temporary WKWebView** and present it in a sheet. **The temporary web view MUST use the parent's `WKWebViewConfiguration`** — this ensures it shares the same `WKWebsiteDataStore`, so OAuth cookies set during the pop-up flow are visible to the parent web view.

```swift
func webView(_ webView: WKWebView,
             createWebViewWith configuration: WKWebViewConfiguration,
             for navigationAction: WKNavigationAction,
             windowFeatures: WKWindowFeatures) -> WKWebView? {

    // CRITICAL: Use the configuration passed in — it inherits the parent's data store.
    // Do NOT create a new configuration.
    let popupWebView = WKWebView(frame: .zero, configuration: configuration)
    popupWebView.navigationDelegate = self

    // Present in a sheet or child window
    presentPopup(popupWebView)

    return popupWebView
}
```

Dismiss the pop-up sheet when:
- The pop-up navigates back to the original service domain (OAuth complete).
- The pop-up's `window.close()` is called (handle via `WKUIDelegate.webViewDidClose`).
- The user manually closes the sheet.

### 5.9 Keyboard Shortcuts

| Shortcut       | Action                              |
|----------------|-------------------------------------|
| `⌘1` – `⌘9`   | Switch to service 1–9 in current space |
| `⌘[`           | Previous service                    |
| `⌘]`           | Next service                        |
| `⌘R`           | Reload current service              |
| `⌘W`           | Hide window (don't quit)            |
| `⌘,`           | Open settings                       |
| `⌘F`           | Find in page (via JS bridge — see below) |
| `⌃Tab`         | Next space                          |
| `⌃⇧Tab`        | Previous space                      |

**Find in page**: WKWebView has no built-in find UI. Implement via JavaScript:

```swift
func findInPage(query: String) {
    let js = "window.find('\(query.escapedForJavaScript)', false, false, true)"
    webView.evaluateJavaScript(js)
}
```

Display a native SwiftUI search bar overlay at the top of the content area when `⌘F` is pressed.

**Preventing multiple windows**: SwiftUI's `WindowGroup` allows `⌘N` to create duplicate windows by default. Override this:

```swift
.commands {
    CommandGroup(replacing: .newItem) {
        Button("Add Service...") { showAddService = true }
            .keyboardShortcut("n", modifiers: .command)
    }
}
```

Use `Window` (singular) instead of `WindowGroup` if you want to guarantee only one window, or handle the multi-window case explicitly by sharing the same `WebViewPool` across windows.

### 5.10 App Presence (Dock / Menu Bar)

```swift
final class AppPresenceManager {
    func apply(mode: AppPresenceMode) {
        switch mode {
        case .dock:
            NSApp.setActivationPolicy(.regular)
            // Hide MenuBarExtra
        case .menuBar:
            NSApp.setActivationPolicy(.accessory)
            // Show MenuBarExtra
        case .both:
            NSApp.setActivationPolicy(.regular)
            // Show MenuBarExtra
        }
    }
}
```

SwiftUI entry point:

```swift
@main
struct ChorusApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        Window("Chorus", id: "main") {
            ContentView()
                .environment(appState)
        }

        MenuBarExtra("Chorus", systemImage: "music.note.list",
                     isInserted: $appState.showMenuBarExtra) {
            MenuBarView()
        }

        Settings {
            SettingsView()
        }
    }
}
```

**Launch at login**: Use `SMAppService.mainApp.register()` / `.unregister()` — the correct approach for sandboxed Mac App Store apps.

### 5.11 Window State Restoration

Persist and restore the user's last state on launch:

- **Selected space**: stored in `AppPreferences.selectedSpaceID`
- **Selected service**: stored in `AppPreferences.selectedServiceID`
- **Window frame**: handled automatically by SwiftUI `Window` scene with a stable ID (`"main"`)
- **Space collapse states**: N/A (spaces don't collapse; services within are always visible)

On cold launch from a notification click, the pending `serviceID` is stored in `AppDelegate` and applied after the `ContentView` has appeared and SwiftData is ready.

---

## 6. WKWebView Configuration

### 6.1 Per-Instance Configuration

```swift
func makeConfiguration(for instance: ServiceInstance,
                        dataStoreManager: DataStoreManager,
                        processPoolManager: ProcessPoolManager,
                        userScriptManager: UserScriptManager) -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()

    // 1. Isolated data store — own cookies, localStorage, cache
    config.websiteDataStore = dataStoreManager.dataStore(for: instance)

    // 2. Isolated process pool — prevents same-origin cross-talk
    config.processPool = processPoolManager.processPool(for: instance.id)

    // 3. JavaScript preferences
    let prefs = WKWebpagePreferences()
    prefs.allowsContentJavaScript = true
    config.defaultWebpagePreferences = prefs

    // 4. User content controller (notification/badge scripts + message handlers)
    let controller = WKUserContentController()
    userScriptManager.configureScripts(for: instance, on: controller)
    config.userContentController = controller

    return config
}
```

### 6.2 Navigation Delegate

```swift
func webView(_ webView: WKWebView,
             decidePolicyFor navigationAction: WKNavigationAction,
             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
    }

    // Open external links (target="_blank" to a different domain) in system browser
    if navigationAction.navigationType == .linkActivated,
       navigationAction.targetFrame == nil,
       let currentHost = webView.url?.host,
       let targetHost = url.host,
       !areSameDomain(currentHost, targetHost) {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
        return
    }

    decisionHandler(.allow)
}

/// Compares base domains (ignoring subdomains and "www.")
private func areSameDomain(_ a: String, _ b: String) -> Bool {
    let normalize: (String) -> String = { host in
        host.replacingOccurrences(of: "www.", with: "")
            .split(separator: ".").suffix(2).joined(separator: ".")
    }
    return normalize(a) == normalize(b)
}
```

### 6.3 File Downloads

Implement `WKDownloadDelegate` (macOS 12+) to handle file downloads. Present `NSSavePanel` for the user to choose a save location.

```swift
func webView(_ webView: WKWebView,
             navigationAction: WKNavigationAction,
             didBecome download: WKDownload) {
    download.delegate = self
}

func download(_ download: WKDownload,
              decideDestinationUsing response: URLResponse,
              suggestedFilename: String,
              completionHandler: @escaping (URL?) -> Void) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedFilename
    panel.begin { response in
        completionHandler(response == .OK ? panel.url : nil)
    }
}
```

### 6.4 Context Menus

Override `WKUIDelegate` to provide native macOS context menus where appropriate:
- "Open Link in Browser" → `NSWorkspace.shared.open(url)`
- "Copy Link" → `NSPasteboard.general`
- "Reload" → `webView.reload()`

---

## 7. Service Catalog

### 7.1 Catalog Format (`ServiceCatalog.json`)

```json
[
    {
        "id": "gmail",
        "name": "Gmail",
        "url": "https://mail.google.com",
        "icon": "gmail-icon",
        "category": "email",
        "badgeJS": "(() => { const el = document.querySelector('.aim .bsU'); return el ? parseInt(el.textContent) || 0 : 0; })()",
        "userAgent": null,
        "description": "Google's email service"
    }
]
```

### 7.2 Curated Services for v1

| Service         | URL                                | Category     |
|-----------------|------------------------------------|--------------|
| Gmail           | https://mail.google.com            | Email        |
| Outlook         | https://outlook.live.com           | Email        |
| ProtonMail      | https://mail.proton.me             | Email        |
| Slack           | https://app.slack.com              | Messaging    |
| Microsoft Teams | https://teams.microsoft.com        | Messaging    |
| Discord         | https://discord.com/app            | Messaging    |
| WhatsApp        | https://web.whatsapp.com           | Messaging    |
| Telegram        | https://web.telegram.org           | Messaging    |
| Twitter / X     | https://x.com                      | Social       |
| LinkedIn        | https://www.linkedin.com           | Social       |
| Facebook        | https://www.facebook.com           | Social       |
| Instagram       | https://www.instagram.com          | Social       |
| Reddit          | https://www.reddit.com             | Social       |
| Notion          | https://www.notion.so              | Productivity |
| Trello          | https://trello.com                 | Productivity |
| Asana           | https://app.asana.com              | Productivity |
| Google Calendar | https://calendar.google.com        | Productivity |
| Google Drive    | https://drive.google.com           | Productivity |
| ChatGPT         | https://chatgpt.com                | AI           |
| Claude          | https://claude.ai                  | AI           |

### 7.3 Custom URL Flow

1. User taps "Add Custom Service" and enters a URL (must be `https://`).
2. `FaviconFetcher` tries in order: `<link rel="apple-touch-icon">` parsed from HTML, `/apple-touch-icon.png`, `/favicon.ico`. First successful fetch is cached as `customIconData`.
3. User provides a label and optionally uploads a custom icon.
4. A `ServiceInstance` is created with `catalogEntryID = nil`.
5. Badge detection falls back to title polling only (no curated DOM selectors).

---

## 8. Entitlements & Info.plist

### 8.1 Entitlements (`Chorus.entitlements`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- App Sandbox (required for Mac App Store) -->
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <!-- Outgoing network connections (loading web content) -->
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- File downloads via NSSavePanel -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

### 8.2 Info.plist Keys

```xml
<!-- User Notifications -->
<key>NSUserNotificationsUsageDescription</key>
<string>Chorus forwards notifications from your web services to macOS.</string>
```

---

## 9. Build Phases & Implementation Order

### Phase 1 — Core Shell (MVP)
1. Xcode project: SwiftUI App, macOS 14+ target, App Sandbox.
2. SwiftData models: `ServiceInstance`, `Space`, `SpaceServiceLink`, `AppPreferences`.
3. `DataStoreManager` + `ProcessPoolManager`.
4. `WebViewPool` with pre-created WKWebView instances (NOT created inside NSViewRepresentable).
5. Two-tiered navigation: space strip + service sidebar + web content area.
6. Hard-code one default space ("🌐 General") with 5 services.
7. **Verification gate**: two Gmail instances have completely independent logins across app restarts.

### Phase 2 — Spaces & Catalog
8. Full `ServiceCatalog.json` with all 20 curated services.
9. "Add Service" sheet: catalog grid with search + custom URL input.
10. Space creation/editing: emoji picker, naming.
11. Multi-space aliasing: add the same service to multiple spaces.
12. Drag-and-drop: reorder services within spaces, reorder spaces.
13. Delete flows: remove service from space vs. delete service entirely.

### Phase 3 — Notifications & Badges
14. Title polling (Layer 1) — every 5 seconds per loaded web view.
15. Curated DOM badge extraction (Layer 2) — every 10 seconds.
16. Legacy Notification API interception (Layer 3) — injected script.
17. Swift-side `WKScriptMessageHandler` → `UNUserNotificationCenter` bridge.
18. Per-service mute toggle in Settings.
19. Notification click → navigate to correct space and service.
20. Cold launch notification handling (queued service ID).
21. Dock badge aggregation.

### Phase 4 — Browser Chrome & Navigation
22. Toolbar: back, forward, reload, progress bar, domain display.
23. `allowsBackForwardNavigationGestures = true`.
24. `⌘F` find in page via JS bridge + SwiftUI search bar overlay.
25. OAuth pop-up handling via `WKUIDelegate.createWebViewWith` (shared data store).
26. File downloads via `WKDownloadDelegate` + `NSSavePanel`.
27. Context menus: open in browser, copy link.
28. Error page display for failed navigations.

### Phase 5 — Keyboard Shortcuts & App Presence
29. `⌘1`–`⌘9` service switching within current space.
30. `⌃Tab` / `⌃⇧Tab` space switching.
31. `⌘[` / `⌘]` prev/next service.
32. Dock/menu bar/both mode via `AppPresenceManager`.
33. `MenuBarExtra` with quick-switch menu.
34. Launch at login via `SMAppService`.
35. Window state restoration (selected space, selected service).
36. Override `⌘N` to prevent duplicate windows.

### Phase 6 — App Store Preparation
37. App icon, marketing screenshots.
38. Privacy policy (no server-side data storage).
39. App Review notes explaining WKWebView multi-instance usage and data store paths.
40. **Sandbox verification**: confirm `WKWebsiteDataStore(forIdentifier:)` works correctly under App Sandbox with TestFlight.
41. TestFlight beta.
42. Submit.

---

## 10. Known Limitations

| Limitation | Impact | Mitigation |
|-----------|--------|------------|
| Web Push (Push API) does not work in WKWebView | No real-time push notifications from services | Title polling + DOM extraction + legacy Notification API interception |
| Badge DOM selectors break when services redesign | Badge counts may stop working for specific services | Title regex is primary; DOM selectors are best-effort; plan for remote JSON updates post-v1 |
| Per-instance process pools increase memory | ~30–50 MB per service beyond shared-pool baseline | Required for isolation correctness; still far below Chromium |
| Some services block non-Safari user agents | WhatsApp Web, occasionally Google | Default UA mimics Safari; per-service UA overrides in catalog |
| WKWebView data stores live outside app container | Path is `~/Library/WebKit/WebsiteDataStore/<UUID>/` | WebKit handles sandbox access transparently; verify in TestFlight |
| No `window.open` support by default | OAuth and pop-up flows break | `WKUIDelegate.createWebViewWith` handles this explicitly |

---

## 11. Testing Strategy

| Test Type    | Scope                                                |
|--------------|------------------------------------------------------|
| Unit Tests   | SwiftData models, DataStoreManager, ProcessPoolManager, BadgeManager, ServiceCatalog parsing, SpaceServiceLink integrity |
| Integration  | WKWebView creation with isolated data stores + process pools, notification script injection, badge extraction, OAuth pop-up flow |
| UI Tests     | Space creation/deletion, service reordering across spaces, multi-space alias behavior, toolbar navigation |
| Manual QA    | Login persistence across restarts, multi-account isolation, OAuth flows (Google, Microsoft, Apple), memory profiling with 10+ services, App Sandbox verification |

### Critical Test Cases

1. **Isolation**: Log into Gmail A in Service 1, Gmail B in Service 2. Restart app. Verify both sessions persist independently. Verify no cookie leakage between them.
2. **Multi-space alias**: Add Gmail to both 🏢 Work and 🏠 Personal spaces. Verify switching spaces shows the exact same web view (same scroll position, same state).
3. **Data deletion**: Remove a service entirely. Verify `WKWebsiteDataStore.remove(forIdentifier:)` succeeds and the session is wiped.
4. **Link integrity**: Remove a service from one space (but it exists in another). Verify the service and its session survive. Remove from the last space. Verify prompt to delete entirely.
5. **OAuth flow**: Add a new Gmail instance. Complete Google OAuth (pop-up flow). Verify login succeeds and persists across restart.
6. **Notification muting**: Unmuted service triggers a macOS notification; muted service does not.
7. **Cold launch notification**: Click a notification when app is not running. Verify app launches and navigates to the correct service.
8. **Memory**: Open 10 services. Monitor RSS via Instruments. Verify it stays under 1 GB.
9. **Toolbar**: Back/forward buttons work. Progress bar shows during load. Reload works.

---

## 12. Future Considerations (Post-v1)

- **Remote catalog updates** — fetch updated `ServiceCatalog.json` (especially badge selectors) without an app update.
- **Theming** — dark/light/accent color customization.
- **Per-service zoom** — remember zoom level per service via `WKWebView.pageZoom`.
- **Tab support within a service** — multiple tabs inside a single service.
- **Session export/import** — back up and restore all service sessions.
- **Keyboard shortcut customization** — user-defined shortcuts.
- **iCloud sync** — sync spaces and service list (not session data) across Macs.
- **Custom CSS/JS injection** — allow power users to inject scripts per service (deferred from v1 for simplicity and security).
