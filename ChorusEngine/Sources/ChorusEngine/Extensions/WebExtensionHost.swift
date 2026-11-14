import AppKit
import WebKit

/// What an extension is, read before the user agrees to add it.
public struct WebExtensionSummary {
    public let name: String
    public let version: String?
    public let summary: String?
    public let icon: NSImage?
    /// Raw `WKWebExtension.Permission` values it asks for up front.
    public let permissions: [String]
    /// Match patterns it asks for up front, as strings.
    public let matchPatterns: [String]
    /// It asks to talk to its Mac app, which Chorus cannot allow.
    public let needsNativeApp: Bool
    /// What WebKit found wrong with the manifest. An extension can load with
    /// some of these.
    public let problems: [String]
}

/// One extension's button for the toolbar.
public struct WebExtensionToolbarItem: Identifiable {
    public let id: UUID
    public let label: String
    public let icon: NSImage?
    public let badgeText: String
    public let isEnabled: Bool
}

/// Runs web extensions in Chorus's service pages through WebKit's
/// `WKWebExtensionController`: one controller for the app, one context per
/// extension, every service page a tab of one window.
///
/// What it cannot do: let an extension talk to its own Mac app. macOS hands
/// that only to Safari (the system refuses to look the app's handler up for
/// any other host), so an extension that needs it loads, and the parts that
/// call its app fail with a message saying why.
@available(macOS 15.4, *)
@MainActor
@Observable
public final class WebExtensionHost: NSObject, WebExtensionHosting {
    @ObservationIgnored let controller: WKWebExtensionController
    @ObservationIgnored private(set) var contexts: [UUID: WKWebExtensionContext] = [:]
    @ObservationIgnored private var tabsByView: [ObjectIdentifier: WebExtensionTab] = [:]
    @ObservationIgnored private(set) var orderedTabs: [WebExtensionTab] = []
    /// The tab last reported to WebKit as active, to fire `tabs.onActivated`
    /// once per change.
    @ObservationIgnored private weak var reportedActiveTab: WebExtensionTab?
    /// Loads waiting on WebKit, and the ones the user cancelled meanwhile by
    /// turning the extension off or removing it.
    @ObservationIgnored private var loading: Set<UUID> = []
    @ObservationIgnored private var cancelledLoads: Set<UUID> = []
    /// Loads waiting for an extension's background to start.
    @ObservationIgnored private var backgroundWaits: [UUID: (token: UUID, continuation: CheckedContinuation<Void, Never>)] = [:]
    /// How long a load waits for a background before going on without it.
    static let backgroundStartLimit: Duration = .seconds(10)
    @ObservationIgnored private(set) lazy var window = WebExtensionWindow(host: self)
    @ObservationIgnored private var anchors: [UUID: WeakView] = [:]
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    /// Each extension's stand-in for Chrome's offscreen document, kept until
    /// the extension stops. See `ExtensionCompatibility`.
    @ObservationIgnored private(set) var offscreenPages: [UUID: WKWebView] = [:]

    /// Bumped when an extension changes its button (icon, badge, title), so
    /// SwiftUI views that read `toolbarItems` draw again.
    public private(set) var actionRevision = 0
    /// Which extensions are running. Observable, for the toolbar and settings.
    public private(set) var loadedIDs: Set<UUID> = []

    /// When false, new pages get no controller: with no extension on, Chorus's
    /// pages are exactly what they were before extensions existed.
    @ObservationIgnored public var isActive = false

    /// The page on screen; see `WebExtensionHosting`.
    @ObservationIgnored public var displayedPage: (() -> WKWebView?)?

    /// The tab on screen, worked out when asked, so a switch between a
    /// service's tabs or to a Mac app is never missed.
    var activeTab: WebExtensionTab? {
        displayedPage?().flatMap { tabsByView[ObjectIdentifier($0)] }
    }

    /// Opens a URL an extension asked to open in a new tab or window. Chorus
    /// has no free-standing tabs, so it routes it like a link leaving a service.
    @ObservationIgnored public var onOpenURL: ((URL) -> Void)?
    /// Brings a service to the front, for `tabs.update({active: true})`.
    @ObservationIgnored public var onActivateService: ((UUID) -> Void)?
    /// Asks the user about permissions an extension requests while running.
    /// Gets the extension's name and plain-word lines; true allows them all.
    /// Unset means deny.
    @ObservationIgnored public var onPermissionPrompt: ((String, [String]) async -> Bool)?
    /// The grants changed while running; the app saves them to the record.
    @ObservationIgnored public var onGrantsChanged: ((UUID, [String], [String]) -> Void)?

    /// `storageIdentifier` names where extensions keep their settings and
    /// data; nil keeps nothing on disk, for tests.
    public init(storageIdentifier: UUID?) {
        let configuration = storageIdentifier.map { WKWebExtensionController.Configuration(identifier: $0) }
            ?? .nonPersistent()
        // Extensions pick a code path from the user agent of their own pages.
        // A Safari path talks to the vendor's Mac app, which only Safari can
        // reach, so extension pages claim Chrome and take the path that works
        // alone. Bitwarden's Chrome build, told it was in Safari, spun waiting
        // for its app and its popup never opened; with no browser named it
        // could not start at all. Service pages still claim Safari.
        let pageConfiguration = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        pageConfiguration.applicationNameForUserAgent = Self.extensionApplicationName
        configuration.webViewConfiguration = pageConfiguration
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
        observeGrantChanges()
    }

    /// The tail of an extension page's user agent.
    static let extensionApplicationName = ExtensionCompatibility.chromeApplicationName

    // MARK: - Loading

    /// Reads an extension without running it, for the confirmation screen.
    public func inspect(_ source: WebExtensionRecord.Source, library: WebExtensionLibrary) async throws -> WebExtensionSummary {
        let webExtension = try await Self.makeExtension(source, library: library)
        let permissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
        return WebExtensionSummary(
            name: webExtension.displayName ?? "Extension",
            version: webExtension.displayVersion ?? webExtension.version,
            summary: webExtension.displayDescription,
            icon: webExtension.icon(for: CGSize(width: 64, height: 64)),
            permissions: permissions,
            matchPatterns: webExtension.allRequestedMatchPatterns.map(\.string).sorted(),
            needsNativeApp: permissions.contains(WebExtensionPermissionText.nativeMessaging)
                || webExtension.optionalPermissions.map(\.rawValue).contains(WebExtensionPermissionText.nativeMessaging),
            problems: webExtension.errors.map(\.localizedDescription)
        )
    }

    /// Starts an extension with the grants in its record.
    public func load(_ record: WebExtensionRecord, library: WebExtensionLibrary) async throws {
        try await load(record, library: library, grantingAccess: true)
    }

    /// Starts a background and waits until it is up, the extension is
    /// unloaded, or the time limit passes. WebKit never answers a start whose
    /// context was unloaded meanwhile, so waiting on it alone hung forever
    /// and left the extension marked as loading for good.
    private func startBackground(of context: WKWebExtensionContext, id: UUID, name: String) async {
        let token = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            backgroundWaits[id] = (token, continuation)
            Task { @MainActor [weak self] in
                do {
                    try await context.loadBackgroundContent()
                } catch {
                    AppLogger.extensions.error("Background of \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                self?.endBackgroundWait(id, token: token)
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.backgroundStartLimit)
                self?.endBackgroundWait(id, token: token)
            }
        }
    }

    /// Ends the wait for `id`; with a token, only that wait, so a late answer
    /// from an earlier load cannot cut a newer one short.
    private func endBackgroundWait(_ id: UUID, token: UUID? = nil) {
        guard let wait = backgroundWaits[id], token == nil || wait.token == token else { return }
        backgroundWaits.removeValue(forKey: id)
        wait.continuation.resume()
    }

    /// `grantingAccess` false loads the extension with no permissions or
    /// sites, so it can reach no page: for finding its stored data to delete.
    private func load(_ record: WebExtensionRecord, library: WebExtensionLibrary, grantingAccess: Bool) async throws {
        guard contexts[record.id] == nil, !loading.contains(record.id) else { return }
        loading.insert(record.id)
        cancelledLoads.remove(record.id)
        defer { loading.remove(record.id) }
        let webExtension = try await Self.makeExtension(record.source, library: library)
        // Turned off or removed while WebKit read it, or loaded by another
        // call in the meantime.
        guard !cancelledLoads.contains(record.id), contexts[record.id] == nil else {
            cancelledLoads.remove(record.id)
            return
        }
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = record.id.uuidString
        context.baseURL = record.baseURL
        // Every service store is persistent, so this only keeps extensions out
        // of anything private that might be added later.
        context.hasAccessToPrivateData = false
        #if DEBUG
        context.isInspectable = true
        #endif
        if grantingAccess {
            for permission in record.grantedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
            }
            for pattern in record.grantedMatchPatterns {
                guard let matchPattern = try? WKWebExtension.MatchPattern(string: pattern) else { continue }
                context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
            }
        }
        try controller.load(context)
        contexts[record.id] = context
        loadedIDs = loadedIDs.union([record.id])
        actionRevision += 1
        // Wait for the background to start before returning. On macOS 15 and
        // 26, WebKit drops a content script's message that arrives while the
        // background is still starting (macOS 27 queues it); CI caught this.
        // Callers that build pages after `load` returns are then safe.
        if grantingAccess, webExtension.hasBackgroundContent {
            await startBackground(of: context, id: record.id, name: record.name)
        }
        AppLogger.extensions.info("Loaded extension \(record.name, privacy: .public)")
    }

    public func unload(_ id: UUID) {
        if loading.contains(id) { cancelledLoads.insert(id) }
        endBackgroundWait(id)
        guard let context = contexts.removeValue(forKey: id) else { return }
        do {
            try controller.unload(context)
        } catch {
            AppLogger.extensions.error("Unloading an extension failed: \(error.localizedDescription, privacy: .public)")
        }
        loadedIDs = loadedIDs.subtracting([id])
        anchors.removeValue(forKey: id)
        offscreenPages.removeValue(forKey: id)
        actionRevision += 1
    }

    /// Deletes what an extension stored, for a removal: what it kept through
    /// the storage APIs (settings, a cached vault), and its pages' own site
    /// data (IndexedDB, local storage) under its fixed origin. An extension
    /// that is not running is loaded for this with no access to any page.
    /// Returns false when the storage-API data could not be reached, because
    /// the extension's files are gone or damaged.
    public func removeStoredData(for record: WebExtensionRecord, library: WebExtensionLibrary) async -> Bool {
        let wasRunning = contexts[record.id] != nil
        if !wasRunning {
            try? await load(record, library: library, grantingAccess: false)
        }
        var reached = false
        if let context = contexts[record.id] {
            reached = true
            let types = WKWebExtensionController.allExtensionDataTypes
            let dataRecord: WKWebExtension.DataRecord? = await withCheckedContinuation { continuation in
                controller.fetchDataRecord(ofTypes: types, for: context) { continuation.resume(returning: $0) }
            }
            if let dataRecord {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    controller.removeData(ofTypes: types, from: [dataRecord]) { continuation.resume() }
                }
            }
        }
        if !wasRunning { unload(record.id) }
        await removeSiteData(for: record)
        return reached
    }

    /// The website data WebKit keeps for the extension's origin. Main actor
    /// on purpose: `WKWebsiteDataStore` removal off the main thread crashes.
    private func removeSiteData(for record: WebExtensionRecord) async {
        guard let store = controller.configuration.defaultWebsiteDataStore else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let host = record.baseURL.host ?? record.id.uuidString.lowercased()
        let records = await store.dataRecords(ofTypes: types)
        let matching = records.filter { $0.displayName.lowercased().contains(host) }
        guard !matching.isEmpty else { return }
        await store.removeData(ofTypes: types, for: matching)
    }

    /// The name, version and icon of a running extension, for Settings.
    public func details(for id: UUID) -> (name: String?, version: String?, icon: NSImage?)? {
        guard let webExtension = contexts[id]?.webExtension else { return nil }
        return (
            webExtension.displayName,
            webExtension.displayVersion ?? webExtension.version,
            webExtension.icon(for: CGSize(width: 32, height: 32))
        )
    }

    /// Problems WebKit reported for a running extension.
    public func problems(for id: UUID) -> [String] {
        contexts[id]?.errors.map(\.localizedDescription) ?? []
    }

    public func hasOptionsPage(_ id: UUID) -> Bool {
        contexts[id]?.optionsPageURL != nil
    }

    public func openOptionsPage(_ id: UUID) {
        guard let context = contexts[id] else { return }
        presentOptionsPage(for: context)
    }

    private static func makeExtension(_ source: WebExtensionRecord.Source, library: WebExtensionLibrary) async throws -> WKWebExtension {
        switch source {
        case .appExtension(let path):
            guard let bundle = Bundle(url: URL(fileURLWithPath: path, isDirectory: true)) else {
                throw WebExtensionLibrary.ImportError.notFound
            }
            return try await WKWebExtension(appExtensionBundle: bundle)
        case .package(let folder):
            // Must be an absolute directory URL: a relative one kills the
            // process outright (found in the 2026-11-09 probe).
            let root = library.packageURL(folder: folder).absoluteURL
            do {
                try ExtensionCompatibility.apply(to: root)
            } catch {
                AppLogger.extensions.error("Compatibility script not added to \(folder, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return try await WKWebExtension(resourceBaseURL: root)
        }
    }

    // MARK: - WebExtensionHosting

    public func attach(to configuration: WKWebViewConfiguration) {
        guard isActive else { return }
        configuration.webExtensionController = controller
    }

    public func pageOpened(_ webView: WKWebView, service: UUID) {
        guard webView.configuration.webExtensionController === controller,
              tabsByView[ObjectIdentifier(webView)] == nil else { return }
        dropTabsWithoutPages()
        let tab = WebExtensionTab(webView: webView, serviceID: service, host: self)
        tabsByView[ObjectIdentifier(webView)] = tab
        orderedTabs = orderedTabs + [tab]
        tab.startObserving { [weak self] tab, property in
            self?.controller.didChangeTabProperties(property, for: tab)
        }
        controller.didOpenTab(tab)
    }

    public func pageActivated(_ webView: WKWebView) {
        syncActiveTab()
    }

    /// Tells WebKit when the tab on screen differs from the one it last heard
    /// about. Runs on every activation hint and before every button click.
    func syncActiveTab() {
        let current = activeTab
        guard current !== reportedActiveTab else { return }
        let previous = reportedActiveTab
        reportedActiveTab = current
        if let current {
            controller.didActivateTab(current, previousActiveTab: previous)
        }
        actionRevision += 1
    }

    public func pageClosed(_ webView: WKWebView) {
        guard let tab = tabsByView.removeValue(forKey: ObjectIdentifier(webView)) else { return }
        tab.stopObserving()
        orderedTabs = orderedTabs.filter { $0 !== tab }
        if reportedActiveTab === tab { reportedActiveTab = nil }
        controller.didCloseTab(tab, windowIsClosing: false)
    }

    /// A page freed without a close (a coordinator deinit) leaves a tab with
    /// no web view; close those out so extensions stop seeing them.
    private func dropTabsWithoutPages() {
        let orphans = tabsByView.filter { $0.value.webView == nil }
        guard !orphans.isEmpty else { return }
        for (key, tab) in orphans {
            tabsByView.removeValue(forKey: key)
            tab.stopObserving()
            controller.didCloseTab(tab, windowIsClosing: false)
        }
        orderedTabs = orderedTabs.filter { $0.webView != nil }
    }

    func index(of tab: WebExtensionTab) -> Int {
        orderedTabs.firstIndex { $0 === tab } ?? 0
    }

    // MARK: - Toolbar

    /// The button of each running extension that has one, for the page on
    /// screen. Reads `actionRevision`, so a view showing these redraws when an
    /// extension changes its button.
    public func toolbarItems(for webView: WKWebView?, order: [UUID]) -> [WebExtensionToolbarItem] {
        _ = actionRevision
        let running = loadedIDs
        let tab = webView.flatMap { tabsByView[ObjectIdentifier($0)] }
        return order.compactMap { id in
            guard running.contains(id), let context = contexts[id], let action = context.action(for: tab) else { return nil }
            let label = action.label.isEmpty ? (context.webExtension.displayName ?? "Extension") : action.label
            return WebExtensionToolbarItem(
                id: id,
                label: label,
                icon: action.icon(for: CGSize(width: 16, height: 16)),
                badgeText: action.badgeText,
                isEnabled: action.isEnabled
            )
        }
    }

    /// The user clicked an extension's button while `webView` was on screen.
    public func performAction(_ id: UUID, on webView: WKWebView?) {
        guard let context = contexts[id] else { return }
        syncActiveTab()
        let tab = webView.flatMap { tabsByView[ObjectIdentifier($0)] }
        if let tab { context.userGesturePerformed(in: tab) }
        context.performAction(for: tab)
    }

    /// The view an extension's popup points at: its toolbar button.
    public func setAnchor(_ view: NSView?, for id: UUID) {
        anchors[id] = view.map(WeakView.init)
    }

    private func recordID(of context: WKWebExtensionContext) -> UUID? {
        contexts.first { $0.value === context }?.key
    }

    // MARK: - Grants

    private func observeGrantChanges() {
        let names: [Notification.Name] = [
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
        ]
        notificationTokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let context = note.object as? WKWebExtensionContext
                MainActor.assumeIsolated {
                    guard let self, let context else { return }
                    self.reportGrants(of: context)
                }
            }
        }
    }

    private func reportGrants(of context: WKWebExtensionContext) {
        guard let id = recordID(of: context) else { return }
        let permissions = context.grantedPermissions.keys.map(\.rawValue)
        let patterns = context.grantedPermissionMatchPatterns.keys.map(\.string)
        onGrantsChanged?(id, permissions, patterns)
    }

    // MARK: - Pages the extension opens

    private func presentOptionsPage(for context: WKWebExtensionContext) {
        guard let url = context.optionsPageURL, let configuration = context.webViewConfiguration else { return }
        ExtensionPageWindow.open(
            url: url,
            configuration: configuration,
            title: context.webExtension.displayName ?? "Extension Settings"
        )
    }
}

// MARK: - WKWebExtensionControllerDelegate

@available(macOS 15.4, *)
extension WebExtensionHost: WKWebExtensionControllerDelegate {
    public func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    public func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        openRequestedPage(configuration.url, context: extensionContext)
        completionHandler(nil, nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        configuration.tabURLs.forEach { openRequestedPage($0, context: extensionContext) }
        completionHandler(nil, nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        presentOptionsPage(for: extensionContext)
        completionHandler(nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let lines = WebExtensionPermissionText.lines(forPermissions: permissions.map(\.rawValue))
        ask(extensionContext, lines: lines.isEmpty ? ["Use more of Chorus's features"] : lines) { allowed in
            completionHandler(allowed ? permissions : [], nil)
        }
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = urls.compactMap(\.host).sortedUnique()
        let line = hosts.isEmpty ? "Read and change more sites" : "Read and change pages on \(hosts.joined(separator: ", "))"
        ask(extensionContext, lines: [line]) { allowed in
            completionHandler(allowed ? urls : [], nil)
        }
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let line = WebExtensionPermissionText.siteLine(forMatchPatterns: matchPatterns.map(\.string)) ?? "Read and change more sites"
        ask(extensionContext, lines: [line]) { allowed in
            completionHandler(allowed ? matchPatterns : [], nil)
        }
    }

    public func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actionRevision += 1
    }

    public func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else {
            return completionHandler(WebExtensionAdapterError.unsupported("this popup"))
        }
        let anchor = recordID(of: context).flatMap { anchors[$0]?.view }
            ?? activeTab?.webView
            ?? NSApp.keyWindow?.contentView
        guard let anchor, anchor.window != nil else {
            return completionHandler(WebExtensionAdapterError.pageGone)
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        completionHandler(nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        replyHandler(nil, Self.nativeAppError(extensionContext))
    }

    public func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(Self.nativeAppError(extensionContext))
    }

    private static func nativeAppError(_ context: WKWebExtensionContext) -> NSError {
        let name = context.webExtension.displayName ?? "This extension"
        return NSError(domain: "Chorus.WebExtension", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(name) needs its Mac app for this, and macOS lets only Safari reach it.",
        ])
    }

    private func openRequestedPage(_ url: URL?, context: WKWebExtensionContext) {
        guard let url else { return }
        if url.fragment == Self.offscreenMarker, url.scheme == context.baseURL.scheme, url.host == context.baseURL.host {
            openOffscreenPage(url, context: context)
            return
        }
        // An extension's own page (a welcome or settings page) can only load
        // with the extension's configuration, so it gets a window of its own.
        if url.scheme == context.baseURL.scheme, let configuration = context.webViewConfiguration {
            ExtensionPageWindow.open(url: url, configuration: configuration, title: context.webExtension.displayName ?? "Extension")
            return
        }
        onOpenURL?(url)
    }

    /// The fragment `ExtensionCompatibility`'s `chrome.offscreen` puts on the
    /// page it asks for.
    static let offscreenMarker = "chorus-offscreen"

    /// Loads an extension's offscreen document in a view no window shows.
    /// Chrome lets that page write the clipboard without a click when the
    /// extension holds `clipboardWrite`; WebKit only through a preference,
    /// set here on this page alone. Reading stays off: WebKit drops Chrome's
    /// `clipboardRead`, so nobody agreed to it.
    private func openOffscreenPage(_ url: URL, context: WKWebExtensionContext) {
        guard let id = recordID(of: context), offscreenPages[id] == nil,
              let base = context.webViewConfiguration,
              let configuration = base.copy() as? WKWebViewConfiguration,
              let preferences = base.preferences.copy() as? WKPreferences else { return }
        if context.hasPermission(.clipboardWrite) {
            preferences.setValue(true, forKey: "javaScriptCanAccessClipboard")
        }
        configuration.preferences = preferences
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        #if DEBUG
        page.isInspectable = true
        #endif
        page.load(URLRequest(url: url))
        offscreenPages[id] = page
    }

    private func ask(_ context: WKWebExtensionContext, lines: [String], completion: @escaping (Bool) -> Void) {
        guard let prompt = onPermissionPrompt else { return completion(false) }
        let name = context.webExtension.displayName ?? "An extension"
        Task { @MainActor in
            completion(await prompt(name, lines))
        }
    }
}

/// Holds a view without keeping it alive.
private struct WeakView {
    weak var view: NSView?
}
