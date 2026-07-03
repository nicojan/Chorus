import XCTest
@testable import Chorus

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
}
