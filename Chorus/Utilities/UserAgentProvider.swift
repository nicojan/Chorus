import Foundation

enum UserAgentProvider {
    /// Default Safari-like user agent for macOS.
    /// Some services (WhatsApp Web, Google) block non-Safari user agents.
    static let safariDefault = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}
