import AppKit
import WebKit
import XCTest
@testable import Chorus

@MainActor
final class WebViewDepartureTests: XCTestCase {
    func testDepartureClearsNativeHoverWithoutMovingThePointer() async throws {
        let (window, webView) = try await hoveredFixture()
        defer { window.close() }
        let cursorBefore = NSEvent.mouseLocation

        WebViewDeparture.endHover(in: webView)

        try await waitUntil(webView, "!document.getElementById('target').matches(':hover') && window.trustedExits > 0")
        XCTAssertEqual(NSEvent.mouseLocation, cursorBefore)
    }

    func testHideCommandDoesNotWaitAndClearsNativeHover() async throws {
        let (window, webView) = try await hoveredFixture()
        let wasHidden = NSApp.isHidden
        defer {
            if wasHidden { NSApp.hide(nil) } else { NSApp.unhideWithoutActivation() }
            window.close()
        }
        let started = ContinuousClock.now

        WebViewDeparture.hideApplication()

        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        // AppKit can refuse to hide an inactive app on a locked runner. Test
        // the command's departure policy here; actual hiding is a live check.
        NSApp.unhideWithoutActivation()
        try await waitUntil(webView, "window.trustedExits > 0 && !document.getElementById('target').matches(':hover')")
    }

    func testDestructiveDepartureAllowsWorkStartedByHoverExit() async throws {
        let (window, webView) = try await hoveredFixture()
        defer { window.close() }

        await WebViewDeparture.prepareForDestruction(in: [webView])

        let status = try await webView.evaluateJavaScript("document.getElementById('status').textContent")
        XCTAssertEqual(status as? String, "Saved")
    }

    func testSwitchingViewsEndsTheOutgoingPagesHover() async throws {
        let (window, webView) = try await hoveredFixture()
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView as? WebViewHostView)
        let replacement = WKWebView(frame: webView.frame, configuration: webView.configuration)

        host.setWebView(replacement)
        XCTAssertTrue(host.subviews.last === replacement, "Show the new page without waiting")

        try await waitUntil(webView, "window.trustedExits > 0 && document.getElementById('status').textContent === 'Saved'")
        try await waitForDetachment(webView)
        XCTAssertTrue(replacement.superview === host)
    }

    func testReloadPreservesWorkStartedByHoverExit() async throws {
        let (window, webView) = try await hoveredFixture()
        defer { window.close() }

        await WebViewCoordinator.reload(webView, fallbackURL: nil)

        try await waitUntil(webView, "window.loadCount === 2")
        let status = try await webView.evaluateJavaScript("document.getElementById('status').textContent")
        XCTAssertEqual(status as? String, "Saved")
    }

    func testQuickReturnDoesNotDetachOrEndHoverOnTheRestoredPage() async throws {
        let (window, webView) = try await hoveredFixture()
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView as? WebViewHostView)
        let replacement = WKWebView(frame: webView.frame, configuration: webView.configuration)

        host.setWebView(replacement)
        host.setWebView(webView)
        try await waitForDetachment(replacement)

        XCTAssertTrue(webView.superview === host)
        XCTAssertTrue(host.subviews.last === webView)
        let hovering = try await webView.evaluateJavaScript("document.getElementById('target').matches(':hover')")
        XCTAssertEqual(hovering as? Bool, true)
        XCTAssertNil(replacement.superview)
    }

    func testQuitFinishesHoverExitWorkBeforeReleasingThePage() async throws {
        let (window, webView) = try await hoveredFixture(releasesForQuit: true)
        defer { window.close() }

        await WebViewDeparture.prepareForQuit(in: [webView])

        let status = try await webView.evaluateJavaScript("document.getElementById('status').textContent")
        XCTAssertEqual(status as? String, "pagehide:Saved")
    }

    func testQuitHonoursWorkFromAnAlreadyDeliveredHoverExit() async throws {
        let (window, webView) = try await hoveredFixture(releasesForQuit: true)
        defer { window.close() }
        WebViewDeparture.endHover(in: webView)
        try await waitUntil(webView, "window.trustedExits > 0")

        await WebViewDeparture.prepareForQuit(in: [webView])

        let status = try await webView.evaluateJavaScript("document.getElementById('status').textContent")
        XCTAssertEqual(status as? String, "pagehide:Saved")
    }

    func testDestructiveDepartureSupportsQuirksModePages() async throws {
        let (window, webView) = try await hoveredFixture(standardsMode: false)
        defer { window.close() }

        await WebViewDeparture.prepareForDestruction(in: [webView])

        let status = try await webView.evaluateJavaScript("document.getElementById('status').textContent")
        XCTAssertEqual(status as? String, "Saved")
    }

    func testCancelledReloadKeepsTheCurrentDocument() async throws {
        let (window, webView) = try await hoveredFixture()
        defer { window.close() }
        let reload = Task { @MainActor in
            await WebViewCoordinator.reload(webView, fallbackURL: nil)
        }
        try await waitUntil(webView, "window.trustedExits > 0")

        reload.cancel()
        await reload.value

        let loads = try await webView.evaluateJavaScript("window.loadCount")
        XCTAssertEqual(loads as? Int, 1)
    }

    func testSwitchTransfersKeyboardFocusToTheNewPage() async throws {
        let (window, webView) = try await hoveredFixture()
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView as? WebViewHostView)
        let replacement = WKWebView(frame: webView.frame, configuration: webView.configuration)

        host.setWebView(replacement)

        let focused = window.firstResponder as? NSView
        XCTAssertTrue(focused === replacement || focused?.isDescendant(of: replacement) == true)
    }

    func testRestoredPageStillFillsTheResizedWindow() async throws {
        let (window, webView) = try await hoveredFixture()
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView as? WebViewHostView)
        let replacement = WKWebView(frame: webView.frame, configuration: webView.configuration)
        host.setWebView(replacement)
        host.setWebView(webView)

        window.setContentSize(NSSize(width: 600, height: 500))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(webView.frame, host.bounds)
    }

    private func hoveredFixture(standardsMode: Bool = true, releasesForQuit: Bool = false) async throws -> (NSWindow, WKWebView) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if releasesForQuit {
            configuration.userContentController.addUserScript(WKUserScript(
                source: UserScriptManager.makeVisibilityOverrideScript(),
                injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = FixtureWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = WebViewHostView(frame: webView.frame)
        host.setWebView(webView)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chorus-departure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fixtureURL = directory.appendingPathComponent("fixture.html")
        try """
            \(standardsMode ? "<!doctype html>" : "")
            <style>
              body { margin: 0 }
              #target { width: 400px; height: 300px; background: blue }
              #target:hover { background: red }
            </style>
            <div id="target">Hover fixture <span id="status">Pending</span></div>
            <script>
              window.fixtureReady = true;
              window.trustedExits = 0;
              document.getElementById('status').textContent = sessionStorage.getItem('saved') || 'Pending';
              window.loadCount = Number(sessionStorage.getItem('loads') || '0') + 1;
              sessionStorage.setItem('loads', String(window.loadCount));
              window.addEventListener('pagehide', function () {
                var status = document.getElementById('status');
                status.textContent = 'pagehide:' + status.textContent;
              });
              document.addEventListener('mouseout', function (event) {
                if (event.isTrusted && !event.relatedTarget) {
                  window.trustedExits++;
                  setTimeout(function () {
                    sessionStorage.setItem('saved', 'Saved');
                    document.getElementById('status').textContent = 'Saved';
                  }, 150);
                }
              });
            </script>
            """.write(to: fixtureURL, atomically: true, encoding: .utf8)
        webView.loadFileURL(fixtureURL, allowingReadAccessTo: directory)
        try await waitUntil(webView, "window.fixtureReady === true && !document.hidden")

        // Seed hover through AppKit, not a DOM event or a cursor warp.
        let move = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: webView.convert(NSPoint(x: 100, y: 100), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        ))
        sendNativeMove(move, in: webView)
        try await waitUntil(webView, "document.getElementById('target').matches('#target:hover')")
        return (window, webView)
    }

    /// Control only the platform window metadata. The real WebKit engine still
    /// handles input, hit-testing, CSS hover, and trusted DOM events. This keeps
    /// the fixture usable on a locked desktop or a headless CI runner.
    private final class FixtureWindow: NSWindow {
        override var occlusionState: NSWindow.OcclusionState { [.visible] }
        override var isKeyWindow: Bool { true }
    }

    private func sendNativeMove(_ event: NSEvent, in view: NSView) {
        for area in view.trackingAreas where area.options.contains(.mouseMoved) {
            if let owner = area.owner as? NSObject,
               owner.responds(to: #selector(NSResponder.mouseMoved(with:))) {
                owner.perform(#selector(NSResponder.mouseMoved(with:)), with: event)
            }
        }
        for subview in view.subviews { sendNativeMove(event, in: subview) }
    }

    private func waitForDetachment(_ webView: WKWebView) async throws {
        for _ in 0..<200 {
            if webView.superview == nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The outgoing page remained attached after its grace period")
        throw FixtureError.timeout
    }

    private func waitUntil(_ webView: WKWebView, _ condition: String) async throws {
        for _ in 0..<100 {
            if try await webView.evaluateJavaScript(condition) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("WebKit did not reach expected state: \(condition)")
        throw FixtureError.timeout
    }

    private enum FixtureError: Error { case timeout }
}
