import Foundation

enum UserAgentProvider {
    /// Safari user agent string used when a service has no custom userAgent set.
    /// Matches a real Safari release so services like Gmail, Outlook, Slack, and
    /// WhatsApp recognise the browser and serve their full web app instead of a
    /// degraded view (or refuse outright — Slack drops support for older Safari
    /// versions on a rolling basis).
    ///
    /// Keep the `Version/N.N` token bumped to a currently-shipping Safari major
    /// when releasing. The "Intel Mac OS X 10_15_7" platform token is what
    /// Apple's own Safari emits on Apple Silicon too — don't change it.
    static let safariDefault = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
}
