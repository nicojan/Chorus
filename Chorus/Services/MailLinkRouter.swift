import Foundation

/// A snapshot of a service's persisted mail declaration, revalidated on routing.
struct MailLinkRegistration: Equatable, Sendable {
    let account: MailLinkAccount
    var serviceID: UUID { account.serviceID }
    let serviceURL: String
    let handlerTemplate: String
    let declaringOrigin: String
    let enabled: Bool

    /// A copy that revalidates against a different stored service URL.
    func withServiceURL(_ serviceURL: String) -> MailLinkRegistration {
        MailLinkRegistration(
            account: account,
            serviceURL: serviceURL,
            handlerTemplate: handlerTemplate,
            declaringOrigin: declaringOrigin,
            enabled: enabled
        )
    }
}

/// Transient sending-account identity and display context, also used by the chooser.
struct MailLinkAccount: Identifiable, Equatable, Sendable {
    var id: UUID { serviceID }
    let serviceID: UUID
    let label: String
    let providerLabel: String?
    let spaceLabels: [String]

    /// The line under the label in the account chooser: provider and space
    /// context, with the account's own label dropped when it would repeat.
    var chooserSubtitle: String {
        let pieces = ([providerLabel].compactMap { $0 } + spaceLabels)
            .filter { !$0.isEmpty && $0 != label }
        return pieces.joined(separator: " · ")
    }
}

struct MailLinkDestination: Equatable, Sendable {
    let serviceID: UUID
    let url: URL
}

enum MailLinkRouteOutcome: Equatable, Sendable {
    case noEligibleService
    case open(MailLinkDestination)
    case choose([MailLinkAccount])
    case rejectInvalidRequest
}

/// Serialises short-lived compatibility probes so discovering handlers cannot
/// double the app's live web-view count all at once during space preload.
struct MailHandlerProbeQueue: Sendable {
    private var waiting: [UUID] = []
    private(set) var active: UUID?

    mutating func enqueue(_ id: UUID) -> Bool {
        guard active != id, !waiting.contains(id) else { return false }
        waiting.append(id)
        return true
    }

    mutating func beginNext() -> UUID? {
        guard active == nil, !waiting.isEmpty else { return nil }
        let id = waiting.removeFirst()
        active = id
        return id
    }

    mutating func finish(_ id: UUID) -> Bool {
        if active == id {
            active = nil
            return true
        }
        let oldCount = waiting.count
        waiting.removeAll { $0 == id }
        return waiting.count != oldCount
    }
}

/// Bounds compatibility probes per service. A service that never declares a
/// handler would otherwise get a hidden Chromium-UA page load on every finished
/// navigation. The window still retries later in the session, so a declaration
/// made after sign-in is discovered without paying for a probe every time.
struct MailHandlerProbeThrottle {
    private let window: TimeInterval
    private var lastProbeDates: [UUID: Date] = [:]

    init(window: TimeInterval = 300) {
        self.window = window
    }

    /// Records the attempt when it allows one, so callers need a single call.
    mutating func allowsProbe(for id: UUID, at now: Date) -> Bool {
        if let lastProbe = lastProbeDates[id], now.timeIntervalSince(lastProbe) < window {
            return false
        }
        lastProbeDates[id] = now
        return true
    }

    mutating func reset(for id: UUID) {
        lastProbeDates.removeValue(forKey: id)
    }
}

struct MailLinkRequestQueue: Sendable {
    private(set) var requests: [URL] = []
    var isLocked = false

    var current: URL? { isLocked ? nil : requests.first }

    mutating func enqueue(_ url: URL) { requests.append(url) }

    @discardableResult
    mutating func completeCurrent() -> URL? {
        guard !requests.isEmpty else { return nil }
        return requests.removeFirst()
    }
}

/// The trust and routing seam for mail links. Callers provide current service
/// registrations; this type validates them afresh and never knows providers.
enum MailLinkRouter {
    static func registration(
        account: MailLinkAccount,
        serviceURL: String,
        protocolName: String,
        handlerTemplate: String,
        declaringPageURL: String,
        isMainFrame: Bool,
        enabled: Bool
    ) -> MailLinkRegistration? {
        guard isMainFrame,
              protocolName.caseInsensitiveCompare("mailto") == .orderedSame,
              let declaringURL = URL(string: declaringPageURL),
              let declaringOrigin = Origin(declaringURL),
              let resolvedTemplate = resolveTemplate(handlerTemplate, against: declaringURL),
              let handlerURL = URL(string: resolvedTemplate),
              validatedHandlerOrigin(
                template: handlerTemplate, resolvedURL: handlerURL,
                serviceURL: serviceURL, declaringOrigin: declaringOrigin.serialized
              ) != nil
        else { return nil }

        return MailLinkRegistration(
            account: account,
            serviceURL: serviceURL,
            handlerTemplate: resolvedTemplate,
            declaringOrigin: declaringOrigin.serialized,
            enabled: enabled
        )
    }

    /// Registration for `service`'s own declaration, using the minimal account
    /// shape routing needs before an account becomes a chooser candidate.
    static func registration(
        for service: ServiceInstance,
        protocolName: String,
        handlerTemplate: String,
        declaringPageURL: String,
        isMainFrame: Bool,
        enabled: Bool
    ) -> MailLinkRegistration? {
        registration(
            account: MailLinkAccount(serviceID: service.id, label: service.label, providerLabel: nil, spaceLabels: []),
            serviceURL: service.url,
            protocolName: protocolName,
            handlerTemplate: handlerTemplate,
            declaringPageURL: declaringPageURL,
            isMainFrame: isMainFrame,
            enabled: enabled
        )
    }

    static func route(_ request: URL, registrations: [MailLinkRegistration]) -> MailLinkRouteOutcome {
        guard request.scheme?.caseInsensitiveCompare("mailto") == .orderedSame else {
            return .rejectInvalidRequest
        }

        var seen = Set<UUID>()
        let eligible = registrations.filter { registration in
            // Mark the service seen only after it proves eligible: an invalid
            // registration must not consume the slot its own valid one needs.
            guard !seen.contains(registration.serviceID),
                  validatedDestination(for: request, registration: registration) != nil
            else { return false }
            seen.insert(registration.serviceID)
            return true
        }
        guard !eligible.isEmpty else { return .noEligibleService }
        if eligible.count == 1,
           let destination = validatedDestination(for: request, registration: eligible[0]) {
            return .open(destination)
        }
        return .choose(eligible.map(\.account))
    }

    static func destination(
        for request: URL,
        serviceID: UUID,
        registrations: [MailLinkRegistration]
    ) -> MailLinkDestination? {
        guard request.scheme?.caseInsensitiveCompare("mailto") == .orderedSame,
              let registration = registrations.first(where: { $0.serviceID == serviceID })
        else { return nil }
        return validatedDestination(for: request, registration: registration)
    }

    private static func validatedDestination(
        for request: URL,
        registration: MailLinkRegistration
    ) -> MailLinkDestination? {
        guard registration.enabled,
              let handlerURL = URL(string: registration.handlerTemplate),
              let handlerOrigin = validatedHandlerOrigin(
                template: registration.handlerTemplate, resolvedURL: handlerURL,
                serviceURL: registration.serviceURL, declaringOrigin: registration.declaringOrigin
              )
        else { return nil }

        let encodedRequest = percentEncodeForSubstitution(request.absoluteString)
        let destinationString = registration.handlerTemplate.replacingOccurrences(of: "%s", with: encodedRequest)
        guard let destination = URL(string: destinationString),
              Origin(destination) == handlerOrigin
        else { return nil }
        return MailLinkDestination(serviceID: registration.serviceID, url: destination)
    }

    /// Declaration acceptance supplies the raw template and its resolved URL;
    /// routing supplies the persisted absolute template. Metadata and boundary-
    /// specific frame, protocol and enablement checks stay with their callers.
    private static func validatedHandlerOrigin(
        template: String,
        resolvedURL: URL,
        serviceURL: String,
        declaringOrigin: String
    ) -> Origin? {
        guard placeholderCount(in: template) == 1,
              resolvedURL.scheme?.lowercased() == "https",
              let handlerOrigin = Origin(resolvedURL),
              let service = URL(string: serviceURL),
              let serviceOrigin = Origin(service),
              handlerOrigin.serialized == declaringOrigin,
              serviceOrigin.serialized == declaringOrigin
        else { return nil }
        return handlerOrigin
    }

    private static func placeholderCount(in string: String) -> Int {
        string.components(separatedBy: "%s").count - 1
    }

    /// Foundation treats `%s` as malformed percent encoding in some URL paths.
    /// Resolve with a URL-safe sentinel, then put the protocol placeholder back.
    private static func resolveTemplate(_ template: String, against base: URL) -> String? {
        let sentinel = "CHORUS_MAILTO_PLACEHOLDER_8E7A1D"
        let protected = template.replacingOccurrences(of: "%s", with: sentinel)
        guard let resolved = URL(string: protected, relativeTo: base)?.absoluteURL.absoluteString else { return nil }
        return resolved.replacingOccurrences(of: sentinel, with: "%s")
    }

    private static func percentEncodeForSubstitution(_ string: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        return string.utf8.map { byte in
            unreserved.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

}

/// Normalized origin components; callers retain their own trust policy.
struct Origin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty,
              scheme == "https" || scheme == "http"
        else { return nil }
        self.init(scheme: scheme, host: host, port: url.port)
    }

    init(scheme: String, host: String, port: Int?) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port ?? (scheme.lowercased() == "https" ? 443 : 80)
    }

    var serialized: String {
        let defaultPort = scheme == "https" ? 443 : 80
        return port == defaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
}
