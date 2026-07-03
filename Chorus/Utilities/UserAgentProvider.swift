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

    /// Mobile Safari (iOS) user agent used by a service's "Mobile view" toggle,
    /// so sites serve their phone/tablet web layout instead of the desktop one.
    /// Keep the iOS and `Version/N` tokens roughly current when bumping
    /// `safariDefault`.
    static let mobileSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
}
