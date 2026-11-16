import WebKit

/// What a new version asks for that the user has not granted. Strict on
/// purpose: any new permission waits for the user, quiet ones included, and a
/// site counts as granted only when a grant covers it. Grants are never
/// pruned when a version asks for less.
@available(macOS 15.4, *)
enum WebExtensionUpdateReview {
    /// The permissions and match patterns in the request that the grants do
    /// not cover, each sorted and once. `nativeMessaging` is left out: Chorus
    /// can never grant it.
    @MainActor static func newRequests(
        permissions: [String],
        matchPatterns: [String],
        grantedPermissions: [String],
        grantedMatchPatterns: [String]
    ) -> (permissions: [String], matchPatterns: [String]) {
        let ignored: Set<String> = Set(grantedPermissions).union([WebExtensionPermissionText.nativeMessaging])
        let newPermissions = permissions.filter { !ignored.contains($0) }.sortedUnique()
        let newPatterns = matchPatterns
            .filter { requested in !grantedMatchPatterns.contains { covers(granted: $0, requested: requested) } }
            .sortedUnique()
        return (newPermissions, newPatterns)
    }

    /// Whether one granted pattern covers a requested one: the same string,
    /// the two ways of writing every site, or WebKit's own match with no
    /// options. Never `.matchBidirectionally`, which would let a narrow grant
    /// cover a broad request.
    @MainActor static func covers(granted: String, requested: String) -> Bool {
        if granted == requested { return true }
        // WebKit says `*://*/*` does not cover `<all_urls>`, which also takes
        // file URLs. Chorus pages are web pages, so the two count as one.
        // Every other pattern goes to WebKit, which checks scheme and path:
        // `https://*/*` is every host, not every site.
        if everySite.contains(granted) && everySite.contains(requested) { return true }
        guard let grant = try? WKWebExtension.MatchPattern(string: granted),
              let ask = try? WKWebExtension.MatchPattern(string: requested) else { return false }
        return grant.matches(ask)
    }

    private static let everySite: Set<String> = ["<all_urls>", "*://*/*"]
}
