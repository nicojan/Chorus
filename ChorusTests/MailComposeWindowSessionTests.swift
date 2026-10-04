import AppKit
import WebKit
import XCTest
import SwiftData
import SwiftUI
@testable import Chorus

@MainActor
final class MailComposeWindowSessionTests: XCTestCase {
    func testHostedErrorOKRetainsSecondRequestForSeparateAcknowledgment() async throws {
        try await acknowledgeHostedErrors(usingKeyboard: false)
    }

    func testHostedErrorKeyboardRetainsSecondRequestForSeparateAcknowledgment() async throws {
        try await acknowledgeHostedErrors(usingKeyboard: true)
    }

    private func acknowledgeHostedErrors(usingKeyboard: Bool) async throws {
        let container = try ModelContainer(for: Schema(versionedSchema: ChorusSchemaVCurrent.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let app = AppState(modelContainer: container, dataStoreManager: DataStoreManager(makeStore: { _ in .nonPersistent() }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text("Synthetic mail fixture").modifier(MailLinkPresentation(appState: app)))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        app.enqueueMailLink(try XCTUnwrap(URL(string: "mailto:first@example.test?subject=First")))
        let shown = await eventually { window.attachedSheet != nil }
        XCTAssertTrue(shown)
        app.enqueueMailLink(try XCTUnwrap(URL(string: "mailto:second@example.test?subject=Second")))
        let firstSheet = try XCTUnwrap(window.attachedSheet)
        let staleError = try XCTUnwrap(app.mailLinkError)
        if usingKeyboard {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: firstSheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            firstSheet.sendEvent(event)
        } else {
            try XCTUnwrap(button(named: "OK", in: firstSheet.contentView)).performClick(nil)
        }
        let secondShown = await eventually { window.attachedSheet != nil && window.attachedSheet !== firstSheet }
        XCTAssertTrue(secondShown, "One OK click must leave the second error actionable")
        XCTAssertNotNil(app.mailLinkErrorMessage)
        guard secondShown else { return }
        let secondError = try XCTUnwrap(app.mailLinkError)
        app.dismissMailLinkError(staleError.id)
        XCTAssertEqual(app.mailLinkError?.id, secondError.id)
        try XCTUnwrap(button(named: "OK", in: window.attachedSheet?.contentView)).performClick(nil)
        let idle = await eventually { window.attachedSheet == nil && app.mailLinkErrorMessage == nil }
        XCTAssertTrue(idle)
    }

    func testStaleErrorAcknowledgmentCannotConsumeRequestsAcrossLockOrEligibilityChanges() throws {
        let container = try ModelContainer(for: Schema(versionedSchema: ChorusSchemaVCurrent.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let app = AppState(modelContainer: container, dataStoreManager: DataStoreManager(makeStore: { _ in .nonPersistent() }))
        app.enqueueMailLink(try XCTUnwrap(URL(string: "mailto:first@example.test")))
        let beforeLock = try XCTUnwrap(app.mailLinkError)
        app.enqueueMailLink(try XCTUnwrap(URL(string: "mailto:second@example.test")))
        app.appLockEnabled = true
        app.lock()
        app.dismissMailLinkError(beforeLock.id)
        XCTAssertNil(app.mailLinkError)
        app.isLocked = false
        let resumed = try XCTUnwrap(app.mailLinkError)
        app.dismissMailLinkError(beforeLock.id)
        XCTAssertEqual(app.mailLinkError?.id, resumed.id)
        for label in ["First", "Second"] {
            let service = ServiceInstance(label: label, url: "https://fixture.example.test")
            service.mailtoHandlerOrigin = service.url
            service.mailtoHandlerTemplate = service.url + "/compose?mail=%s"
            container.mainContext.insert(service)
        }
        try container.mainContext.save()
        app.dismissMailLinkError(resumed.id)
        let choice = try XCTUnwrap(app.pendingMailLink)
        app.dismissMailLinkError(resumed.id)
        XCTAssertEqual(app.pendingMailLink?.id, choice.id)
        app.cancelMailLink(choice.id)
        XCTAssertNil(app.pendingMailLink)
        XCTAssertNil(app.mailLinkError)
    }

    func testDiscardConfirmationCanBeCancelledThenAccepted() async throws {
        var closeCount = 0
        let session = try await openFixture("""
            <div contenteditable="true">Disposable fixture</div>
            <button id="discard" onclick="if (confirm('Discard fixture?')) window.close()">Discard</button>
            """) { closeCount += 1 }
        defer { session.window.close() }
        let webView = try XCTUnwrap(session.window.contentView as? WKWebView)

        try await webView.evaluateJavaScript("setTimeout(() => document.getElementById('discard').click(), 0); null")
        let presented = await eventually { session.window.attachedSheet != nil }
        XCTAssertTrue(presented, "Provider confirmation must appear instead of silently cancelling")
        guard presented else { return }
        session.window.endSheet(try XCTUnwrap(session.window.attachedSheet), returnCode: .alertSecondButtonReturn)
        let cancelled = await eventually { session.window.attachedSheet == nil }
        XCTAssertTrue(cancelled)
        XCTAssertTrue(session.window.isVisible)
        XCTAssertEqual(closeCount, 0)

        try await webView.evaluateJavaScript("setTimeout(() => document.getElementById('discard').click(), 0); null")
        let presentedAgain = await eventually { session.window.attachedSheet != nil }
        XCTAssertTrue(presentedAgain)
        guard presentedAgain else { return }
        session.window.endSheet(try XCTUnwrap(session.window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let closed = await eventually { closeCount == 1 }
        XCTAssertTrue(closed, "Confirmed provider window.close() must finish the compose session")
        XCTAssertFalse(session.window.isVisible)
        XCTAssertEqual(closeCount, 1)
    }

    func testAlertAndPromptArePresentedInsteadOfSilentlyDismissed() async throws {
        let session = try await openFixture("<script>window.result = null;</script>")
        defer { session.window.close() }
        let webView = try XCTUnwrap(session.window.contentView as? WKWebView)
        try await webView.evaluateJavaScript("setTimeout(() => { alert('Fixture notice'); window.result = prompt('Fixture input', 'default'); }, 0); null")
        let alertShown = await eventually { session.window.attachedSheet != nil }
        XCTAssertTrue(alertShown)
        guard alertShown else { return }
        session.window.endSheet(try XCTUnwrap(session.window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let promptShown = await eventually {
            guard let sheet = session.window.attachedSheet else { return false }
            return self.textField(in: sheet.contentView) != nil
        }
        XCTAssertTrue(promptShown)
        guard promptShown else { return }
        let sheet = try XCTUnwrap(session.window.attachedSheet)
        let field = try XCTUnwrap(textField(in: sheet.contentView))
        XCTAssertEqual(field.stringValue, "default")
        field.stringValue = "fixture response"
        session.window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        let resumed = await eventually {
            (try? await webView.evaluateJavaScript("window.result")) as? String == "fixture response"
        }
        XCTAssertTrue(resumed)
    }

    func testNativeCloseReleasesTheSessionAndWebViewExactlyOnce() async throws {
        var retainedSession: MailComposeWindowSession?
        var closes = 0
        retainedSession = try await openFixture("<div contenteditable='true'>Fixture</div>") {
            closes += 1
            retainedSession = nil
        }
        let window = try XCTUnwrap(retainedSession?.window)
        weak var session = retainedSession
        weak var webView = window.contentView as? WKWebView
        window.performClose(nil) // The standard close action used by red close and Command-W.
        let released = await eventually { session == nil && webView == nil }
        XCTAssertTrue(released)
        XCTAssertNil(window.contentView)
        XCTAssertFalse(window.isVisible)
        window.close()
        XCTAssertEqual(closes, 1)
    }

    func testBriefStartupEditorDoesNotArmCompletionDuringLoading() async throws {
        let session = try await openFixture("""
            <div id="editor" contenteditable="true">Startup placeholder</div>
            <script>
            setTimeout(() => document.getElementById('editor').remove(), 50);
            setTimeout(() => {
                document.body.insertAdjacentHTML('afterbegin', '<div contenteditable="true">Ready</div>');
                window.startupFinished = true;
            }, 1200);
            </script>
            """)
        defer { session.window.close() }
        let webView = try XCTUnwrap(session.window.contentView as? WKWebView)
        let finished = await eventually {
            (try? await webView.evaluateJavaScript("window.startupFinished === true")) as? Bool == true
        }
        XCTAssertTrue(finished)
        XCTAssertTrue(session.window.isVisible, "A transient startup editor must not arm inferred closure")
    }

    func testOnlyStableDisappearanceClosesAnEstablishedComposer() async throws {
        var closes = 0
        let session = try await openFixture("<div id='editor' contenteditable='true'>Fixture signature</div>") { closes += 1 }
        defer { session.window.close() }
        let webView = try XCTUnwrap(session.window.contentView as? WKWebView)
        try await Task.sleep(for: .milliseconds(700))
        // A brief detach, then a replacement with signature-like markup, is not completion.
        try await webView.evaluateJavaScript("""
            var editor = document.getElementById('editor');
            editor.remove();
            setTimeout(() => document.body.appendChild(editor), 100);
            null
            """)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(session.window.isVisible)
        try await webView.evaluateJavaScript("""
            document.getElementById('editor').outerHTML = '<div id="editor" contenteditable="true"><p>Fresh signature</p></div>';
            null
            """)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(session.window.isVisible, "An ambiguous replacement must preserve the draft")
        XCTAssertEqual(closes, 0)

        try await webView.evaluateJavaScript("document.getElementById('editor').remove(); null")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(session.window.isVisible, "Disappearance requires a stability interval")
        let closed = await eventually { closes == 1 }
        XCTAssertTrue(closed, "The installed lifecycle bridge must report stable disappearance")
        XCTAssertFalse(session.window.isVisible)
    }

    func testErrorPageRemainsOpenAndNativeCloseCancelsAnOutstandingDialog() async throws {
        var closes = 0
        let session = try await openFixture("<p>Provider error fixture: no editor</p>") { closes += 1 }
        defer { session.window.close() }
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertTrue(session.window.isVisible)
        let webView = try XCTUnwrap(session.window.contentView as? WKWebView)
        try await webView.evaluateJavaScript("setTimeout(() => confirm('Fixture confirmation'), 0); null")
        let shown = await eventually { session.window.attachedSheet != nil }
        XCTAssertTrue(shown)
        guard shown else { return }
        session.window.close()
        XCTAssertEqual(closes, 1)
        XCTAssertFalse(session.window.isVisible)
        XCTAssertNil(session.window.contentView)
    }

    func testSameOriginChildComposerCanCompleteButCrossOriginSignalsCannot() async throws {
        let untrusted = try await ComposeFixtureServer(pages: ["/": """
            <script>
            window.addEventListener('message', () => {
                window.webkit.messageHandlers.chorusMailHandler.postMessage({composerClosed:true, windowClose:true});
                parent.postMessage('attempted', '*');
            });
            </script>
            """])
        defer { untrusted.stop() }
        let trusted = try await ComposeFixtureServer(pages: ["/": """
            <iframe id="trusted" src="/child"></iframe>
            <iframe id="untrusted" src="\(untrusted.url())"></iframe>
            <script>
            window.onload = () => { window.fixtureReady = true; };
            window.addEventListener('message', () => { window.attempted = true; });
            </script>
            """, "/child": """
            <div id="editor" contenteditable="true">Child fixture</div>
            <script>window.addEventListener('message', () => document.getElementById('editor').remove());</script>
            """])
        defer { trusted.stop() }
        var closes = 0
        let session = try await openURL(trusted.url()) { closes += 1 }
        defer { session.window.close() }
        let webView = try XCTUnwrap(session.window.contentView as? WKWebView)
        try await Task.sleep(for: .milliseconds(700))
        try await webView.evaluateJavaScript("document.getElementById('untrusted').contentWindow.postMessage('try', '*'); null")
        let attempted = await eventually {
            (try? await webView.evaluateJavaScript("window.attempted === true")) as? Bool == true
        }
        XCTAssertTrue(attempted, "Untrusted fixture must actually attempt to close the window")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(session.window.isVisible)
        XCTAssertEqual(closes, 0)
        try await webView.evaluateJavaScript("document.getElementById('trusted').contentWindow.postMessage('complete', '*'); null")
        let closed = await eventually { closes == 1 }
        XCTAssertTrue(closed, "Trusted child-frame lifecycle must reach the native window")
    }

    func testAccountStoresStayIsolatedAndClosingOneRequestLeavesTheOthersUntouched() async throws {
        let server = try await ComposeFixtureServer(pages: ["/": """
            <div contenteditable="true">Fixture</div>
            <script>window.fixtureReady = true;</script>
            """])
        defer { server.stop() }
        let personal = WKWebsiteDataStore.nonPersistent()
        let work = WKWebsiteDataStore.nonPersistent()
        for (store, marker) in [(personal, "personal"), (work, "work")] {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [
                .domain: "127.0.0.1", .path: "/", .name: "fixtureAccount", .value: marker
            ]))
            await store.httpCookieStore.setCookie(cookie)
        }
        let first = try await openURL(server.url(), dataStore: personal)
        let second = try await openURL(server.url(), dataStore: personal)
        let third = try await openURL(server.url(), dataStore: work)
        defer { first.window.close(); second.window.close(); third.window.close() }
        for (session, expected) in [(first, "personal"), (second, "personal"), (third, "work")] {
            let view = try XCTUnwrap(session.window.contentView as? WKWebView)
            let marker = try await view.evaluateJavaScript("document.cookie") as? String
            XCTAssertEqual(marker, "fixtureAccount=\(expected)")
        }
        let otherView = try XCTUnwrap(second.window.contentView as? WKWebView)
        try await otherView.evaluateJavaScript("window.preserved = 17; null")
        first.window.performClose(nil)
        XCTAssertTrue(second.window.isVisible)
        XCTAssertTrue(third.window.isVisible)
        let preserved = try await otherView.evaluateJavaScript("window.preserved") as? Int
        XCTAssertEqual(preserved, 17, "Closing another request must not reload this view")
    }

    func testInitialRedirectAndDelayedEditorRemainOpen() async throws {
        let server = try await ComposeFixtureServer(pages: ["/": """
            <p>Redirecting fixture</p>
            <script>setTimeout(() => location.replace('/compose'), 100);</script>
            """, "/compose": """
            <p>Loading fixture</p>
            <script>
            setTimeout(() => {
                document.body.insertAdjacentHTML('beforeend', '<textarea></textarea>');
                window.fixtureReady = true;
            }, 1000);
            </script>
            """])
        defer { server.stop() }
        let session = try await openURL(server.url())
        defer { session.window.close() }
        XCTAssertTrue(session.window.isVisible)
        let webView = try XCTUnwrap(session.window.contentView as? WKWebView)
        XCTAssertEqual(webView.url, server.url("/compose"))
        let userAgent = try await webView.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(userAgent, UserAgentProvider.safariDefault)
    }

    func testMailLinksReachRoutingOnceWithoutReplacingTheComposer() async throws {
        let mail = "mailto:alice%2Btag@example.test?subject=Hello%20%E2%98%83&body=A%26B%3F%23"
        let server = try await ComposeFixtureServer(pages: ["/": """
            <a id="ordinary" href="\(mail)">Mail</a>
            <a id="newTarget" target="_blank" href="\(mail)">New target</a>
            <a id="web" href="/next">Web link</a>
            <script>window.fixtureReady = true;</script>
            """, "/next": "<p>Ordinary navigation</p>"])
        defer { server.stop() }
        var received: [URL] = []
        let session = MailComposeWindowSession(
            dataStore: .nonPersistent(), userAgent: UserAgentProvider.safariDefault,
            title: "Mail routing fixture", url: server.url(),
            onMailRequest: { received.append($0) }, onClose: {}
        )
        session.show()
        defer { session.window.close() }
        let view = try XCTUnwrap(session.window.contentView as? WKWebView)
        let ready = await eventually {
            (try? await view.evaluateJavaScript("window.fixtureReady === true")) as? Bool == true
        }
        XCTAssertTrue(ready)
        for (index, id) in ["ordinary", "newTarget"].enumerated() {
            try await view.evaluateJavaScript("document.getElementById('\(id)').click()")
            let delivered = await eventually { received.count == index + 1 }
            XCTAssertTrue(delivered)
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(received.map(\.absoluteString), [mail, mail])
        XCTAssertEqual(view.url, server.url())
        XCTAssertTrue(session.window.isVisible)
        try await view.evaluateJavaScript("document.getElementById('web').click()")
        let navigated = await eventually { view.url == server.url("/next") }
        XCTAssertTrue(navigated, "Non-mail navigation must retain its existing behavior")
        XCTAssertEqual(received.count, 2)
    }

    func testApplicationRoutingQueuesRevalidatesAndRetainsIndependentComposers() throws {
        let container = try ModelContainer(
            for: Schema(versionedSchema: ChorusSchemaVCurrent.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let stores = DataStoreManager(makeStore: { _ in .nonPersistent() })
        let app = AppState(modelContainer: container, dataStoreManager: stores)
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        func composers() -> [NSWindow] {
            NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) && $0.contentView is WKWebView }
        }
        defer { composers().forEach { $0.close() } }
        var presentations = 0
        app.openMainWindow = { presentations += 1 }
        let mail = try XCTUnwrap(URL(string: "mailto:fixture@example.test?subject=A%26B"))
        app.enqueueMailLink(mail)
        XCTAssertNotNil(app.mailLinkErrorMessage)
        XCTAssertEqual(presentations, 1)
        app.dismissMailLinkError(try XCTUnwrap(app.mailLinkError).id)

        func addAccount(_ label: String) -> ServiceInstance {
            let service = ServiceInstance(label: label, url: "https://127.0.0.1:1")
            service.mailtoHandlerTemplate = "https://127.0.0.1:1/compose?mail=%s"
            service.mailtoHandlerOrigin = "https://127.0.0.1:1"
            container.mainContext.insert(service)
            return service
        }
        let first = addAccount("First")
        try container.mainContext.save()
        let selectedSpace = UUID()
        app.selectedSpaceID = selectedSpace
        app.enqueueMailLink(mail)
        XCTAssertEqual(composers().count, 1)
        XCTAssertEqual(presentations, 1, "Direct routing must not raise the main window")
        XCTAssertTrue((composers().first?.contentView as? WKWebView)?.configuration.websiteDataStore === stores.dataStore(for: first))
        XCTAssertEqual(app.selectedSpaceID, selectedSpace)
        XCTAssertNil(app.selectedServiceID)

        let second = addAccount("Second")
        try container.mainContext.save()
        app.enqueueMailLink(mail)
        let cancelled = try XCTUnwrap(app.pendingMailLink)
        app.enqueueMailLink(mail)
        app.cancelMailLink(cancelled.id)
        let next = try XCTUnwrap(app.pendingMailLink)
        XCTAssertNotEqual(next.id, cancelled.id)
        second.mailtoHandlerEnabled = false
        app.chooseMailService(second.id, requestID: next.id)
        XCTAssertNotNil(app.mailLinkErrorMessage)
        XCTAssertEqual(composers().count, 1)
        app.enqueueMailLink(mail)
        app.dismissMailLinkError(try XCTUnwrap(app.mailLinkError).id)
        XCTAssertEqual(composers().count, 2, "The next direct route creates an independent compose window")

        second.mailtoHandlerEnabled = true
        app.enqueueMailLink(mail)
        let deletedChoice = try XCTUnwrap(app.pendingMailLink)
        let deletedID = second.id
        container.mainContext.delete(second)
        try container.mainContext.save()
        app.chooseMailService(deletedID, requestID: deletedChoice.id)
        XCTAssertNotNil(app.mailLinkErrorMessage)
        app.dismissMailLinkError(try XCTUnwrap(app.mailLinkError).id)

        app.appLockEnabled = true
        app.lock()
        app.enqueueMailLink(mail)
        app.enqueueMailLink(mail)
        XCTAssertNil(app.pendingMailLink)
        XCTAssertNil(app.mailLinkErrorMessage)
        XCTAssertEqual(composers().count, 2)
        app.isLocked = false
        XCTAssertEqual(composers().count, 4)
        XCTAssertEqual(app.selectedSpaceID, selectedSpace)
        XCTAssertTrue(composers().allSatisfy { $0.isVisible })
    }

    func testComposerClickUsesPoolConnectionToApplicationChooser() async throws {
        let server = try await ComposeFixtureServer(pages: ["/": """
            <a id="mail" target="_blank" href="mailto:fixture@example.test?body=A%26B">Mail</a>
            <script>window.fixtureReady = true;</script>
            """])
        defer { server.stop() }
        let container = try ModelContainer(for: Schema(versionedSchema: ChorusSchemaVCurrent.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let app = AppState(modelContainer: container, dataStoreManager: DataStoreManager(makeStore: { _ in .nonPersistent() }))
        let services = ["First", "Second"].map { label in
            let service = ServiceInstance(label: label, url: "https://127.0.0.1:1")
            service.mailtoHandlerOrigin = service.url
            service.mailtoHandlerTemplate = service.url + "/compose?mail=%s"
            container.mainContext.insert(service)
            return service
        }
        try container.mainContext.save()
        let oldWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        app.webViewPool.openMailComposer(for: services[0], at: server.url())
        let window = try XCTUnwrap(NSApp.windows.first { !oldWindows.contains(ObjectIdentifier($0)) && $0.contentView is WKWebView })
        defer {
            NSApp.windows.filter { !oldWindows.contains(ObjectIdentifier($0)) && $0.contentView is WKWebView }.forEach { $0.close() }
        }
        let inbox = app.webViewPool.webView(for: services[0])
        inbox.loadHTMLString("<script>window.fixtureReady = true; window.draftMarker = 17;</script>", baseURL: server.url())
        defer { app.webViewPool.removeWebView(for: services[0].id) }
        let inboxReady = await eventually { (try? await inbox.evaluateJavaScript("window.fixtureReady === true")) as? Bool == true }
        XCTAssertTrue(inboxReady)
        let selectedSpace = UUID()
        app.selectedSpaceID = selectedSpace
        app.selectedServiceID = services[0].id
        let view = try XCTUnwrap(window.contentView as? WKWebView)
        let ready = await eventually { (try? await view.evaluateJavaScript("window.fixtureReady === true")) as? Bool == true }
        XCTAssertTrue(ready)
        try await view.evaluateJavaScript("document.getElementById('mail').click()")
        let choosing = await eventually { app.pendingMailLink != nil }
        XCTAssertTrue(choosing)
        XCTAssertEqual(app.pendingMailLink?.candidates.count, 2)
        XCTAssertEqual(view.url, server.url())
        XCTAssertTrue(window.isVisible)
        app.cancelMailLink(try XCTUnwrap(app.pendingMailLink).id)
        XCTAssertNil(app.pendingMailLink, "A single click must enqueue exactly one request")
        XCTAssertNil(app.mailLinkErrorMessage)

        try await view.evaluateJavaScript("document.getElementById('mail').click()")
        let choosingAgain = await eventually { app.pendingMailLink != nil }
        XCTAssertTrue(choosingAgain)
        app.chooseMailService(services[1].id, requestID: try XCTUnwrap(app.pendingMailLink).id)
        let composers = NSApp.windows.filter { !oldWindows.contains(ObjectIdentifier($0)) && $0.contentView is WKWebView }
        XCTAssertEqual(composers.count, 2)
        let destination = try XCTUnwrap(composers.first { $0 !== window }?.contentView as? WKWebView)
        XCTAssertTrue(destination.configuration.websiteDataStore === app.dataStoreManager.dataStore(for: services[1]))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(view.url, server.url())
        XCTAssertEqual(app.selectedSpaceID, selectedSpace)
        XCTAssertEqual(app.selectedServiceID, services[0].id)
        let marker = try await inbox.evaluateJavaScript("window.draftMarker") as? Int
        XCTAssertEqual(marker, 17, "Composing must not navigate or reload the inbox")
    }

    func testOrdinaryLinkSelectsFirstLinkedSpaceEvenWhenCurrentSpaceContainsService() throws {
        let container = try ModelContainer(for: Schema(versionedSchema: ChorusSchemaVCurrent.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let app = AppState(modelContainer: container, dataStoreManager: DataStoreManager(makeStore: { _ in .nonPersistent() }))
        let service = ServiceInstance(label: "Linked", url: "https://127.0.0.1:1")
        container.mainContext.insert(service)
        for name in ["First", "Second"] {
            let space = Space(name: name, emoji: "", sortOrder: 0)
            container.mainContext.insert(space)
            let link = SpaceServiceLink(sortOrder: 0, space: space, service: service)
            if link.modelContext == nil { container.mainContext.insert(link) }
        }
        try container.mainContext.save()
        // Materialize the saved relationship before observing its baseline order.
        _ = try container.mainContext.fetch(FetchDescriptor<ServiceInstance>())
        let firstSpace = try XCTUnwrap(service.spaceLinks.first?.liveSpace)
        app.selectedSpaceID = try XCTUnwrap(service.spaceLinks.last?.liveSpace).id
        app.webViewPool.externalLinkHandler?(try XCTUnwrap(URL(string: service.url + "/link")), nil)
        XCTAssertEqual(app.selectedSpaceID, firstSpace.id)
        XCTAssertEqual(app.selectedServiceID, service.id)
        app.webViewPool.removeWebView(for: service.id)
    }

    func testIsolatedApplicationAcceptsConstructedWebKitMailDeclaration() async throws {
        let container = try ModelContainer(for: Schema(versionedSchema: ChorusSchemaVCurrent.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let app = AppState(modelContainer: container, dataStoreManager: DataStoreManager(makeStore: { _ in .nonPersistent() }))
        let service = ServiceInstance(label: "Discovery fixture", url: "https://fixture.example.test")
        container.mainContext.insert(service)
        try container.mainContext.save()
        let inbox = app.webViewPool.webView(for: service)
        defer { app.webViewPool.removeWebView(for: service.id) }
        inbox.loadHTMLString("<script>window.fixtureReady = true;</script>", baseURL: URL(string: service.url))
        let ready = await eventually { (try? await inbox.evaluateJavaScript("window.fixtureReady === true")) as? Bool == true }
        XCTAssertTrue(ready)
        try await inbox.evaluateJavaScript("try { navigator.registerProtocolHandler('mailto', '/compose?mail=%s', 'Fixture'); } catch (_) {}")
        let discovered = await eventually { service.mailtoHandlerTemplate == "https://fixture.example.test/compose?mail=%s" }
        XCTAssertTrue(discovered, "Isolated setup must install the production discovery connection")
        XCTAssertEqual(service.mailtoHandlerOrigin, "https://fixture.example.test")
    }

    func testSubframeDeclarationReachesTheBridgeWithItsFrameState() async throws {
        let scripts = UserScriptManager()
        let stores = DataStoreManager(makeStore: { _ in .nonPersistent() })
        var declarations: [MailHandlerDeclaration] = []
        scripts.onMailHandlerDeclaration = { declarations.append($0) }
        let pool = WebViewPool(
            dataStoreManager: stores, userScriptManager: scripts,
            contentBlocker: ContentBlockerManager(), loadMailProbe: { _, _ in }
        )
        let service = ServiceInstance(label: "Subframe fixture", url: "https://subframe.example.test")
        defer { pool.removeWebView(for: service.id) }
        let webView = pool.webView(for: service)
        webView.loadHTMLString(
            subframeDeclarationPage(
                template: "https://subframe.example.test/compose?mail=%s",
                waitsForDelivery: false),
            baseURL: URL(string: service.url))
        let ready = await fixturePageIsReady(webView)
        XCTAssertTrue(ready)
        let reported = await eventually { declarations.count == 1 }
        XCTAssertTrue(reported, "The bridge must report what the subframe sent")
        XCTAssertEqual(declarations.first?.serviceID, service.id)
        XCTAssertEqual(declarations.first?.isMainFrame, false)
    }

    func testSubframeDeclarationCannotPersistAHandlerAndDoesNotShadowTheMainFrame() async throws {
        let container = try ModelContainer(
            for: Schema(versionedSchema: ChorusSchemaVCurrent.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let app = AppState(modelContainer: container, dataStoreManager: DataStoreManager(makeStore: { _ in .nonPersistent() }))
        let service = ServiceInstance(label: "Subframe rejection fixture", url: "https://fixture.example.test")
        container.mainContext.insert(service)
        try container.mainContext.save()
        let inbox = app.webViewPool.webView(for: service)
        defer { app.webViewPool.removeWebView(for: service.id) }
        let delivery = SubframeDeliveryObservation()
        inbox.configuration.userContentController.add(delivery, name: "fixtureSettled")
        defer { inbox.configuration.userContentController.removeScriptMessageHandler(forName: "fixtureSettled") }
        inbox.loadHTMLString(
            subframeDeclarationPage(
                template: "https://fixture.example.test/subframe?mail=%s",
                waitsForDelivery: true),
            baseURL: URL(string: service.url))
        let ready = await fixturePageIsReady(inbox)
        XCTAssertTrue(ready)
        let subframeProcessed = await eventually { delivery.count == 1 }
        XCTAssertTrue(subframeProcessed, "The subframe declaration must be handled before the intermediate assertion")
        XCTAssertNil(service.mailtoHandlerTemplate, "A subframe declaration must not be stored")
        XCTAssertNil(service.mailtoHandlerOrigin)
        try await inbox.evaluateJavaScript("try { navigator.registerProtocolHandler('mailto', '/compose?mail=%s', 'Fixture'); } catch (_) {}")
        let discovered = await eventually { service.mailtoHandlerTemplate != nil }
        XCTAssertTrue(discovered, "The main frame declaration must still be accepted")
        XCTAssertEqual(
            service.mailtoHandlerTemplate,
            "https://fixture.example.test/compose?mail=%s",
            "The main frame declaration must not be shadowed by the rejected subframe one")
        XCTAssertEqual(service.mailtoHandlerOrigin, "https://fixture.example.test")
    }

    func testDiscoveryCompletionTimeoutAndCancellationAdvanceSerialProbes() async throws {
        for ending in ["completion", "timeout", "cancellation"] {
            let scripts = UserScriptManager()
            let stores = DataStoreManager(makeStore: { _ in .nonPersistent() })
            var loaded: [WKWebView] = []
            var declarations: [UUID] = []
            let pool = WebViewPool(
                dataStoreManager: stores, userScriptManager: scripts,
                contentBlocker: ContentBlockerManager(),
                loadMailProbe: { view, url in
                    loaded.append(view)
                    view.loadHTMLString("<script>window.fixtureReady = true;</script>", baseURL: url)
                }
            )
            scripts.onMailHandlerDeclaration = { declarations.append($0.serviceID) }
            let first = ServiceInstance(label: "First", url: "https://first.example.test")
            let second = ServiceInstance(label: "Second", url: "https://second.example.test")
            pool.probeMailHandler(for: first)
            pool.probeMailHandler(for: second)
            XCTAssertEqual(loaded.count, 1)
            XCTAssertTrue(loaded[0].configuration.websiteDataStore === stores.dataStore(for: first))
            XCTAssertEqual(loaded[0].customUserAgent, UserAgentProvider.chromiumMailHandlerDiscovery)
            let ready = await eventually { (try? await loaded[0].evaluateJavaScript("window.fixtureReady === true")) as? Bool == true }
            XCTAssertTrue(ready)
            switch ending {
            case "completion": pool.completeMailHandlerProbe(for: first.id)
            case "cancellation": pool.removeWebView(for: first.id)
            default: break // The normal post-navigation timeout must advance it.
            }
            let advanced = await eventually { loaded.count == 2 }
            XCTAssertTrue(advanced)
            guard loaded.count == 2 else { continue }
            XCTAssertTrue(loaded[1].configuration.websiteDataStore === stores.dataStore(for: second))
            let secondReady = await eventually { (try? await loaded[1].evaluateJavaScript("window.fixtureReady === true")) as? Bool == true }
            XCTAssertTrue(secondReady)
            let declaration = "try { navigator.registerProtocolHandler('mailto', '/compose?mail=%s', 'Fixture'); } catch (_) {}"
            try await loaded[0].evaluateJavaScript(declaration)
            try await loaded[1].evaluateJavaScript(declaration)
            let published = await eventually { declarations == [second.id] }
            XCTAssertTrue(published, "Abandoned probes cannot publish late declarations")
            pool.completeMailHandlerProbe(for: second.id)
        }
    }

    func testRepeatProbeForOneServiceIsThrottledWhileAnotherServiceStillProbes() async throws {
        let scripts = UserScriptManager()
        let stores = DataStoreManager(makeStore: { _ in .nonPersistent() })
        var loaded: [WKWebView] = []
        let pool = WebViewPool(
            dataStoreManager: stores, userScriptManager: scripts,
            contentBlocker: ContentBlockerManager(),
            loadMailProbe: { view, _ in loaded.append(view) }
        )
        let first = ServiceInstance(label: "First", url: "https://first.example.test")
        let second = ServiceInstance(label: "Second", url: "https://second.example.test")
        pool.probeMailHandler(for: first)
        XCTAssertEqual(loaded.count, 1)
        pool.probeMailHandler(for: first)
        XCTAssertEqual(loaded.count, 1, "A repeat probe inside the window must be skipped")
        pool.completeMailHandlerProbe(for: first.id)
        pool.probeMailHandler(for: first)
        XCTAssertEqual(loaded.count, 1, "Completing a probe must not reset the window")
        pool.probeMailHandler(for: second)
        XCTAssertEqual(loaded.count, 2, "Throttling one service must not block another")
        pool.completeMailHandlerProbe(for: second.id)
    }

    func testStaleChooserActionsCannotExposeErrorsWhileLockedOrReplaceNewerRequests() throws {
        let container = try ModelContainer(for: Schema(versionedSchema: ChorusSchemaVCurrent.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let app = AppState(modelContainer: container, dataStoreManager: DataStoreManager(makeStore: { _ in .nonPersistent() }))
        for label in ["First", "Second"] {
            let service = ServiceInstance(label: label, url: "https://127.0.0.1:1")
            service.mailtoHandlerOrigin = service.url
            service.mailtoHandlerTemplate = service.url + "/compose?mail=%s"
            container.mainContext.insert(service)
        }
        try container.mainContext.save()
        app.enqueueMailLink(try XCTUnwrap(URL(string: "mailto:first@example.test")))
        let stale = try XCTUnwrap(app.pendingMailLink)
        let account = try XCTUnwrap(stale.candidates.first).serviceID
        app.appLockEnabled = true
        app.lock()
        app.chooseMailService(account, requestID: stale.id)
        XCTAssertNil(app.mailLinkErrorMessage)
        XCTAssertNil(app.pendingMailLink)
        app.isLocked = false
        let resumed = try XCTUnwrap(app.pendingMailLink)
        app.chooseMailService(account, requestID: stale.id)
        XCTAssertEqual(app.pendingMailLink?.id, resumed.id)
        XCTAssertNil(app.mailLinkErrorMessage)
        app.cancelMailLink(resumed.id)
        XCTAssertNil(app.pendingMailLink)
    }

    private func openURL(_ url: URL, dataStore: WKWebsiteDataStore = .nonPersistent(), onClose: @escaping () -> Void = {}) async throws -> MailComposeWindowSession {
        let session = MailComposeWindowSession(
            dataStore: dataStore, userAgent: UserAgentProvider.safariDefault,
            title: "Compose fixture", url: url, onClose: onClose
        )
        session.show()
        let webView = try XCTUnwrap(session.window.contentView as? WKWebView)
        let ready = await eventually {
            (try? await webView.evaluateJavaScript("window.fixtureReady === true")) as? Bool == true
        }
        XCTAssertTrue(ready)
        return session
    }

    private func textField(in view: NSView?) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view?.subviews.compactMap { textField(in: $0) }.first
    }

    private func subframeDeclarationPage(template: String, waitsForDelivery: Bool) -> String {
        let settle = waitsForDelivery
            ? "childWindow.webkit.messageHandlers.fixtureSettled.postMessage(null);"
            : ""
        return """
            <!doctype html><html><body>
            <iframe id="declarer"></iframe>
            <script>
                var childWindow = document.getElementById('declarer').contentWindow;
                childWindow.webkit.messageHandlers.chorusMailHandler.postMessage({
                    protocol: 'mailto',
                    template: '\(template)'
                });
                \(settle)
                window.fixtureReady = true;
            </script>
            </body></html>
            """
    }

    private func fixturePageIsReady(_ webView: WKWebView) async -> Bool {
        await eventually {
            (try? await webView.evaluateJavaScript("window.fixtureReady === true")) as? Bool == true
        }
    }

    private func openFixture(_ html: String, onClose: @escaping () -> Void = {}) async throws -> MailComposeWindowSession {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("compose-\(UUID()).html")
        try ("<!doctype html><html><body>" + html + "<script>window.fixtureReady = true;</script></body></html>")
            .write(to: fixture, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        return try await openURL(fixture, onClose: onClose)
    }
}

/// Counts delivery markers the fixture page posts from its subframe, so a test
/// can wait until an earlier declaration from the same frame was handled.
@MainActor
private final class SubframeDeliveryObservation: NSObject, WKScriptMessageHandler {
    private(set) var count = 0

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated { count += 1 }
    }
}
