import Foundation

enum UserAgentProvider {
    /// Safari user agent string used when a service has no custom userAgent set.
    /// Matches a real Safari release so services like Gmail, Outlook, and WhatsApp
    /// recognise the browser and serve their full web app instead of a degraded view.
    static let safariDefault = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
}
