import Foundation
import SwiftData

/// Per-service dark-theming choice. `auto` follows the global auto-dark setting
/// plus detection; `on` always themes (when the app is Dark); `off` never does.
enum ServiceDarkMode: String, CaseIterable {
    case auto, on, off
}

/// Per-service camera/microphone permission. `ask` prompts once and remembers
/// the answer (flipping to allow/deny); `allow` grants silently; `deny` blocks.
enum MediaPermissionPolicy: String, CaseIterable {
    case ask, allow, deny

    var displayName: String {
        switch self {
        case .ask: return "Ask"
        case .allow: return "Allow"
        case .deny: return "Deny"
        }
    }
}

/// Which capture a page requested. Mirrors `WKMediaCaptureType` without pulling
/// WebKit into the model, so the resolution logic stays pure and unit-testable.
enum MediaCaptureKind {
    case camera, microphone, cameraAndMicrophone
}

/// Pure resolution of camera/microphone permission. No WebKit, no SwiftData —
/// just the policy math, so the truth table is unit-testable in isolation.
enum MediaPermissionResolver {
    /// The outcome for a single capture request.
    enum Resolution: Equatable {
        case grant, deny, ask
    }

    /// The effective policy for one field: an explicit per-service value wins,
    /// else the global default, else `.ask`. Resolution-time fallback (like page
    /// zoom), so changing the global default moves every service that hasn't
    /// pinned its own value.
    static func effectivePolicy(serviceRaw: String?, globalRaw: String?) -> MediaPermissionPolicy {
        if let raw = serviceRaw, let policy = MediaPermissionPolicy(rawValue: raw) { return policy }
        if let raw = globalRaw, let policy = MediaPermissionPolicy(rawValue: raw) { return policy }
        return .ask
    }

    /// Combines the camera and microphone policies for a capture request.
    /// Restrictiveness order is deny > ask > allow: a combined request grants
    /// only when both fields allow, denies if either denies, otherwise asks.
    static func resolve(
        _ kind: MediaCaptureKind,
        camera: MediaPermissionPolicy,
        microphone: MediaPermissionPolicy
    ) -> Resolution {
        switch kind {
        case .camera: return resolution(for: camera)
        case .microphone: return resolution(for: microphone)
        case .cameraAndMicrophone:
            if camera == .deny || microphone == .deny { return .deny }
            if camera == .ask || microphone == .ask { return .ask }
            return .grant
        }
    }

    /// The device(s) a prompt is actually deciding: those the request involves
    /// AND whose policy is currently `.ask`. Gating by the request kind (not just
    /// the `.ask` state) is what stops a single-device prompt from persisting its
    /// answer to the other, un-asked device — and lets the prompt copy name only
    /// what's in question. Pure, so it's unit-testable.
    static func askedFields(
        _ kind: MediaCaptureKind,
        camera: MediaPermissionPolicy,
        microphone: MediaPermissionPolicy
    ) -> (camera: Bool, microphone: Bool) {
        let cameraInvolved: Bool
        let microphoneInvolved: Bool
        switch kind {
        case .camera: (cameraInvolved, microphoneInvolved) = (true, false)
        case .microphone: (cameraInvolved, microphoneInvolved) = (false, true)
        case .cameraAndMicrophone: (cameraInvolved, microphoneInvolved) = (true, true)
        }
        return (cameraInvolved && camera == .ask, microphoneInvolved && microphone == .ask)
    }

    private static func resolution(for policy: MediaPermissionPolicy) -> Resolution {
        switch policy {
        case .allow: return .grant
        case .deny: return .deny
        case .ask: return .ask
        }
    }
}

@Model
final class ServiceInstance {
    @Attribute(.unique) var id: UUID
    var label: String
    var url: String
    var customIconData: Data?
    var fetchedIconData: Data?
    var faviconFetchedAt: Date?
    var catalogEntryID: String?
    var isMuted: Bool
    var showBadge: Bool
    var neverHibernate: Bool
    var userAgent: String?
    var dataStoreIdentifier: UUID
    /// Per-service page zoom (e.g. 1.0 = 100%, 1.25 = 125%). Stored optional
    /// so SwiftData lightweight migration succeeds on existing rows — read
    /// sites should use `zoomLevelEffective` which substitutes 1.0 for nil.
    var pageZoom: Double?

    /// Whether this service forwards its web notifications to macOS Notification
    /// Center. Stored optional so SwiftData lightweight migration succeeds on
    /// existing rows — nil is treated as enabled (the prior default). Read sites
    /// should use `notifiesOSEffective`. Independent of `showBadge` (badge) and
    /// of `isMuted` (mute is the master override over both).
    var osNotificationsEnabled: Bool?

    /// Per-service custom CSS injected into the page. Stored optional so
    /// SwiftData lightweight migration succeeds on existing rows — nil means
    /// "use the built-in default for this service" (see `ServiceCSSDefaults`),
    /// so a service like LinkedIn still gets its messaging-only view untouched.
    /// A non-nil value overrides the default; a blank value disables both.
    var customCSS: String?

    /// Force a dark appearance on a service that has no dark theme of its own,
    /// by inverting the page. Services that DO have a dark theme should leave
    /// this off and simply follow the system appearance. Optional for SwiftData
    /// lightweight migration; nil is treated as off. Read via
    /// `isForceDarkModeEnabled`.
    var forceDarkMode: Bool?

    /// Per-service dark-theming choice (auto/on/off), stored raw for SwiftData
    /// lightweight migration. Read via `darkMode`, which migrates the legacy
    /// `forceDarkMode` flag. Only `darkModeRaw` is written from now on.
    var darkModeRaw: String?

    /// Cached detection verdict for `auto` mode: true if the service was found to
    /// lack its own dark theme (a light background under a dark app). nil until
    /// probed once; kept so the site only flashes into dark theming on the first
    /// visit. Cleared when the service's URL changes.
    var detectedLacksDarkTheme: Bool?

    /// Per-service camera / microphone permission, stored raw for SwiftData
    /// lightweight migration. nil means "no per-service value" — resolution falls
    /// back to the global default, then `.ask` (see `MediaPermissionResolver`).
    /// Read the raw directly for resolution; the `cameraPolicy`/`microphonePolicy`
    /// accessors are for the editor UI (nil → `.ask`).
    var cameraPolicyRaw: String?
    var microphonePolicyRaw: String?

    /// Whether the one-time "Passkeys aren't available for sign-in" notice has
    /// been shown for this service. Optional for SwiftData lightweight
    /// migration; nil is treated as "not yet seen" (see `needsPasskeyNotice`).
    /// A one-time launch backfill marks the services of a pre-existing install
    /// as seen, so the notice only appears for services added after this
    /// shipped — not retroactively for every service the user already had.
    var hasSeenPasskeyNotice: Bool?

    @Relationship(deleteRule: .cascade, inverse: \SpaceServiceLink.service)
    var spaceLinks: [SpaceServiceLink]

    var createdAt: Date
    var lastAccessedAt: Date

    /// Materialises the storage-optional zoom into a Double (nil → 1.0).
    var zoomLevelEffective: Double { pageZoom ?? 1.0 }

    /// Materialises the storage-optional force-dark flag (nil → false).
    var isForceDarkModeEnabled: Bool { forceDarkMode ?? false }

    /// The effective dark-theming mode. An explicit `darkModeRaw` wins; otherwise
    /// a legacy `forceDarkMode == true` service maps to `.on` (preserving its
    /// behavior), and everything else defaults to `.auto`.
    var darkMode: ServiceDarkMode {
        if let raw = darkModeRaw, let mode = ServiceDarkMode(rawValue: raw) { return mode }
        if forceDarkMode == true { return .on }
        return .auto
    }

    /// Whether the passkey-limitation notice still needs to be shown for this
    /// service (nil or false → not yet seen).
    var needsPasskeyNotice: Bool { !(hasSeenPasskeyNotice ?? false) }

    /// Materialises the storage-optional OS-notification flag (nil → true), so
    /// services created before this flag existed keep forwarding notifications.
    var notifiesOSEffective: Bool { osNotificationsEnabled ?? true }

    /// The service's own camera policy (nil → `.ask`). For in-hand reads and the
    /// editor; runtime resolution uses `cameraPolicyRaw` + the global default.
    var cameraPolicy: MediaPermissionPolicy {
        get { cameraPolicyRaw.flatMap(MediaPermissionPolicy.init(rawValue:)) ?? .ask }
        set { cameraPolicyRaw = newValue.rawValue }
    }

    /// The service's own microphone policy (nil → `.ask`). See `cameraPolicy`.
    var microphonePolicy: MediaPermissionPolicy {
        get { microphonePolicyRaw.flatMap(MediaPermissionPolicy.init(rawValue:)) ?? .ask }
        set { microphonePolicyRaw = newValue.rawValue }
    }

    /// True if this service is muted directly, or via any space it belongs to
    /// (muting a space cascades to its members). Use this when the model object
    /// is already in hand — it avoids AppState's fetch-all-then-scan lookup.
    var isEffectivelyMuted: Bool {
        if isMuted { return true }
        // Skip links whose space was deleted: reading `.space` on a dangling
        // link faults the freed model and traps. `.modelContext` is nil once a
        // model is deleted, so check it before touching `isMutedEffective`.
        return spaceLinks.contains { $0.space.modelContext != nil && $0.space.isMutedEffective }
    }

    init(
        id: UUID = UUID(),
        label: String,
        url: String,
        customIconData: Data? = nil,
        fetchedIconData: Data? = nil,
        faviconFetchedAt: Date? = nil,
        catalogEntryID: String? = nil,
        isMuted: Bool = false,
        showBadge: Bool = true,
        neverHibernate: Bool = false,
        userAgent: String? = nil,
        dataStoreIdentifier: UUID = UUID(),
        pageZoom: Double? = nil,
        osNotificationsEnabled: Bool? = nil,
        customCSS: String? = nil,
        forceDarkMode: Bool? = nil,
        darkModeRaw: String? = nil,
        detectedLacksDarkTheme: Bool? = nil,
        hasSeenPasskeyNotice: Bool? = nil,
        cameraPolicyRaw: String? = nil,
        microphonePolicyRaw: String? = nil
    ) {
        self.id = id
        self.label = label
        self.url = url
        self.customIconData = customIconData
        self.fetchedIconData = fetchedIconData
        self.faviconFetchedAt = faviconFetchedAt
        self.catalogEntryID = catalogEntryID
        self.isMuted = isMuted
        self.showBadge = showBadge
        self.neverHibernate = neverHibernate
        self.userAgent = userAgent
        self.dataStoreIdentifier = dataStoreIdentifier
        self.pageZoom = pageZoom
        self.osNotificationsEnabled = osNotificationsEnabled
        self.customCSS = customCSS
        self.forceDarkMode = forceDarkMode
        self.darkModeRaw = darkModeRaw
        self.detectedLacksDarkTheme = detectedLacksDarkTheme
        self.hasSeenPasskeyNotice = hasSeenPasskeyNotice
        self.cameraPolicyRaw = cameraPolicyRaw
        self.microphonePolicyRaw = microphonePolicyRaw
        self.spaceLinks = []
        self.createdAt = Date()
        self.lastAccessedAt = Date()
    }
}
