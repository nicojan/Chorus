import Foundation
import WebKit

/// The Chorus side of the engine seam: turns a `ServiceInstance` into the
/// `WebSurface` the pool takes, and keeps the pool's service-shaped calls so
/// `AppState` and the views call it as before.
///
/// The checks that need the live model stay here, never in the pool: whether a
/// SwiftData object is still in its context, and whether a service is a Mac app.
extension ServiceInstance {
    var webSurface: WebSurface {
        WebSurface(
            id: id,
            url: url,
            // The shared sign-in store, NOT the service's own id. Getting this
            // wrong signs people out. See CLAUDE.md, "Sign-in stores are shared".
            dataStore: .persistent(dataStoreIdentifier),
            userAgent: userAgent,
            css: ServiceCSSDefaults.effectiveCSS(instanceCSS: customCSS, catalogID: catalogEntryID),
            darkThemed: darkMode == .on,
            // The effective policy, not the legacy `neverHibernate` flag.
            keepsLoaded: hibernationPolicyEffective == .never,
            staysActiveInBackground: staysActiveInBackgroundEffective,
            label: label
        )
    }
}

extension WebViewPool {
    func webView(for instance: ServiceInstance) -> WKWebView {
        webView(for: instance.webSurface)
    }

    /// Preloads a web view for a service in the background without making it
    /// active. Skips a service that already has a web view, a deleted one, and a
    /// Mac-app service, which has no page to load.
    func preload(_ instance: ServiceInstance) {
        guard !hasWebView(for: instance.id) else { return }
        guard instance.modelContext != nil else { return }
        guard instance.nativeAppBundleID == nil else { return }
        preload(instance.webSurface)
    }

    /// Preloads web views for multiple services with a staggered delay to avoid
    /// overwhelming the network and CPU on startup.
    /// Captures references before the loop so deleted SwiftData objects don't
    /// cause issues across await suspension points. Each service is read only
    /// when its turn comes, so a change made during the sleep (a new sign-in
    /// store, say) is the one that gets built.
    func preloadAll(_ instances: [ServiceInstance], delayBetween: Duration = .milliseconds(500)) async {
        // Snapshot the list before any suspension points — a service could be
        // deleted during the staggered sleep, and accessing a deleted @Model
        // object's properties is undefined.
        struct PreloadEntry { let id: UUID; let instance: ServiceInstance }
        let entries = instances.map { PreloadEntry(id: $0.id, instance: $0) }

        for entry in entries {
            guard !Task.isCancelled else { break }
            guard !hasWebView(for: entry.id) else { continue }
            // Verify the model object is still in a valid context before accessing it
            guard entry.instance.modelContext != nil else { continue }
            preload(entry.instance)
            try? await Task.sleep(for: delayBetween)
        }
    }

    func applyDarkState(isDark: Bool, services: [ServiceInstance]) {
        let byID = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        applyDarkState(isDark: isDark, surface: { byID[$0]?.webSurface })
    }

    func refreshDarkMode(for instance: ServiceInstance) {
        refreshDarkMode(for: instance.webSurface)
    }
}
