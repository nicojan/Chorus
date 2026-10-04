import AppKit
import Security
import SwiftData
import WebKit
import XCTest
@testable import Chorus

@MainActor
final class ManifestDiscoveryTests: XCTestCase {
    func testRelativeManifestHandlerWithMixedEntriesRegistersOnlyItsAccountsAndRoutesToChooser() async throws {
        let fixture = try await ManifestFixture(manifests: ["/manifest": .init(body: """
            {"protocol_handlers":[
                null,
                {"protocol":"web+fixture","url":"/other?value=%s"},
                {"protocol":"mailto","url":"/missing-placeholder"},
                {"protocol":"mailto","url":"https://unrelated.example.test/compose?mail=%s"},
                {"protocol":"mailto","url":"compose?mail=%s"}
            ]}
            """)])
        defer { fixture.close() }
        let personal = fixture.addAccount("Personal")
        let work = fixture.addAccount("Work")
        let unrelated = fixture.addAccount("Unrelated")
        try fixture.container.mainContext.save()
        try await fixture.discover(personal, manifest: "/manifest")
        try await fixture.discover(work, manifest: "/manifest")
        for service in [personal, work] {
            XCTAssertEqual(service.mailtoHandlerTemplate, fixture.origin + "/compose?mail=%s")
            XCTAssertEqual(service.mailtoHandlerOrigin, fixture.origin)
            XCTAssertEqual(service.mailtoHandlerEnabled, true)
        }
        XCTAssertNil(unrelated.mailtoHandlerTemplate)
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: "mailto:fixture@example.test?subject=A%26B")))
        let chooser = try XCTUnwrap(fixture.app.pendingMailLink)
        XCTAssertEqual(Set(chooser.candidates.map(\.serviceID)), Set([personal.id, work.id]))
        XCTAssertEqual(Set(chooser.candidates.map(\.label)), Set(["Personal", "Work"]))
        XCTAssertNil(fixture.app.mailLinkError)
        fixture.app.cancelMailLink(chooser.id)
        XCTAssertNil(fixture.app.pendingMailLink)
    }

    func testFixtureCleanupClosesAnyDirectComposerCreatedDuringDiscoveryAssertions() async throws {
        let fixture = try await ManifestFixture(manifests: ["/manifest": .init(body: """
            {"protocol_handlers":[{"protocol":"mailto","url":"/compose?mail=%s"}]}
            """)])
        defer { fixture.close() }
        let service = fixture.addAccount("Cleanup fixture")
        try fixture.container.mainContext.save()
        try await fixture.discover(service, manifest: "/manifest")
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: "mailto:cleanup@example.test")))
        let composer = try XCTUnwrap(NSApp.windows.first {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.contentView is WKWebView
        })
        XCTAssertTrue(composer.isVisible)
        XCTAssertNil(fixture.app.mailLinkError)
        fixture.close()
        XCTAssertFalse(composer.isVisible)
        XCTAssertNil(composer.contentView)
    }

    func testRedirectedManifestResolvesHandlerAgainstActualFinalResponseURL() async throws {
        let fixture = try await ManifestFixture(manifests: [
            "/manifest": .init(body: "", status: "302 Found", headers: ["Location": "/config/deep/app.webmanifest"]),
            "/config/deep/app.webmanifest": .init(body: """
                {"protocol_handlers":[{"protocol":"mailto","url":"../compose?mail=%s"}]}
                """)
        ])
        defer { fixture.close() }
        let service = fixture.addAccount("Redirect fixture")
        try fixture.container.mainContext.save()
        try await fixture.discover(service, manifest: "/manifest")
        XCTAssertTrue(fixture.server.requestedTargets.contains("/manifest"))
        XCTAssertTrue(fixture.server.requestedTargets.contains("/config/deep/app.webmanifest"))
        XCTAssertEqual(service.mailtoHandlerTemplate, fixture.origin + "/config/compose?mail=%s")
        XCTAssertEqual(service.mailtoHandlerOrigin, fixture.origin)
    }

    func testFetchedInvalidManifestsSettleWithoutRegistrationOrPageErrors() async throws {
        let cases: [(String, ComposeFixtureServer.Response)] = [
            ("malformed JSON", .init(body: "{this is not JSON")),
            ("unsuccessful response", .init(body: """
                {"protocol_handlers":[{"protocol":"mailto","url":"/compose?mail=%s"}]}
                """, status: "503 Service Unavailable")),
            ("missing placeholder", .init(body: """
                {"protocol_handlers":[{"protocol":"mailto","url":"/compose"}]}
                """)),
            ("cross-origin handler", .init(body: """
                {"protocol_handlers":[{"protocol":"mailto","url":"https://unrelated.example.test/compose?mail=%s"}]}
                """))
        ]
        for (label, response) in cases {
            let fixture = try await ManifestFixture(manifests: ["/manifest": response])
            defer { fixture.close() }
            let service = fixture.addAccount(label)
            try fixture.container.mainContext.save()
            try await fixture.discover(service, manifest: "/manifest")
            XCTAssertTrue(fixture.server.requestedTargets.contains("/manifest"), label)
            XCTAssertNil(service.mailtoHandlerTemplate, label)
            XCTAssertNil(service.mailtoHandlerOrigin, label)
            XCTAssertNil(service.mailtoHandlerEnabled, label)
            fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: "mailto:rejected@example.test")))
            XCTAssertNotNil(fixture.app.mailLinkError, label)
            XCTAssertNil(fixture.app.pendingMailLink, label)
            fixture.app.dismissMailLinkError(try XCTUnwrap(fixture.app.mailLinkError).id)
        }
    }

    func testRejectedAndRepeatedDiscoveryPreserveExistingRegistrationOptOutAndOtherAccount() async throws {
        let fixture = try await ManifestFixture(manifests: [
            "/valid": .init(body: """
                {"protocol_handlers":[{"protocol":"mailto","url":"/compose?mail=%s"}]}
                """),
            "/invalid": .init(body: """
                {"protocol_handlers":[
                    {"protocol":"mailto","url":"/no-placeholder"},
                    {"protocol":"mailto","url":"https://unrelated.example.test/compose?mail=%s"}
                ]}
                """)
        ])
        defer { fixture.close() }
        let personal = fixture.addAccount("Personal")
        let work = fixture.addAccount("Work")
        try fixture.container.mainContext.save()
        try await fixture.discover(personal, manifest: "/valid")
        personal.mailtoHandlerEnabled = false
        try fixture.container.mainContext.save()
        try await fixture.discover(personal, manifest: "/invalid")
        XCTAssertEqual(personal.mailtoHandlerTemplate, fixture.origin + "/compose?mail=%s")
        XCTAssertEqual(personal.mailtoHandlerOrigin, fixture.origin)
        XCTAssertEqual(personal.mailtoHandlerEnabled, false)
        XCTAssertNil(work.mailtoHandlerTemplate)
        XCTAssertNil(work.mailtoHandlerOrigin)
        XCTAssertNil(work.mailtoHandlerEnabled)
        try await fixture.discover(personal, manifest: "/valid")
        XCTAssertEqual(personal.mailtoHandlerTemplate, fixture.origin + "/compose?mail=%s")
        XCTAssertEqual(personal.mailtoHandlerOrigin, fixture.origin)
        XCTAssertEqual(personal.mailtoHandlerEnabled, false)
        XCTAssertNil(work.mailtoHandlerTemplate)
        XCTAssertNil(work.mailtoHandlerOrigin)
        XCTAssertNil(work.mailtoHandlerEnabled)
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: "mailto:disabled@example.test")))
        XCTAssertNotNil(fixture.app.mailLinkError)
        XCTAssertNil(fixture.app.pendingMailLink)
        fixture.app.dismissMailLinkError(try XCTUnwrap(fixture.app.mailLinkError).id)
    }
}

@MainActor
private final class ManifestFixture {
    let container: ModelContainer
    let app: AppState
    let server: ComposeFixtureServer
    private let certificateData: Data
    private var views: [(WKWebView, DiscoveryObservation)] = []
    private var accountIDs: [UUID] = []

    var origin: String { "https://127.0.0.1:\(server.port)" }

    init(manifests: [String: ComposeFixtureServer.Response]) async throws {
        // This publicly committed identity is only for loopback test transport.
        // SecKeyCreateWithData/SecIdentityCreate keep it in memory, never Keychain.
        let bundle = Bundle(for: ManifestDiscoveryTests.self)
        certificateData = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "loopback-certificate", withExtension: "der")))
        let keyData = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "loopback-private-key", withExtension: "der")))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certificateData as CFData))
        let key = try XCTUnwrap(SecKeyCreateWithData(keyData as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ] as CFDictionary, nil))
        let identity = try XCTUnwrap(SecIdentityCreate(nil, certificate, key))
        var responses = manifests.mapValues { response in
            var response = response
            response.headers["Content-Type"] = "application/manifest+json"
            return response
        }
        for path in manifests.keys {
            responses["/pages" + path] = .init(body: "<link rel='manifest' href='\(path)'><p>Synthetic discovery fixture</p>")
        }
        server = try await ComposeFixtureServer(responses: responses, tlsIdentity: identity)
        container = try ModelContainer(for: Schema(versionedSchema: ChorusSchemaVCurrent.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        app = AppState(modelContainer: container, dataStoreManager: DataStoreManager(makeStore: { _ in .nonPersistent() }))
    }

    func addAccount(_ label: String) -> ServiceInstance {
        let service = ServiceInstance(label: label, url: origin + "/inbox")
        container.mainContext.insert(service)
        accountIDs.append(service.id)
        return service
    }

    func discover(_ service: ServiceInstance, manifest: String) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = app.dataStoreManager.dataStore(for: service)
        let observation = DiscoveryObservation(port: Int(server.port), certificate: certificateData)
        let controller = configuration.userContentController
        controller.add(observation, name: "fixtureDiscovery")
        controller.addUserScript(WKUserScript(source: DiscoveryObservation.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        app.userScriptManager.configureMailHandlerDiscovery(for: service.id, on: controller)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = observation
        views.append((view, observation))
        view.load(URLRequest(url: server.url("/pages" + manifest)))
        let deadline = Date().addingTimeInterval(5)
        while !observation.settled && observation.navigationError == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(observation.navigationError)
        XCTAssertTrue(observation.settled, "The real fetch and JSON processing must settle before checking registration")
        let errors = try await view.evaluateJavaScript("window.fixtureErrors.join('|')") as? String
        XCTAssertEqual(errors, "", "Discovery failures must not escape into the provider page")
    }

    func close() {
        for (view, _) in views {
            view.stopLoading()
            view.navigationDelegate = nil
            let controller = view.configuration.userContentController
            app.userScriptManager.removeMailHandler(on: controller)
            controller.removeScriptMessageHandler(forName: "fixtureDiscovery")
            controller.removeAllUserScripts()
        }
        views.removeAll()
        // Unexpected direct routing must not leak a composer when an assertion
        // fails. Use the pool's account teardown rather than window-count state.
        accountIDs.forEach { app.webViewPool.removeWebView(for: $0) }
        accountIDs.removeAll()
        server.stop()
    }
}

@MainActor
private final class DiscoveryObservation: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let port: Int
    let certificate: Data
    var settled = false
    var navigationError: Error?

    init(port: Int, certificate: Data) {
        self.port = port
        self.certificate = certificate
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host == "127.0.0.1", space.port == port,
           let trust = space.serverTrust,
           let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
           let leaf = chain.first,
           SecCertificateCopyData(leaf) as Data == certificate {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationError = error
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.body as? String == "settled" else { return }
        MainActor.assumeIsolated { settled = true }
    }

    // Observe completion only: native fetch, Response.json and URL are not
    // replaced with fixture answers. The next event-loop turn runs after the
    // discovery promise chain, ordering its bridge messages before this marker.
    static let script = """
        window.fixtureErrors = [];
        window.addEventListener('error', event => window.fixtureErrors.push(String(event.message)));
        window.addEventListener('unhandledrejection', event => window.fixtureErrors.push(String(event.reason)));
        function fixtureSettled() {
            setTimeout(() => window.webkit.messageHandlers.fixtureDiscovery.postMessage('settled'), 0);
        }
        var fixtureFetch = window.fetch;
        window.fetch = function() {
            return fixtureFetch.apply(this, arguments).then(response => {
                if (!response.ok) { fixtureSettled(); return response; }
                var fixtureJSON = response.json;
                response.json = function() { return fixtureJSON.apply(this, arguments).finally(fixtureSettled); };
                return response;
            }, error => { fixtureSettled(); throw error; });
        };
        """
}
