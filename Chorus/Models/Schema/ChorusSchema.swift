import Foundation
import SwiftData

// Explicit, versioned SwiftData schema + migration plan.
//
// Why this exists: Chorus used to open its store with a plain `Schema` and let
// SwiftData infer the migration. Inference is not deterministic — on some
// upgrades the store opened empty without throwing, silently losing data (the
// 1.5.11 → 1.5.12 incident). Pinning each shipped shape as a `VersionedSchema`
// and listing the steps in a `SchemaMigrationPlan` removes the "reconstruct the
// source shape at open time" guesswork: the store is matched to a declared
// version and walked through fixed, pre-declared stages.
//
// Scope (see docs/superpowers/specs/2026-07-24-versioned-schema-migration-plan.md):
// the floor is 1.5.11 — the incident's source version and the oldest shape worth
// covering for a Sparkle-auto-updated app. From 1.5.11 to today, ONLY
// `ServiceInstance` changed, and only by adding optional fields, so every stage
// is `.lightweight`. `Space`, `SpaceServiceLink`, and `AppPreferences` are
// unchanged across the whole window.
//
// Because `ServiceInstance`, `Space`, and `SpaceServiceLink` reference each other
// through relationships, each historical version freezes all three together in
// its own namespace so the relationship graph stays within-version. The
// standalone `AppPreferences` has no relationships and is identical across the
// window, so every version references the current type directly.
//
// IMPORTANT — the frozen types below mirror ONLY the stored shape (persisted
// properties + relationships). Computed helpers, static tables, and
// `ServiceCatalog` lookups are deliberately omitted: they do not affect the
// on-disk schema and would only add dependencies. Do not "enrich" them.
//
// Discipline: any change to a `@Model` stored property is a NEW schema version.
// Freeze the prior shape as a new `ChorusSchemaV…`, bump `ChorusSchemaVCurrent`'s
// `versionIdentifier`, and add a `.lightweight` (additive) or `.custom`
// (reshape) stage plus a fixture test. The plan-shape unit test turns "forgot to
// do this" into a red test instead of field data loss.

// MARK: - V1.5.11 (floor: before `stayActiveInBackground`)

enum ChorusSchemaV1_5_11: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 5, 11)

    static var models: [any PersistentModel.Type] {
        [ServiceInstance.self, Space.self, SpaceServiceLink.self, AppPreferences.self]
    }  // AppPreferences here is this namespace's frozen copy.

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
        var pageZoom: Double?
        var osNotificationsEnabled: Bool?
        var customCSS: String?
        var forceDarkMode: Bool?
        var darkModeRaw: String?
        var cameraPolicyRaw: String?
        var microphonePolicyRaw: String?
        var openExternalLinksInApp: Bool?
        var hasSeenPasskeyNotice: Bool?

        @Relationship(deleteRule: .cascade, inverse: \SpaceServiceLink.service)
        var spaceLinks: [SpaceServiceLink]

        var createdAt: Date
        var lastAccessedAt: Date

        init(id: UUID = UUID(), label: String = "", url: String = "") {
            self.id = id
            self.label = label
            self.url = url
            self.isMuted = false
            self.showBadge = true
            self.neverHibernate = false
            self.dataStoreIdentifier = UUID()
            self.spaceLinks = []
            self.createdAt = Date()
            self.lastAccessedAt = Date()
        }
    }

    @Model
    final class Space {
        @Attribute(.unique) var id: UUID
        var name: String
        var emoji: String
        var sortOrder: Int
        var isMuted: Bool?

        @Relationship(deleteRule: .cascade, inverse: \SpaceServiceLink.space)
        var serviceLinks: [SpaceServiceLink]

        var createdAt: Date

        init(id: UUID = UUID(), name: String = "", emoji: String = "", sortOrder: Int = 0) {
            self.id = id
            self.name = name
            self.emoji = emoji
            self.sortOrder = sortOrder
            self.serviceLinks = []
            self.createdAt = Date()
        }
    }

    @Model
    final class SpaceServiceLink {
        @Attribute(.unique) var id: UUID
        var sortOrder: Int

        @Relationship var space: Space
        @Relationship var service: ServiceInstance

        init(id: UUID = UUID(), sortOrder: Int = 0, space: Space, service: ServiceInstance) {
            self.id = id
            self.sortOrder = sortOrder
            self.space = space
            self.service = service
        }
    }

    // `AppPreferences` has no relationships and is byte-identical from 1.5.11
    // through the current shape, so this ONE frozen copy is shared by every
    // historical version (V1.5.12 references it too). It is frozen rather than
    // pointing at the live `AppPreferences` on purpose: referencing the live type
    // would mean a future field added to app settings silently changes the
    // *declared* 1.5.11/1.5.12 schema, so a real old store would stop matching
    // its version and fall back to inference. Uses the shared top-level
    // `AppPresenceMode` enum (stable). Stored properties only.
    @Model
    final class AppPreferences {
        @Attribute(.unique) var id: UUID
        var appPresenceMode: AppPresenceMode
        var launchAtLogin: Bool
        var globalKeyboardShortcutsEnabled: Bool
        var showBadgeCountInDock: Bool
        var autoDismissCookieBanners: Bool
        var selectedSpaceID: UUID?
        var selectedServiceID: UUID?
        var defaultZoom: Double?
        var scheduledDNDEnabled: Bool?
        var dndStartMinutes: Int?
        var dndEndMinutes: Int?
        var appLockEnabled: Bool?
        var lockOnLaunch: Bool?
        var lockOnSleep: Bool?
        var railLayoutRaw: String?
        var appearanceModeRaw: String?
        var contentBlockingEnabled: Bool?
        var annoyanceBlockingEnabled: Bool?
        var defaultCameraPolicyRaw: String?
        var defaultMicrophonePolicyRaw: String?
        var googleFaviconFallbackEnabled: Bool?
        var autoHibernateIdleEnabled: Bool?
        var autoHibernateIdleMinutes: Int?

        init(id: UUID = UUID()) {
            self.id = id
            self.appPresenceMode = .dock
            self.launchAtLogin = false
            self.globalKeyboardShortcutsEnabled = true
            self.showBadgeCountInDock = true
            self.autoDismissCookieBanners = true
        }
    }
}

// MARK: - V1.5.12 (adds `stayActiveInBackground` — the incident field)

enum ChorusSchemaV1_5_12: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 5, 12)

    // Reuses V1.5.11's frozen AppPreferences (unchanged between these versions);
    // ServiceInstance/Space/SpaceServiceLink are this namespace's own because the
    // relationship triangle must point at THIS version's ServiceInstance.
    static var models: [any PersistentModel.Type] {
        [ServiceInstance.self, Space.self, SpaceServiceLink.self, ChorusSchemaV1_5_11.AppPreferences.self]
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
        var pageZoom: Double?
        var osNotificationsEnabled: Bool?
        var customCSS: String?
        var forceDarkMode: Bool?
        var darkModeRaw: String?
        var cameraPolicyRaw: String?
        var microphonePolicyRaw: String?
        var openExternalLinksInApp: Bool?
        var stayActiveInBackground: Bool?
        var hasSeenPasskeyNotice: Bool?

        @Relationship(deleteRule: .cascade, inverse: \SpaceServiceLink.service)
        var spaceLinks: [SpaceServiceLink]

        var createdAt: Date
        var lastAccessedAt: Date

        init(id: UUID = UUID(), label: String = "", url: String = "") {
            self.id = id
            self.label = label
            self.url = url
            self.isMuted = false
            self.showBadge = true
            self.neverHibernate = false
            self.dataStoreIdentifier = UUID()
            self.spaceLinks = []
            self.createdAt = Date()
            self.lastAccessedAt = Date()
        }
    }

    @Model
    final class Space {
        @Attribute(.unique) var id: UUID
        var name: String
        var emoji: String
        var sortOrder: Int
        var isMuted: Bool?

        @Relationship(deleteRule: .cascade, inverse: \SpaceServiceLink.space)
        var serviceLinks: [SpaceServiceLink]

        var createdAt: Date

        init(id: UUID = UUID(), name: String = "", emoji: String = "", sortOrder: Int = 0) {
            self.id = id
            self.name = name
            self.emoji = emoji
            self.sortOrder = sortOrder
            self.serviceLinks = []
            self.createdAt = Date()
        }
    }

    @Model
    final class SpaceServiceLink {
        @Attribute(.unique) var id: UUID
        var sortOrder: Int

        @Relationship var space: Space
        @Relationship var service: ServiceInstance

        init(id: UUID = UUID(), sortOrder: Int = 0, space: Space, service: ServiceInstance) {
            self.id = id
            self.sortOrder = sortOrder
            self.space = space
            self.service = service
        }
    }
}

// MARK: - Current (1.5.13 / 1.5.14: adds per-service hibernation fields)
//
// Reuses the live top-level model types — today's model files are the single
// source of truth for the shipping shape. When a stored property changes, freeze
// THIS shape into a new `ChorusSchemaV…` before editing the live models, then
// bump the identifier here.

enum ChorusSchemaVCurrent: VersionedSchema {
    // NOTE: `versionIdentifier` is a schema-SHAPE label, not the app's marketing
    // version. It is (1,5,13) because the current shape first shipped in 1.5.13;
    // 1.5.14 added no model change, so it shares this identifier. Bump it only
    // when the stored shape changes — and to a value not already used by a
    // different shape (do not blindly mint the next marketing number).
    static let versionIdentifier = Schema.Version(1, 5, 13)

    static var models: [any PersistentModel.Type] {
        [ServiceInstance.self, Space.self, SpaceServiceLink.self, AppPreferences.self]
    }
}

// MARK: - Migration plan

enum ChorusMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ChorusSchemaV1_5_11.self, ChorusSchemaV1_5_12.self, ChorusSchemaVCurrent.self]
    }

    static var stages: [MigrationStage] {
        [
            // 1.5.11 → 1.5.12: adds ServiceInstance.stayActiveInBackground (optional).
            .lightweight(fromVersion: ChorusSchemaV1_5_11.self, toVersion: ChorusSchemaV1_5_12.self),
            // 1.5.12 → current: adds ServiceInstance.hibernationPolicyRaw + hibernateAfterMinutes (optional).
            .lightweight(fromVersion: ChorusSchemaV1_5_12.self, toVersion: ChorusSchemaVCurrent.self),
        ]
    }
}
