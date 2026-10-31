import XCTest
import SwiftData
import WebKit
@testable import Chorus
@testable import ChorusEngine

/// The engine seam: `ServiceInstance.webSurface` must hand the web engine the
/// values Chorus used before the seam existed. Each mapping here fails silently
/// in the app if it goes wrong, so each gets a test.
@MainActor
final class WebSurfaceTests: XCTestCase {

    /// The store is the shared sign-in store, never the service's own id. A
    /// wrong mapping signs people out of everything.
    func testDataStoreIsTheSharedSignInStoreNotTheServiceID() {
        let shared = UUID()
        let service = ServiceInstance(label: "Gmail", url: "https://mail.google.com", dataStoreIdentifier: shared)
        XCTAssertNotEqual(service.id, shared)
        XCTAssertEqual(service.webSurface.dataStore, .persistent(shared))
        XCTAssertEqual(service.webSurface.id, service.id)
    }

    /// The CSS is the effective CSS, with the catalog defaults, not the raw
    /// field. Mapping the raw field drops LinkedIn's messaging view.
    func testCSSIsTheEffectiveCSS() {
        let linkedIn = ServiceInstance(label: "LinkedIn", url: "https://www.linkedin.com/messaging/", catalogEntryID: "linkedin")
        XCTAssertEqual(linkedIn.webSurface.css, ServiceCSSDefaults.linkedInMessaging)

        let custom = ServiceInstance(label: "LinkedIn", url: "https://www.linkedin.com", catalogEntryID: "linkedin", customCSS: "body{}")
        XCTAssertEqual(custom.webSurface.css, "body{}")

        let plain = ServiceInstance(label: "Slack", url: "https://app.slack.com", catalogEntryID: "slack")
        XCTAssertNil(plain.webSurface.css)
    }

    /// "Keep Loaded" follows the effective policy, not the legacy flag, in both
    /// directions.
    func testKeepsLoadedFollowsTheEffectivePolicy() {
        let newPolicy = ServiceInstance(label: "A", url: "https://a.example", neverHibernate: false, hibernationPolicyRaw: HibernationPolicy.never.rawValue)
        XCTAssertTrue(newPolicy.webSurface.keepsLoaded)

        let legacyOnly = ServiceInstance(label: "B", url: "https://b.example", neverHibernate: true)
        XCTAssertTrue(legacyOnly.webSurface.keepsLoaded)

        let overridden = ServiceInstance(label: "C", url: "https://c.example", neverHibernate: true, hibernationPolicyRaw: HibernationPolicy.after.rawValue)
        XCTAssertFalse(overridden.webSurface.keepsLoaded)
    }

    /// Dark theming follows the effective mode, including the legacy flag.
    func testDarkThemedFollowsTheEffectiveMode() {
        XCTAssertTrue(ServiceInstance(label: "A", url: "https://a.example", darkModeRaw: "on").webSurface.darkThemed)
        XCTAssertTrue(ServiceInstance(label: "B", url: "https://b.example", forceDarkMode: true).webSurface.darkThemed)
        XCTAssertFalse(ServiceInstance(label: "C", url: "https://c.example", forceDarkMode: true, darkModeRaw: "off").webSurface.darkThemed)
        XCTAssertFalse(ServiceInstance(label: "D", url: "https://d.example").webSurface.darkThemed)
    }

    /// The remaining fields pass through, with the stay-active default of off.
    func testPassThroughFields() {
        let service = ServiceInstance(label: "Teams", url: "https://teams.microsoft.com", userAgent: "UA/1", stayActiveInBackground: true)
        let surface = service.webSurface
        XCTAssertEqual(surface.url, "https://teams.microsoft.com")
        XCTAssertEqual(surface.userAgent, "UA/1")
        XCTAssertEqual(surface.label, "Teams")
        XCTAssertTrue(surface.staysActiveInBackground)

        let unset = ServiceInstance(label: "X", url: "")
        XCTAssertNil(unset.webSurface.userAgent)
        XCTAssertFalse(unset.webSurface.staysActiveInBackground)
        XCTAssertEqual(unset.webSurface.url, "")
    }

    /// The engine-side truth table: themed only when the surface asks for it
    /// AND the app is dark.
    func testDarkInjectionByFlag() {
        typealias I = DarkReaderSupport.DarkInjection
        XCTAssertEqual(DarkReaderSupport.injection(themed: true, appDark: true), I.themed)
        XCTAssertEqual(DarkReaderSupport.injection(themed: true, appDark: false), I.none)
        XCTAssertEqual(DarkReaderSupport.injection(themed: false, appDark: true), I.none)
        XCTAssertEqual(DarkReaderSupport.injection(themed: false, appDark: false), I.none)
    }

    // MARK: - How the pool uses a surface

    /// A pool with nothing compiled or started. Surfaces below use an empty
    /// address, so no page loads and no web content process does any work.
    private func makePool() -> (WebViewPool, DataStoreManager) {
        let stores = DataStoreManager()
        let pool = WebViewPool(
            dataStoreManager: stores,
            userScriptManager: UserScriptManager(),
            contentBlocker: ContentBlockerManager(isEnabled: false)
        )
        return (pool, stores)
    }

    private func surface(id: UUID = UUID(), store: UUID = UUID(), keepsLoaded: Bool = false) -> WebSurface {
        WebSurface(
            id: id, url: "", dataStore: .persistent(store), userAgent: nil, css: nil,
            darkThemed: false, keepsLoaded: keepsLoaded, staysActiveInBackground: false, label: "Test"
        )
    }

    /// The web view is built on the surface's store, not on a store named after
    /// the surface. This is the line that keeps people signed in.
    func testPoolBuildsTheWebViewOnTheSurfacesStore() throws {
        let (pool, stores) = makePool()
        let id = UUID(), shared = UUID()
        pool.preload(surface(id: id, store: shared))
        defer { pool.removeWebView(for: id) }

        let store = try XCTUnwrap(pool.liveWebView(for: id)).configuration.websiteDataStore
        XCTAssertEqual(store.identifier, shared)
        XCTAssertNotEqual(store.identifier, id)
        XCTAssertTrue(store === stores.dataStore(forIdentifier: shared), "the cached store is reused")
    }

    /// "Keep Loaded" exempts a preloaded surface from the idle sweep; a surface
    /// without it is a candidate.
    func testKeepsLoadedExemptsAPreloadedSurfaceFromTheIdleSweep() {
        let (pool, _) = makePool()
        let kept = surface(keepsLoaded: true), plain = surface(keepsLoaded: false)
        pool.preload(kept)
        pool.preload(plain)
        defer { pool.removeWebView(for: kept.id); pool.removeWebView(for: plain.id) }

        let candidates = Set(pool.idleCandidates(now: Date().addingTimeInterval(3600)).map(\.id))
        XCTAssertFalse(candidates.contains(kept.id))
        XCTAssertTrue(candidates.contains(plain.id))
    }

    // MARK: - The guards that stay in Chorus

    /// A service that is not in a model context (deleted, or never saved) gets
    /// no web view.
    func testPreloadSkipsAServiceOutsideAModelContext() {
        let (pool, _) = makePool()
        let detached = ServiceInstance(label: "Gone", url: "")
        XCTAssertNil(detached.modelContext)
        pool.preload(detached)
        XCTAssertFalse(pool.hasWebView(for: detached.id))
    }

    /// A Mac-app service has no page, so it gets no web view even when it is a
    /// live model.
    func testPreloadSkipsAMacAppService() throws {
        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let macApp = ServiceInstance(label: "Notes", url: "\(NativeApp.scheme)://com.apple.Notes")
        context.insert(macApp)
        XCTAssertNotNil(macApp.modelContext)
        XCTAssertNotNil(macApp.nativeAppBundleID)

        let (pool, _) = makePool()
        pool.preload(macApp)
        XCTAssertFalse(pool.hasWebView(for: macApp.id))
    }
}
