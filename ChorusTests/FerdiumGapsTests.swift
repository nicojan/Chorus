import XCTest
import SwiftData
import WebKit
import ChorusEngine
@testable import ChorusEngine
@testable import Chorus

/// Custom user agent, custom JavaScript, lock after idle time and private
/// notifications (the gaps found against Ferdium, issue #49).
@MainActor
final class FerdiumGapsTests: XCTestCase {
    // MARK: - Code editor

    /// Custom JavaScript and CSS are typed into a text view. A plain SwiftUI
    /// TextEditor follows the Mac's typing settings and turned ' into a curly
    /// quote and -- into a dash, so a typed script failed to parse and never
    /// ran. Types through the text view the way keys do; the trailing space
    /// is what makes AppKit apply its substitutions.
    func testCodeEditorKeepsTypedQuotesAndDashes() throws {
        let typed = "document.body.insertAdjacentHTML('afterbegin', \"<b>x</b>\"); i -- 1; "

        let control = NSTextView.scrollableTextView()
        let controlView = try XCTUnwrap(control.documentView as? NSTextView)
        XCTAssertNotEqual(try type(typed, into: control) {
            controlView.isAutomaticQuoteSubstitutionEnabled = true
            controlView.isAutomaticDashSubstitutionEnabled = true
        }, typed, "control: with substitutions on, typing this way changes the text")

        let editor = CodeTextEditor.makeScrollView()
        XCTAssertEqual(try type(typed, into: editor) {}, typed)
        XCTAssertFalse(try XCTUnwrap(editor.documentView as? NSTextView).isRichText)
    }

    /// Puts `scrollView` in a window, focuses its text view, runs `prepare`,
    /// and types `text` one character at a time.
    private func type(_ text: String, into scrollView: NSScrollView, prepare: () -> Void) throws -> String {
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        prepare()
        for character in text {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return textView.string
    }

    // MARK: - User agent choice

    func testUserAgentChoiceResolvesStoredValues() {
        XCTAssertEqual(UserAgentChoice.resolving(stored: nil).choice, .standard)
        XCTAssertEqual(UserAgentChoice.resolving(stored: UserAgentProvider.mobileSafari).choice, .mobile)
        let custom = UserAgentChoice.resolving(stored: "CatalogUA/2.0")
        XCTAssertEqual(custom.choice, .custom)
        XCTAssertEqual(custom.customText, "CatalogUA/2.0", "a catalog user agent opens pre-filled")
    }

    func testUserAgentChoiceStoredValue() {
        XCTAssertNil(UserAgentChoice.storedValue(choice: .standard, customText: "ignored"))
        XCTAssertEqual(UserAgentChoice.storedValue(choice: .mobile, customText: ""), UserAgentProvider.mobileSafari)
        XCTAssertEqual(UserAgentChoice.storedValue(choice: .custom, customText: "  MyUA/1  "), "MyUA/1")
        XCTAssertNil(UserAgentChoice.storedValue(choice: .custom, customText: ""))
        XCTAssertNil(UserAgentChoice.storedValue(choice: .custom, customText: " \n\t "), "blank custom text means default")
    }

    func testUnchangedCatalogUserAgentRoundTripsUnchanged() {
        let opened = UserAgentChoice.resolving(stored: "CatalogUA/2.0")
        XCTAssertEqual(
            UserAgentChoice.storedValue(choice: opened.choice, customText: opened.customText),
            "CatalogUA/2.0"
        )
    }

    // MARK: - Custom JavaScript

    func testCustomJSScriptOnlyWhenNotBlank() {
        XCTAssertNil(UserScriptManager.makeCustomJSUserScript(nil))
        XCTAssertNil(UserScriptManager.makeCustomJSUserScript(""))
        XCTAssertNil(UserScriptManager.makeCustomJSUserScript(" \n\t "))
        let script = UserScriptManager.makeCustomJSUserScript("document.title = 'x'")
        XCTAssertNotNil(script)
        XCTAssertEqual(script?.injectionTime, .atDocumentEnd)
        XCTAssertEqual(script?.isForMainFrameOnly, true)
        XCTAssertTrue(script?.source.contains("document.title = 'x'") ?? false)
        XCTAssertTrue(script?.source.contains("try {") ?? false, "user code runs inside a try/catch")
    }

    func testInstallUserScriptsAddsCustomJSOnlyWhenSet() {
        func count(js: String?) -> Int {
            let controller = WKUserContentController()
            UserScriptManager().installUserScripts(
                for: UUID(), customCSS: nil, customJS: js,
                darkInjection: .none, stayActiveInBackground: false, on: controller
            )
            return controller.userScripts.filter { $0.source.contains("Chorus custom JavaScript failed") }.count
        }
        XCTAssertEqual(count(js: nil), 0)
        XCTAssertEqual(count(js: "   "), 0)
        XCTAssertEqual(count(js: "window.x = 1"), 1)
    }

    func testServiceSurfaceCarriesCustomJS() {
        let with = ServiceInstance(label: "A", url: "https://a.example", customJS: "alert(1)")
        let without = ServiceInstance(label: "B", url: "https://b.example")
        XCTAssertEqual(with.webSurface.customJS, "alert(1)")
        XCTAssertNil(without.webSurface.customJS)
    }

    // MARK: - Setup archive

    func testSetupArchiveRoundTripLeavesCustomJSNil() throws {
        let source = try ModelContainer(
            for: Space.self, ServiceInstance.self, SpaceServiceLink.self, RailDivider.self, ServiceGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = source.mainContext
        let space = Space(name: "Work", emoji: "W", sortOrder: 0)
        let service = ServiceInstance(label: "Slack", url: "https://app.slack.com", customJS: "steal()")
        ctx.insert(space)
        ctx.insert(service)
        try ctx.save()
        let link = SpaceServiceLink(sortOrder: 0, space: space, service: service)
        if link.modelContext == nil { ctx.insert(link) }
        try ctx.save()

        let data = try SetupArchive.capture(from: ctx, appVersion: "1.5.38").encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("steal()"), "the file never carries the code")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("customJS"))

        let target = try ModelContainer(
            for: Space.self, ServiceInstance.self, SpaceServiceLink.self, RailDivider.self, ServiceGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        _ = try SetupArchive.decode(data).apply(to: target.mainContext)
        let imported = try target.mainContext.fetch(FetchDescriptor<ServiceInstance>())
        XCTAssertEqual(imported.count, 1)
        XCTAssertNil(imported.first?.customJS)
    }

    func testSetupArchiveImportIgnoresACustomJSKeyInTheFile() throws {
        let service = SetupArchive.ServiceRecord(
            label: "X", url: "https://example.com", catalogEntryID: nil, customIconData: nil, isMuted: false,
            showBadge: true, neverHibernate: false, userAgent: nil, pageZoom: nil, osNotificationsEnabled: nil,
            customCSS: nil, darkModeRaw: nil, openExternalLinksInApp: nil, stayActiveInBackground: nil,
            hibernationPolicyRaw: nil, hibernateAfterMinutes: nil
        )
        let archive = SetupArchive(
            format: SetupArchive.format, version: 1, exportedAt: Date(), appVersion: nil,
            spaces: [.init(name: "S", emoji: "S", sortOrder: 0, isMuted: nil, members: [.init(service: 0, sortOrder: 0)])],
            services: [service]
        )
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: try archive.encoded()) as? [String: Any])
        var services = try XCTUnwrap(root["services"] as? [[String: Any]])
        services[0]["customJS"] = "evil()"
        root["services"] = services
        let tampered = try JSONSerialization.data(withJSONObject: root)

        let container = try ModelContainer(
            for: Space.self, ServiceInstance.self, SpaceServiceLink.self, RailDivider.self, ServiceGroup.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        _ = try SetupArchive.decode(tampered).apply(to: container.mainContext)
        let imported = try container.mainContext.fetch(FetchDescriptor<ServiceInstance>())
        XCTAssertEqual(imported.count, 1)
        XCTAssertNil(imported.first?.customJS)
    }

    // MARK: - Unlock prompt

    /// An idle or sleep lock happens while Chorus is in the background. Touch
    /// ID asked at once and pulled Chorus to the front; it waits for the user
    /// to bring Chorus forward instead, and never stacks a second prompt.
    func testUnlockPromptWaitsForChorusToBeActive() {
        func rule(locked: Bool = true, active: Bool = true, prompting: Bool = false) -> Bool {
            AppState.shouldPromptForUnlock(isLocked: locked, appIsActive: active, isPrompting: prompting)
        }
        XCTAssertTrue(rule())
        XCTAssertFalse(rule(active: false), "Chorus in the background: wait")
        XCTAssertFalse(rule(prompting: true), "a prompt is already up")
        XCTAssertFalse(rule(locked: false), "nothing to unlock")
    }

    // MARK: - Idle lock rule

    func testShouldLockForIdle() {
        func rule(_ idle: TimeInterval, minutes: Int = 5, locked: Bool = false, enabled: Bool = true) -> Bool {
            AppState.shouldLockForIdle(idleSeconds: idle, minutes: minutes, isLocked: locked, lockEnabled: enabled)
        }
        XCTAssertFalse(rule(299))
        XCTAssertTrue(rule(300))
        XCTAssertTrue(rule(3600))
        XCTAssertFalse(rule(3600, locked: true), "already locked")
        XCTAssertFalse(rule(3600, enabled: false), "lock off")
        XCTAssertFalse(rule(3600, minutes: 0), "timeout off")
        XCTAssertFalse(rule(3600, minutes: -1))
    }

    // MARK: - Private notifications

    func testNotificationTextShownNormally() {
        let text = NotificationMessageHandler.notificationText(
            pageTitle: "Ana", pageBody: "Lunch at noon?", serviceLabel: "Slack", hideText: false)
        XCTAssertEqual(text.title, "Ana")
        XCTAssertEqual(text.body, "Lunch at noon?")
        XCTAssertEqual(text.subtitle, "Slack")
    }

    func testNotificationTextHiddenWhenPrivate() {
        let text = NotificationMessageHandler.notificationText(
            pageTitle: "Ana", pageBody: "Lunch at noon?", serviceLabel: "Slack", hideText: true)
        XCTAssertEqual(text.title, "Slack")
        XCTAssertEqual(text.body, "New notification")
        XCTAssertEqual(text.subtitle, "")
        let unnamed = NotificationMessageHandler.notificationText(
            pageTitle: "Ana", pageBody: "secret", serviceLabel: nil, hideText: true)
        XCTAssertFalse(unnamed.title.contains("Ana"))
        XCTAssertFalse(unnamed.body.contains("secret"))
    }

    // MARK: - Migration from 1.5.30

    func testMigratesFrom1_5_30KeepingEverythingAndNewFieldsNil() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "chorus-migr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "default.store")
        let serviceID = UUID(), spaceID = UUID(), linkID = UUID(), groupID = UUID(), prefsID = UUID()

        try autoreleasepool {
            let schema = Schema(versionedSchema: ChorusSchemaV1_5_30.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let ctx = container.mainContext
            let space = ChorusSchemaV1_5_30.Space(id: spaceID, name: "Work", emoji: "W", sortOrder: 2)
            let service = ChorusSchemaV1_5_30.ServiceInstance(id: serviceID, label: "Slack", url: "https://slack.com")
            service.userAgent = "CustomUA/1.0"
            service.customCSS = "body{}"
            service.isGlobal = true
            service.globalSortOrder = 4
            let prefs = ChorusSchemaV1_5_30.AppPreferences(id: prefsID)
            prefs.appLockEnabled = true
            prefs.lockOnSleep = false
            prefs.autoHibernateIdleMinutes = 20
            ctx.insert(space)
            ctx.insert(service)
            ctx.insert(prefs)
            ctx.insert(ChorusSchemaV1_5_30.ServiceGroup(id: groupID, spaceID: spaceID, name: "Chat"))
            try ctx.save()
            let link = ChorusSchemaV1_5_30.SpaceServiceLink(id: linkID, sortOrder: 3, space: space, service: service)
            link.groupID = groupID
            if link.modelContext == nil { ctx.insert(link) }
            try ctx.save()
        }

        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: ChorusMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        let ctx = container.mainContext

        let service = try XCTUnwrap(try ctx.fetch(FetchDescriptor<ServiceInstance>()).first)
        XCTAssertEqual(service.id, serviceID)
        XCTAssertEqual(service.label, "Slack")
        XCTAssertEqual(service.userAgent, "CustomUA/1.0")
        XCTAssertEqual(service.customCSS, "body{}")
        XCTAssertEqual(service.isGlobal, true)
        XCTAssertEqual(service.globalSortOrder, 4)
        XCTAssertNil(service.customJS)

        let prefs = try XCTUnwrap(try ctx.fetch(FetchDescriptor<AppPreferences>()).first)
        XCTAssertEqual(prefs.id, prefsID)
        XCTAssertEqual(prefs.appLockEnabled, true)
        XCTAssertEqual(prefs.lockOnSleep, false)
        XCTAssertEqual(prefs.autoHibernateIdleMinutes, 20)
        XCTAssertNil(prefs.lockAfterIdleMinutes)
        XCTAssertNil(prefs.hideNotificationText)

        let link = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SpaceServiceLink>()).first)
        XCTAssertEqual(link.id, linkID)
        XCTAssertEqual(link.sortOrder, 3)
        XCTAssertEqual(link.groupID, groupID)
        XCTAssertEqual(link.liveEnds?.space.id, spaceID)
        XCTAssertEqual(link.liveEnds?.service.id, serviceID)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ServiceGroup>()).map(\.id), [groupID])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Space>()).first?.name, "Work")
    }
}
