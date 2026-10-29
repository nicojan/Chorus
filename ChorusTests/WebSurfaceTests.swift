import XCTest
@testable import Chorus

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

    func testDarkInjectionByFlagMatchesByMode() {
        for appDark in [true, false] {
            XCTAssertEqual(DarkReaderSupport.injection(themed: true, appDark: appDark),
                           DarkReaderSupport.injection(mode: .on, appDark: appDark))
            XCTAssertEqual(DarkReaderSupport.injection(themed: false, appDark: appDark),
                           DarkReaderSupport.injection(mode: .off, appDark: appDark))
        }
    }
}
