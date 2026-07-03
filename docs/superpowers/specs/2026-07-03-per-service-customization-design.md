# Spec B — Per-service customization

Date: 2026-07-03
Status: Approved (decisions delegated to Claude; user reviews the result)

Second of three specs in the "Chorus 1.1" milestone. Covers per-service custom
CSS (with presets and a baked-in LinkedIn recipe), a mobile-view toggle, and
spellcheck.

## Custom CSS

### What it does

Injects CSS into a service's page. LinkedIn ships with a verified recipe that
trims it to just the messaging pane, filling the window like a dedicated chat
app (matching what Rambox does). Users can override the CSS per service or apply
a named preset in the Edit Service sheet.

### Mechanism

- `UserScriptManager.makeCSSInjectionScript(css:)` builds a script that appends a
  `<style id="chorus-custom-css">` to the page. The CSS is JSON-encoded into a JS
  string literal (safe against quotes/newlines/backslashes), and the style node
  is reused if already present, so re-injection can't stack.
- Injected as a `WKUserScript` at `.atDocumentStart`, main frame only, so the
  page never flashes its full layout before the CSS applies. It re-runs on real
  reloads and persists across the SPA's client-side navigation (the style lives
  in the DOM, which the SPA doesn't tear down).
- `configureScripts(for:customCSS:on:)` takes the resolved CSS and adds the
  script only when it's non-blank.

### Where the CSS comes from (design change from Spec A's sketch)

Spec A sketched putting `customCSS` on the catalog JSON entry (mirroring
`badgeJS`). We changed to a **code-side default** instead:

- `ServiceCSSDefaults.css(forCatalogID:)` maps a catalog id to its default CSS,
  sourced from `CSSPresets` (Swift constants).
- `ServiceInstance.customCSS: String?` holds a per-instance override (optional,
  so SwiftData lightweight migration succeeds; nil means "use the default").
- `ServiceCSSDefaults.effectiveCSS(instanceCSS:catalogID:)` = the instance CSS if
  set, else the default; a blank result injects nothing.

Why the change: it keeps a single Swift source of truth shared with the preset
library, avoids escaping a multi-line CSS blob inside JSON, and makes the
resolution logic a pure, unit-tested function. LinkedIn still gets its view with
zero user action and no data migration, because the default is keyed on its
catalog id.

### Presets

`CSSPreset { id, name, css }` with a small library in `CSSPresets.all`
("LinkedIn: messaging only", "Hide scrollbars"). The Edit Service sheet offers
an "Apply preset" menu that fills the CSS box; the user can then edit freely.

### Applying an edit at runtime

Custom CSS is injected when the web view is built, so an edit needs the view
rebuilt. `WebViewPool.recreateWebView(for:preserveURL:)` tears the view down
(keeping the active pointer and never-hibernate state) and lets the next access
rebuild it with the new script. `AppState.applyServiceEdits` bumps an observable
`webViewRebuildToken`; `WebContentView` watches it and re-fetches the active
service's view, so the change shows immediately. The rebuild also carries a
user-agent change and the new URL, so those don't need separate handling.

## Mobile view

A per-service toggle in Edit Service. On → the instance's `userAgent` is set to
`UserAgentProvider.mobileSafari` (an iOS Safari string); off → nil (desktop
Safari default). A user-agent change applies live via
`WebViewPool.setUserAgent(_:for:)` (which sets `customUserAgent` and reloads) —
no full rebuild needed, since `customUserAgent` is settable on a live view.

## Spellcheck

macOS WKWebView already spell-checks editable web content (contenteditable,
textarea, input — e.g. Slack/Gmail compose boxes) by default, using the system
spell checker, toggled through the standard **Edit ▸ Spelling and Grammar** menu.
There is no clean per-`WKWebView` API to force it beyond what's on by default,
and adding custom grammar-check plumbing to the coordinator would be fragile. So
this is treated as already delivered: no code, verify the Edit menu is present.
Revisit only if a service is found not to check spelling.

## Remote CSS — findings (deferred, documented per request)

We considered fetching the CSS from the GitHub repo at launch so recipes could
be updated without an app release (as Ferdium/Rambox do). Decision: **keep it
baked in for now.** Feasible, but the tradeoffs pushed it to a separate,
security-reviewed effort:

- **Additive, not a swap.** A remote fetch can fail (offline, first launch, GitHub
  down), so a bundled fallback and a cache are still required. There's also a
  cold-launch race: the web view often loads before the fetch returns, so the
  first load uses the cached/bundled copy and the fresh one applies next load.
- **Trust boundary.** Today the CSS ships inside the signed, notarized bundle —
  tamper-resistant. Fetching at runtime injects whatever the URL serves into
  **logged-in** sessions. CSS in an authenticated page isn't fully benign: it can
  exfiltrate server-rendered attribute values or overlay/clickjack.
- **The sharp edge is a remote catalog.** If the whole `ServiceCatalog` went
  remote, `badgeJS` (already executed via `evaluateJavaScript`) would become
  remote code execution in every service's authenticated context.
- **Lower payoff for Chorus.** Sparkle already ships auto-updates, so a broken
  selector can be fixed with a patch release — cheaper than for an app with no
  update channel.

If pursued later: pin HTTPS and verify a signature on the fetched file with the
Developer ID key so it keeps notarization-level trust. Its own spec.

## Files

- `Models/ServiceInstance.swift` — `customCSS: String?`.
- `Services/UserScriptManager.swift` — injection script, `configureScripts`
  param, `CSSPreset` / `CSSPresets` / `ServiceCSSDefaults`.
- `Utilities/UserAgentProvider.swift` — `mobileSafari`.
- `Views/WebView/WebViewPool.swift` — resolve effective CSS; `recreateWebView`,
  `setUserAgent`.
- `App/AppState.swift` — `webViewRebuildToken`; extended `applyServiceEdits`.
- `Views/MainWindow/WebContentView.swift` — observe the rebuild token.
- `Views/AddService/EditServiceSheet.swift` — Custom CSS section, presets,
  Mobile view toggle.

## Testing

Unit tests: CSS injection script escapes CSS and tags the style id; effective-CSS
resolution (instance → default → nothing, blank = nothing); LinkedIn ships a
baked-in default; a fresh instance has nil `customCSS`. Build green, plus a live
check that LinkedIn renders messaging-only in the app.
