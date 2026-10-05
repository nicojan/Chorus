import AppKit
import SwiftData
import WebKit
import XCTest
@testable import Chorus

@MainActor
final class WebViewPoolTests: XCTestCase {
    func testForegroundAndPreloadUseTheSameConstructionPolicy() throws {
        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let stores = DataStoreManager()
        let pool = WebViewPool(
            dataStoreManager: stores,
            userScriptManager: UserScriptManager(),
            contentBlocker: ContentBlockerManager(isEnabled: false)
        )
        let host = WebViewHostView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let previousSize = WebViewHostView.lastSize
        host.layout()
        defer {
            host.setFrameSize(previousSize)
            host.layout()
        }

        for userAgent in [nil, "FixtureBrowser/1.0"] as [String?] {
            let foreground = ServiceInstance(label: "Foreground", url: "about:blank", userAgent: userAgent)
            let preloaded = ServiceInstance(label: "Preloaded", url: "about:blank", userAgent: userAgent)
            container.mainContext.insert(foreground)
            container.mainContext.insert(preloaded)
            defer {
                for service in [foreground, preloaded] {
                    pool.removeWebView(for: service.id)
                    stores.evict(identifier: service.dataStoreIdentifier)
                }
            }
            let identifiers = [foreground.dataStoreIdentifier, preloaded.dataStoreIdentifier]
            addTeardownBlock { @MainActor in
                // These identifiers belong only to this test. Views and cached
                // stores are released, but the network process can lag behind.
                for identifier in identifiers {
                    for attempt in 0..<30 {
                        try await Task.sleep(for: .milliseconds(100))
                        do {
                            try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                            break
                        } catch {
                            if attempt == 29 { throw error }
                        }
                    }
                }
            }

            let displayed = pool.webView(for: foreground)
            pool.preload(preloaded)
            let background = try XCTUnwrap(pool.liveWebView(for: preloaded.id))

            XCTAssertEqual(pool.activeServiceID, foreground.id, "Preloading must not change the active service")
            for webView in [displayed, background] {
                XCTAssertEqual(webView.frame.size, CGSize(width: 640, height: 480))
                XCTAssertTrue(webView.allowsBackForwardNavigationGestures)
                XCTAssertEqual(webView.customUserAgent, userAgent ?? UserAgentProvider.safariDefault)
                XCTAssertNotNil(webView.navigationDelegate)
                XCTAssertNotNil(webView.uiDelegate)
                XCTAssertTrue(webView.navigationDelegate === webView.uiDelegate)
                #if DEBUG
                XCTAssertTrue(webView.isInspectable)
                #endif
            }
            XCTAssertEqual(displayed.configuration.websiteDataStore.identifier, foreground.dataStoreIdentifier)
            XCTAssertEqual(background.configuration.websiteDataStore.identifier, preloaded.dataStoreIdentifier)
            XCTAssertTrue(pool.webView(for: preloaded) === background, "Activation must reuse the preloaded page")
        }
    }
}
