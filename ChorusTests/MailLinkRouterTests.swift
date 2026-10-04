import XCTest
import SwiftData
import JavaScriptCore
@testable import Chorus

@MainActor
final class MailLinkRouterTests: XCTestCase {
    private let gmailID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let outlookID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testValidDeclarationRoutesOneServiceAndPreservesTheWholeMailURL() throws {
        let request = try XCTUnwrap(URL(string: "mailto:one@example.com,two@example.com?cc=c@example.com&bcc=b@example.com&subject=Hello%20%E2%98%83&body=first%20line%0Asecond%20line%20%26%20more"))
        let registration = try XCTUnwrap(MailLinkRouter.registration(
            account: MailLinkAccount(serviceID: gmailID, label: "Personal Gmail", providerLabel: "Gmail", spaceLabels: ["Personal"]),
            serviceURL: "https://mail.google.com/mail/u/0/",
            protocolName: "MAILTO",
            handlerTemplate: "https://mail.google.com/mail/?extsrc=mailto&url=%s",
            declaringPageURL: "https://mail.google.com/mail/u/0/",
            isMainFrame: true,
            enabled: true
        ))

        let outcome = MailLinkRouter.route(request, registrations: [registration])
        guard case .open(let destination) = outcome else {
            return XCTFail("Expected direct open, got \(outcome)")
        }
        XCTAssertEqual(destination.serviceID, gmailID)
        let encoded = try XCTUnwrap(destination.url.absoluteString.components(separatedBy: "url=").last)
        XCTAssertEqual(encoded.removingPercentEncoding, request.absoluteString)
    }

    func testSeveralDistinctInstancesRequireAChoiceAndDuplicateInstanceIsRemoved() throws {
        let gmail = try makeRegistration(id: gmailID, label: "Work", host: "mail.google.com")
        let outlook = try makeRegistration(id: outlookID, label: "Work", host: "outlook.office.com")
        let request = try XCTUnwrap(URL(string: "mailto:person@example.com"))

        let outcome = MailLinkRouter.route(request, registrations: [gmail, gmail, outlook])
        guard case .choose(let candidates) = outcome else {
            return XCTFail("Expected chooser, got \(outcome)")
        }
        XCTAssertEqual(candidates.map(\.serviceID), [gmailID, outlookID])
        XCTAssertEqual(candidates.map(\.label), ["Work", "Work"])
    }

    func testIneligibleRegistrationDoesNotShadowAnEligibleOneForTheSameService() throws {
        let valid = try makeRegistration(id: gmailID, label: "Mail", host: "mail.example.com")
        let ineligible = MailLinkRegistration(
            account: valid.account,
            serviceURL: valid.serviceURL,
            handlerTemplate: "https://other.example.com/compose?url=%s",
            declaringOrigin: valid.declaringOrigin,
            enabled: true
        )
        let request = try XCTUnwrap(URL(string: "mailto:person@example.com"))

        guard case .open(let destination) = MailLinkRouter.route(request, registrations: [ineligible, valid]) else {
            return XCTFail("An ineligible first registration must not shadow the eligible one")
        }
        XCTAssertEqual(destination.serviceID, gmailID)
    }

    func testChooserPreservesDistinctIdentityAndDisplayContextForDuplicateLabels() throws {
        let first = try XCTUnwrap(MailLinkRouter.registration(
            account: MailLinkAccount(serviceID: gmailID, label: "Shared", providerLabel: "Shared", spaceLabels: ["", "Shared", "Personal", "Work"]),
            serviceURL: "https://mail.example.test", protocolName: "mailto", handlerTemplate: "/compose?mail=%s",
            declaringPageURL: "https://mail.example.test/inbox", isMainFrame: true, enabled: true
        ))
        let second = try XCTUnwrap(MailLinkRouter.registration(
            account: MailLinkAccount(serviceID: outlookID, label: "Shared", providerLabel: "Fixture Mail", spaceLabels: ["Other"]),
            serviceURL: "https://mail.example.test", protocolName: "mailto", handlerTemplate: "/compose?mail=%s",
            declaringPageURL: "https://mail.example.test/inbox", isMainFrame: true, enabled: true
        ))
        guard case .choose(let candidates) = MailLinkRouter.route(URL(string: "mailto:fixture@example.test")!, registrations: [first, second, first]) else {
            return XCTFail("Distinct instances with duplicate labels must require a choice")
        }
        XCTAssertEqual(candidates.map(\.id), [gmailID, outlookID])
        XCTAssertEqual(candidates.map(\.label), ["Shared", "Shared"])
        XCTAssertEqual(candidates.map(\.providerLabel), ["Shared", "Fixture Mail"])
        XCTAssertEqual(candidates.map(\.spaceLabels), [["", "Shared", "Personal", "Work"], ["Other"]])
        XCTAssertEqual(candidates.map(\.chooserSubtitle), ["Personal · Work", "Fixture Mail · Other"])
    }

    func testStoredTemplatesAreRevalidatedWithoutNormalizingUntrustedOriginStrings() throws {
        for (template, origin) in [
            ("https://mail.example.test/compose", "https://mail.example.test"),
            ("https://mail.example.test/compose?a=%s&b=%s", "https://mail.example.test"),
            ("http://mail.example.test/compose?mail=%s", "https://mail.example.test"),
            ("https://other.example.test/compose?mail=%s", "https://mail.example.test"),
            ("https://mail.example.test/compose?mail=%s", "https://mail.example.test/untrusted-path")
        ] {
            let registration = MailLinkRegistration(
                account: MailLinkAccount(serviceID: gmailID, label: "Fixture", providerLabel: nil, spaceLabels: []),
                serviceURL: "https://mail.example.test", handlerTemplate: template, declaringOrigin: origin, enabled: true
            )
            let mail = try XCTUnwrap(URL(string: "mailto:fixture@example.test"))
            XCTAssertEqual(MailLinkRouter.route(mail, registrations: [registration]), .noEligibleService)
            XCTAssertNil(MailLinkRouter.destination(for: mail, serviceID: gmailID, registrations: [registration]))
        }
    }

    func testNoEligibleAndInvalidRequestAreDifferentOutcomes() throws {
        let disabled = try makeRegistration(id: gmailID, label: "Gmail", host: "mail.google.com", enabled: false)
        XCTAssertEqual(
            MailLinkRouter.route(URL(string: "mailto:a@example.com")!, registrations: [disabled]),
            .noEligibleService
        )
        XCTAssertEqual(
            MailLinkRouter.route(URL(string: "tel:+15551212")!, registrations: [disabled]),
            .rejectInvalidRequest
        )
    }

    func testDeclarationValidationRejectsEveryUntrustedShape() throws {
        func accepted(
            page: String = "https://mail.example.com/inbox",
            service: String = "https://mail.example.com/",
            proto: String = "mailto",
            template: String = "https://mail.example.com/compose?url=%s",
            main: Bool = true
        ) -> Bool {
            MailLinkRouter.registration(
                account: MailLinkAccount(serviceID: gmailID, label: "Mail", providerLabel: nil, spaceLabels: []),
                serviceURL: service, protocolName: proto, handlerTemplate: template,
                declaringPageURL: page, isMainFrame: main, enabled: true
            ) != nil
        }

        XCTAssertTrue(accepted())
        XCTAssertFalse(accepted(main: false))
        XCTAssertFalse(accepted(proto: "web+mail"))
        XCTAssertFalse(accepted(template: "http://mail.example.com/compose?url=%s"))
        XCTAssertFalse(accepted(template: "https://evil.example/compose?url=%s"))
        XCTAssertFalse(accepted(template: "https://mail.example.com/compose"))
        XCTAssertFalse(accepted(template: "https://mail.example.com/compose?a=%s&b=%s"))
        XCTAssertFalse(accepted(template: "://not a URL %s"))
        XCTAssertFalse(accepted(page: "https://sub.mail.example.com", service: "https://mail.example.com"))
        XCTAssertFalse(accepted(page: "https://mail.example.com", service: "https://mail.example.com:444"))
    }

    func testDefaultHTTPSPortIsTheSameOrigin() {
        XCTAssertNotNil(MailLinkRouter.registration(
            account: MailLinkAccount(serviceID: gmailID, label: "Mail", providerLabel: nil, spaceLabels: []),
            serviceURL: "https://mail.example.com:443/home", protocolName: "mailto",
            handlerTemplate: "https://mail.example.com/compose?url=%s",
            declaringPageURL: "https://mail.example.com/inbox", isMainFrame: true, enabled: true
        ))
    }

    func testStoredRegistrationBecomesIneligibleWhenServiceOriginChanges() throws {
        let registration = try makeRegistration(id: gmailID, label: "Mail", host: "mail.example.com")
            .withServiceURL("https://calendar.example.com")
        XCTAssertEqual(
            MailLinkRouter.route(URL(string: "mailto:a@example.com")!, registrations: [registration]),
            .noEligibleService
        )
    }

    func testWindowCloseShimReportsAndPreservesThePagesCloseCall() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            var messages = [];
            var originalCloseCalls = 0;
            this.window = this;
            window.close = function() { originalCloseCalls += 1; return 17; };
            window.webkit = { messageHandlers: { chorusMailHandler: {
                postMessage: function(value) { messages.push(value); }
            } } };
        """)
        context.evaluateScript(UserScriptManager.makeWindowCloseInterceptionScript())
        let result = context.evaluateScript("window.close()")
        XCTAssertEqual(result?.toInt32(), 17)
        XCTAssertEqual(context.evaluateScript("originalCloseCalls")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("messages.length")?.toInt32(), 1)
        XCTAssertTrue(context.evaluateScript("messages[0].windowClose")?.toBool() == true)
    }

    func testRegistrationShimPreservesNativeFunctionAndCapturesArguments() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            var captured = [];
            var nativeArgs = [];
            this.window = this;
            this.navigator = {
                registerProtocolHandler: function() {
                    nativeArgs = Array.prototype.slice.call(arguments);
                    return 42;
                }
            };
            window.webkit = { messageHandlers: { chorusMailHandler: {
                postMessage: function(value) { captured.push(value); }
            } } };
        """)
        context.evaluateScript(UserScriptManager.makeMailHandlerRegistrationScript())
        let result = context.evaluateScript("navigator.registerProtocolHandler('mailto', '/compose?u=%s', 'Mail')")
        XCTAssertEqual(result?.toInt32(), 42)
        XCTAssertEqual(context.evaluateScript("nativeArgs.join('|')")?.toString(), "mailto|/compose?u=%s|Mail")
        XCTAssertEqual(context.evaluateScript("captured[0].protocol")?.toString(), "mailto")
        XCTAssertEqual(context.evaluateScript("captured[0].template")?.toString(), "/compose?u=%s")
    }

    func testRegistrationShimReportsOnceAndPreservesThrowingNativeCall() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            var captured = [], nativeArgs = [], nativeReceiver = null, calls = 0, order = [];
            var nativeError = new Error('Synthetic native registration failure');
            this.window = this;
            this.navigator = {
                registerProtocolHandler: function() {
                    calls += 1;
                    order.push('native');
                    nativeReceiver = this;
                    nativeArgs = Array.prototype.slice.call(arguments);
                    throw nativeError;
                }
            };
            window.webkit = { messageHandlers: { chorusMailHandler: {
                postMessage: function(value) { order.push('bridge'); captured.push(value); }
            } } };
        """)
        context.evaluateScript(UserScriptManager.makeMailHandlerRegistrationScript())
        context.evaluateScript("""
            var caught = null;
            var extra = { fixture: true };
            try { navigator.registerProtocolHandler('mailto', '/compose?u=%s', 'Fixture', extra); }
            catch (error) { caught = error; }
        """)
        XCTAssertTrue(context.evaluateScript("caught === nativeError")?.toBool() == true)
        XCTAssertTrue(context.evaluateScript("nativeReceiver === navigator")?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("nativeArgs.length")?.toInt32(), 4)
        XCTAssertEqual(context.evaluateScript("nativeArgs.slice(0, 3).join('|')")?.toString(), "mailto|/compose?u=%s|Fixture")
        XCTAssertTrue(context.evaluateScript("nativeArgs[3] === extra")?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("calls")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("captured.length")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("captured[0].protocol")?.toString(), "mailto")
        XCTAssertEqual(context.evaluateScript("captured[0].template")?.toString(), "/compose?u=%s")
        XCTAssertEqual(context.evaluateScript("order.join('|')")?.toString(), "bridge|native")
        XCTAssertNil(context.exception)
    }

    func testRegistrationShimSuppliesMailtoSurfaceWhenNativeFunctionIsAbsent() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            var captured = [];
            this.window = this;
            this.navigator = {};
            window.webkit = { messageHandlers: { chorusMailHandler: {
                postMessage: function(value) { captured.push(value); }
            } } };
        """)
        context.evaluateScript(UserScriptManager.makeMailHandlerRegistrationScript())
        context.evaluateScript("navigator.registerProtocolHandler('mailto', 'https://mail.example/compose?u=%s')")
        XCTAssertEqual(context.evaluateScript("captured.length")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("captured[0].protocol")?.toString(), "mailto")
    }

    func testWebNavigationRoutesOnlyClickedMailtoInternally() {
        let mail = URL(string: "mailto:person@example.com")!
        XCTAssertEqual(
            WebViewCoordinator.nonWebNavigationAction(for: mail, navigationType: .linkActivated),
            .routeMail
        )
        XCTAssertEqual(
            WebViewCoordinator.nonWebNavigationAction(for: mail, navigationType: .other),
            .cancel
        )
        XCTAssertEqual(
            WebViewCoordinator.nonWebNavigationAction(
                for: URL(string: "tel:+15551212")!, navigationType: .linkActivated),
            .openSystem
        )
        XCTAssertNil(WebViewCoordinator.nonWebNavigationAction(
            for: URL(string: "https://example.com")!, navigationType: .linkActivated))
    }

    func testProbeThrottleAllowsOneAttemptPerServicePerWindow() {
        var throttle = MailHandlerProbeThrottle(window: 300)
        let first = UUID(), second = UUID()
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertTrue(throttle.allowsProbe(for: first, at: start))
        XCTAssertFalse(throttle.allowsProbe(for: first, at: start.addingTimeInterval(299)))
        XCTAssertTrue(throttle.allowsProbe(for: first, at: start.addingTimeInterval(300)))
        XCTAssertTrue(throttle.allowsProbe(for: second, at: start))

        throttle.reset(for: first)
        XCTAssertTrue(throttle.allowsProbe(for: first, at: start.addingTimeInterval(301)))
    }

    func testMailHandlerProbeQueueRunsOneServiceAtATimeAndDeduplicates() {
        let first = UUID(), second = UUID()
        var queue = MailHandlerProbeQueue()
        XCTAssertTrue(queue.enqueue(first))
        XCTAssertFalse(queue.enqueue(first))
        XCTAssertTrue(queue.enqueue(second))
        XCTAssertEqual(queue.beginNext(), first)
        XCTAssertNil(queue.beginNext())
        XCTAssertFalse(queue.enqueue(first))
        XCTAssertTrue(queue.finish(first))
        XCTAssertEqual(queue.beginNext(), second)
        XCTAssertTrue(queue.finish(second))
        XCTAssertNil(queue.beginNext())
    }

    func testChromiumCompatibilityUserAgentAdvertisesOnlyForDiscovery() {
        XCTAssertTrue(UserAgentProvider.chromiumMailHandlerDiscovery.contains("Chrome/"))
        XCTAssertTrue(UserAgentProvider.safariDefault.contains("Version/"))
        XCTAssertNotEqual(
            UserAgentProvider.chromiumMailHandlerDiscovery,
            UserAgentProvider.safariDefault
        )
    }

    func testQueueRetainsOrderAndHidesCurrentWhileLocked() {
        let first = URL(string: "mailto:first@example.com")!
        let second = URL(string: "mailto:second@example.com")!
        var queue = MailLinkRequestQueue()
        queue.enqueue(first)
        queue.enqueue(second)
        XCTAssertEqual(queue.current, first)

        queue.isLocked = true
        XCTAssertNil(queue.current)
        queue.isLocked = false
        XCTAssertEqual(queue.current, first)
        XCTAssertEqual(queue.completeCurrent(), first)
        XCTAssertEqual(queue.current, second)
    }

    func testAcceptedRequestsKeepTheirOwnAccountAndDestinationWhenQueueAdvances() throws {
        let personal = try makeRegistration(id: gmailID, label: "Personal", host: "mail.example")
        let work = try makeRegistration(id: outlookID, label: "Work", host: "mail.example")
        var queue = MailLinkRequestQueue()
        queue.enqueue(URL(string: "mailto:first@example.com")!)
        queue.enqueue(URL(string: "mailto:second@example.com")!)
        let first = try XCTUnwrap(MailLinkRouter.destination(
            for: XCTUnwrap(queue.current), serviceID: work.serviceID, registrations: [personal, work]
        ))
        // The caller acknowledges window creation, not navigation or closure.
        queue.completeCurrent()
        let second = try XCTUnwrap(MailLinkRouter.destination(
            for: XCTUnwrap(queue.current), serviceID: personal.serviceID, registrations: [personal, work]
        ))
        queue.completeCurrent()
        XCTAssertNil(queue.current)
        XCTAssertEqual(first.serviceID, outlookID)
        XCTAssertEqual(first.url.absoluteString, "https://mail.example/compose?url=mailto%3Afirst%40example.com")
        XCTAssertEqual(second.serviceID, gmailID)
        XCTAssertEqual(second.url.absoluteString, "https://mail.example/compose?url=mailto%3Asecond%40example.com")
    }

    func testMigrates1_5_19ServiceWithMailFieldsUnset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "chorus-mail-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "default.store")
        let id = UUID()

        try autoreleasepool {
            let oldSchema = Schema(versionedSchema: ChorusSchemaV1_5_19.self)
            let oldConfig = ModelConfiguration(schema: oldSchema, url: storeURL)
            let oldContainer = try ModelContainer(for: oldSchema, configurations: [oldConfig])
            let service = ChorusSchemaV1_5_19.ServiceInstance(
                id: id, label: "Existing Mail", url: "https://mail.example.com")
            oldContainer.mainContext.insert(service)
            try oldContainer.mainContext.save()
        }

        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let config = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema, migrationPlan: ChorusMigrationPlan.self, configurations: [config])
        let service = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<ServiceInstance>()).first)
        XCTAssertEqual(service.id, id)
        XCTAssertEqual(service.label, "Existing Mail")
        XCTAssertNil(service.mailtoHandlerTemplate)
        XCTAssertNil(service.mailtoHandlerOrigin)
        XCTAssertNil(service.mailtoHandlerEnabled)
    }

    private func makeRegistration(
        id: UUID,
        label: String,
        host: String,
        enabled: Bool = true
    ) throws -> MailLinkRegistration {
        try XCTUnwrap(MailLinkRouter.registration(
            account: MailLinkAccount(serviceID: id, label: label, providerLabel: label, spaceLabels: ["Work"]),
            serviceURL: "https://\(host)/",
            protocolName: "mailto", handlerTemplate: "https://\(host)/compose?url=%s",
            declaringPageURL: "https://\(host)/inbox", isMainFrame: true, enabled: enabled
        ))
    }
}
