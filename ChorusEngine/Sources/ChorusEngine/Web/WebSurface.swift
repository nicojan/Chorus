import Foundation

/// What the web engine needs to know about one page it hosts. Chorus builds a
/// fresh one from a `ServiceInstance` at every call (`ServiceInstance.webSurface`),
/// so the engine never holds a SwiftData model and never reads one later.
///
/// Every value is already resolved by the app: `css` is the effective CSS, not
/// the raw field, and the Bools are the effective policies, not the stored flags.
public struct WebSurface: Sendable, Equatable {
    /// Which cookie and storage jar the page uses.
    public enum DataStore: Sendable, Hashable {
        /// `WKWebsiteDataStore(forIdentifier:)`. Several surfaces can share one id,
        /// so it is not the surface's own id.
        case persistent(UUID)
    }

    public let id: UUID
    /// The home address. A String, as stored, so an empty or malformed address
    /// takes the same path through `URL(string:)` it always has.
    public let url: String
    public let dataStore: DataStore
    /// Nil means the default Safari user agent.
    public let userAgent: String?
    /// The effective CSS to inject, or nil for none.
    public let css: String?
    /// The user turned dark theming on for this page. It themes only while the
    /// app is dark too.
    public let darkThemed: Bool
    /// Exempt from soft and full hibernation ("Keep Loaded").
    public let keepsLoaded: Bool
    /// Report the page as focused while it is in the background.
    public let staysActiveInBackground: Bool
    /// The name used in log lines.
    public let label: String

    public init(
        id: UUID,
        url: String,
        dataStore: DataStore,
        userAgent: String?,
        css: String?,
        darkThemed: Bool,
        keepsLoaded: Bool,
        staysActiveInBackground: Bool,
        label: String
    ) {
        self.id = id
        self.url = url
        self.dataStore = dataStore
        self.userAgent = userAgent
        self.css = css
        self.darkThemed = darkThemed
        self.keepsLoaded = keepsLoaded
        self.staysActiveInBackground = staysActiveInBackground
        self.label = label
    }
}
