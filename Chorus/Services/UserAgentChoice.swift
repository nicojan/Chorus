import ChorusEngine
import Foundation

/// The three user-agent choices the Edit Service sheet offers, and how each one
/// maps to the stored `ServiceInstance.userAgent`.
enum UserAgentChoice: String, CaseIterable, Identifiable {
    /// The default Safari user agent (stored as nil).
    case standard
    /// The iPhone user agent, so a site serves its mobile layout.
    case mobile
    /// Any other string the user types, or a catalog entry sets.
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default Safari"
        case .mobile: return "iPhone (mobile layout)"
        case .custom: return "Custom"
        }
    }

    /// The choice and the custom text a stored value opens at. A non-nil value
    /// that is neither nil nor the iPhone string opens as Custom, pre-filled.
    static func resolving(stored: String?) -> (choice: UserAgentChoice, customText: String) {
        guard let stored else { return (.standard, "") }
        if stored == UserAgentProvider.mobileSafari { return (.mobile, "") }
        return (.custom, stored)
    }

    /// The value to store for a choice. Custom with blank text is nil.
    static func storedValue(choice: UserAgentChoice, customText: String) -> String? {
        switch choice {
        case .standard: return nil
        case .mobile: return UserAgentProvider.mobileSafari
        case .custom:
            let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
