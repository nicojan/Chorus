import XCTest
@testable import Chorus

@MainActor
final class ChorusTests: XCTestCase {
    func testServiceInstanceCreation() {
        let service = ServiceInstance(
            label: "Test Gmail",
            url: "https://mail.google.com",
            catalogEntryID: "gmail"
        )
        XCTAssertEqual(service.label, "Test Gmail")
        XCTAssertEqual(service.url, "https://mail.google.com")
        XCTAssertFalse(service.isMuted)
        XCTAssertNotNil(service.dataStoreIdentifier)
    }

    func testSpaceCreation() {
        let space = Space(name: "Work", emoji: "🏢", sortOrder: 0)
        XCTAssertEqual(space.name, "Work")
        XCTAssertEqual(space.emoji, "🏢")
        XCTAssertEqual(space.sortOrder, 0)
        XCTAssertTrue(space.serviceLinks.isEmpty)
    }

    func testServiceCatalogParsing() {
        let json = """
        [{"id":"gmail","name":"Gmail","url":"https://mail.google.com","icon":"gmail-icon","category":"Email","badgeJS":null,"userAgent":null,"description":"Google email"}]
        """.data(using: .utf8)!

        let entries = try! JSONDecoder().decode([ServiceCatalogEntry].self, from: json)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "gmail")
        XCTAssertEqual(entries[0].category, "Email")
    }

    @MainActor
    func testBadgeCountExtraction() {
        XCTAssertEqual(NotificationManager.extractBadgeCount(from: "Inbox (5) - Gmail"), 5)
        XCTAssertEqual(NotificationManager.extractBadgeCount(from: "(12) Slack"), 12)
        XCTAssertEqual(NotificationManager.extractBadgeCount(from: "No badges here"), 0)
    }

    func testHibernatedBadgeExtraction() {
        XCTAssertEqual(HibernatedBadgePoller.extractBadgeFromTitle(html: "<title>(3) Slack</title>"), 3)
        XCTAssertEqual(HibernatedBadgePoller.extractBadgeFromTitle(html: "<title>Gmail</title>"), 0)
        XCTAssertEqual(HibernatedBadgePoller.extractBadgeFromTitle(html: "<title>Inbox (42) - Gmail</title>"), 42)
        XCTAssertEqual(HibernatedBadgePoller.extractBadgeFromTitle(html: "no title tag"), 0)
    }

    func testCustomServiceInputValidation() {
        XCTAssertEqual(
            AddServiceSheet.validatedCustomServiceInput(label: "  Docs  ", url: " HTTPS://example.com/app "),
            .valid(label: "Docs", url: "https://example.com/app")
        )
        XCTAssertEqual(
            AddServiceSheet.validatedCustomServiceInput(label: "   ", url: "https://example.com"),
            .invalid("Label can't be empty")
        )
        XCTAssertEqual(
            AddServiceSheet.validatedCustomServiceInput(label: "Broken", url: "https://"),
            .invalid("URL must include a host")
        )
        XCTAssertEqual(
            AddServiceSheet.validatedCustomServiceInput(label: "FTP", url: "ftp://example.com"),
            .invalid("URL must start with https:// or http://")
        )
    }

    func testFaviconParserHandlesAttributeOrderAndRelativeURLs() {
        let html = """
        <html><head>
            <link href="icons/favicon-32.png" rel="icon" sizes="16x16 32x32">
            <link sizes="180x180" rel="apple-touch-icon" href="/apple-touch-icon.png">
            <link rel="stylesheet" href="/site.css">
        </head></html>
        """
        let links = FaviconFetcher.parseIconLinks(
            from: html,
            baseURL: URL(string: "https://example.com/app/page")!
        )

        XCTAssertEqual(
            links,
            [
                .init(url: "https://example.com/app/icons/favicon-32.png", size: 32),
                .init(url: "https://example.com/apple-touch-icon.png", size: 180),
            ]
        )
    }

    func testServiceReorderPlacement() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let ids = [first, second, third, fourth]

        XCTAssertEqual(
            ServiceReorder.reorderedIDs(ids, moving: first, relativeTo: second, placement: .after),
            [second, first, third, fourth]
        )
        XCTAssertEqual(
            ServiceReorder.reorderedIDs(ids, moving: fourth, relativeTo: first, placement: .before),
            [fourth, first, second, third]
        )
        XCTAssertEqual(
            ServiceReorder.reorderedIDs(ids, moving: second, relativeTo: fourth, placement: .after),
            [first, third, fourth, second]
        )
    }

    func testServiceReorderNoOpsAndInvalidDrops() {
        let first = UUID()
        let second = UUID()
        let missing = UUID()
        let ids = [first, second]

        XCTAssertNil(ServiceReorder.reorderedIDs(ids, moving: first, relativeTo: first, placement: .after))
        XCTAssertNil(ServiceReorder.reorderedIDs(ids, moving: first, relativeTo: second, placement: .before))
        XCTAssertNil(ServiceReorder.reorderedIDs(ids, moving: second, relativeTo: first, placement: .after))
        XCTAssertNil(ServiceReorder.reorderedIDs(ids, moving: missing, relativeTo: first, placement: .before))
        XCTAssertNil(ServiceReorder.reorderedIDs(ids, moving: first, relativeTo: missing, placement: .before))
    }

    // MARK: - BadgeManager

    @MainActor
    func testMutingPreservesRawCountAndRestoresOnUnmute() {
        let manager = BadgeManager()
        let id = UUID()

        // A live poll reports 5 unread.
        manager.updateBadge(for: id, count: 5, isMuted: false, showBadge: true)
        XCTAssertEqual(manager.badgeCount(for: id), 5)
        XCTAssertEqual(manager.rawCount(for: id), 5)

        // Muting hides the badge but must NOT destroy the real count — the
        // adaptive poller relies on rawCount to detect deltas, and un-muting
        // must restore the badge instantly without waiting for a poll tick.
        manager.updateBadge(for: id, count: 5, isMuted: true, showBadge: true)
        XCTAssertEqual(manager.badgeCount(for: id), 0, "muted badge is hidden")
        XCTAssertEqual(manager.rawCount(for: id), 5, "real count survives muting")

        // Un-mute by re-applying with the preserved rawCount (mirrors
        // AppState.refreshBadgeState reading rawCount).
        manager.updateBadge(for: id, count: manager.rawCount(for: id), isMuted: false, showBadge: true)
        XCTAssertEqual(manager.badgeCount(for: id), 5, "un-mute restores the badge immediately")
    }

    @MainActor
    func testAggregateAndTotalExcludeMaskedServices() {
        let manager = BadgeManager()
        let visible = UUID()
        let muted = UUID()
        let hidden = UUID()

        manager.updateBadge(for: visible, count: 3, isMuted: false, showBadge: true)
        manager.updateBadge(for: muted, count: 7, isMuted: true, showBadge: true)
        manager.updateBadge(for: hidden, count: 4, isMuted: false, showBadge: false)

        XCTAssertEqual(manager.aggregateCount(for: [visible, muted, hidden]), 3)
        XCTAssertEqual(manager.totalCount, 3)
        // Raw counts are all preserved regardless of masking.
        XCTAssertEqual(manager.rawCount(for: muted), 7)
        XCTAssertEqual(manager.rawCount(for: hidden), 4)
    }

    @MainActor
    func testDoNotDisturbZerosVisibleCountsButKeepsRaw() {
        let manager = BadgeManager()
        let id = UUID()
        manager.updateBadge(for: id, count: 9, isMuted: false, showBadge: true)

        manager.doNotDisturb = true
        XCTAssertEqual(manager.badgeCount(for: id), 0)
        XCTAssertEqual(manager.aggregateCount(for: [id]), 0)
        XCTAssertEqual(manager.totalCount, 0)
        XCTAssertEqual(manager.rawCount(for: id), 9, "DND does not destroy the real count")

        manager.doNotDisturb = false
        XCTAssertEqual(manager.badgeCount(for: id), 9)
    }

    @MainActor
    func testUpdateBadgeClampsOutOfRangeCounts() {
        let manager = BadgeManager()
        let negative = UUID()
        let huge = UUID()
        let ok = UUID()

        // A misbehaving DOM badge (catalog badgeJS) could yield a negative or a
        // garbage-large value; a stored negative would subtract from the sum and
        // hide the dock badge for every other service.
        manager.updateBadge(for: negative, count: -5, isMuted: false, showBadge: true)
        manager.updateBadge(for: huge, count: 100_000, isMuted: false, showBadge: true)
        manager.updateBadge(for: ok, count: 3, isMuted: false, showBadge: true)

        XCTAssertEqual(manager.rawCount(for: negative), 0, "negative clamps to 0")
        XCTAssertEqual(manager.rawCount(for: huge), 999, "huge clamps to 999")
        // The total is the clamped sum, never dragged below the other services.
        XCTAssertEqual(manager.totalCount, 0 + 999 + 3)
    }

    @MainActor
    func testDoNotDisturbSnapshotMirrorsValue() {
        let manager = BadgeManager()
        XCTAssertFalse(manager.doNotDisturbSnapshot.value)
        manager.doNotDisturb = true
        XCTAssertTrue(manager.doNotDisturbSnapshot.value, "snapshot follows the property for off-main reads")
        manager.doNotDisturb = false
        XCTAssertFalse(manager.doNotDisturbSnapshot.value)
    }

    @MainActor
    func testRemoveBadgeClearsMaskState() {
        let manager = BadgeManager()
        let id = UUID()
        manager.updateBadge(for: id, count: 2, isMuted: true, showBadge: true)
        manager.removeBadge(for: id)
        // Re-adding an un-muted badge after removal must not stay masked.
        manager.updateBadge(for: id, count: 6, isMuted: false, showBadge: true)
        XCTAssertEqual(manager.badgeCount(for: id), 6)
    }

    // MARK: - Orphaned-service detection (space deletion)

    func testServicesOrphanedByDeletingSpace() {
        let space = UUID()
        let otherSpace = UUID()
        let onlyHere = UUID()      // belongs only to `space` → orphaned
        let alsoElsewhere = UUID() // belongs to `space` and `otherSpace` → kept
        let elsewhere = UUID()     // not in `space` at all → untouched

        let memberships: [UUID: Set<UUID>] = [
            onlyHere: [space],
            alsoElsewhere: [space, otherSpace],
            elsewhere: [otherSpace],
        ]

        XCTAssertEqual(
            AppState.servicesOrphaned(byDeletingSpace: space, memberships: memberships),
            [onlyHere]
        )
    }

    func testServicesOrphanedHandlesEmptyAndAbsentSpace() {
        let space = UUID()
        let svc = UUID()
        // Deleting a space no service belongs to orphans nothing.
        XCTAssertEqual(
            AppState.servicesOrphaned(byDeletingSpace: space, memberships: [svc: [UUID()]]),
            []
        )
        XCTAssertEqual(
            AppState.servicesOrphaned(byDeletingSpace: space, memberships: [:]),
            []
        )
    }

    // MARK: - WebContent crash backoff

    func testCrashBackoffStopsAfterRepeatedCrashes() {
        let now = Date()
        // First two crashes within the window still auto-reload.
        XCTAssertTrue(WebViewCoordinator.shouldAutoReload(
            crashTimestamps: [now], now: now, maxCrashes: 3, window: 30))
        XCTAssertTrue(WebViewCoordinator.shouldAutoReload(
            crashTimestamps: [now.addingTimeInterval(-5), now], now: now, maxCrashes: 3, window: 30))
        // Third crash in the window stops the loop (show error page instead).
        XCTAssertFalse(WebViewCoordinator.shouldAutoReload(
            crashTimestamps: [now.addingTimeInterval(-10), now.addingTimeInterval(-5), now],
            now: now, maxCrashes: 3, window: 30))
    }

    func testCrashBackoffIgnoresStaleCrashesOutsideWindow() {
        let now = Date()
        // Two crashes long ago + one now: the old ones fall outside the window,
        // so we still auto-reload.
        XCTAssertTrue(WebViewCoordinator.shouldAutoReload(
            crashTimestamps: [now.addingTimeInterval(-300), now.addingTimeInterval(-120), now],
            now: now, maxCrashes: 3, window: 30))
    }

    func testErrorPageEmbedsEscapedRetryURL() {
        let html = WebViewCoordinator.errorPageHTML(
            title: "Unable to connect",
            message: "The network connection was lost.",
            retryURLString: "https://example.com/a'b\"c"
        )
        XCTAssertTrue(html.contains("The network connection was lost."))
        // Retry target is JSON-encoded so quotes can't break out of the JS string.
        XCTAssertTrue(html.contains(#"https://example.com/a'b\"c"#),
                      "retry URL should be JSON-escaped into the script")
        XCTAssertFalse(html.contains("location.reload()"),
                       "retry must navigate to the real URL, not reload about:blank")
    }

    func testErrorPageWithoutRetryURLHasNoButton() {
        let html = WebViewCoordinator.errorPageHTML(
            title: "Page unavailable", message: "Keeps crashing.", retryURLString: nil)
        XCTAssertFalse(html.contains("<button"))
    }

    // MARK: - Cookie matching (hibernated poller)

    private func makeCookie(domain: String, path: String, name: String = "s", secure: Bool = false) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .path: path, .name: name, .value: "v",
        ]
        if secure { props[.secure] = "TRUE" }
        return HTTPCookie(properties: props)!
    }

    func testCookiePathMatchFollowsRFC6265() {
        let cookie = makeCookie(domain: "example.com", path: "/foo")
        // Exact, trailing-slash, and sub-path match.
        XCTAssertEqual(HibernatedBadgePoller.cookies([cookie], matching: URL(string: "https://example.com/foo")!).count, 1)
        XCTAssertEqual(HibernatedBadgePoller.cookies([cookie], matching: URL(string: "https://example.com/foo/bar")!).count, 1)
        // A path that merely shares the prefix but isn't a sub-path must NOT match.
        XCTAssertEqual(HibernatedBadgePoller.cookies([cookie], matching: URL(string: "https://example.com/foobar")!).count, 0)
    }

    func testCookieDomainAndSecureMatching() {
        let dotCookie = makeCookie(domain: ".example.com", path: "/")
        // Subdomain matches a dot-prefixed domain cookie.
        XCTAssertEqual(HibernatedBadgePoller.cookies([dotCookie], matching: URL(string: "https://mail.example.com/")!).count, 1)
        // Unrelated host doesn't.
        XCTAssertEqual(HibernatedBadgePoller.cookies([dotCookie], matching: URL(string: "https://notexample.com/")!).count, 0)

        // Secure cookies are withheld from http requests.
        let secure = makeCookie(domain: "example.com", path: "/", secure: true)
        XCTAssertEqual(HibernatedBadgePoller.cookies([secure], matching: URL(string: "http://example.com/")!).count, 0)
        XCTAssertEqual(HibernatedBadgePoller.cookies([secure], matching: URL(string: "https://example.com/")!).count, 1)
    }

    // MARK: - OS-notification gate + per-service notify flag

    func testOSNotificationGateFiresOnlyWhenEnabledUnmutedAndNotDND() {
        // Fires only when not muted, notifyOS on, and DND off.
        XCTAssertTrue(NotificationManager.shouldPostOSNotification(
            isMuted: false, notifyOS: true, doNotDisturb: false))
        // Each condition independently vetoes.
        XCTAssertFalse(NotificationManager.shouldPostOSNotification(
            isMuted: true, notifyOS: true, doNotDisturb: false), "mute vetoes")
        XCTAssertFalse(NotificationManager.shouldPostOSNotification(
            isMuted: false, notifyOS: false, doNotDisturb: false), "notifyOS off vetoes")
        XCTAssertFalse(NotificationManager.shouldPostOSNotification(
            isMuted: false, notifyOS: true, doNotDisturb: true), "DND vetoes")
    }

    func testShouldStopOutgoingPollReconcilesAgainstPoolActiveID() {
        let outgoing = UUID()
        let incoming = UUID()
        // Normal sidebar switch: the pool still regards the outgoing service as
        // active, so the view layer stops its active poll before the pool
        // downgrades it to background.
        XCTAssertTrue(NotificationManager.shouldStopOutgoingPoll(
            previousID: outgoing, poolActiveID: outgoing))
        // Deep-link switch: AppState already made the incoming service active
        // and moved the outgoing one onto a background poll, so the view layer
        // must NOT stop it (that was the OPEN-ITEMS item 1 race).
        XCTAssertFalse(NotificationManager.shouldStopOutgoingPoll(
            previousID: outgoing, poolActiveID: incoming))
        // No previously displayed service: nothing to stop.
        XCTAssertFalse(NotificationManager.shouldStopOutgoingPoll(
            previousID: nil, poolActiveID: incoming))
    }

    func testNotifiesOSEffectiveDefaultsToEnabledForLegacyRows() {
        let service = ServiceInstance(label: "X", url: "https://x.test")
        // nil (new row, or a row created before the flag existed) → enabled,
        // preserving the prior always-notify behavior.
        XCTAssertNil(service.osNotificationsEnabled)
        XCTAssertTrue(service.notifiesOSEffective)
        // Explicit values are honored.
        service.osNotificationsEnabled = false
        XCTAssertFalse(service.notifiesOSEffective)
        service.osNotificationsEnabled = true
        XCTAssertTrue(service.notifiesOSEffective)
    }

    // MARK: - EmojiPickerView.emojiToPromote

    func testEmojiToPromotePromotesEmojiFromSearchField() {
        // A single emoji picked from the system Character Viewer lands as the
        // selection rather than a search query.
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "🎉"), "🎉")
        // Skin-tone modifiers, ZWJ sequences, VS16, and flags stay intact.
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "👍🏽"), "👍🏽")
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "👩‍💻"), "👩‍💻")
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "❤️"), "❤️")
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "🇺🇸"), "🇺🇸")
        // Surrounding whitespace is ignored.
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "  🚀 "), "🚀")
        // When several emoji are present, the most recent pick wins.
        XCTAssertEqual(EmojiPickerView.emojiToPromote(from: "😀😃"), "😃")
    }

    func testEmojiToPromoteLeavesKeywordSearchesAlone() {
        // Ordinary text must keep filtering the grid, not get promoted.
        XCTAssertNil(EmojiPickerView.emojiToPromote(from: "smile"))
        XCTAssertNil(EmojiPickerView.emojiToPromote(from: ""))
        XCTAssertNil(EmojiPickerView.emojiToPromote(from: "   "))
        // Bare digits report isEmoji == true but aren't real emoji.
        XCTAssertNil(EmojiPickerView.emojiToPromote(from: "123"))
        // Mixed text + emoji is treated as a search.
        XCTAssertNil(EmojiPickerView.emojiToPromote(from: "cat 🐱"))
    }

    // MARK: - About: version string

    func testAppVersionStringFormatsShortAndBuild() {
        XCTAssertEqual(
            AppVersion.string(from: ["CFBundleShortVersionString": "1.0.2", "CFBundleVersion": "3"]),
            "Version 1.0.2 (3)"
        )
    }

    func testAppVersionStringFallsBackWhenKeysMissing() {
        XCTAssertEqual(AppVersion.string(from: nil), "Version — (—)")
        XCTAssertEqual(
            AppVersion.string(from: ["CFBundleShortVersionString": "2.0"]),
            "Version 2.0 (—)"
        )
    }

    // MARK: - Custom CSS injection + resolution

    func testCSSInjectionScriptEscapesCSSAndTagsStyle() {
        let css = ".x { content: \"a\"; }\n.y { color: red; }"
        let script = UserScriptManager.makeCSSInjectionScript(css: css)
        // The <style> gets a stable id so re-injection is idempotent.
        XCTAssertTrue(script.contains("chorus-custom-css"))
        // CSS is embedded as a JSON string literal, so the inner quotes are
        // escaped rather than able to break out of the script.
        XCTAssertTrue(script.contains("\\\"a\\\""), "quotes should be JSON-escaped")
        // The raw newline is encoded, so the second rule can't sit on its own
        // line inside the JS source.
        XCTAssertFalse(script.contains("\n.y { color: red; }"), "raw newline must be encoded")
    }

    func testEffectiveCSSPrefersInstanceThenDefaultThenNothing() {
        // No instance CSS → the baked-in default for a known service.
        XCTAssertEqual(
            ServiceCSSDefaults.effectiveCSS(instanceCSS: nil, catalogID: "linkedin"),
            ServiceCSSDefaults.linkedInMessaging
        )
        // An instance override wins over the default.
        XCTAssertEqual(
            ServiceCSSDefaults.effectiveCSS(instanceCSS: "body{}", catalogID: "linkedin"),
            "body{}"
        )
        // A blank override injects nothing — an explicit "no CSS".
        XCTAssertNil(ServiceCSSDefaults.effectiveCSS(instanceCSS: "   ", catalogID: "linkedin"))
        // A service with neither an override nor a default gets nothing.
        XCTAssertNil(ServiceCSSDefaults.effectiveCSS(instanceCSS: nil, catalogID: "slack"))
        XCTAssertNil(ServiceCSSDefaults.effectiveCSS(instanceCSS: nil, catalogID: nil))
    }

    func testLinkedInShipsBakedInMessagingCSS() {
        let css = ServiceCSSDefaults.css(forCatalogID: "linkedin")
        XCTAssertNotNil(css)
        XCTAssertTrue(css?.contains("#global-nav") == true)
        XCTAssertTrue(css?.contains(".scaffold-layout__aside") == true)
    }

    func testServiceInstanceCustomCSSDefaultsNil() {
        let service = ServiceInstance(label: "X", url: "https://x.test", catalogEntryID: "linkedin")
        // A fresh instance carries no override, so it tracks the baked-in default.
        XCTAssertNil(service.customCSS)
    }

    // MARK: - Zoom resolution

    @MainActor
    func testEffectiveZoomPrefersPerServiceThenGlobalDefault() {
        // An explicit per-service zoom wins over the global default.
        XCTAssertEqual(AppState.effectiveZoom(pageZoom: 1.25, defaultZoom: 0.9), 1.25)
        // With no per-service zoom, the global default applies.
        XCTAssertEqual(AppState.effectiveZoom(pageZoom: nil, defaultZoom: 0.9), 0.9)
        XCTAssertEqual(AppState.effectiveZoom(pageZoom: nil, defaultZoom: 1.0), 1.0)
    }

    func testAppPreferencesDefaultZoomEffectiveFallsBackToOne() {
        XCTAssertEqual(AppPreferences().defaultZoomEffective, 1.0)
        XCTAssertEqual(AppPreferences(defaultZoom: 0.8).defaultZoomEffective, 0.8)
    }

    // MARK: - Scheduled DND (quiet hours)

    @MainActor
    func testQuietHoursSameDayWindow() {
        // 09:00–17:00.
        let start = 9 * 60, end = 17 * 60
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: 10 * 60, start: start, end: end))
        XCTAssertFalse(AppState.isWithinQuietHours(nowMinutes: 8 * 60, start: start, end: end))
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: end - 1, start: start, end: end))
        XCTAssertFalse(AppState.isWithinQuietHours(nowMinutes: end, start: start, end: end), "end is exclusive")
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: start, start: start, end: end), "start is inclusive")
    }

    @MainActor
    func testQuietHoursWrapsMidnight() {
        // 22:00–07:00.
        let start = 22 * 60, end = 7 * 60
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: 23 * 60, start: start, end: end))
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: 5 * 60, start: start, end: end))
        XCTAssertFalse(AppState.isWithinQuietHours(nowMinutes: end, start: start, end: end), "end is exclusive")
        XCTAssertTrue(AppState.isWithinQuietHours(nowMinutes: end - 1, start: start, end: end))
        XCTAssertFalse(AppState.isWithinQuietHours(nowMinutes: 20 * 60, start: start, end: end))
    }

    @MainActor
    func testQuietHoursZeroLengthWindowIsNeverActive() {
        XCTAssertFalse(AppState.isWithinQuietHours(nowMinutes: 12 * 60, start: 9 * 60, end: 9 * 60))
    }

    // MARK: - Dark mode

    func testForceDarkModeDefaultsOff() {
        XCTAssertFalse(ServiceInstance(label: "X", url: "https://x.test").isForceDarkModeEnabled)
        XCTAssertTrue(ServiceInstance(label: "X", url: "https://x.test", forceDarkMode: true).isForceDarkModeEnabled)
        XCTAssertFalse(ServiceInstance(label: "X", url: "https://x.test", forceDarkMode: false).isForceDarkModeEnabled)
    }

    // MARK: - Link routing (belongsToService)

    func testBelongsToServiceKeepsSlackWorkspacesInApp() {
        // Same registrable domain, subdomain differs — Slack switching
        // workspaces must stay in-app rather than spawning a new window.
        XCTAssertTrue(WebViewCoordinator.belongsToService("app.slack.com", serviceHost: "app.slack.com"))
        XCTAssertTrue(WebViewCoordinator.belongsToService("myteam.slack.com", serviceHost: "app.slack.com"))
        XCTAssertTrue(WebViewCoordinator.belongsToService("app.slack.com", serviceHost: "myteam.slack.com"))
    }

    func testBelongsToServiceSeparatesGoogleProducts() {
        // Shared-umbrella domain: a Docs/Drive link must NOT be treated as part
        // of the Gmail service (the reported "Google Docs opened in Gmail" bug).
        XCTAssertFalse(WebViewCoordinator.belongsToService("docs.google.com", serviceHost: "mail.google.com"))
        XCTAssertFalse(WebViewCoordinator.belongsToService("drive.google.com", serviceHost: "mail.google.com"))
        // The exact same host is still the same service.
        XCTAssertTrue(WebViewCoordinator.belongsToService("mail.google.com", serviceHost: "mail.google.com"))
        XCTAssertTrue(WebViewCoordinator.belongsToService("docs.google.com", serviceHost: "docs.google.com"))
    }

    func testBelongsToServiceRejectsUnrelatedDomains() {
        XCTAssertFalse(WebViewCoordinator.belongsToService("example.com", serviceHost: "slack.com"))
        XCTAssertFalse(WebViewCoordinator.belongsToService("notion.so", serviceHost: "mail.google.com"))
    }

    func testBelongsToServiceIgnoresWWWAndCase() {
        XCTAssertTrue(WebViewCoordinator.belongsToService("www.notion.so", serviceHost: "notion.so"))
        XCTAssertTrue(WebViewCoordinator.belongsToService("APP.SLACK.COM", serviceHost: "app.slack.com"))
    }

    func testAuthHostsAreRecognized() {
        // Identity gateways stay in-app so sign-in completes (the reported
        // "Gmail login kicked to the default browser" bug).
        XCTAssertTrue(WebViewCoordinator.isAuthHost("accounts.google.com"))
        XCTAssertTrue(WebViewCoordinator.isAuthHost("login.microsoftonline.com"))
        XCTAssertTrue(WebViewCoordinator.isAuthHost("appleid.apple.com"))
        // Case- and www-insensitive, and subdomains of a gateway still match.
        XCTAssertTrue(WebViewCoordinator.isAuthHost("ACCOUNTS.GOOGLE.COM"))
        XCTAssertTrue(WebViewCoordinator.isAuthHost("eu.login.microsoftonline.com"))
        // Ordinary product hosts are not auth gateways.
        XCTAssertFalse(WebViewCoordinator.isAuthHost("mail.google.com"))
        XCTAssertFalse(WebViewCoordinator.isAuthHost("docs.google.com"))
        XCTAssertFalse(WebViewCoordinator.isAuthHost("example.com"))
    }

    func testAuthHostExemptionLeavesUmbrellaSeparationIntact() {
        // The exemption is layered on top of belongsToService, not baked into
        // it: Google products stay separate for ordinary link routing.
        XCTAssertFalse(WebViewCoordinator.belongsToService("accounts.google.com", serviceHost: "mail.google.com"))
        XCTAssertFalse(WebViewCoordinator.belongsToService("docs.google.com", serviceHost: "mail.google.com"))
    }

    // MARK: - Download destination

    func testSanitizedDownloadFilenameStripsPathParts() {
        // A crafted name must not be able to escape the Downloads folder.
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename("../../etc/passwd"), "passwd")
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename("report.pdf"), "report.pdf")
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename("a/b/c.txt"), "c.txt")
    }

    func testSanitizedDownloadFilenameFallsBackWhenEmpty() {
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename(""), "download")
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename("   "), "download")
        XCTAssertEqual(WebViewCoordinator.sanitizedDownloadFilename("/"), "download")
    }

    func testNonCollidingURLReturnsBaseWhenFree() {
        let dir = URL(fileURLWithPath: "/Users/x/Downloads")
        let url = WebViewCoordinator.nonCollidingURL(in: dir, filename: "a.txt", fileExists: { _ in false })
        XCTAssertEqual(url.lastPathComponent, "a.txt")
    }

    func testNonCollidingURLAppendsIndexOnCollision() {
        let dir = URL(fileURLWithPath: "/Users/x/Downloads")
        // "a.txt" and "a (1).txt" are taken; the next free name is "a (2).txt".
        let taken: Set<String> = ["a.txt", "a (1).txt"]
        let url = WebViewCoordinator.nonCollidingURL(
            in: dir,
            filename: "a.txt",
            fileExists: { taken.contains($0.lastPathComponent) }
        )
        XCTAssertEqual(url.lastPathComponent, "a (2).txt")
    }

    func testNonCollidingURLHandlesExtensionlessNames() {
        let dir = URL(fileURLWithPath: "/Users/x/Downloads")
        let taken: Set<String> = ["README"]
        let url = WebViewCoordinator.nonCollidingURL(
            in: dir,
            filename: "README",
            fileExists: { taken.contains($0.lastPathComponent) }
        )
        XCTAssertEqual(url.lastPathComponent, "README (1)")
    }

    private func httpResponse(headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/file")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    func testIsAttachmentDetectsDisposition() {
        XCTAssertTrue(WebViewCoordinator.isAttachment(
            httpResponse(headers: ["Content-Disposition": "attachment; filename=\"report.pdf\""])
        ))
        // Case-insensitive on the header value.
        XCTAssertTrue(WebViewCoordinator.isAttachment(
            httpResponse(headers: ["Content-Disposition": "ATTACHMENT"])
        ))
    }

    func testIsAttachmentFalseForInlineOrMissing() {
        XCTAssertFalse(WebViewCoordinator.isAttachment(
            httpResponse(headers: ["Content-Disposition": "inline"])
        ))
        XCTAssertFalse(WebViewCoordinator.isAttachment(httpResponse(headers: [:])))
        // A non-HTTP response has no headers to inspect.
        let url = URL(string: "https://example.com")!
        XCTAssertFalse(WebViewCoordinator.isAttachment(
            URLResponse(url: url, mimeType: "application/pdf", expectedContentLength: 1, textEncodingName: nil)
        ))
    }

    // MARK: - Passkey notice

    func testNeedsPasskeyNoticeDefaultsTrueForNewService() {
        // A freshly created service has never seen the notice.
        let service = ServiceInstance(label: "Test", url: "https://example.com")
        XCTAssertTrue(service.needsPasskeyNotice)
    }

    func testNeedsPasskeyNoticeFalseOnceSeen() {
        let service = ServiceInstance(label: "Test", url: "https://example.com", hasSeenPasskeyNotice: true)
        XCTAssertFalse(service.needsPasskeyNotice)
    }

    // MARK: - Content blocker

    // MARK: - Dark Reader

    func testDarkInjectionTruthTable() {
        typealias I = DarkReaderSupport.DarkInjection
        func inj(_ m: ServiceDarkMode, _ auto: Bool, _ dark: Bool, _ detected: Bool?) -> I {
            DarkReaderSupport.injection(mode: m, globalAuto: auto, appDark: dark, detectedLacksDark: detected)
        }
        // App light → never themes, whatever the mode.
        XCTAssertEqual(inj(.on, true, false, true), I.none)
        // Explicit On themes even with the global toggle off; Off never themes.
        XCTAssertEqual(inj(.on, false, true, nil), I.themed)
        XCTAssertEqual(inj(.off, true, true, true), I.none)
        // Auto needs the global toggle on.
        XCTAssertEqual(inj(.auto, false, true, true), I.none)
        // Auto + global: no verdict → probe; lacks-dark → themed; has-dark → none.
        XCTAssertEqual(inj(.auto, true, true, nil), I.probe)
        XCTAssertEqual(inj(.auto, true, true, true), I.themed)
        XCTAssertEqual(inj(.auto, true, true, false), I.none)
    }

    func testClassifyLacksDark() {
        XCTAssertTrue(DarkReaderSupport.classifyLacksDark(r: 255, g: 255, b: 255, a: 1))   // white → light
        XCTAssertFalse(DarkReaderSupport.classifyLacksDark(r: 26, g: 26, b: 26, a: 1))     // #1a1a1a → dark
        XCTAssertTrue(DarkReaderSupport.classifyLacksDark(r: 0, g: 0, b: 0, a: 0))         // transparent → light
    }

    func testDarkModeMigrationFromLegacyFlag() {
        // Explicit mode wins.
        XCTAssertEqual(ServiceInstance(label: "x", url: "https://e.com", darkModeRaw: "off").darkMode, .off)
        // Legacy force-dark maps to On.
        XCTAssertEqual(ServiceInstance(label: "x", url: "https://e.com", forceDarkMode: true).darkMode, .on)
        // Nothing set defaults to Auto.
        XCTAssertEqual(ServiceInstance(label: "x", url: "https://e.com").darkMode, .auto)
    }

    func testAutoDarkModeDefaultsFalse() {
        XCTAssertFalse(AppPreferences().autoDarkModeEnabledEffective)
        XCTAssertTrue(AppPreferences(autoDarkModeEnabled: true).autoDarkModeEnabledEffective)
    }

    func testAnnoyanceBlockingDefaultsFalse() {
        XCTAssertFalse(AppPreferences().annoyanceBlockingEnabledEffective)
        XCTAssertTrue(AppPreferences(annoyanceBlockingEnabled: true).annoyanceBlockingEnabledEffective)
    }

    func testReaderModeLibraryLoads() {
        XCTAssertFalse(ReaderMode.libraryJS.isEmpty)
        XCTAssertTrue(ReaderMode.libraryJS.contains("Readability"))
    }

    func testDarkReaderBootstrapEnablesOnlyWhenDark() {
        let dark = DarkReaderSupport.bootstrapScript(enable: true)
        XCTAssertTrue(dark.contains("DarkReader.enable"))
        XCTAssertTrue(dark.contains("setFetchMethod(window.fetch)"))

        let light = DarkReaderSupport.bootstrapScript(enable: false)
        XCTAssertFalse(light.contains("DarkReader.enable("))
        XCTAssertTrue(light.contains("setFetchMethod(window.fetch)"))
    }

    func testDarkReaderAntiFlashSetsDarkBackground() {
        let s = DarkReaderSupport.antiFlashScript()
        XCTAssertTrue(s.contains("chorus-dr-antiflash"))
        XCTAssertTrue(s.contains("#1a1a1a"))
    }

    func testContentBlockingEnabledDefaultsTrue() {
        // nil (existing installs / fresh) resolves to enabled.
        XCTAssertTrue(AppPreferences().contentBlockingEnabledEffective)
        XCTAssertFalse(AppPreferences(contentBlockingEnabled: false).contentBlockingEnabledEffective)
    }

    func testBlocklistIdentifierIsStableAndContentAddressed() {
        let a = BlocklistSupport.identifier(prefix: "hz", forJSON: "[1,2,3]")
        let b = BlocklistSupport.identifier(prefix: "hz", forJSON: "[1,2,3]")
        let c = BlocklistSupport.identifier(prefix: "hz", forJSON: "[1,2,4]")
        XCTAssertEqual(a, b)                 // same JSON → same id (cache hit)
        XCTAssertNotEqual(a, c)              // changed JSON → new id (recompile)
        XCTAssertTrue(a.hasPrefix("hz-"))
    }

    func testBlocklistRuleCountAndChunkingGuard() throws {
        let json = "[{\"x\":1},{\"x\":2},{\"x\":3}]"
        XCTAssertEqual(try BlocklistSupport.ruleCount(inJSON: json), 3)
        XCTAssertFalse(BlocklistSupport.needsChunking(count: 3, cap: 5))
        XCTAssertTrue(BlocklistSupport.needsChunking(count: 6, cap: 5))
    }

    func testBlocklistChunkUnderCapReturnsSingle() throws {
        let json = "[{\"x\":1},{\"x\":2}]"
        let chunks = try BlocklistSupport.chunk(json: json, cap: 10)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, json)
    }

    func testBlocklistChunkSplitsOverCapPreservingTotal() throws {
        let rules = (0..<7).map { "{\"x\":\($0)}" }.joined(separator: ",")
        let json = "[\(rules)]"
        let chunks = try BlocklistSupport.chunk(json: json, cap: 3)
        XCTAssertEqual(chunks.count, 3)  // 3 + 3 + 1
        let total = try chunks.reduce(0) { $0 + (try BlocklistSupport.ruleCount(inJSON: $1)) }
        XCTAssertEqual(total, 7)
    }

    func testBlocklistChunkRejectsNonArray() {
        XCTAssertThrowsError(try BlocklistSupport.chunk(json: "{\"not\":\"an array\"}"))
    }

    // MARK: - Rail layout preference

    func testRailLayoutParsesFromStoredValueWithSidebarFallback() {
        XCTAssertEqual(AppPreferences(railLayoutRaw: nil).railLayout, .sidebar)
        XCTAssertEqual(AppPreferences(railLayoutRaw: "sidebar").railLayout, .sidebar)
        XCTAssertEqual(AppPreferences(railLayoutRaw: "topBars").railLayout, .topBars)
        XCTAssertEqual(AppPreferences(railLayoutRaw: "hybrid").railLayout, .hybrid)
        XCTAssertEqual(AppPreferences(railLayoutRaw: "garbage").railLayout, .sidebar)
    }

    func testAppearanceModeParsesFromStoredValueWithSystemFallback() {
        XCTAssertEqual(AppPreferences(appearanceModeRaw: nil).appearanceMode, .system)
        XCTAssertEqual(AppPreferences(appearanceModeRaw: "system").appearanceMode, .system)
        XCTAssertEqual(AppPreferences(appearanceModeRaw: "light").appearanceMode, .light)
        XCTAssertEqual(AppPreferences(appearanceModeRaw: "dark").appearanceMode, .dark)
        XCTAssertEqual(AppPreferences(appearanceModeRaw: "garbage").appearanceMode, .system)
    }

    // MARK: - Notification grouping by space

    /// Wires a service into a space on both relationship sides, mirroring what a
    /// live model context would maintain, so `NotificationGrouping` sees it.
    @discardableResult
    private func link(_ service: ServiceInstance, to space: Space, sortOrder: Int) -> SpaceServiceLink {
        let link = SpaceServiceLink(sortOrder: sortOrder, space: space, service: service)
        space.serviceLinks.append(link)
        service.spaceLinks.append(link)
        return link
    }

    func testNotificationGroupingIsFlatAndHeaderlessWhenNoSpacesHaveMembers() {
        let a = ServiceInstance(label: "Zulip", url: "https://z.example")
        let b = ServiceInstance(label: "Asana", url: "https://a.example")
        let empty = Space(name: "Empty", emoji: "📭", sortOrder: 0)

        let result = NotificationGrouping.grouped(spaces: [empty], services: [a, b])

        XCTAssertFalse(result.showsHeaders)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertNil(result.groups[0].space)
        // Flat bucket is sorted by label.
        XCTAssertEqual(result.groups[0].services.map(\.label), ["Asana", "Zulip"])
    }

    func testNotificationGroupingFollowsSpaceOrderThenLinkOrder() {
        let work = Space(name: "Work", emoji: "🏢", sortOrder: 0)
        let play = Space(name: "Play", emoji: "🎮", sortOrder: 1)
        let slack = ServiceInstance(label: "Slack", url: "https://s.example")
        let gmail = ServiceInstance(label: "Gmail", url: "https://g.example")
        let discord = ServiceInstance(label: "Discord", url: "https://d.example")
        // Add gmail first but at a higher sortOrder to prove link order wins.
        link(gmail, to: work, sortOrder: 1)
        link(slack, to: work, sortOrder: 0)
        link(discord, to: play, sortOrder: 0)

        let result = NotificationGrouping.grouped(spaces: [work, play], services: [slack, gmail, discord])

        XCTAssertTrue(result.showsHeaders)
        XCTAssertEqual(result.groups.map { $0.space?.name }, ["Work", "Play"])
        XCTAssertEqual(result.groups[0].services.map(\.label), ["Slack", "Gmail"])
        XCTAssertEqual(result.groups[1].services.map(\.label), ["Discord"])
    }

    func testNotificationGroupingPutsUngroupedServicesInTrailingBucket() {
        let work = Space(name: "Work", emoji: "🏢", sortOrder: 0)
        let slack = ServiceInstance(label: "Slack", url: "https://s.example")
        let loose2 = ServiceInstance(label: "Notion", url: "https://n.example")
        let loose1 = ServiceInstance(label: "Figma", url: "https://f.example")
        link(slack, to: work, sortOrder: 0)

        let result = NotificationGrouping.grouped(spaces: [work], services: [slack, loose2, loose1])

        XCTAssertTrue(result.showsHeaders)
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.groups[0].space?.name, "Work")
        XCTAssertNil(result.groups[1].space)  // the ungrouped bucket, last
        XCTAssertEqual(result.groups[1].services.map(\.label), ["Figma", "Notion"])
    }

    func testNotificationGroupingSkipsSpacesWithNoServices() {
        let full = Space(name: "Full", emoji: "📥", sortOrder: 0)
        let empty = Space(name: "Empty", emoji: "📭", sortOrder: 1)
        let slack = ServiceInstance(label: "Slack", url: "https://s.example")
        link(slack, to: full, sortOrder: 0)

        let result = NotificationGrouping.grouped(spaces: [full, empty], services: [slack])

        XCTAssertEqual(result.groups.map { $0.space?.name }, ["Full"])
    }

    func testNotificationGroupingRepeatsServiceInEachSpace() {
        let home = Space(name: "Home", emoji: "🏠", sortOrder: 0)
        let design = Space(name: "Design", emoji: "🎨", sortOrder: 1)
        let slack = ServiceInstance(label: "Slack", url: "https://s.example")
        link(slack, to: home, sortOrder: 0)
        link(slack, to: design, sortOrder: 0)

        let result = NotificationGrouping.grouped(spaces: [home, design], services: [slack])

        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.groups[0].services.map(\.label), ["Slack"])
        XCTAssertEqual(result.groups[1].services.map(\.label), ["Slack"])
        // Same underlying object under both headers, so toggles stay in sync.
        XCTAssertTrue(result.groups[0].services[0] === result.groups[1].services[0])
        // No ungrouped bucket when every service belongs to a space.
        XCTAssertFalse(result.groups.contains { $0.space == nil })
    }

}
