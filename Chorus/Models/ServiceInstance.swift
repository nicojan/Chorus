import Foundation
import SwiftData

/// Per-service dark-theming choice. `on` always themes while the app is Dark;
/// `off` never does. Off is the default.
enum ServiceDarkMode: String, CaseIterable {
    case on, off
}

/// Per-service hibernation policy — when Chorus frees this service's WebContent
/// process while it runs in the background. The service you're viewing always
/// stays loaded, so every policy acts only while the service is not on screen.
/// - `followGlobal`: obey the app-wide auto-hibernate setting (the prior default).
/// - `never`: keep the service loaded (the legacy "Keep Loaded" flag).
/// - `immediate`: hibernate a few seconds after you switch to another service.
/// - `after`: hibernate once idle for `hibernateAfterMinutes`.
enum HibernationPolicy: String, CaseIterable {
    case followGlobal, never, immediate, after
}

/// Pure policy → idle-threshold math for auto-hibernation, kept free of AppState
/// and WebKit so the truth table is unit-testable in isolation. Mirrors
/// `MediaPermissionResolver`.
enum HibernationResolver {
    /// The idle sweep's backstop for `.immediate` services: short, because their
    /// real teardown is the switch-away grace timer — this only catches one that
    /// somehow escaped it. Also the grace period itself, kept in one place.
    static let immediateBackstopSeconds: TimeInterval = 5

    /// The idle seconds after which a service should hibernate on a sweep, or nil
    /// if it shouldn't hibernate on this sweep at all.
    /// - `never`: never hibernates.
    /// - `followGlobal`: the global interval, but only while the global toggle is on.
    /// - `after`: the service's own idle minutes.
    /// - `immediate`: the short backstop above.
    static func idleThreshold(
        policy: HibernationPolicy,
        globalEnabled: Bool,
        globalIdleMinutes: Int,
        afterMinutes: Int
    ) -> TimeInterval? {
        switch policy {
        case .never:
            return nil
        case .followGlobal:
            return globalEnabled ? TimeInterval(globalIdleMinutes * 60) : nil
        case .after:
            return TimeInterval(afterMinutes * 60)
        case .immediate:
            return immediateBackstopSeconds
        }
    }
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

    /// Per-service camera / microphone permission, stored raw for SwiftData
    /// lightweight migration. nil means "no per-service value" — resolution falls
    /// back to the global default, then `.ask` (see `MediaPermissionResolver`).
    /// Read the raw directly for resolution; the `cameraPolicy`/`microphonePolicy`
    /// accessors are for the editor UI (nil → `.ask`).
    var cameraPolicyRaw: String?
    var microphonePolicyRaw: String?

    /// Open a link that leaves this service in an in-app Chorus window instead of
    /// the system browser. Only affects links that no other Chorus service owns —
    /// a link matching another service still switches to it. Optional for
    /// SwiftData lightweight migration; nil is treated as off (today's behaviour:
    /// external links open in the default browser). Read via
    /// `opensExternalLinksInAppEffective`.
    var openExternalLinksInApp: Bool?

    /// Report the page as focused even while Chorus is in the background, so a
    /// service that flips your status to "away" or "idle" on window blur
    /// (Microsoft Teams and the like) keeps showing you as active. Optional for
    /// SwiftData lightweight migration; nil is treated as off. Read via
    /// `staysActiveInBackgroundEffective`. Off by default because faking focus
    /// can make a service think you're already looking at it and hold back the
    /// desktop notifications Chorus forwards — an opt-in trade.
    var stayActiveInBackground: Bool?

    /// Whether the one-time "Passkeys aren't available for sign-in" notice has
    /// been shown for this service. Optional for SwiftData lightweight
    /// migration; nil is treated as "not yet seen" (see `needsPasskeyNotice`).
    /// A one-time launch backfill marks the services of a pre-existing install
    /// as seen, so the notice only appears for services added after this
    /// shipped — not retroactively for every service the user already had.
    var hasSeenPasskeyNotice: Bool?

    /// Per-service hibernation policy, stored raw for SwiftData lightweight
    /// migration. nil means "no per-service value set" — read via
    /// `hibernationPolicyEffective`, which migrates the legacy `neverHibernate`
    /// flag (true → `.never`) so existing "Keep Loaded" services are preserved.
    var hibernationPolicyRaw: String?

    /// Idle minutes before hibernation when the policy is `.after`. Optional for
    /// SwiftData lightweight migration; read via `hibernateAfterMinutesEffective`,
    /// which clamps to 1...120 (nil → 10). Ignored for the other policies.
    var hibernateAfterMinutes: Int?

    @Relationship(deleteRule: .cascade, inverse: \SpaceServiceLink.service)
    var spaceLinks: [SpaceServiceLink]

    var createdAt: Date
    var lastAccessedAt: Date

    /// Materialises the storage-optional zoom into a Double (nil → 1.0).
    var zoomLevelEffective: Double { pageZoom ?? 1.0 }

    /// Materialises the storage-optional force-dark flag (nil → false).
    var isForceDarkModeEnabled: Bool { forceDarkMode ?? false }

    /// The effective dark-theming mode. An explicit `darkModeRaw` of `"on"` or
    /// `"off"` wins; otherwise a legacy `forceDarkMode == true` service maps to
    /// `.on` (preserving its behavior). A stored `"auto"`, an unknown value, or
    /// nothing set all default to `.off` — manual theming is opt-in, so any
    /// service that rode the old auto mode stops theming until the user turns it
    /// back on for that service.
    var darkMode: ServiceDarkMode {
        if let raw = darkModeRaw, let mode = ServiceDarkMode(rawValue: raw) { return mode }
        if forceDarkMode == true { return .on }
        return .off
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

    /// Materialises the storage-optional in-app-links flag (nil → false), so
    /// existing services keep opening external links in the system browser.
    var opensExternalLinksInAppEffective: Bool { openExternalLinksInApp ?? false }

    /// Materialises the storage-optional stay-active flag (nil → false), so a
    /// service only fakes focus when the user has explicitly opted in.
    var staysActiveInBackgroundEffective: Bool { stayActiveInBackground ?? false }

    /// Catalog categories whose services must never auto-hibernate (chat apps).
    /// A hibernated web app can only refresh its badge on the periodic sweep, not
    /// fire an instant alert, so chat apps stay live even when a per-service timer
    /// is set — you need to hear from them the moment a message lands.
    static let notificationCriticalCategories: Set<String> = ["Messaging"]

    /// True when this service must stay live for real-time notifications, decided
    /// by its catalog category. Custom (non-catalog) services aren't covered —
    /// use the `.never` hibernation policy for those.
    var isNotificationCritical: Bool {
        guard let catalogEntryID,
              let entry = ServiceCatalog.shared.entry(for: catalogEntryID)
        else { return false }
        return Self.notificationCriticalCategories.contains(entry.category)
    }

    /// The effective hibernation policy. An explicit `hibernationPolicyRaw` wins;
    /// otherwise a legacy `neverHibernate == true` service maps to `.never`
    /// (preserving "Keep Loaded"), and everything else — including an unknown
    /// stored value — defaults to `.followGlobal`.
    var hibernationPolicyEffective: HibernationPolicy {
        if let raw = hibernationPolicyRaw, let policy = HibernationPolicy(rawValue: raw) {
            return policy
        }
        return neverHibernate ? .never : .followGlobal
    }

    /// Idle minutes before hibernation for the `.after` policy, clamped to a sane
    /// 1...120 (nil → 10). Mirrors the global `autoHibernateIdleMinutesEffective`.
    var hibernateAfterMinutesEffective: Int {
        min(120, max(1, hibernateAfterMinutes ?? 10))
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
        hasSeenPasskeyNotice: Bool? = nil,
        cameraPolicyRaw: String? = nil,
        microphonePolicyRaw: String? = nil,
        openExternalLinksInApp: Bool? = nil,
        stayActiveInBackground: Bool? = nil,
        hibernationPolicyRaw: String? = nil,
        hibernateAfterMinutes: Int? = nil
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
        self.hasSeenPasskeyNotice = hasSeenPasskeyNotice
        self.cameraPolicyRaw = cameraPolicyRaw
        self.microphonePolicyRaw = microphonePolicyRaw
        self.openExternalLinksInApp = openExternalLinksInApp
        self.stayActiveInBackground = stayActiveInBackground
        self.hibernationPolicyRaw = hibernationPolicyRaw
        self.hibernateAfterMinutes = hibernateAfterMinutes
        self.spaceLinks = []
        self.createdAt = Date()
        self.lastAccessedAt = Date()
    }
}
