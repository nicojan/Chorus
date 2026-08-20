import WebKit

/// Vends per-service `WKWebsiteDataStore` instances, caching them by
/// identifier. WebKit backs every store for a given identifier with the same
/// on-disk data, but repeatedly *constructing* `WKWebsiteDataStore(forIdentifier:)`
/// is wasteful and — on macOS 26 — sits in the same fragile WebKit territory
/// that already forced avoiding `allDataStoreIdentifiers`. Reusing one instance
/// per identifier avoids that churn.
@MainActor
final class DataStoreManager {
    private var cache: [UUID: WKWebsiteDataStore] = [:]

    func dataStore(for instance: ServiceInstance) -> WKWebsiteDataStore {
        dataStore(forIdentifier: instance.dataStoreIdentifier)
    }

    func dataStore(forIdentifier identifier: UUID) -> WKWebsiteDataStore {
        if let cached = cache[identifier] {
            return cached
        }
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        Self.disableTrackingPrevention(on: store)
        cache[identifier] = store
        return store
    }

    /// Selector for WebKit's per-store Intelligent Tracking Prevention switch.
    /// SPI, so it is probed rather than called blind.
    private static let resourceLoadStatisticsSelector = Selector(("_setResourceLoadStatisticsEnabled:"))

    /// Turns ITP off for a service's store.
    ///
    /// ITP treats a cookie read from an iframe on another registrable domain as
    /// third-party and blocks it. Enterprise SSO is built on exactly that: the
    /// service embeds a hidden frame pointed at its identity provider and reads
    /// the session cookie from there. With the cookie blocked the silent refresh
    /// can only fail, and the service falls back to telling the user to sign in
    /// again — which runs the same silent flow and fails the same way. Microsoft
    /// Teams loops like this against `login.microsoftonline.com`, reporting
    /// `AADSTS50058: a silent sign-in request was sent but no user is signed in`
    /// and then loading its own `report-third-party-cookies.html`. There is no
    /// way out of that loop from inside the app: no button reaches a real
    /// sign-in, and restarting does not clear it, because ITP's record is on
    /// disk.
    ///
    /// Turning ITP off costs little here that isolation is not already paying
    /// for. Every service gets its own `WKWebsiteDataStore`, so one service can
    /// never read another's cookies whatever ITP does; what ITP adds is blocking
    /// third-party cookies *within* a single service's own container, where the
    /// only participants are that service and the identity provider it chose.
    ///
    /// What is genuinely given up is ITP's cross-site tracking defence *inside*
    /// one service's container: an ad network embedded on that service's own
    /// pages can keep a cookie across the sites it appears on there. The
    /// content blocker already drops most of those requests, and the blast
    /// radius stops at the one service. Whether that trade is worth making by
    /// default, or belongs behind a per-service toggle, is a call for the
    /// project rather than something to assume — the code is written so either
    /// answer is a small change.
    ///
    /// Probed and logged rather than assumed: this is SPI, and a macOS release
    /// can drop it. If it ever disappears, SSO services break the way they do
    /// today and the log says why.
    ///
    /// The setter takes a scalar `BOOL`, so it has to be called through its
    /// implementation with that signature. `perform(_:with:)` passes an object
    /// *pointer* in the argument slot, and any non-nil pointer reads as a true
    /// BOOL — it silently turns ITP on rather than off, which is exactly the
    /// wrong way round and leaves no trace.
    private typealias BoolSetter = @convention(c) (AnyObject, Selector, ObjCBool) -> Void

    private static func disableTrackingPrevention(on store: WKWebsiteDataStore) {
        guard store.responds(to: resourceLoadStatisticsSelector),
              let method = class_getInstanceMethod(type(of: store), resourceLoadStatisticsSelector)
        else {
            AppLogger.dataStore.warning(
                "WebKit no longer exposes _setResourceLoadStatisticsEnabled: — SSO services that refresh through a third-party frame may loop on sign-in"
            )
            return
        }
        let setter = unsafeBitCast(method_getImplementation(method), to: BoolSetter.self)
        setter(store, resourceLoadStatisticsSelector, ObjCBool(false))

        // Read it back. A silent no-op here is the failure that cost the most
        // time to find, so prove the write landed instead of trusting it.
        if let enabled = (store.value(forKey: "_resourceLoadStatisticsEnabled") as? NSNumber)?.boolValue,
           enabled {
            AppLogger.dataStore.warning("Tracking prevention stayed on for a service store — SSO refresh may loop")
        }
    }

    /// Drops the cached instance for an identifier. Call before removing the
    /// store from disk so a stale handle can't keep it alive.
    func evict(identifier: UUID) {
        cache.removeValue(forKey: identifier)
    }

    // NOTE: there is deliberately no direct `deleteDataStore(...)` here. Removing
    // a `WKWebsiteDataStore` while its `WKWebView` is still retained hard-crashes
    // inside WebKit, so every on-disk removal must go through AppState's
    // `markDataStoreOrphaned` → deferred `cleanUpOrphanedDataStores` path, which
    // evicts the cached handle and only removes once the web view has torn down.
}
