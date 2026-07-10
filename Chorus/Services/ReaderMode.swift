import WebKit

/// Reader mode: strips the current page to its article text with Mozilla's
/// Readability (Apache-2.0), which runs entirely on the DOM — no network. The
/// library is injected on demand into an ISOLATED world so its `Readability`
/// global stays off the page's own `window`; it reads a clone of the shared DOM
/// and replaces the page with a clean, styled article. Toggling again reloads
/// the original page.
enum ReaderMode {

    /// Isolated world for the Readability library and the reader flag. Main-actor
    /// isolated because the WebKit lookup is.
    @MainActor static var world: WKContentWorld {
        WKContentWorld.world(name: "ChorusReader")
    }

    /// The Readability library source, loaded once from the app bundle.
    static let libraryJS: String = {
        guard let url = Bundle.main.url(forResource: "readability", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            AppLogger.general.error("readability.js not found in bundle; reader mode disabled")
            return ""
        }
        return js
    }()

    /// Enters or exits reader mode on the given web view. Injected into the
    /// isolated world: if already in reader mode it reloads the original page,
    /// otherwise it parses the article and replaces the page with a clean view.
    @MainActor static func toggle(on webView: WKWebView) {
        guard !libraryJS.isEmpty else { return }
        webView.evaluateJavaScript(libraryJS + "\n" + runnerJS, in: nil, in: world, completionHandler: nil)
    }

    /// Clean reader stylesheet. Follows the app's light/dark via `color-scheme`
    /// and `prefers-color-scheme`.
    private static let styles = """
    :root { color-scheme: light dark; }
    html, body { margin: 0; padding: 0; background: #fbfbf9; color: #1a1a1a; }
    @media (prefers-color-scheme: dark) { html, body { background: #1a1a1a; color: #e4e4e4; } }
    .chorus-reader { max-width: 42rem; margin: 0 auto; padding: 3rem 1.5rem 6rem;
        font: 18px/1.7 -apple-system, Georgia, 'Times New Roman', serif; }
    .chorus-reader h1 { font-size: 2rem; line-height: 1.2; margin: 0 0 .5rem; }
    .chorus-reader .byline { color: #888; margin: 0 0 2rem; font-size: .95rem; }
    .chorus-reader img, .chorus-reader figure { max-width: 100%; height: auto; }
    .chorus-reader figure { margin: 1.5rem 0; }
    .chorus-reader a { color: #2563eb; }
    @media (prefers-color-scheme: dark) { .chorus-reader a { color: #6ea8fe; } }
    .chorus-reader pre { overflow: auto; background: rgba(127,127,127,.14); padding: 1rem; border-radius: 8px; }
    .chorus-reader blockquote { border-left: 3px solid rgba(127,127,127,.4); margin: 1.5rem 0; padding: 0 1rem; color: inherit; opacity: .9; }
    """

    /// Runs after the library at injection time. Reloads if already in reader
    /// mode; otherwise parses a clone of the document and replaces the page.
    private static var runnerJS: String {
        """
        (function() {
            if (window.__chorusReaderActive) { location.reload(); return; }
            try {
                function esc(s) {
                    return String(s == null ? "" : s)
                        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
                }
                var article = new Readability(document.cloneNode(true)).parse();
                if (!article || !article.content) { return; }
                window.__chorusReaderActive = true;
                var head = '<head><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
                    + '<style>\(styles)</style></head>';
                var body = '<body><main class="chorus-reader">'
                    + (article.title ? '<h1>' + esc(article.title) + '</h1>' : '')
                    + (article.byline ? '<p class="byline">' + esc(article.byline) + '</p>' : '')
                    + article.content
                    + '</main></body>';
                document.documentElement.innerHTML = head + body;
            } catch (e) {}
        })();
        """
    }
}
