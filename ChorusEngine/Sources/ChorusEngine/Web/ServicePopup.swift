import AppKit
import WebKit

/// One popup window a service opened with `window.open`: a sign-in flow, or a
/// page the service wanted in a window of its own.
@MainActor
final class ServicePopup {
    let webView: WKWebView
    let window: NSWindow
    /// Whether the popup was *opened at* a known sign-in gateway. Set once, from
    /// the URL that opened it — see `WebViewCoordinator.shouldReloadOpener` for
    /// why the rest of the navigation chain is deliberately not consulted.
    let openedAtAuthHost: Bool
    /// False for a popup a tab opened: closing it never reloads anything. See
    /// `WebViewCoordinator.createWebViewWith`.
    let reloadsOpener: Bool
    var titleObservation: NSKeyValueObservation?
    /// Recent WebContent terminations, so a popup that crashes on every load
    /// gets the same backoff the main view has instead of reloading forever.
    var crashTimestamps: [Date] = []

    init(webView: WKWebView, window: NSWindow, openedAtAuthHost: Bool, reloadsOpener: Bool = true) {
        self.webView = webView
        self.window = window
        self.openedAtAuthHost = openedAtAuthHost
        self.reloadsOpener = reloadsOpener
    }
}

/// Which popups close when one opens or closes, as index ranges into the list a
/// coordinator keeps, first-opened first.
///
/// The list is a chain, not a single slot, because a sign-in popup can open a
/// popup of its own: an identity provider handing a second step to another
/// window. With one slot, the child's arrival closed its parent, the child's
/// `window.opener` went dead, and the sign-in stopped there. Each popup's
/// children sit after it, so "a popup and everything it opened" is always the
/// tail from its index.
enum PopupChain {
    /// What to close before a new popup opens. The service opening one replaces
    /// the whole chain — one flow at a time, as before. A popup opening one
    /// replaces only its own earlier children and keeps itself and its parents.
    static func closedWhenOpening(fromPopupAt openerIndex: Int?, count: Int) -> Range<Int> {
        let start = openerIndex.map { min($0 + 1, count) } ?? 0
        return start..<count
    }

    /// What to close when the popup at `index` closes: it, and every popup it
    /// opened, which would otherwise be left talking to a dead opener.
    static func closedWhenClosing(at index: Int, count: Int) -> Range<Int> {
        min(index, count)..<count
    }
}
