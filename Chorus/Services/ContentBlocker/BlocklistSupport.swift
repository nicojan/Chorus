import Foundation
import CryptoKit

/// Pure, testable helpers for the content blocker: deriving a stable cache
/// identifier from the rule JSON, and splitting an oversized rule set into
/// chunks that each fit WebKit's per-list cap. No WebKit or disk access here so
/// this stays unit-testable.
enum BlocklistSupport {

    /// WebKit compiles at most this many rules into a single `WKContentRuleList`
    /// (raised from the original 50k). HaGezi Light sits well under it today; the
    /// guard exists so a future list that grows past the cap is split rather than
    /// silently rejected at compile time.
    static let maxRulesPerList = 150_000

    /// A short, stable identifier for a rule-list JSON payload, used as the
    /// `WKContentRuleListStore` cache key. Same JSON → same id (cache hit); any
    /// change → new id (recompile). Truncated SHA-256 is plenty to avoid
    /// collisions between the handful of versions we ever hold.
    static func identifier(prefix: String, forJSON json: String) -> String {
        let digest = SHA256.hash(data: Data(json.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(hex.prefix(16))"
    }

    /// Number of rules in a content-rule JSON array. Returns 0 if the JSON isn't
    /// a top-level array (the only shape WebKit accepts).
    static func ruleCount(inJSON json: String) throws -> Int {
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return (parsed as? [Any])?.count ?? 0
    }

    /// Whether a rule set of `count` rules needs splitting to fit the per-list cap.
    static func needsChunking(count: Int, cap: Int = maxRulesPerList) -> Bool {
        count > cap
    }

    /// Splits a content-rule JSON array into chunks that each hold at most `cap`
    /// rules, re-serialised as JSON-array strings. A set already within the cap
    /// comes back as a single element, so callers always add whatever this
    /// returns. Throws if the JSON isn't a top-level array.
    static func chunk(json: String, cap: Int = maxRulesPerList) throws -> [String] {
        guard cap > 0 else { return [json] }
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let rules = parsed as? [Any] else {
            throw BlocklistError.notAnArray
        }
        if rules.count <= cap {
            return [json]
        }

        var chunks: [String] = []
        var index = 0
        while index < rules.count {
            let slice = Array(rules[index..<min(index + cap, rules.count)])
            let data = try JSONSerialization.data(withJSONObject: slice)
            chunks.append(String(decoding: data, as: UTF8.self))
            index += cap
        }
        return chunks
    }

    enum BlocklistError: Error {
        case notAnArray
    }
}
