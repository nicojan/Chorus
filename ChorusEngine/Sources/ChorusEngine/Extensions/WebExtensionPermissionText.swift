import Foundation

/// Plain words for what an extension asks to do, for the screen where the user
/// agrees to add it. Pure, so the tests can pin the wording.
public enum WebExtensionPermissionText {
    /// The permission an extension needs to talk to its own Mac app. Chorus can
    /// never grant it: macOS lets only Safari reach those apps.
    public static let nativeMessaging = "nativeMessaging"

    /// One line per permission worth telling the user about, in a fixed order.
    /// Permissions with no effect a user would notice (storage, alarms) are
    /// left out.
    public static func lines(forPermissions permissions: [String]) -> [String] {
        let known: [(String, String)] = [
            ("tabs", "See the address and title of each page"),
            ("activeTab", "Read and change a page when you click its button"),
            ("scripting", "Run its own scripts in pages"),
            ("webNavigation", "See which pages you open"),
            ("webRequest", "See the requests pages make"),
            ("declarativeNetRequest", "Block or change what pages load"),
            ("declarativeNetRequestWithHostAccess", "Block or change what pages load"),
            ("cookies", "Read and change cookies"),
            ("clipboardWrite", "Copy text to the clipboard"),
            ("clipboardRead", "Read the clipboard"),
            ("notifications", "Show notifications"),
            ("contextMenus", "Add items to the menu you get with a right click"),
            ("menus", "Add items to the menu you get with a right click"),
            ("downloads", "Start downloads"),
            ("history", "Read your history"),
            ("bookmarks", "Read your bookmarks"),
            ("idle", "Tell when you step away from the Mac"),
            ("privacy", "Change privacy settings"),
        ]
        let present = Set(permissions)
        var seen = Set<String>()
        return known
            .filter { present.contains($0.0) }
            .map(\.1)
            .filter { seen.insert($0).inserted }
    }

    /// One line for the sites an extension can read and change.
    public static func siteLine(forMatchPatterns patterns: [String]) -> String? {
        guard !patterns.isEmpty else { return nil }
        if patterns.contains(where: isEverySite) {
            return "Read and change every site you open in Chorus"
        }
        let hosts = patterns.compactMap(host(of:)).sortedUnique()
        guard !hosts.isEmpty else { return nil }
        let shown = hosts.prefix(4).joined(separator: ", ")
        let more = hosts.count > 4 ? " and \(hosts.count - 4) more" : ""
        return "Read and change pages on \(shown)\(more)"
    }

    /// Whether a match pattern covers every web page.
    static func isEverySite(_ pattern: String) -> Bool {
        if pattern == "<all_urls>" { return true }
        guard let host = host(of: pattern) else { return false }
        return host == "*"
    }

    /// The host part of `scheme://host/path`, or nil.
    static func host(of pattern: String) -> String? {
        guard let schemeEnd = pattern.range(of: "://") else { return nil }
        let rest = pattern[schemeEnd.upperBound...]
        let host = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return host.isEmpty ? nil : host
    }
}
