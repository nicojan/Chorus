import Foundation
import WebKit

/// A page a service opened with `window.open` that Chorus shows as a tab inside
/// the service's card instead of in a window of its own: a Canva design, a
/// Figma file. The service's own page is not a tab; it is always there, ahead
/// of these.
@MainActor
@Observable
public final class ServiceTab: Identifiable {
    public let id = UUID()
    public let webView: WKWebView
    public private(set) var title: String?
    @ObservationIgnored private var titleObservation: NSKeyValueObservation?
    /// Recent WebContent terminations, so a tab that crashes on every load
    /// gets the same backoff the service's page has instead of reloading forever.
    @ObservationIgnored var crashTimestamps: [Date] = []

    init(webView: WKWebView) {
        self.webView = webView
        title = webView.title
        // Read the title from the change value, not the web view: the closure is
        // nonisolated, and the web view is main-actor state.
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            let value = change.newValue ?? nil
            Task { @MainActor [weak self] in
                guard let self, let value, !value.isEmpty else { return }
                self.title = value
            }
        }
    }

    func stopObserving() {
        titleObservation?.invalidate()
        titleObservation = nil
    }
}

/// The tabs one service has open, in the order they were opened, and which one
/// is on screen. A nil selection means the service's own page.
///
/// Kept in memory only. Tabs close when the service is hibernated or rebuilt,
/// and are not restored at launch.
@MainActor
@Observable
public final class ServiceTabs {
    public private(set) var tabs: [ServiceTab] = []
    public private(set) var selectedID: UUID?

    /// Nonisolated so the coordinator can make one as a stored default.
    nonisolated init() {}

    public var selectedTab: ServiceTab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    public var isEmpty: Bool { tabs.isEmpty }

    public func tab(for webView: WKWebView) -> ServiceTab? {
        tabs.first { $0.webView === webView }
    }

    public func add(_ tab: ServiceTab) {
        tabs = tabs + [tab]
        selectedID = tab.id
    }

    /// Shows a tab, or the service's own page for nil. An id that is not open
    /// is ignored.
    public func select(_ id: UUID?) {
        guard id == nil || tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Moves the selection by `offset` through the service's page and its tabs,
    /// wrapping at either end.
    public func selectOffset(_ offset: Int) {
        let index = TabSelection.index(of: selectedID, in: tabs.map(\.id))
        selectedID = TabSelection.moving(from: index, by: offset, tabCount: tabs.count)
            .map { tabs[$0].id }
    }

    /// Takes a tab out and returns it so the caller can tear its web view down.
    @discardableResult
    public func remove(_ id: UUID) -> ServiceTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tabs[index]
        let selectedIndex = TabSelection.index(of: selectedID, in: tabs.map(\.id))
        let remaining = tabs.enumerated().filter { $0.offset != index }.map(\.element)
        let next = TabSelection.afterClosing(index: index, selectedIndex: selectedIndex, tabCount: tabs.count)
        tabs = remaining
        selectedID = next.map { remaining[$0].id }
        removed.stopObserving()
        return removed
    }

    /// Takes every tab out, for a teardown.
    public func removeAll() -> [ServiceTab] {
        let removed = tabs
        tabs = []
        selectedID = nil
        removed.forEach { $0.stopObserving() }
        return removed
    }
}

/// Where the selection goes as tabs open, close and cycle. Indices are into the
/// tab list; nil is the service's own page. Pure, for the tests.
enum TabSelection {
    static func index(of id: UUID?, in ids: [UUID]) -> Int? {
        guard let id else { return nil }
        return ids.firstIndex(of: id)
    }

    /// The selection after the tab at `index` closes, as an index into the list
    /// that remains. Closing the tab on screen shows the one to its left, or the
    /// service's page when it was the first. Closing any other tab leaves the
    /// selection where it was, shifted if it sat to the right.
    static func afterClosing(index: Int, selectedIndex: Int?, tabCount: Int) -> Int? {
        guard let selectedIndex, (0..<tabCount).contains(index) else { return selectedIndex }
        if selectedIndex == index {
            return index > 0 ? index - 1 : nil
        }
        return selectedIndex > index ? selectedIndex - 1 : selectedIndex
    }

    /// Cycles through the page (position 0) and the tabs (positions 1...n).
    static func moving(from selectedIndex: Int?, by offset: Int, tabCount: Int) -> Int? {
        guard tabCount > 0 else { return nil }
        let positions = tabCount + 1
        let current = selectedIndex.map { $0 + 1 } ?? 0
        let next = ((current + offset) % positions + positions) % positions
        return next == 0 ? nil : next - 1
    }
}
