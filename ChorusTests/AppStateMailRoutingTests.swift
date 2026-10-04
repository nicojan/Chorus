import AppKit
import SwiftData
import SwiftUI
import WebKit
import XCTest
@testable import Chorus

@MainActor
final class AppStateMailRoutingTests: XCTestCase {
    // Independent literals, not destinations recomputed through the router.
    private let firstMail = "mailto:alice%2Btag@example.test?subject=Hello%20%E2%98%83&body=A%26B%3F%23"
    private let firstPayload = "mailto%3Aalice%252Btag%40example.test%3Fsubject%3DHello%2520%25E2%2598%2583%26body%3DA%2526B%253F%2523"
    private let secondMail = "mailto:bob@example.test?subject=Second%3F&body=Line%201%0ALine%202"
    private let secondPayload = "mailto%3Abob%40example.test%3Fsubject%3DSecond%253F%26body%3DLine%25201%250ALine%25202"
    private let thirdMail = "mailto:carol@example.test?subject=Third%23&body=C%2BD"
    private let thirdPayload = "mailto%3Acarol%40example.test%3Fsubject%3DThird%2523%26body%3DC%252BD"

    func testChooserKeepsSortedDistinctSpaceContextAndSeparateInstancesWithDuplicateLabels() async throws {
        let fixture = try await RoutingFixture()
        defer { fixture.close() }
        let first = fixture.addAccount("Shared", path: "/first")
        let second = fixture.addAccount("Shared", path: "/second")
        for name in ["Beta", "Alpha", "Shared", "Alpha"] {
            let space = Space(name: name, emoji: "", sortOrder: 0)
            fixture.container.mainContext.insert(space)
            let link = SpaceServiceLink(sortOrder: 0, space: space, service: first)
            if link.modelContext == nil { fixture.container.mainContext.insert(link) }
        }
        try fixture.container.mainContext.save()
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: firstMail)))
        let chooser = try XCTUnwrap(fixture.app.pendingMailLink)
        let firstCandidate = try XCTUnwrap(chooser.candidates.first { $0.serviceID == first.id })
        let secondCandidate = try XCTUnwrap(chooser.candidates.first { $0.serviceID == second.id })
        XCTAssertEqual(chooser.candidates.count, 2)
        XCTAssertEqual(firstCandidate.label, "Shared")
        XCTAssertEqual(secondCandidate.label, "Shared")
        XCTAssertEqual(firstCandidate.spaceLabels, ["Alpha", "Beta", "Shared"])
        XCTAssertEqual(firstCandidate.chooserSubtitle, "Alpha · Beta")
        XCTAssertEqual(secondCandidate.spaceLabels, [])
        XCTAssertEqual(secondCandidate.chooserSubtitle, "")
        XCTAssertNil(firstCandidate.providerLabel)
        XCTAssertNil(secondCandidate.providerLabel)
        fixture.app.cancelMailLink(chooser.id)
    }

    func testFIFOAccountChoicesAdvanceWhileFirstSuccessfulNavigationIsHeld() async throws {
        let fixture = try await RoutingFixture(holdPaths: ["/first"])
        defer { fixture.close() }
        let personal = fixture.addAccount("Personal", path: "/first")
        let work = fixture.addAccount("Work", path: "/second")
        try fixture.container.mainContext.save()
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: firstMail)))
        let firstChoice = try XCTUnwrap(fixture.app.pendingMailLink)
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: secondMail)))
        fixture.app.chooseMailService(personal.id, requestID: firstChoice.id)
        let first = try XCTUnwrap(fixture.loads.first)
        XCTAssertEqual(first.url.absoluteString, "https://fixture.example.test/first?mail=" + firstPayload)
        XCTAssertTrue(first.view.configuration.websiteDataStore === fixture.stores.dataStore(for: personal))
        let received = await eventually { fixture.server.requestedTargets.contains("/first?mail=" + self.firstPayload) }
        XCTAssertTrue(received, "The server must have accepted a request it has not answered")
        XCTAssertTrue(first.view.isLoading)
        let firstWindow = try XCTUnwrap(first.view.window)
        XCTAssertTrue(firstWindow.isVisible)

        let secondChoice = try XCTUnwrap(fixture.app.pendingMailLink)
        XCTAssertNotEqual(secondChoice.id, firstChoice.id)
        fixture.app.chooseMailService(work.id, requestID: firstChoice.id)
        fixture.app.cancelMailLink(firstChoice.id)
        XCTAssertEqual(fixture.app.pendingMailLink?.id, secondChoice.id)
        fixture.app.chooseMailService(work.id, requestID: secondChoice.id)
        let second = try XCTUnwrap(fixture.loads.last)
        XCTAssertEqual(second.url.absoluteString, "https://fixture.example.test/second?mail=" + secondPayload)
        XCTAssertTrue(second.view.configuration.websiteDataStore === fixture.stores.dataStore(for: work))
        XCTAssertTrue(second.view !== first.view)
        let secondLoaded = await eventually { second.view.url == fixture.server.url("/second?mail=" + self.secondPayload) && !second.view.isLoading }
        XCTAssertTrue(secondLoaded)
        XCTAssertTrue(first.view.isLoading, "Later routing must not wait for the held response")
        XCTAssertTrue(firstWindow.isVisible)
        XCTAssertTrue(firstWindow.contentView === first.view)
        XCTAssertNil(fixture.app.pendingMailLink)
        fixture.server.releaseHeldResponses()
        let firstLoaded = await eventually { first.view.url == fixture.server.url("/first?mail=" + self.firstPayload) && !first.view.isLoading }
        XCTAssertTrue(firstLoaded, "The stall must end in a successful navigation, not a connection failure")
        let marker = try await first.view.evaluateJavaScript("window.fixtureMarker") as? String
        XCTAssertEqual(marker, "retained")
    }

    func testLockResumesOldestAndCancellationRemovesOnlyMatchingDraft() async throws {
        let fixture = try await RoutingFixture()
        defer { fixture.close() }
        let personal = fixture.addAccount("Personal", path: "/first")
        _ = fixture.addAccount("Work", path: "/second")
        try fixture.container.mainContext.save()
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: thirdMail)))
        let cancelled = try XCTUnwrap(fixture.app.pendingMailLink)
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: firstMail)))
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: secondMail)))
        fixture.app.cancelMailLink(cancelled.id)
        let beforeLock = try XCTUnwrap(fixture.app.pendingMailLink)
        fixture.app.appLockEnabled = true
        fixture.app.lock()
        fixture.app.chooseMailService(personal.id, requestID: beforeLock.id)
        fixture.app.cancelMailLink(beforeLock.id)
        XCTAssertNil(fixture.app.pendingMailLink)
        XCTAssertTrue(fixture.loads.isEmpty)
        fixture.app.isLocked = false
        let resumed = try XCTUnwrap(fixture.app.pendingMailLink)
        fixture.app.cancelMailLink(beforeLock.id)
        XCTAssertEqual(fixture.app.pendingMailLink?.id, resumed.id)
        fixture.app.chooseMailService(personal.id, requestID: resumed.id)
        let first = try XCTUnwrap(fixture.loads.first)
        XCTAssertEqual(first.url.absoluteString, "https://fixture.example.test/first?mail=" + firstPayload)
        fixture.app.chooseMailService(personal.id, requestID: try XCTUnwrap(fixture.app.pendingMailLink).id)
        let second = try XCTUnwrap(fixture.loads.last)
        XCTAssertEqual(second.url.absoluteString, "https://fixture.example.test/first?mail=" + secondPayload)
        XCTAssertTrue(first.view !== second.view)
        XCTAssertTrue(first.view.configuration.websiteDataStore === second.view.configuration.websiteDataStore)
        XCTAssertTrue(first.view.configuration.websiteDataStore === fixture.stores.dataStore(for: personal))
        let loaded = await eventually { !first.view.isLoading && !second.view.isLoading && first.view.url != nil && second.view.url != nil }
        XCTAssertTrue(loaded)
        XCTAssertTrue(try XCTUnwrap(first.view.window).isVisible)
        XCTAssertTrue(try XCTUnwrap(second.view.window).isVisible)
        XCTAssertFalse(fixture.server.requestedTargets.contains { $0.contains(self.thirdPayload) })
        XCTAssertNil(fixture.app.pendingMailLink)
        XCTAssertNil(fixture.app.mailLinkError)
    }

    func testErrorToDirectRouteLeavesExistingComposerAndInboxUntouched() async throws {
        let fixture = try await RoutingFixture()
        defer { fixture.close() }
        let personal = fixture.addAccount("Personal", path: "/first")
        try fixture.container.mainContext.save()
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: firstMail)))
        let first = try XCTUnwrap(fixture.loads.first)
        let loaded = await eventually { !first.view.isLoading && first.view.url != nil }
        XCTAssertTrue(loaded)
        try await first.view.evaluateJavaScript("window.draftMarker = 29; null")
        let inbox = fixture.app.webViewPool.webView(for: personal)
        defer { fixture.app.webViewPool.removeWebView(for: personal.id) }
        inbox.loadHTMLString("<script>window.inboxMarker = 17;</script>", baseURL: fixture.server.url())
        let inboxReady = await eventually { (try? await inbox.evaluateJavaScript("window.inboxMarker")) as? Int == 17 }
        XCTAssertTrue(inboxReady)
        let space = UUID()
        fixture.app.selectedSpaceID = space
        fixture.app.selectedServiceID = personal.id
        var mainPresentations = 0
        fixture.app.openMainWindow = { mainPresentations += 1 }
        personal.mailtoHandlerEnabled = false
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: thirdMail)))
        let failed = try XCTUnwrap(fixture.app.mailLinkError)
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: secondMail)))
        personal.mailtoHandlerEnabled = true
        fixture.app.dismissMailLinkError(failed.id)
        fixture.app.dismissMailLinkError(failed.id)
        XCTAssertEqual(fixture.loads.count, 2)
        XCTAssertEqual(fixture.loads.last?.url.absoluteString, "https://fixture.example.test/first?mail=" + secondPayload)
        XCTAssertEqual(mainPresentations, 1, "The direct next route must not raise the main window")
        XCTAssertEqual(fixture.app.selectedSpaceID, space)
        XCTAssertEqual(fixture.app.selectedServiceID, personal.id)
        XCTAssertTrue(try XCTUnwrap(first.view.window).isVisible)
        let draftMarker = try await first.view.evaluateJavaScript("window.draftMarker") as? Int
        XCTAssertEqual(draftMarker, 29)
        let inboxMarker = try await inbox.evaluateJavaScript("window.inboxMarker") as? Int
        XCTAssertEqual(inboxMarker, 17)
        XCTAssertEqual(first.view.url, fixture.server.url("/first?mail=" + firstPayload))
        XCTAssertNil(fixture.app.mailLinkError)
        XCTAssertNil(fixture.app.pendingMailLink)
    }

    func testHostedErrorCompletionPreservesNextChooser() async throws {
        let fixture = try await RoutingFixture()
        let window = hostMailPresentation(fixture.app)
        defer { window.close(); fixture.close() }
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: thirdMail)))
        let shown = await eventually { window.attachedSheet != nil }
        XCTAssertTrue(shown)
        let oldSheet = try XCTUnwrap(window.attachedSheet)
        let oldError = try XCTUnwrap(fixture.app.mailLinkError)
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: firstMail)))
        let personal = fixture.addAccount("Personal", path: "/first")
        _ = fixture.addAccount("Work", path: "/second")
        try fixture.container.mainContext.save()
        try XCTUnwrap(button(named: "OK", in: oldSheet.contentView)).performClick(nil)
        let choosing = await eventually { window.attachedSheet != nil && window.attachedSheet !== oldSheet && fixture.app.pendingMailLink != nil }
        XCTAssertTrue(choosing, "Closing the error must leave the production account chooser visible")
        let choice = try XCTUnwrap(fixture.app.pendingMailLink)
        fixture.app.dismissMailLinkError(oldError.id)
        XCTAssertEqual(fixture.app.pendingMailLink?.id, choice.id)
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: secondMail)))
        let firstChooserSheet = try XCTUnwrap(window.attachedSheet)
        fixture.app.chooseMailService(personal.id, requestID: choice.id)
        let nextChooser = await eventually { window.attachedSheet != nil && window.attachedSheet !== firstChooserSheet && fixture.app.pendingMailLink != nil }
        XCTAssertTrue(nextChooser, "Completion callbacks for the first chooser must not cancel the next one")
        let next = try XCTUnwrap(fixture.app.pendingMailLink)
        fixture.app.cancelMailLink(choice.id)
        XCTAssertEqual(fixture.app.pendingMailLink?.id, next.id)
        fixture.app.cancelMailLink(next.id)
        let closed = await eventually { window.attachedSheet == nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(fixture.loads.count, 1)
        XCTAssertEqual(fixture.loads.first?.url.absoluteString, "https://fixture.example.test/first?mail=" + firstPayload)
    }

    func testHostedErrorCompletionCreatesExactlyOneNextDirectComposer() async throws {
        let fixture = try await RoutingFixture()
        let window = hostMailPresentation(fixture.app)
        defer { window.close(); fixture.close() }
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: thirdMail)))
        let shown = await eventually { window.attachedSheet != nil }
        XCTAssertTrue(shown)
        let oldError = try XCTUnwrap(fixture.app.mailLinkError)
        fixture.app.enqueueMailLink(try XCTUnwrap(URL(string: secondMail)))
        _ = fixture.addAccount("Personal", path: "/first")
        try fixture.container.mainContext.save()
        try XCTUnwrap(button(named: "OK", in: window.attachedSheet?.contentView)).performClick(nil)
        let closed = await eventually { window.attachedSheet == nil }
        XCTAssertTrue(closed)
        fixture.app.dismissMailLinkError(oldError.id)
        XCTAssertEqual(fixture.loads.count, 1)
        XCTAssertEqual(fixture.loads.first?.url.absoluteString, "https://fixture.example.test/first?mail=" + secondPayload)
        XCTAssertTrue(try XCTUnwrap(fixture.loads.first?.view.window).isVisible)
        XCTAssertNil(fixture.app.pendingMailLink)
        XCTAssertNil(fixture.app.mailLinkError)
    }

    private func hostMailPresentation(_ app: AppState) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Text("Synthetic routing fixture").modifier(MailLinkPresentation(appState: app)))
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

/// Changes only the page-loading boundary from the trusted synthetic HTTPS
/// destination to loopback HTTP. AppState, the pool, views and windows are real.
@MainActor
private final class RoutingFixture {
    let container: ModelContainer
    let stores = DataStoreManager(makeStore: { _ in .nonPersistent() })
    let server: ComposeFixtureServer
    private(set) var app: AppState!
    private(set) var loads: [(view: WKWebView, url: URL)] = []

    init(holdPaths: Set<String> = []) async throws {
        server = try await ComposeFixtureServer(pages: [
            "/first": "<script>window.fixtureMarker = 'retained';</script><textarea></textarea>",
            "/second": "<textarea></textarea>"
        ], holdPaths: holdPaths)
        container = try ModelContainer(for: Schema(versionedSchema: ChorusSchemaVCurrent.self), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        app = AppState(modelContainer: container, dataStoreManager: stores, loadMailComposer: { [weak self] view, destination in
            guard let self else { return }
            self.loads.append((view, destination))
            view.load(URLRequest(url: self.server.url(destination.path + "?" + (destination.query ?? ""))))
        })
    }

    func addAccount(_ label: String, path: String) -> ServiceInstance {
        let service = ServiceInstance(label: label, url: "https://fixture.example.test")
        service.mailtoHandlerOrigin = service.url
        service.mailtoHandlerTemplate = service.url + path + "?mail=%s"
        container.mainContext.insert(service)
        return service
    }

    func close() {
        loads.forEach { $0.view.window?.close() }
        loads.removeAll()
        server.stop()
    }
}
