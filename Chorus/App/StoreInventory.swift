import Foundation
import SQLite3

/// The spaces and services `seedDefaultDataIfNeeded` writes on a genuine fresh
/// install. Shared with `StoreContent.looksLikeUntouchedSeed` so the seeder and
/// the fingerprint can never drift apart; `testSeededStoreIsFingerprintedAsSeed`
/// fails if they do.
enum DefaultSeed {
    static let spaces: [(name: String, emoji: String)] = [
        (name: "Personal", emoji: "🏠"),
        (name: "Work", emoji: "💼"),
    ]

    static let personalServices: [(label: String, url: String, catalogID: String)] = [
        (label: "Gmail", url: "https://mail.google.com/mail/u/0/#inbox", catalogID: "gmail"),
        (label: "Discord", url: "https://discord.com/channels/@me", catalogID: "discord"),
        (label: "ChatGPT", url: "https://chatgpt.com", catalogID: "chatgpt"),
        (label: "Claude", url: "https://claude.ai", catalogID: "claude"),
    ]

    static let workServices: [(label: String, url: String, catalogID: String)] = [
        (label: "Gmail", url: "https://mail.google.com/mail/u/0/#inbox", catalogID: "gmail"),
        (label: "Slack", url: "https://app.slack.com/client", catalogID: "slack"),
        (label: "Outlook", url: "https://outlook.cloud.microsoft/mail/", catalogID: "outlook"),
    ]

    /// Every seeded service label, including the duplicate Gmail that appears in
    /// both spaces. Compared as a multiset, so the duplicate matters.
    static var allServiceLabels: [String] {
        (personalServices + workServices).map(\.label)
    }
}

/// What a store holds. Read from a raw SQLite file for a backup, or from the
/// open container for the live store. Comparable so candidates can be ranked
/// without opening anything. `Hashable` because `StoreCandidate` carries one and
/// the picker's `List` selection binds to the candidate itself.
struct StoreContent: Hashable, Sendable {
    let spaces: Int
    let services: Int
    let links: Int
    /// Space names and service labels, used only to recognize the untouched
    /// default seed. Order is not significant; both are compared as multisets.
    let spaceNames: [String]
    let serviceLabels: [String]

    var isEmpty: Bool { spaces == 0 && services == 0 }

    /// Whether this store holds more than `other`: more services, or the same
    /// services spread over more spaces. The single comparison the ranking and
    /// both offer triggers share, so "more complete" means one thing everywhere.
    func holdsMore(than other: StoreContent) -> Bool {
        if services != other.services { return services > other.services }
        return spaces > other.spaces
    }

    /// True only when the store is exactly what `seedDefaultDataIfNeeded`
    /// writes: the two seeded spaces, the seven seeded services, nothing added,
    /// nothing renamed. A store like this holds nothing of the user's, which is
    /// what makes it safe to preselect a backup over.
    var looksLikeUntouchedSeed: Bool {
        spaces == DefaultSeed.spaces.count
            && services == DefaultSeed.allServiceLabels.count
            && spaceNames.sorted() == DefaultSeed.spaces.map(\.name).sorted()
            && serviceLabels.sorted() == DefaultSeed.allServiceLabels.sorted()
    }
}
