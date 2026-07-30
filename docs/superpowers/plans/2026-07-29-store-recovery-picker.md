# Store Recovery Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find the most complete store among the live store and every backup Chorus keeps, and offer to restore it, so a user who lost their spaces and services recovers without copying files in Terminal.

**Architecture:** A new nonisolated `StoreInventory` enum reads each candidate store file's contents from raw SQLite, ranks them with pure functions, and decides whether to offer a restore. The choice is written to `UserDefaults` and applied at the next launch by `StoreRepair`, before any `ModelContainer` opens, because that is the only safe point to swap SQLite files. `AppState` wires the decision to a banner button and a Settings item, both opening one sheet.

**Tech Stack:** Swift 6 language mode, SwiftUI, SwiftData, raw SQLite3 via the C API, XCTest.

## Global Constraints

- Design spec: `docs/superpowers/specs/2026-07-29-store-recovery-picker-design.md`. Read it before starting.
- Deployment target is macOS 14.0. No API newer than that.
- `AppState` is `@MainActor`; `StoreRepair` and the new `StoreInventory` are plain nonisolated enums. `ChorusTests` is `@MainActor`.
- No `@Model` stored property changes anywhere in this plan. Touching one means a new schema version, a migration stage, and a fixture (see `CLAUDE.md`); this feature needs none.
- SQLite reads open read-only and **never** with `immutable=1`: a `.bak` can have a `-wal` sibling holding committed rows that an immutable open ignores.
- A count that cannot be read is `nil`, meaning unknown. Never treat unknown as zero.
- Never delete or overwrite a user's store without first copying the current triple (`store`, `store-wal`, `store-shm`) aside.
- Tests use fixtures under `NSTemporaryDirectory()` and injected `UserDefaults(suiteName:)`. **Never** touch `~/Library/Application Support/default.store`.
- Full test run: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`
- Single test: append `-only-testing:ChorusTests/ChorusTests/<testName>`
- New `.swift` files are not in the checked-in `.pbxproj`. After creating one, run `xcodegen generate`, and keep `project.yml` and the project file consistent per `CLAUDE.md`.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `test:`, `refactor:`, `docs:`).

## File Structure

**Create:**
- `Chorus/App/StoreInventory.swift` — `StoreContent`, `StoreCandidate`, the SQLite content reader, candidate enumeration, ranking, preselection, the offer rule, and the record encode/decode. All nonisolated and pure apart from the file reads. Target under 400 lines.
- `Chorus/Utilities/AppRelauncher.swift` — one function that relaunches the app after the current process exits. Roughly 20 lines.
- `Chorus/Views/MainWindow/StoreRecoveryView.swift` — the candidate picker sheet.

**Modify:**
- `Chorus/App/StoreRepair.swift` — add `applyPendingRestore`, `copyAside`, and `validatedRestoreName`; fix `pruneSnapshots` to protect the newest snapshot that is not seed-shaped.
- `Chorus/App/AppState.swift` — share the default-seed lists, record content on open and at termination, compute the offer, expose picker state, and handle the user's choice.
- `Chorus/Views/MainWindow/ContentView.swift` — a "Review backups" button in the existing store banner.
- `Chorus/Views/Settings/SettingsView.swift` — a "Restore from a backup" item.
- `ChorusTests/ChorusTests.swift` — tests for every task below.

---

### Task 1: `StoreContent` and the default-seed fingerprint

The fingerprint has to stay in step with what the seeder actually writes, so this task makes both read one list.

**Files:**
- Create: `Chorus/App/StoreInventory.swift`
- Modify: `Chorus/App/AppState.swift:2396-2426` (the seed lists in `seedDefaultDataIfNeeded`)
- Test: `ChorusTests/ChorusTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `StoreContent(spaces:services:links:spaceNames:serviceLabels:)`, `StoreContent.isEmpty`, `StoreContent.holdsMore(than:) -> Bool`, `StoreContent.looksLikeUntouchedSeed -> Bool`, `DefaultSeed.spaces: [(name: String, emoji: String)]`, `DefaultSeed.personalServices` and `DefaultSeed.workServices` as `[(label: String, url: String, catalogID: String)]`, `DefaultSeed.allServiceLabels: [String]`.

- [ ] **Step 1: Write the failing tests**

Add to `ChorusTests/ChorusTests.swift`, inside `final class ChorusTests`:

```swift
    // MARK: - Store content and the default-seed fingerprint

    /// `holdsMore` ranks by services first, then spaces, and is false for equal
    /// content — the comparison both the ranking and the offer rule depend on.
    func testHoldsMoreRanksServicesThenSpaces() {
        let big = StoreContent(spaces: 4, services: 13, links: 13, spaceNames: [], serviceLabels: [])
        let fewerServices = StoreContent(spaces: 9, services: 12, links: 12, spaceNames: [], serviceLabels: [])
        let sameServicesFewerSpaces = StoreContent(spaces: 2, services: 13, links: 13, spaceNames: [], serviceLabels: [])

        XCTAssertTrue(big.holdsMore(than: fewerServices), "more services wins even with fewer spaces")
        XCTAssertTrue(big.holdsMore(than: sameServicesFewerSpaces), "equal services falls through to spaces")
        XCTAssertFalse(big.holdsMore(than: big), "equal content is not more")
        XCTAssertFalse(fewerServices.holdsMore(than: big))
    }

    /// The fingerprint must match the seed exactly and nothing else.
    func testUntouchedSeedFingerprint() {
        let seed = StoreContent(
            spaces: 2,
            services: 7,
            links: 7,
            spaceNames: DefaultSeed.spaces.map(\.name),
            serviceLabels: DefaultSeed.allServiceLabels
        )
        XCTAssertTrue(seed.looksLikeUntouchedSeed, "the exact seed shape must match")

        var labels = DefaultSeed.allServiceLabels
        labels.append("Notion")
        let plusOne = StoreContent(spaces: 2, services: 8, links: 8, spaceNames: DefaultSeed.spaces.map(\.name), serviceLabels: labels)
        XCTAssertFalse(plusOne.looksLikeUntouchedSeed, "one added service means the user has touched it")

        let renamed = StoreContent(spaces: 2, services: 7, links: 7, spaceNames: ["Personal", "Clients"], serviceLabels: DefaultSeed.allServiceLabels)
        XCTAssertFalse(renamed.looksLikeUntouchedSeed, "a renamed space means the user has touched it")

        let empty = StoreContent(spaces: 0, services: 0, links: 0, spaceNames: [], serviceLabels: [])
        XCTAssertFalse(empty.looksLikeUntouchedSeed, "an empty store is empty, not seeded")
        XCTAssertTrue(empty.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testHoldsMoreRanksServicesThenSpaces
```
Expected: build failure, `cannot find 'StoreContent' in scope`.

- [ ] **Step 3: Create `StoreInventory.swift` with the seed lists and `StoreContent`**

```swift
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
```

- [ ] **Step 4: Add the file to the project**

Run:
```sh
xcodegen generate
git diff --stat Chorus.xcodeproj/project.pbxproj
```
Expected: the diff shows `StoreInventory.swift` added. `project.yml` needs no edit because its `sources` entry is the whole `Chorus` directory.

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testHoldsMoreRanksServicesThenSpaces \
  -only-testing:ChorusTests/ChorusTests/testUntouchedSeedFingerprint
```
Expected: both PASS.

- [ ] **Step 6: Point the seeder at the shared lists**

In `Chorus/App/AppState.swift`, inside `seedDefaultDataIfNeeded`, replace the two hardcoded local arrays and the two `Space(...)` constructions. Replace this:

```swift
        let personalSpace = Space(name: "Personal", emoji: "🏠", sortOrder: 0)
        let workSpace = Space(name: "Work", emoji: "💼", sortOrder: 1)
```

with:

```swift
        let personalSpace = Space(name: DefaultSeed.spaces[0].name, emoji: DefaultSeed.spaces[0].emoji, sortOrder: 0)
        let workSpace = Space(name: DefaultSeed.spaces[1].name, emoji: DefaultSeed.spaces[1].emoji, sortOrder: 1)
```

Then delete the `let personalServices: [(String, String, String)] = [...]` and `let workServices: [(String, String, String)] = [...]` literals, and change the two loops to read the shared lists:

```swift
        for (index, entry) in DefaultSeed.personalServices.enumerated() {
            let service = ServiceInstance(label: entry.label, url: entry.url, catalogEntryID: entry.catalogID)
            context.insert(service)
            context.insert(SpaceServiceLink(sortOrder: index, space: personalSpace, service: service))
        }

        for (index, entry) in DefaultSeed.workServices.enumerated() {
            let service = ServiceInstance(label: entry.label, url: entry.url, catalogEntryID: entry.catalogID)
            context.insert(service)
            context.insert(SpaceServiceLink(sortOrder: index, space: workSpace, service: service))
        }
```

- [ ] **Step 7: Write the anti-drift test**

This is the guard that makes the shared list worth having: it seeds a store through the seeder's own data and asserts the fingerprint recognizes it.

```swift
    /// The fingerprint must recognize a store built from the seed lists the
    /// seeder uses. If someone edits one seed list and not the fingerprint, this
    /// goes red.
    func testSeededStoreIsFingerprintedAsSeed() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-seedprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = ModelConfiguration(schema: Self.storeSchema, url: storeURL)
        let container = try ModelContainer(for: Self.storeSchema, configurations: [config])
        let ctx = container.mainContext
        let spaces = DefaultSeed.spaces.enumerated().map { index, entry in
            Space(name: entry.name, emoji: entry.emoji, sortOrder: index)
        }
        for space in spaces { ctx.insert(space) }
        for (index, entry) in DefaultSeed.personalServices.enumerated() {
            let service = ServiceInstance(label: entry.label, url: entry.url, catalogEntryID: entry.catalogID)
            ctx.insert(service)
            ctx.insert(SpaceServiceLink(sortOrder: index, space: spaces[0], service: service))
        }
        for (index, entry) in DefaultSeed.workServices.enumerated() {
            let service = ServiceInstance(label: entry.label, url: entry.url, catalogEntryID: entry.catalogID)
            ctx.insert(service)
            ctx.insert(SpaceServiceLink(sortOrder: index, space: spaces[1], service: service))
        }
        try ctx.save()

        let content = StoreContent(
            spaces: try ctx.fetchCount(FetchDescriptor<Space>()),
            services: try ctx.fetchCount(FetchDescriptor<ServiceInstance>()),
            links: try ctx.fetchCount(FetchDescriptor<SpaceServiceLink>()),
            spaceNames: try ctx.fetch(FetchDescriptor<Space>()).map(\.name),
            serviceLabels: try ctx.fetch(FetchDescriptor<ServiceInstance>()).map(\.label)
        )
        XCTAssertTrue(content.looksLikeUntouchedSeed, "a store built from DefaultSeed must fingerprint as the seed")
    }
```

- [ ] **Step 8: Run the full suite**

Run: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`
Expected: 136 existing tests plus the 3 new ones pass. The seeder refactor is behavior-preserving, so no existing test should change.

- [ ] **Step 9: Commit**

```sh
git add Chorus/App/StoreInventory.swift Chorus/App/AppState.swift Chorus.xcodeproj/project.pbxproj ChorusTests/ChorusTests.swift
git commit -m "feat: store content value type and default-seed fingerprint

The seeder and the fingerprint now read one shared list of seeded spaces and
services, with a test that fails if they drift apart."
```

---

### Task 2: Read a store file's content from raw SQLite

**Files:**
- Modify: `Chorus/App/StoreInventory.swift`
- Test: `ChorusTests/ChorusTests.swift`

**Interfaces:**
- Consumes: `StoreContent` from Task 1.
- Produces: `StoreInventory.readContent(at: URL) -> StoreContent?` (nil means unreadable or unrecognized, never empty).

- [ ] **Step 1: Write the failing test**

```swift
    /// Reading a store file must report its real counts, count rows sitting in
    /// the WAL, and return nil (unknown) rather than zero for anything it cannot
    /// read.
    func testReadContentCountsRowsAndDistinguishesUnknown() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-readcontent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePopulatedStore(at: storeURL, spaces: 3)
        let content = try XCTUnwrap(StoreInventory.readContent(at: storeURL))
        XCTAssertEqual(content.spaces, 3)
        XCTAssertEqual(content.services, 0, "makePopulatedStore inserts spaces only")
        XCTAssertEqual(Set(content.spaceNames), ["S0", "S1", "S2"], "names come back for the fingerprint")

        // A missing file is unknown, not empty.
        XCTAssertNil(StoreInventory.readContent(at: dir.appendingPathComponent("nope.sqlite")))

        // A file that is not a database is unknown.
        let garbage = dir.appendingPathComponent("garbage.sqlite")
        try "not a database".write(to: garbage, atomically: true, encoding: .utf8)
        XCTAssertNil(StoreInventory.readContent(at: garbage))

        // A database with an unrecognized schema is unknown, never zero.
        let alien = dir.appendingPathComponent("alien.sqlite")
        _ = try Self.runSQLite(alien, "CREATE TABLE ZOTHER (x INTEGER);")
        XCTAssertNil(StoreInventory.readContent(at: alien))
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testReadContentCountsRowsAndDistinguishesUnknown
```
Expected: build failure, `type 'StoreInventory' has no member 'readContent'`.

- [ ] **Step 3: Implement the reader**

Append to `Chorus/App/StoreInventory.swift`:

```swift
/// Reads store files without opening a `ModelContainer`, so candidates can be
/// inspected and ranked before anything migrates or locks them. Read-only
/// throughout: nothing here writes to a store.
enum StoreInventory {
    private static let spaceTable = "ZSPACE"
    private static let serviceTable = "ZSERVICEINSTANCE"
    private static let linkTable = "ZSPACESERVICELINK"

    /// What the store at `url` holds, or nil when that cannot be established:
    /// no file, a file that is not a database, or a schema without the tables
    /// this app owns. Nil is "unknown" and callers must not read it as empty.
    ///
    /// Opened read-only and deliberately WITHOUT `immutable=1`: a `.bak` can sit
    /// beside a `-wal` holding committed rows, and an immutable open ignores the
    /// WAL, which would under-count a backup and could cost it the ranking.
    static func readContent(at url: URL) -> StoreContent? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        defer { sqlite3_close(db) }

        // Require this app's tables before counting; an unrecognized schema is
        // unknown, not empty.
        let known = scalarInt(db, """
            SELECT COUNT(*) FROM sqlite_master WHERE type='table'
             AND name IN ('\(spaceTable)','\(serviceTable)','\(linkTable)');
            """) ?? 0
        guard known == 3 else { return nil }

        guard let spaces = scalarInt(db, "SELECT COUNT(*) FROM \(spaceTable);"),
              let services = scalarInt(db, "SELECT COUNT(*) FROM \(serviceTable);"),
              let links = scalarInt(db, "SELECT COUNT(*) FROM \(linkTable);") else {
            return nil
        }
        return StoreContent(
            spaces: spaces,
            services: services,
            links: links,
            spaceNames: textColumn(db, "SELECT ZNAME FROM \(spaceTable);"),
            serviceLabels: textColumn(db, "SELECT ZLABEL FROM \(serviceTable);")
        )
    }

    /// Whether the store at `url` passes an integrity check. `(1)` stops at the
    /// first error, which bounds the cost when several candidates are checked at
    /// launch.
    static func passesIntegrityCheck(at url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return false
        }
        sqlite3_busy_timeout(db, 3000)
        defer { sqlite3_close(db) }
        return scalarText(db, "PRAGMA integrity_check(1);") == "ok"
    }

    // MARK: - SQLite helpers

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func scalarText(_ db: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cString)
    }

    /// Every non-null value of a single text column. Nulls are skipped rather
    /// than turned into empty strings, so a null name cannot look like a rename.
    private static func textColumn(_ db: OpaquePointer, _ sql: String) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var values: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                values.append(String(cString: cString))
            }
        }
        return values
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testReadContentCountsRowsAndDistinguishesUnknown
```
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add Chorus/App/StoreInventory.swift ChorusTests/ChorusTests.swift
git commit -m "feat: read a store file's contents without opening a container

Read-only and WAL-visible, so a backup with uncheckpointed rows is not
under-counted. Unreadable stays unknown rather than reading as empty."
```

---

### Task 3: Enumerate the candidates

**Files:**
- Modify: `Chorus/App/StoreInventory.swift`
- Test: `ChorusTests/ChorusTests.swift`

**Interfaces:**
- Consumes: `StoreInventory.readContent`, `StoreInventory.passesIntegrityCheck`, `StoreContent`, and `StoreRepair.stampAndVersion(_:prefix:)`.
- Produces: `StoreCandidate` (with `url`, `kind`, `takenAt`, `content`, `isDamaged`, `isRestorable`), `StoreCandidate.Kind` (`.live`, `.snapshot(version: String?)`, `.prerestore`, `.corrupt`), and `StoreInventory.candidates(for storeURL: URL, liveContent: StoreContent?) -> [StoreCandidate]`.

**Reuse, not duplication:** `StoreRepair` already parses these filenames in a `private static func stampAndVersion(_:prefix:)`. Do NOT write a second copy. Change that one's `private` to internal (drop the `private` keyword, leave everything else alone) and call it from `StoreInventory`. Its existing implementation already returns `(stamp, nil)` for a name with no version segment, which is exactly what `.prerestore-` and `.corrupt-` names need, so nothing has to change in its body.

- [ ] **Step 1: Write the failing test**

```swift
    /// Enumeration must find all three backup families plus the live store,
    /// parse stamps, and mark an unreadable file as unknown rather than empty.
    func testCandidateEnumerationCoversAllBackupFamilies() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Live store with 1 space; a 4-space snapshot; a 2-space prerestore; a
        // 3-space corrupt-family backup; and one unreadable snapshot.
        try makePopulatedStore(at: storeURL, spaces: 4)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.5.11+20")
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 2)
        try FileManager.default.copyItem(
            at: storeURL,
            to: dir.appendingPathComponent("store.sqlite.prerestore-1700000500.bak")
        )
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 3)
        try FileManager.default.copyItem(
            at: storeURL,
            to: dir.appendingPathComponent("store.sqlite.corrupt-1700000600.bak")
        )
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 1)
        try "not a database".write(
            to: dir.appendingPathComponent("store.sqlite.snapshot-1700000900-1.5.12+21.bak"),
            atomically: true,
            encoding: .utf8
        )

        let live = try XCTUnwrap(StoreInventory.readContent(at: storeURL))
        let found = StoreInventory.candidates(for: storeURL, liveContent: live)

        XCTAssertEqual(found.count, 5, "live + snapshot + prerestore + corrupt + unreadable snapshot")
        XCTAssertEqual(found.filter { $0.kind == .live }.count, 1)
        XCTAssertEqual(found.first { $0.kind == .live }?.content?.spaces, 1)

        let snapshot = try XCTUnwrap(found.first { $0.kind == .snapshot(version: "1.5.11+20") })
        XCTAssertEqual(snapshot.content?.spaces, 4)
        XCTAssertEqual(snapshot.takenAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(snapshot.isRestorable)

        XCTAssertEqual(found.first { $0.kind == .prerestore }?.content?.spaces, 2)
        XCTAssertEqual(found.first { $0.kind == .corrupt }?.content?.spaces, 3)

        let unreadable = try XCTUnwrap(found.first { $0.kind == .snapshot(version: "1.5.12+21") })
        XCTAssertNil(unreadable.content, "an unreadable candidate is unknown, not empty")
        XCTAssertFalse(unreadable.isRestorable, "unknown content is never restorable")
    }
```

Add this helper next to `makePopulatedStore` in the test class, since two tasks need it:

```swift
    /// Inserts `count` spaces into an existing store by raw SQL, so a fixture can
    /// be reshaped without reopening a container. `Z_PK` is assigned explicitly
    /// because Core Data's `Z_PRIMARYKEY` bookkeeping is not maintained here;
    /// these fixtures are only ever read back by raw SQLite.
    private static func insertSpaces(_ url: URL, count: Int) throws {
        let entity = try runSQLite(url, "SELECT Z_ENT FROM ZSPACE LIMIT 1;")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ent = entity.isEmpty ? "1" : entity
        for i in 0..<count {
            _ = try runSQLite(url, """
                INSERT INTO ZSPACE (Z_PK, Z_ENT, Z_OPT, ZNAME, ZEMOJI, ZSORTORDER)
                VALUES (\(1000 + i), \(ent), 1, 'S\(i)', '🏠', \(i));
                """)
        }
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testCandidateEnumerationCoversAllBackupFamilies
```
Expected: build failure, no member `candidates`.

- [ ] **Step 3: Implement `StoreCandidate` and enumeration**

Append to `Chorus/App/StoreInventory.swift`:

```swift
/// One store the user could be running on: the live file, or a backup Chorus
/// kept. `content` is nil when the file could not be read. `Hashable` so the
/// picker's `List` can bind its selection to a candidate directly.
struct StoreCandidate: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        /// The store the app is running on now.
        case live
        /// A pre-update snapshot. Version is the build it preceded, when the
        /// filename parses.
        case snapshot(version: String?)
        /// The store set aside by an earlier restore.
        case prerestore
        /// The store set aside before dangling-link repair. Damaged by
        /// definition, so never preselected.
        case corrupt
    }

    let url: URL
    let kind: Kind
    let takenAt: Date?
    let content: StoreContent?
    let isDamaged: Bool

    var id: String { url.path }

    /// Whether this can be restored from: a backup (not the live store) whose
    /// content is known and whose file is intact.
    var isRestorable: Bool {
        kind != .live && content != nil && !isDamaged
    }
}

extension StoreInventory {
    /// Filename infixes of the three backup families, all of which are copies of
    /// the user's own store and so all worth offering.
    private static let backupInfixes = [".snapshot-", ".prerestore-", ".corrupt-"]

    /// Every candidate for `storeURL`: the live store (whose content the caller
    /// supplies, since it is already open) plus each backup sibling. Unreadable
    /// and damaged files are included so the user can see they exist; the
    /// ranking excludes them.
    static func candidates(for storeURL: URL, liveContent: StoreContent?) -> [StoreCandidate] {
        var result: [StoreCandidate] = [
            StoreCandidate(
                url: storeURL,
                kind: .live,
                takenAt: (try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.modificationDate]) as? Date,
                content: liveContent,
                isDamaged: false
            )
        ]

        let dir = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return result
        }

        for name in names.sorted() where name.hasSuffix(".bak") {
            guard let infix = backupInfixes.first(where: { name.hasPrefix(base + $0) }) else { continue }
            let url = dir.appending(path: name)
            // Shared with StoreRepair rather than reimplemented; see the task's
            // "Reuse, not duplication" note.
            let parsed = StoreRepair.stampAndVersion(name, prefix: base + infix)
            let kind: StoreCandidate.Kind
            switch infix {
            case ".snapshot-": kind = .snapshot(version: parsed.version)
            case ".prerestore-": kind = .prerestore
            default: kind = .corrupt
            }
            let content = readContent(at: url)
            result.append(StoreCandidate(
                url: url,
                kind: kind,
                takenAt: parsed.stamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                content: content,
                // Only pay for an integrity check on a file we could read at all.
                isDamaged: content == nil || !passesIntegrityCheck(at: url)
            ))
        }
        return result
    }

}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testCandidateEnumerationCoversAllBackupFamilies
```
Expected: PASS. If the `.corrupt-` candidate reports `isDamaged == true` unexpectedly, check that `insertSpaces` produced a valid database (`sqlite3 <file> "PRAGMA integrity_check;"` prints `ok`).

- [ ] **Step 5: Commit**

```sh
git add Chorus/App/StoreInventory.swift ChorusTests/ChorusTests.swift
git commit -m "feat: enumerate live store and all three backup families as candidates"
```

---

### Task 4: Rank the candidates and decide what to preselect

**Files:**
- Modify: `Chorus/App/StoreInventory.swift`
- Test: `ChorusTests/ChorusTests.swift`

**Interfaces:**
- Consumes: `StoreCandidate`, `StoreContent.holdsMore(than:)`, `StoreContent.looksLikeUntouchedSeed`.
- Produces: `StoreInventory.best(among: [StoreCandidate]) -> StoreCandidate?`, `StoreInventory.preselection(among: [StoreCandidate], liveContent: StoreContent?) -> StoreCandidate?`.

- [ ] **Step 1: Write the failing tests**

```swift
    /// Ranking takes the fullest restorable backup, breaks ties on recency, and
    /// ignores the live store, damaged files, and unreadable files.
    func testBestCandidateRanksContentThenRecency() {
        let dir = URL(fileURLWithPath: "/tmp/ranking")
        func candidate(
            _ name: String,
            _ kind: StoreCandidate.Kind,
            spaces: Int,
            services: Int,
            at stamp: TimeInterval,
            damaged: Bool = false,
            unknown: Bool = false
        ) -> StoreCandidate {
            StoreCandidate(
                url: dir.appendingPathComponent(name),
                kind: kind,
                takenAt: Date(timeIntervalSince1970: stamp),
                content: unknown ? nil : StoreContent(spaces: spaces, services: services, links: services, spaceNames: [], serviceLabels: []),
                isDamaged: damaged
            )
        }

        let fullOld = candidate("a", .snapshot(version: "1.5.11+20"), spaces: 4, services: 13, at: 1_000)
        let thinNew = candidate("b", .snapshot(version: "1.5.14+23"), spaces: 2, services: 7, at: 9_000)
        let fullNewer = candidate("c", .prerestore, spaces: 4, services: 13, at: 5_000)
        let live = candidate("live", .live, spaces: 9, services: 99, at: 9_999)
        let damaged = candidate("d", .snapshot(version: nil), spaces: 8, services: 40, at: 9_500, damaged: true)
        let unknown = candidate("e", .snapshot(version: nil), spaces: 0, services: 0, at: 9_600, unknown: true)

        let best = StoreInventory.best(among: [fullOld, thinNew, fullNewer, live, damaged, unknown])
        XCTAssertEqual(best, fullNewer, "equal content must break the tie on recency, and live/damaged/unknown are excluded")

        XCTAssertEqual(
            StoreInventory.best(among: [thinNew, fullOld]),
            fullOld,
            "more content beats more recent"
        )
        XCTAssertNil(StoreInventory.best(among: [live, damaged, unknown]), "nothing restorable means no winner")
    }

    /// Preselection is narrower than ranking: it only fires when the live store
    /// holds nothing of the user's, and never picks a corrupt-family backup.
    func testPreselectionOnlyWhenLiveStoreHoldsNothingOfTheUsers() {
        let dir = URL(fileURLWithPath: "/tmp/preselect")
        let backup = StoreCandidate(
            url: dir.appendingPathComponent("s.bak"),
            kind: .snapshot(version: "1.5.11+20"),
            takenAt: Date(timeIntervalSince1970: 1_000),
            content: StoreContent(spaces: 4, services: 13, links: 13, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )
        let corruptBackup = StoreCandidate(
            url: dir.appendingPathComponent("c.bak"),
            kind: .corrupt,
            takenAt: Date(timeIntervalSince1970: 2_000),
            content: StoreContent(spaces: 9, services: 40, links: 40, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )
        let empty = StoreContent(spaces: 0, services: 0, links: 0, spaceNames: [], serviceLabels: [])
        let seeded = StoreContent(
            spaces: 2, services: 7, links: 7,
            spaceNames: DefaultSeed.spaces.map(\.name),
            serviceLabels: DefaultSeed.allServiceLabels
        )
        let usersOwn = StoreContent(spaces: 3, services: 10, links: 10, spaceNames: ["Home", "Work", "Side"], serviceLabels: [])

        XCTAssertEqual(StoreInventory.preselection(among: [backup], liveContent: empty), backup, "empty live store: preselect")
        XCTAssertEqual(StoreInventory.preselection(among: [backup], liveContent: seeded), backup, "seeded live store: preselect")
        XCTAssertEqual(StoreInventory.preselection(among: [backup], liveContent: nil), backup, "unreadable live store: preselect")
        XCTAssertNil(
            StoreInventory.preselection(among: [backup], liveContent: usersOwn),
            "the user's own data must never be silently preselected over"
        )
        XCTAssertNil(
            StoreInventory.preselection(among: [corruptBackup], liveContent: empty),
            "a corrupt-family backup is never preselected"
        )
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testBestCandidateRanksContentThenRecency
```
Expected: build failure, no member `best`.

- [ ] **Step 3: Implement ranking and preselection**

Append to `Chorus/App/StoreInventory.swift`:

```swift
extension StoreInventory {
    /// The fullest restorable candidate: most services, then most spaces, then
    /// most links, then the most recent. Excludes the live store, damaged files,
    /// and files whose content is unknown.
    static func best(among candidates: [StoreCandidate]) -> StoreCandidate? {
        candidates
            .filter(\.isRestorable)
            .max { lhs, rhs in
                guard let l = lhs.content, let r = rhs.content else { return false }
                if l.services != r.services { return l.services < r.services }
                if l.spaces != r.spaces { return l.spaces < r.spaces }
                if l.links != r.links { return l.links < r.links }
                return (lhs.takenAt ?? .distantPast) < (rhs.takenAt ?? .distantPast)
            }
    }

    /// The candidate to preselect in the picker, or nil to make the user choose.
    ///
    /// Deliberately narrower than `best`. Preselecting is only safe when the live
    /// store holds nothing of the user's: empty, unreadable, or the untouched
    /// seed. When they still have their own spaces, restoring a fuller but older
    /// backup would discard everything they did since, and only they can weigh
    /// that. A `.corrupt` backup is never preselected because that store was
    /// damaged when it was set aside.
    static func preselection(among candidates: [StoreCandidate], liveContent: StoreContent?) -> StoreCandidate? {
        let liveHoldsUsersData = liveContent.map { !$0.isEmpty && !$0.looksLikeUntouchedSeed } ?? false
        guard !liveHoldsUsersData else { return nil }
        guard let winner = best(among: candidates), winner.kind != .corrupt else { return nil }
        // Nothing to gain from a backup that holds no more than what is there.
        if let live = liveContent, let content = winner.content, !content.holdsMore(than: live) { return nil }
        return winner
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testBestCandidateRanksContentThenRecency \
  -only-testing:ChorusTests/ChorusTests/testPreselectionOnlyWhenLiveStoreHoldsNothingOfTheUsers
```
Expected: both PASS.

- [ ] **Step 5: Commit**

```sh
git add Chorus/App/StoreInventory.swift ChorusTests/ChorusTests.swift
git commit -m "feat: rank store candidates and restrict what gets preselected

Ranking takes the fullest backup with recency as the tiebreak. Preselection
only fires when the live store holds nothing of the user's, so a fuller but
older backup is never silently chosen over their current work."
```

---

### Task 5: The offer rule, the content record, and remembered declines

**Files:**
- Modify: `Chorus/App/StoreInventory.swift`
- Test: `ChorusTests/ChorusTests.swift`

**Interfaces:**
- Consumes: `StoreContent`, `StoreCandidate`.
- Produces: `StoreRecoveryOffer` (`.belowRecord`, `.nothingToLose`), `StoreInventory.offer(liveContent:best:record:declinedKeys:) -> StoreRecoveryOffer?`, `StoreInventory.declineKey(live:candidate:) -> String`, `StoreInventory.encodeRecord(_:) -> String`, `StoreInventory.decodeRecord(_:) -> StoreContent?`.

- [ ] **Step 1: Write the failing tests**

```swift
    /// The offer rule: two triggers, and the case that must stay silent.
    func testOfferRuleTriggersAndSilence() {
        let dir = URL(fileURLWithPath: "/tmp/offer")
        let backup = StoreCandidate(
            url: dir.appendingPathComponent("s.bak"),
            kind: .snapshot(version: "1.5.11+20"),
            takenAt: Date(timeIntervalSince1970: 1_000),
            content: StoreContent(spaces: 4, services: 13, links: 13, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )
        let seeded = StoreContent(
            spaces: 2, services: 7, links: 7,
            spaceNames: DefaultSeed.spaces.map(\.name),
            serviceLabels: DefaultSeed.allServiceLabels
        )
        let partial = StoreContent(spaces: 1, services: 4, links: 4, spaceNames: ["Home"], serviceLabels: [])
        let record = StoreContent(spaces: 4, services: 13, links: 13, spaceNames: [], serviceLabels: [])

        // Trigger 1: below the record, with a backup that covers the gap.
        XCTAssertEqual(
            StoreInventory.offer(liveContent: partial, best: backup, record: record, declinedKeys: []),
            .belowRecord
        )

        // Trigger 2: no record yet, and the live store is the untouched seed.
        // This is the already-lost user's first launch on a build that records.
        XCTAssertEqual(
            StoreInventory.offer(liveContent: seeded, best: backup, record: nil, declinedKeys: []),
            .nothingToLose
        )

        // The case that must stay silent: the user deleted spaces on purpose, so
        // the record matches what is there, and their store is their own.
        XCTAssertNil(
            StoreInventory.offer(liveContent: partial, best: backup, record: partial, declinedKeys: []),
            "a store matching its record is not loss, even with a fuller backup"
        )

        // No backup that holds more means nothing to offer.
        let thin = StoreCandidate(
            url: dir.appendingPathComponent("t.bak"),
            kind: .snapshot(version: nil),
            takenAt: nil,
            content: StoreContent(spaces: 1, services: 2, links: 2, spaceNames: [], serviceLabels: []),
            isDamaged: false
        )
        XCTAssertNil(StoreInventory.offer(liveContent: partial, best: thin, record: record, declinedKeys: []))
        XCTAssertNil(StoreInventory.offer(liveContent: partial, best: nil, record: record, declinedKeys: []))

        // A remembered decline silences the same pairing.
        let key = StoreInventory.declineKey(live: partial, candidate: backup)
        XCTAssertNil(
            StoreInventory.offer(liveContent: partial, best: backup, record: record, declinedKeys: [key]),
            "a declined pairing must not ask again"
        )
        // A different live state is a different pairing, so it may ask again.
        XCTAssertNotNil(
            StoreInventory.offer(liveContent: seeded, best: backup, record: record, declinedKeys: [key])
        )
    }

    /// The record round-trips through the string form kept in UserDefaults.
    func testContentRecordRoundTrip() throws {
        let content = StoreContent(spaces: 4, services: 13, links: 13, spaceNames: [], serviceLabels: [])
        let encoded = StoreInventory.encodeRecord(content)
        let decoded = try XCTUnwrap(StoreInventory.decodeRecord(encoded))
        XCTAssertEqual(decoded.spaces, 4)
        XCTAssertEqual(decoded.services, 13)
        XCTAssertEqual(decoded.links, 13)

        XCTAssertNil(StoreInventory.decodeRecord("garbage"), "an unparseable record is no record")
        XCTAssertNil(StoreInventory.decodeRecord("4-13"), "a short record is no record")
        XCTAssertNil(StoreInventory.decodeRecord(""))
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testOfferRuleTriggersAndSilence
```
Expected: build failure, cannot find `StoreRecoveryOffer`.

- [ ] **Step 3: Implement the rule, the record, and the decline key**

Append to `Chorus/App/StoreInventory.swift`:

```swift
/// Why Chorus is offering to restore.
enum StoreRecoveryOffer: Equatable, Sendable {
    /// The live store holds less than Chorus recorded for it: some of the
    /// user's data went missing between launches.
    case belowRecord
    /// There is no record to compare against and the live store holds nothing
    /// of the user's, so there is nothing to weigh against restoring.
    case nothingToLose
}

extension StoreInventory {
    /// Whether to offer a restore, and why.
    ///
    /// Two conditions always hold: a backup exists holding more than the live
    /// store, and the user has not already declined this same pairing. Then one
    /// of two triggers fires.
    ///
    /// Trigger 2 is not redundant. Someone who lost their spaces on 1.5.14 or
    /// earlier has no record on their first launch of a build that writes one,
    /// and their store holds the seed, so trigger 1 can never fire for them.
    /// Without trigger 2 this feature would miss the user who reported the bug.
    static func offer(
        liveContent: StoreContent?,
        best: StoreCandidate?,
        record: StoreContent?,
        declinedKeys: Set<String>
    ) -> StoreRecoveryOffer? {
        guard let best, let backup = best.content, best.isRestorable else { return nil }
        // A backup has to actually cover the gap. An unreadable live store
        // counts as covered: anything readable beats nothing.
        if let live = liveContent, !backup.holdsMore(than: live) { return nil }
        if declinedKeys.contains(declineKey(live: liveContent, candidate: best)) { return nil }

        if let record, let live = liveContent, record.holdsMore(than: live) { return .belowRecord }
        if let record, liveContent == nil, !record.isEmpty { return .belowRecord }

        let liveHoldsUsersData = liveContent.map { !$0.isEmpty && !$0.looksLikeUntouchedSeed } ?? false
        if !liveHoldsUsersData { return .nothingToLose }
        return nil
    }

    /// Identifies one pairing of backup and live state, so declining is
    /// remembered for that pairing only. When either side changes, Chorus may
    /// ask again, which is what makes a stale decline self-correcting.
    static func declineKey(live: StoreContent?, candidate: StoreCandidate) -> String {
        let liveSignature = live.map { "\($0.spaces)-\($0.services)-\($0.links)" } ?? "unknown"
        return "\(candidate.url.lastPathComponent)|\(liveSignature)"
    }

    /// The record's string form, kept readable so `defaults read` shows
    /// something meaningful during support.
    static func encodeRecord(_ content: StoreContent) -> String {
        "\(content.spaces)-\(content.services)-\(content.links)"
    }

    /// Parses `encodeRecord`'s output. Anything else is treated as no record,
    /// never as an empty store.
    static func decodeRecord(_ raw: String?) -> StoreContent? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "-").map(String.init)
        guard parts.count == 3,
              let spaces = Int(parts[0]),
              let services = Int(parts[1]),
              let links = Int(parts[2]) else { return nil }
        return StoreContent(spaces: spaces, services: services, links: links, spaceNames: [], serviceLabels: [])
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testOfferRuleTriggersAndSilence \
  -only-testing:ChorusTests/ChorusTests/testContentRecordRoundTrip
```
Expected: both PASS.

- [ ] **Step 5: Commit**

```sh
git add Chorus/App/StoreInventory.swift ChorusTests/ChorusTests.swift
git commit -m "feat: decide when to offer a store restore

Offers below a recorded content count, or when there is no record and the live
store holds nothing of the user's. Stays silent for a store that matches its
record, so deliberate deletions are never second-guessed."
```

---

### Task 6: Apply a chosen restore at the next launch

**Files:**
- Modify: `Chorus/App/StoreRepair.swift`
- Test: `ChorusTests/ChorusTests.swift`

**Interfaces:**
- Consumes: `StoreInventory.readContent` (to verify the result).
- Produces: `StoreRepair.pendingRestoreKey: String`, `StoreRepair.validatedRestoreName(_:storeName:) -> String?`, `StoreRepair.applyPendingRestore(at:defaults:) -> Bool`.

- [ ] **Step 1: Write the failing tests**

```swift
    /// The pending filename comes from UserDefaults, which is external input, so
    /// it must be validated before any file operation uses it.
    func testValidatedRestoreNameRejectsAnythingUnexpected() {
        let store = "default.store"
        XCTAssertEqual(
            StoreRepair.validatedRestoreName("default.store.snapshot-1700000000-1.5.11+20.bak", storeName: store),
            "default.store.snapshot-1700000000-1.5.11+20.bak"
        )
        XCTAssertEqual(
            StoreRepair.validatedRestoreName("default.store.prerestore-1700000000.bak", storeName: store),
            "default.store.prerestore-1700000000.bak"
        )
        XCTAssertNil(StoreRepair.validatedRestoreName("../../etc/passwd", storeName: store), "no traversal")
        XCTAssertNil(StoreRepair.validatedRestoreName("/tmp/default.store.snapshot-1.bak", storeName: store), "no absolute paths")
        XCTAssertNil(StoreRepair.validatedRestoreName("default.store.snapshot-1/../x.bak", storeName: store), "no separators")
        XCTAssertNil(StoreRepair.validatedRestoreName("default.store", storeName: store), "the live store is not a backup")
        XCTAssertNil(StoreRepair.validatedRestoreName("other.store.snapshot-1.bak", storeName: store), "must belong to this store")
        XCTAssertNil(StoreRepair.validatedRestoreName("default.store.snapshot-1.txt", storeName: store), "must be a .bak")
        XCTAssertNil(StoreRepair.validatedRestoreName("", storeName: store))
    }

    /// Applying a pending restore must copy the chosen backup into place, always
    /// set the current store aside first, and clear the key so a crash cannot
    /// leave it looping.
    func testApplyPendingRestoreCopiesAndAlwaysBacksUp() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "chorus-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try makePopulatedStore(at: storeURL, spaces: 4)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.0.0")
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSpaces(storeURL, count: 1)
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 1, "precondition: live store thinned out")

        defaults.set("store.sqlite.snapshot-1700000000-1.0.0.bak", forKey: StoreRepair.pendingRestoreKey)
        XCTAssertTrue(StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults))

        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 4, "the chosen backup must be in place")
        XCTAssertNil(defaults.string(forKey: StoreRepair.pendingRestoreKey), "the key must be cleared")

        let asideCount = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("store.sqlite.prerestore-") && $0.hasSuffix(".bak") }
            .count
        XCTAssertEqual(asideCount, 1, "the thinned store must have been set aside")

        // A second apply with no key set is a no-op.
        XCTAssertFalse(StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults))

        // A rejected filename must clear the key and change nothing.
        defaults.set("../escape.bak", forKey: StoreRepair.pendingRestoreKey)
        XCTAssertFalse(StoreRepair.applyPendingRestore(at: storeURL, defaults: defaults))
        XCTAssertNil(defaults.string(forKey: StoreRepair.pendingRestoreKey))
        XCTAssertEqual(StoreRepair.spaceCount(at: storeURL), 4, "a rejected name must not touch the store")
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testValidatedRestoreNameRejectsAnythingUnexpected
```
Expected: build failure, no member `validatedRestoreName`.

- [ ] **Step 3: Implement it**

Add to `Chorus/App/StoreRepair.swift`, before the `// MARK: - Helpers` section:

```swift
    // MARK: - User-chosen restore

    /// Where the user's pick waits for the next launch. The restore itself runs
    /// before the container opens, because swapping SQLite files under a live
    /// container faults deleted models and traps.
    static let pendingRestoreKey = "chorus.pendingRestore"

    /// Validates a pending restore filename. The value comes from UserDefaults,
    /// which is outside the app's control, so it is treated as untrusted: it must
    /// be a plain filename (no separators, no traversal) belonging to this store
    /// and naming one of the three backup families.
    static func validatedRestoreName(_ name: String, storeName: String) -> String? {
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains(".."),
              name.hasSuffix(".bak") else { return nil }
        let families = [snapshotInfix, ".prerestore-", ".corrupt-"]
        guard families.contains(where: { name.hasPrefix(storeName + $0) }) else { return nil }
        return name
    }

    /// Puts the user's chosen backup in place, if one is waiting. Returns whether
    /// a restore actually happened.
    ///
    /// The key is cleared before any file work, so a crash part-way through
    /// cannot make the next launch retry forever. The current store is always
    /// copied aside first, with a fresh stamp every time: unlike
    /// `restoreFromSnapshot`, which keeps one copy for an automatic retry loop,
    /// each deliberate restore is a separate decision and deserves its own way
    /// back. If the result cannot be read, the copy is put back.
    @discardableResult
    static func applyPendingRestore(
        at storeURL: URL,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let raw = defaults.string(forKey: pendingRestoreKey) else { return false }
        defaults.removeObject(forKey: pendingRestoreKey)

        guard let name = validatedRestoreName(raw, storeName: storeURL.lastPathComponent) else {
            AppLogger.dataStore.error("Pending restore name rejected; ignoring it")
            return false
        }
        let dir = storeURL.deletingLastPathComponent()
        let source = dir.appending(path: name)
        guard FileManager.default.fileExists(atPath: source.path) else {
            AppLogger.dataStore.error("Pending restore source is gone; ignoring it")
            return false
        }

        let stamp = String(Int(Date().timeIntervalSince1970))
        let asidePrefix = storeURL.path + ".prerestore-\(stamp).bak"
        copyTriple(from: storeURL.path, to: asidePrefix)

        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            let src = URL(fileURLWithPath: source.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.copyItem(at: src, to: URL(fileURLWithPath: storeURL.path + suffix))
            } catch {
                AppLogger.dataStore.error("Restore copy of \(src.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }

        guard StoreInventory.readContent(at: storeURL) != nil else {
            AppLogger.dataStore.error("Chosen restore left an unreadable store; putting the previous one back")
            copyTriple(from: asidePrefix, to: storeURL.path)
            return false
        }
        AppLogger.dataStore.info("Restored the store the user chose: \(name)")
        return true
    }

    /// Copies a store triple, overwriting the destination. Used for both setting
    /// the current store aside and putting it back.
    private static func copyTriple(from sourcePath: String, to destinationPath: String) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: sourcePath + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: destinationPath + suffix)
            try? fm.removeItem(at: dst)
            do { try fm.copyItem(at: src, to: dst) } catch {
                AppLogger.dataStore.error("Copy of \(src.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testValidatedRestoreNameRejectsAnythingUnexpected \
  -only-testing:ChorusTests/ChorusTests/testApplyPendingRestoreCopiesAndAlwaysBacksUp
```
Expected: both PASS.

- [ ] **Step 5: Commit**

```sh
git add Chorus/App/StoreRepair.swift ChorusTests/ChorusTests.swift
git commit -m "feat: apply a user-chosen store restore at launch

Validates the pending filename as untrusted input, always sets the current
store aside first, clears the key before acting so a crash cannot loop, and
puts the previous store back if the result cannot be read."
```

---

### Task 7: Stop pruning protecting a seeded snapshot

**Files:**
- Modify: `Chorus/App/StoreRepair.swift:316-346` (`pruneSnapshots`), `Chorus/App/StoreRepair.swift:145-159` (`snapshotHasUsableData`)
- Test: `ChorusTests/ChorusTests.swift`

**Interfaces:**
- Consumes: `StoreInventory.readContent`, `StoreContent.looksLikeUntouchedSeed`.
- Produces: `StoreRepair.snapshotHoldsUsersData(at: URL) -> Bool`, `StoreRepair.prunePickAsides(at: URL, keeping: Int)`.

**Amendment (2026-07-29, Task 6 review):** Task 6's review found that the user-chosen
restore's way-back copy was written under the `.prerestore-` prefix, which
`restoreFromSnapshot` reads as a sentinel for "an aside already exists, skip taking
one". The ruling moved the deliberate restore's aside to its own `.prepick-` family.
That family has no reaper — `pruneSnapshots` matches `snapshotInfix` only, and it runs
only inside `backupBeforeMigrationIfNeeded`, once per version bump — so one full store
triple accumulates per user-chosen restore, forever. Bounding it is this task's job,
added as Step 4b below.

- [ ] **Step 1: Write the failing test**

```swift
    /// Pruning must protect the newest snapshot holding the user's own data, not
    /// the newest one that merely has rows. A snapshot taken after the loss holds
    /// the default seed, and treating that as worth keeping let the real backup
    /// age out of the keep-3 window and be deleted.
    func testPruneProtectsTheUsersDataNotASeededSnapshot() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-prune-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Oldest snapshot: the user's own 5 spaces.
        try makePopulatedStore(at: storeURL, spaces: 5)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.5.11+20")

        // Then four newer snapshots of a seed-shaped store, as four updates
        // after the loss would produce.
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")
        try Self.insertSeedShape(storeURL)
        for (i, version) in ["1.5.12+21", "1.5.13+22", "1.5.14+23", "1.5.15+24"].enumerated() {
            StoreRepair.snapshot(at: storeURL, stamp: "17000005\(i)0-\(version)")
        }

        StoreRepair.pruneSnapshots(at: storeURL, keeping: 3)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("store.sqlite.snapshot-") && $0.hasSuffix(".bak") }
        XCTAssertTrue(
            remaining.contains { $0.contains("1.5.11+20") },
            "the only snapshot holding the user's data must survive pruning, got \(remaining)"
        )
    }
```

Add this fixture helper beside `insertSpaces`:

```swift
    /// Writes the untouched default seed shape into an existing store by raw SQL:
    /// the two seeded space names and the seven seeded service labels.
    private static func insertSeedShape(_ url: URL) throws {
        let spaceEnt = try runSQLite(url, "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'Space';")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceEnt = try runSQLite(url, "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ServiceInstance';")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for (i, entry) in DefaultSeed.spaces.enumerated() {
            _ = try runSQLite(url, """
                INSERT INTO ZSPACE (Z_PK, Z_ENT, Z_OPT, ZNAME, ZEMOJI, ZSORTORDER)
                VALUES (\(2000 + i), \(spaceEnt.isEmpty ? "1" : spaceEnt), 1, '\(entry.name)', '\(entry.emoji)', \(i));
                """)
        }
        for (i, label) in DefaultSeed.allServiceLabels.enumerated() {
            _ = try runSQLite(url, """
                INSERT INTO ZSERVICEINSTANCE (Z_PK, Z_ENT, Z_OPT, ZLABEL, ZURL)
                VALUES (\(3000 + i), \(serviceEnt.isEmpty ? "2" : serviceEnt), 1, '\(label)', 'https://example.com');
                """)
        }
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testPruneProtectsTheUsersDataNotASeededSnapshot
```
Expected: FAIL with "the only snapshot holding the user's data must survive pruning" — the 1.5.11 snapshot is deleted, because the seeded 1.5.15 snapshot satisfies today's `snapshotHasUsableData`.

- [ ] **Step 3: Add the stricter test and use it when pruning**

In `Chorus/App/StoreRepair.swift`, add after `snapshotHasUsableData`:

```swift
    /// Whether the snapshot at `url` holds data that is actually the user's, as
    /// opposed to the default seed a post-loss snapshot captures.
    ///
    /// `snapshotHasUsableData` answers "can this be opened and does it have a
    /// space", which is the right question for an automatic restore. It is the
    /// wrong question for pruning: the seed has two spaces, so a snapshot taken
    /// after the loss passes it, and protecting that one let the user's real
    /// backup age past `keep` and be deleted.
    static func snapshotHoldsUsersData(at url: URL) -> Bool {
        guard let content = StoreInventory.readContent(at: url), !content.isEmpty,
              !content.looksLikeUntouchedSeed else { return false }
        return snapshotHasUsableData(at: url)
    }
```

Then in `pruneSnapshots`, change the retention clause. Replace:

```swift
        var retain = Set(primaries.prefix(keep))
        if let newestGood = primaries.first(where: { snapshotHasUsableData(at: dir.appending(path: $0)) }) {
            retain.insert(newestGood)
        }
```

with:

```swift
        var retain = Set(primaries.prefix(keep))
        // Protect the newest snapshot holding the USER's data, not merely the
        // newest with rows: a snapshot taken after a loss holds the default
        // seed, and protecting that one would let the real backup age out.
        if let newestUsers = primaries.first(where: { snapshotHoldsUsersData(at: dir.appending(path: $0)) }) {
            retain.insert(newestUsers)
        }
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testPruneProtectsTheUsersDataNotASeededSnapshot
```
Expected: PASS.

- [ ] **Step 4b: Bound the `.prepick-` family (plan amendment — see the note above)**

Task 6 gave the user-chosen restore its own aside family. Nothing reaps it. Write this test first:

```swift
    /// Each user-chosen restore writes a full store triple aside under
    /// `.prepick-`, and no existing reaper matches that family, so without this
    /// the directory grows by one copy of the whole store per restore, forever.
    func testPrunePickAsidesKeepsOnlyTheNewestFew() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-prune-pick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makePopulatedStore(at: storeURL, spaces: 2)

        // Five asides, oldest first. Pruning is filename bookkeeping — it never
        // reads a candidate's contents — so stand-in bytes are the honest
        // fixture here, and they keep the test fast.
        let stamps = ["1700000010", "1700000020", "1700000030", "1700000040", "1700000050"]
        for stamp in stamps {
            for suffix in ["", "-wal", "-shm"] {
                let path = storeURL.path + ".prepick-\(stamp).bak" + suffix
                try Data("aside \(stamp)\(suffix)".utf8).write(to: URL(fileURLWithPath: path))
            }
        }

        StoreRepair.prunePickAsides(at: storeURL, keeping: 3)

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let primaries = left.filter { $0.hasPrefix("store.sqlite.prepick-") && $0.hasSuffix(".bak") }.sorted()
        XCTAssertEqual(
            primaries,
            ["store.sqlite.prepick-1700000030.bak",
             "store.sqlite.prepick-1700000040.bak",
             "store.sqlite.prepick-1700000050.bak"],
            "the three newest asides must survive, got \(primaries)"
        )
        for stamp in ["1700000010", "1700000020"] {
            for suffix in ["", "-wal", "-shm"] {
                XCTAssertFalse(
                    left.contains("store.sqlite.prepick-\(stamp).bak" + suffix),
                    "a pruned aside must take its whole triple with it, \(stamp)\(suffix) survived"
                )
            }
        }
        XCTAssertTrue(left.contains("store.sqlite"), "pruning must never touch the live store")
    }
```

Run it; expect a build failure (no member `prunePickAsides`). Then implement.

If Task 6's fix left `".prepick-"` as a bare literal, introduce `static let pickAsideInfix = ".prepick-"` beside `snapshotInfix` and replace every literal with it — including the one in `validatedRestoreName`'s `families` and, if it reads well there, `StoreInventory.backupInfixes`. The stamp ordering already exists inline in `pruneSnapshots`; extract it rather than writing a second copy:

```swift
    /// Backup primaries for one family, newest first by numeric stamp. A plain
    /// lexical sort would misorder a differently-formatted stamp.
    private static func primariesNewestFirst(in dir: URL, prefix: String) -> [String] {
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return all
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }
            .sorted { stampValue($0, prefix: prefix) > stampValue($1, prefix: prefix) }
    }
```

Match `pruneSnapshots`' existing stamp-parsing exactly — reuse whatever it already does to turn a filename into a sortable number rather than inventing a second parser, and rewrite `pruneSnapshots` to call this helper so there is one ordering in the file, not two.

```swift
    /// The user-chosen restore's way-back copies. Each deliberate restore writes one
    /// full triple, and no other reaper matches the family, so keep the newest few
    /// and delete the rest.
    ///
    /// Recency alone is the right rule here, unlike `pruneSnapshots`: every aside is
    /// by definition the store as it stood immediately before a restore the user
    /// asked for, so there is no seed-shaped impostor to screen out.
    static func prunePickAsides(at url: URL, keeping keep: Int) {
        let dir = url.deletingLastPathComponent()
        let primaries = primariesNewestFirst(in: dir, prefix: url.lastPathComponent + pickAsideInfix)
        for name in primaries.dropFirst(keep) {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: dir.appending(path: name + suffix))
            }
        }
    }
```

Call it once at the end of `applyPendingRestore`, on **both** the success and the revert path — anywhere an aside was written — with `keeping: 3`, matching the snapshot keep count.

Do **not** delete the aside outright on the revert path, even though it is then a copy of a store that was put back unchanged and looks redundant. If the revert itself only partly succeeded, that aside is the only intact copy left. Let `keeping: 3` bound it instead. Say so in a comment so a later reader does not "tidy" it away.

- [ ] **Step 5: Run the whole suite**

Run: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`
Expected: all pass, including the existing prune test. If an existing prune test asserted the old behavior, update it to the new rule and say so in the commit body.

- [ ] **Step 6: Commit**

```sh
git add Chorus/App/StoreRepair.swift ChorusTests/ChorusTests.swift
git commit -m "fix: pruning kept a seeded snapshot over the user's real backup

snapshotHasUsableData only asks whether a store has a space, and the default
seed has two, so a snapshot taken after a loss counted as worth protecting
while the backup holding the user's data aged past the keep window."
```

Commit Step 4b separately, so the seed-prune fix and the new family's reaper stay legible apart:

```sh
git add Chorus/App/StoreRepair.swift ChorusTests/ChorusTests.swift
git commit -m "fix: bound the user-chosen restore's way-back copies

Each deliberate restore sets the whole store triple aside under .prepick- and
no existing reaper matched that family, so the copies accumulated without
limit. Keeps the newest three, by the same stamp ordering the snapshots use."
```

---

### Task 8: Wire it into `AppState`

**Files:**
- Modify: `Chorus/App/AppState.swift` (properties near `:240-252`, `init` at `:254-388`, and a new section beside the recovery code around `:1400-1545`)
- Test: `ChorusTests/ChorusTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1 to 6.
- Produces: `AppState.contentRecordKey`, `AppState.declinedRestoresKey`, `AppState.storeRecoveryOffer: StoreRecoveryOffer?`, `AppState.storeCandidates: [StoreCandidate]`, `AppState.preselectedCandidate: StoreCandidate?`, `AppState.isShowingStoreRecovery: Bool`, `AppState.recordStoreContent()`, `AppState.evaluateStoreRecovery()`, `AppState.declineStoreRecovery()`, `AppState.liveStoreContent() -> StoreContent?`.

- [ ] **Step 1: Write the failing test**

```swift
    /// End to end through AppState's own helpers: a store thinned out below its
    /// record, with a fuller backup present, must produce an offer whose
    /// preselected candidate is that backup.
    func testEvaluateStoreRecoveryOffersTheFullestBackup() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chorus-evaluate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePopulatedStore(at: storeURL, spaces: 4)
        StoreRepair.snapshot(at: storeURL, stamp: "1700000000-1.5.11+20")
        _ = try Self.runSQLite(storeURL, "DELETE FROM ZSPACE;")

        let live = StoreInventory.readContent(at: storeURL)
        let candidates = StoreInventory.candidates(for: storeURL, liveContent: live)
        let best = StoreInventory.best(among: candidates)
        let record = StoreContent(spaces: 4, services: 0, links: 0, spaceNames: [], serviceLabels: [])

        XCTAssertEqual(
            StoreInventory.offer(liveContent: live, best: best, record: record, declinedKeys: []),
            .belowRecord
        )
        XCTAssertEqual(
            StoreInventory.preselection(among: candidates, liveContent: live)?.content?.spaces,
            4,
            "the 4-space snapshot must be preselected over an emptied live store"
        )
    }
```

- [ ] **Step 2: Run it to verify it fails or passes**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testEvaluateStoreRecoveryOffersTheFullestBackup
```
Expected: PASS on the first run, because it exercises Tasks 1 to 5 rather than new code. It is here to pin the composition before the wiring goes in. If it fails, the fault is in an earlier task, so fix that before continuing.

- [ ] **Step 3: Add the keys and observable state**

In `Chorus/App/AppState.swift`, beside `hasEverHadDataKey`:

```swift
    /// The spaces, services, and links the store last held, written after a
    /// clean open and again at termination. A store that comes up below this
    /// lost data between launches; a user who deletes spaces lowers it on the
    /// way out, so their own housekeeping never looks like loss.
    static let contentRecordKey = "chorus.lastKnownContent"

    /// Pairings of backup and live state the user has already declined, so a
    /// declined offer does not come back every launch.
    static let declinedRestoresKey = "chorus.declinedRestores"
```

And with the other observable properties near `storeError`:

```swift
    /// Why Chorus is offering to restore a backup, or nil when it is not.
    private(set) var storeRecoveryOffer: StoreRecoveryOffer?

    /// Every store the user could restore from, including the live one.
    private(set) var storeCandidates: [StoreCandidate] = []

    /// The candidate the picker starts on, or nil when the user must choose.
    private(set) var preselectedCandidate: StoreCandidate?

    /// Whether the picker sheet is up.
    var isShowingStoreRecovery = false
```

- [ ] **Step 4: Add the helpers**

Add a new section in `Chorus/App/AppState.swift` after `loadContainer` and its supporting types:

```swift
    // MARK: - Store recovery picker

    /// What the live store holds right now, read from the open container.
    /// Cheaper and more accurate than a second SQLite read, which would miss
    /// anything not yet checkpointed.
    func liveStoreContent() -> StoreContent? {
        let context = modelContainer.mainContext
        do {
            return StoreContent(
                spaces: try context.fetchCount(FetchDescriptor<Space>()),
                services: try context.fetchCount(FetchDescriptor<ServiceInstance>()),
                links: try context.fetchCount(FetchDescriptor<SpaceServiceLink>()),
                spaceNames: try context.fetch(FetchDescriptor<Space>()).map(\.name),
                serviceLabels: try context.fetch(FetchDescriptor<ServiceInstance>()).map(\.label)
            )
        } catch {
            AppLogger.dataStore.error("Could not read live store content: \(error.localizedDescription)")
            return nil
        }
    }

    /// Records what the store holds, so a later launch can tell loss from
    /// housekeeping. Called after a clean open and again at termination; a hard
    /// crash can leave it stale, which costs at most one declinable offer.
    ///
    /// An empty store is never recorded. That guard is load-bearing: writing the
    /// record while the store is empty would erase the very evidence the offer
    /// depends on, and the loss itself would silence the feature.
    func recordStoreContent(defaults: UserDefaults = .standard) {
        guard let content = liveStoreContent(), !content.isEmpty else { return }
        defaults.set(StoreInventory.encodeRecord(content), forKey: Self.contentRecordKey)
    }

    /// Works out whether to offer a restore and prepares the picker's contents.
    func evaluateStoreRecovery(storeURL: URL, defaults: UserDefaults = .standard) {
        let live = liveStoreContent()
        let candidates = StoreInventory.candidates(for: storeURL, liveContent: live)
        let best = StoreInventory.best(among: candidates)
        let declined = Set(defaults.stringArray(forKey: Self.declinedRestoresKey) ?? [])

        storeCandidates = candidates
        storeRecoveryOffer = StoreInventory.offer(
            liveContent: live,
            best: best,
            record: StoreInventory.decodeRecord(defaults.string(forKey: Self.contentRecordKey)),
            declinedKeys: declined
        )
        preselectedCandidate = StoreInventory.preselection(among: candidates, liveContent: live)
        if let offer = storeRecoveryOffer {
            AppLogger.dataStore.error("Offering a store restore (\(String(describing: offer))); candidates=\(candidates.count)")
        }
    }

    /// Remembers that the user said no to this pairing, and drops the offer.
    func declineStoreRecovery(defaults: UserDefaults = .standard) {
        if let best = StoreInventory.best(among: storeCandidates) {
            let key = StoreInventory.declineKey(live: liveStoreContent(), candidate: best)
            var declined = defaults.stringArray(forKey: Self.declinedRestoresKey) ?? []
            if !declined.contains(key) {
                declined.append(key)
                // Bounded so a long-lived install cannot grow this without end.
                defaults.set(Array(declined.suffix(20)), forKey: Self.declinedRestoresKey)
            }
        }
        storeRecoveryOffer = nil
    }
```

- [ ] **Step 5: Call them from `init`**

In `Chorus/App/AppState.swift`, immediately before `StoreRepair.backupBeforeMigrationIfNeeded(at: config.url)`, apply any pending restore. It must run before the snapshot so the snapshot captures the restored store, and before any container opens:

```swift
        // A restore the user picked last session, applied before anything opens
        // the store.
        StoreRepair.applyPendingRestore(at: config.url)
```

Then at the end of `init`, after `cleanUpOrphanedDataStores()`:

```swift
        // Record what the store holds, then decide whether a fuller backup is
        // worth offering. Order matters: recording first would hide the very
        // shortfall the offer looks for, so evaluate first.
        evaluateStoreRecovery(storeURL: config.url)
        recordStoreContent()
```

`config` is already a local in `init`, so no plumbing is needed.

- [ ] **Step 6: Record again at termination**

`NSApplication.willTerminateNotification` is posted on `NotificationCenter.default`, not on `NSWorkspace.shared.notificationCenter`. The existing `systemObserverTokens` array is only for the workspace center (that is what `deinit` unregisters it from at `AppState.swift:391`), so this needs its own array.

Add beside the other token arrays at `AppState.swift:172-177`, matching their attributes:

```swift
    /// Tokens registered on `NotificationCenter.default`, unregistered in
    /// `deinit`. Kept apart from `systemObserverTokens`, which belongs to
    /// `NSWorkspace.shared.notificationCenter`.
    @ObservationIgnored nonisolated(unsafe) private var defaultCenterTokens: [NSObjectProtocol] = []
```

Add a setup method next to `setupSystemSleepHandling`:

```swift
    /// Records what the store holds as the app goes away. A deliberate deletion
    /// during the session lowers the record here, which is what stops the next
    /// launch reading the user's own housekeeping as data loss.
    private func setupTerminationRecording() {
        defaultCenterTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordStoreContent() }
        })
    }
```

Call it in `init` beside the other `setup…` calls (they run together around `AppState.swift:370-377`):

```swift
        setupTerminationRecording()
```

And unregister in `deinit`, beside the two loops already there:

```swift
        for token in defaultCenterTokens {
            NotificationCenter.default.removeObserver(token)
        }
```

- [ ] **Step 7: Run the whole suite**

Run: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'`
Expected: everything passes. Existing `loadContainer` tests must be untouched by this task; if one now fails, the wiring changed behavior it did not mean to.

- [ ] **Step 8: Commit**

```sh
git add Chorus/App/AppState.swift ChorusTests/ChorusTests.swift
git commit -m "feat: record store content and evaluate a restore offer at launch"
```

---

### Task 9: Relaunch, and act on the user's choice

**Files:**
- Create: `Chorus/Utilities/AppRelauncher.swift`
- Modify: `Chorus/App/AppState.swift`
- Test: `ChorusTests/ChorusTests.swift`

**Interfaces:**
- Consumes: `StoreRepair.pendingRestoreKey`, `StoreRepair.validatedRestoreName`.
- Produces: `AppRelauncher.relaunchAfterExit()`, `AppState.chooseStoreRestore(_ candidate: StoreCandidate) -> Bool`.

- [ ] **Step 1: Write the failing test**

The relaunch itself cannot be unit-tested, so the test covers the part that can be: the choice is written in a form the launch path accepts.

```swift
    /// The filename a choice writes must be one the launch path will accept.
    /// This is the seam between the picker and `applyPendingRestore`, and a
    /// mismatch here would silently do nothing on the next launch.
    func testChosenCandidateNameSurvivesValidation() {
        let storeURL = URL(fileURLWithPath: "/tmp/whatever/default.store")
        let names = [
            "default.store.snapshot-1700000000-1.5.11+20.bak",
            "default.store.prerestore-1700000500.bak",
            "default.store.corrupt-1700000600.bak",
            "default.store.prepick-1700000700.bak",
        ]
        for name in names {
            let candidate = StoreCandidate(
                url: storeURL.deletingLastPathComponent().appendingPathComponent(name),
                kind: .snapshot(version: nil),
                takenAt: nil,
                content: StoreContent(spaces: 1, services: 1, links: 1, spaceNames: [], serviceLabels: []),
                isDamaged: false
            )
            XCTAssertEqual(
                StoreRepair.validatedRestoreName(candidate.url.lastPathComponent, storeName: storeURL.lastPathComponent),
                name,
                "a candidate the picker can show must be one the launch path accepts"
            )
        }
    }
```

- [ ] **Step 2: Run it to verify it passes**

Run:
```sh
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS' \
  -only-testing:ChorusTests/ChorusTests/testChosenCandidateNameSurvivesValidation
```
Expected: PASS, since it pins Task 6's contract. A failure means the families in `validatedRestoreName` and the families in `candidates(for:liveContent:)` have drifted apart.

- [ ] **Step 3: Write the relauncher**

Create `Chorus/Utilities/AppRelauncher.swift`:

```swift
import AppKit

/// Restarts Chorus. Used after the user picks a store to restore, because the
/// swap can only happen at launch, before the container opens.
enum AppRelauncher {
    /// Waits for this process to exit and then reopens the app bundle.
    ///
    /// The wait is the point. Reopening first would put a second Chorus on the
    /// same store, and both instances doing file-level work on one SQLite file
    /// is how stores get corrupted. A detached `sh` polls this PID, so the
    /// reopen cannot start until this process is gone.
    static func relaunchAfterExit() {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            // Bounded so a hung shutdown cannot leave this polling forever.
            "for i in $(seq 1 150); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done; " +
            "open -n \"$1\"",
            "sh",
            bundlePath,
        ]
        do {
            try task.run()
        } catch {
            AppLogger.general.error("Could not schedule a relaunch: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 4: Give `AppState` the store's filename**

Validation needs the live store's filename, which only `init` knows. Add a stored property beside `storeFileURL` at `AppState.swift:240`:

```swift
    /// The live store's filename, used to check a chosen backup belongs to this
    /// store. Debug and release builds use different store paths, so this cannot
    /// be a constant.
    private var storeFileName = "default.store"
```

In `init`, immediately after the `#endif` that closes the debug/release `config` choice (`AppState.swift:273`):

```swift
        self.storeFileName = config.url.lastPathComponent
```

- [ ] **Step 5: Add the choice action to `AppState`**

Add to the store-recovery section added in Task 8:

```swift
    /// Records the user's pick and restarts so it can be applied before the
    /// store opens. Returns false when the pick cannot be used, in which case
    /// nothing is written and the app keeps running.
    @discardableResult
    func chooseStoreRestore(_ candidate: StoreCandidate, defaults: UserDefaults = .standard) -> Bool {
        guard candidate.isRestorable else { return false }
        guard let name = StoreRepair.validatedRestoreName(
            candidate.url.lastPathComponent,
            storeName: storeFileName
        ) else {
            AppLogger.dataStore.error("Refusing to schedule a restore from an unexpected filename")
            return false
        }
        defaults.set(name, forKey: StoreRepair.pendingRestoreKey)
        AppLogger.dataStore.info("Scheduled a restore from \(name); relaunching")
        AppRelauncher.relaunchAfterExit()
        return true
    }
```

- [ ] **Step 6: Add the file to the project and run the suite**

Run:
```sh
xcodegen generate
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'
```
Expected: `AppRelauncher.swift` appears in the pbxproj diff, and all tests pass.

- [ ] **Step 7: Commit**

```sh
git add Chorus/Utilities/AppRelauncher.swift Chorus/App/AppState.swift Chorus.xcodeproj/project.pbxproj ChorusTests/ChorusTests.swift
git commit -m "feat: schedule a chosen restore and relaunch to apply it

The relaunch waits for this process to exit before reopening, so two instances
never hold the same store."
```

---

### Task 10: The picker sheet, the banner button, and the Settings item

**Files:**
- Create: `Chorus/Views/MainWindow/StoreRecoveryView.swift`
- Modify: `Chorus/Views/MainWindow/ContentView.swift:11-44`, `Chorus/Views/Settings/SettingsView.swift`
- Test: manual, plus the full suite for regressions

**Interfaces:**
- Consumes: `AppState.storeCandidates`, `AppState.preselectedCandidate`, `AppState.isShowingStoreRecovery`, `AppState.storeRecoveryOffer`, `AppState.chooseStoreRestore(_:)`, `AppState.declineStoreRecovery()`, `StoreCandidate`.
- Produces: `StoreRecoveryView`.

- [ ] **Step 1: Write the sheet**

Create `Chorus/Views/MainWindow/StoreRecoveryView.swift`:

```swift
import SwiftUI

/// Lists every store Chorus could put back: the live one and each backup it
/// kept. The user picks; nothing is written until they do.
struct StoreRecoveryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selection: StoreCandidate?

    /// Shown when the restore could not be started. Amended in after Task 9's
    /// review: `chooseStoreRestore` returns false if spawning the relaunch
    /// fails, and dismissing the sheet on that path told the user their restore
    /// had been applied when nothing had happened.
    @State private var failureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore your spaces and services")
                .font(.headline)
            Text("Chorus keeps a copy of your data before each update. Pick the one you want and Chorus will restart to put it back. Your current data is set aside first, so nothing is thrown away.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(appState.storeCandidates, selection: $selection) { candidate in
                row(for: candidate)
                    .tag(candidate)
            }
            .frame(minHeight: 200)

            if let failureMessage {
                Text(failureMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }

            HStack {
                if let folder = appState.storeCandidates.first?.url.deletingLastPathComponent() {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore and Restart") {
                    guard let selection else { return }
                    if appState.chooseStoreRestore(selection) { return }
                    failureMessage = "Chorus could not restart itself. Quit and open it again to put this backup back."
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection?.isRestorable != true)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { selection = appState.preselectedCandidate }
    }

Two notes on that failure message.

It is worded for the case that can actually happen: `chooseStoreRestore` returns false when spawning the relaunch fails, and Task 9 keeps the pending choice in that case, so opening Chorus again really does put the backup back. The other false paths — a candidate that is not restorable, or a filename that fails validation — cannot be reached from this button, which stays disabled unless `isRestorable`, and `chooseStoreRestore` checks it again. A filename failing validation would mean the two family lists had drifted apart, which Task 9's test pins.

It went through the humanizer check: `prohibitions_clear`, no hard violations. The one remaining finding is low sentence-length variance, which is justified rather than fixed — a two-sentence error message cannot hit a prose variance target without padding, and Orwell's third rule says cut the word out.

    @ViewBuilder
    private func row(for candidate: StoreCandidate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title(for: candidate)).fontWeight(.medium)
                if candidate.kind == .live {
                    Text("Current")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
            }
            Text(detail(for: candidate))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func title(for candidate: StoreCandidate) -> String {
        switch candidate.kind {
        case .live: return "Your data now"
        case .snapshot(let version): return version.map { "Backup from before \($0)" } ?? "Backup from before an update"
        case .prerestore: return "Backup from an earlier restore"
        case .corrupt: return "Backup from before a repair"
        case .prepick: return "Your data before you restored a backup"
        }
    }

    private func detail(for candidate: StoreCandidate) -> String {
        let when: String
        if let takenAt = candidate.takenAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            when = formatter.string(from: takenAt)
        } else {
            when = "date unknown"
        }
        guard let content = candidate.content else { return "\(when) — can't be read" }
        let spaces = content.spaces == 1 ? "1 space" : "\(content.spaces) spaces"
        let services = content.services == 1 ? "1 service" : "\(content.services) services"
        let damaged = candidate.isDamaged ? " — damaged" : ""
        return "\(when) — \(spaces), \(services)\(damaged)"
    }
}
```

- [ ] **Step 2: Add the banner button**

In `Chorus/Views/MainWindow/ContentView.swift`, inside the existing `if let error = appState.storeError` block, add a button before the dismissible close button (after the `Reveal in Finder` button):

```swift
                    if appState.storeRecoveryOffer != nil {
                        Button("Review backups…") {
                            appState.isShowingStoreRecovery = true
                        }
                        .font(.caption)
                    }
```

The banner shows when `storeError` is set. An offer can exist without a store error, so add a second banner for that case immediately after the `storeError` block:

```swift
            if appState.storeError == nil, appState.storeRecoveryOffer != nil {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    Text("Chorus has a backup with more of your spaces and services than it can see now.")
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("Review backups…") { appState.isShowingStoreRecovery = true }
                        .font(.caption)
                    Button("Not now") { appState.declineStoreRecovery() }
                        .font(.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.15))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Chorus has a backup with more of your spaces and services than it can see now.")
            }
```

Attach the sheet to the outer `VStack` in `ContentView`, beside its other modifiers:

```swift
        .sheet(isPresented: $state.isShowingStoreRecovery) {
            StoreRecoveryView()
        }
```

`@Bindable var state = appState` already exists at the top of `body`, so `$state.isShowingStoreRecovery` binds directly.

- [ ] **Step 3: Add the Settings item**

In `Chorus/Views/Settings/SettingsView.swift`, add a new section to `GeneralSettingsView` (declared at line 56) immediately after its `Section("Startup")` block (line 167). That view already holds `@Environment(AppState.self) private var appState` at line 59, so no environment plumbing is needed:

```swift
            Section("Data") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restore from a backup")
                        Text("Chorus keeps a copy of your spaces and services before each update.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore from a backup…") {
                        appState.isShowingStoreRecovery = true
                    }
                }
            }
```

If `SettingsView` does not already hold an `@Environment(AppState.self)`, add it in the same style the file uses elsewhere.

- [ ] **Step 4: Build and run the suite**

Run:
```sh
xcodegen generate
xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'
```
Expected: builds clean, all tests pass. The sheet has no unit tests; the next step covers it.

- [x] **Step 5: Verify by hand, against a fixture store only** — done 2026-07-29/30; see "What the by-hand pass found" at the end of this plan

Do NOT point a dev build at `~/Library/Application Support/default.store`. Debug builds use `Application Support/Chorus-debug`, which is what these steps exercise.

1. Launch the Debug build, add a third space and a couple of services, and quit. This writes the record.
2. Quit. **First** take a snapshot, by copying the triple to `default.store.snapshot-1700000000-1.5.15+24.bak{,-wal,-shm}` — that is the thing you will restore, so it has to exist before you break anything. **Then** empty the live store's spaces with `sqlite3 ~/Library/Application\ Support/Chorus-debug/default.store "DELETE FROM ZSPACE;"`.
3. Launch again. Confirm: the banner appears, "Review backups…" opens the sheet, the snapshot is preselected, and the row shows the right counts and date.
4. Click Restore and Restart. Confirm the app relaunches once (not twice, and no second instance in Activity Monitor), the spaces are back, and a **`prepick-`** copy of the emptied store now exists. (It is `prepick-`, not `prerestore-`: Task 6's review moved the user-chosen restore's aside to its own family, because writing it under `prerestore-` disarmed the sentinel the automatic restore reads.)
5. Relaunch again and confirm no banner: the record and the store now agree.
6. Delete a space on purpose, quit, relaunch. Confirm no banner, which is the deliberate-deletion case.
7. Open Settings and confirm "Restore from a backup…" opens the same sheet with nothing preselected while the store holds your own data.
8. **A store that will not open at all.** Two behaviours here cannot be unit-tested, because proving them needs a live `AppState` and the suite deliberately never builds one — so this step is the only check they get. Quit, then corrupt the debug store's primary file (`printf 'garbage' > ~/Library/Application\ Support/Chorus-debug/default.store`, keeping a copy of the good triple and a snapshot beside it), and launch. Confirm the live row reads "can't be read" and **not** "0 spaces, 0 services": under this failure Chorus falls back to a throwaway in-memory container, and reporting what *that* holds would describe the wrong store and preselect a backup over a file that might be intact. Confirm a backup is still offered, and that the sheet lists the good snapshot.

   **Then actually restore from it, and confirm it works.** This is new: a late review found the safety check refused a restore in exactly this state, because it asked whether the copy it set aside was *readable* — and a faithful copy of a corrupt store is a corrupt file. So the user picked, the app restarted, and nothing happened, every time. It now asks whether the copy *succeeded* instead, and only asks for readability when what it copied was readable. Pick the snapshot, restore, and confirm your spaces come back. A `prepick-` copy of the corrupt store should be sitting beside the store afterwards, which is the point — even garbage is kept.
9. **A decline has to stick.** With an offer showing, click "Not now", quit, and relaunch. Confirm the banner does **not** come back. This is the other behaviour tests cannot reach: the decline is keyed on the live store's signature, and if that key is computed from the wrong source it never matches on the next launch and the banner returns every single time.
10. **The Settings button has to present in front, including with no main window.** Added after Task 10's review found the sheet was attached to the main window's scene while Settings is a separate one. Open Settings and click "Restore from a backup…": confirm the sheet appears **in front**, not behind the Settings window. Then close the main window entirely (the menu bar item keeps Chorus running), open Settings from the menu bar, and click it again: confirm the main window comes forward and the sheet appears, rather than nothing happening. If nothing appears, check it does not then pop up unprompted the next time you open the main window.
11. **Clicking a row has to enable the button.** Open the sheet from Settings while your store holds your own data, so nothing is preselected. Confirm "Restore and Restart" starts disabled, then click a backup row and confirm it becomes enabled. Selection in this list cannot be covered by a test, and the failure is one-sided: the banner path would still work because it preselects, so only this path would show it.
12. **The sheet has to show current numbers, not launch numbers.** Add a space, then open the sheet from Settings **without** relaunching. Confirm the "Your data now" row counts include the space you just added. Before the review this row showed whatever was true at launch, which could make a backup look fuller than your live data.
13. **Restoring a broken backup has to leave your store intact.** This is the highest-stakes path in the feature and the only one proved solely by a fixture, so it is worth doing by hand. Quit, and write a junk file where a backup would be: `printf 'garbage' > ~/Library/Application\ Support/Chorus-debug/default.store.corrupt-1700009999.bak`. Launch, open the sheet, select "Backup from before a repair", and restore. Chorus restarts, finds the chosen file unreadable, and puts your own store back. Afterwards confirm three things: your spaces are all still there; no `default.store-wal` is left beside the store that does not belong to it; and the log names the revert rather than a generic copy failure. If the row is not selectable, that is correct too — say so, because it means the picker refused a file it could not read, which is the better outcome.

- [ ] **Step 6: Commit**

```sh
git add Chorus/Views/MainWindow/StoreRecoveryView.swift Chorus/Views/MainWindow/ContentView.swift Chorus/Views/Settings/SettingsView.swift Chorus.xcodeproj/project.pbxproj
git commit -m "feat: a picker for restoring the most complete store

One sheet, reached from the launch banner when Chorus notices missing data and
from Settings at any time."
```

---

### Task 11: Documentation

**Files:**
- Modify: `CHANGELOG.md`, `docs/internal/OPEN-ITEMS.md`, `.remember/remember.md`

- [ ] **Step 1: Add the changelog entry**

Under `## [Unreleased]`, add an `### Added` entry. Draft it, then run it through the humanizer loop as `CLAUDE.md` requires: call `humanizer_check_text`, fix every finding, re-run until `prohibitions_clear` is true, and check it against Orwell's six rules. Plain, active, concrete. No em-dashes.

Content to convey: Chorus can now show every backup it keeps, with what each holds and when it was taken, and put the one you pick back; it offers this by itself when it notices your spaces and services are missing; your current data is set aside first.

- [ ] **Step 2: Update the open items**

In `docs/internal/OPEN-ITEMS.md`, move the recovery picker out of open work and into the current status, and note that the shared-store-path item is still open and unaffected by this work.

Three statements in the existing "In progress" section have gone stale and must be corrected rather than carried over:

- It says tasks 1 to 6 of 11 are done at 150 tests. All eleven are done; use the final test count from your own suite run.
- It says candidate enumeration covers "all three backup families". There are four now — Task 6 added `.prepick-`, the aside a user-chosen restore sets the current store aside under. Say why it is separate: writing it under `.prerestore-` disarmed the sentinel `restoreFromSnapshot` reads to decide whether to take its own safety copy.
- It carries "One open behavior question for Nico" about an unreadable live store with no recorded count. That was decided: **keep the offer.** Unknown stays treated as nothing-to-lose, because the outcome is a banner the user can decline and never an automatic write. Record the decision and drop the question.

- [ ] **Step 3: Add the test-configuration warning to `CLAUDE.md`**

This is a new standing rule, so it belongs in `CLAUDE.md`'s "Build & test" section rather than in the open items. `ChorusTests` is app-hosted, and `ChorusApp.init` builds an `AppState`, so **every** `xcodebuild test` run executes the launch path — including `StoreRepair.applyPendingRestore`, which writes files. Under the default Debug configuration that is harmless: the store resolves to `Application Support/Chorus-debug` and the defaults domain to `com.nicojan.Chorus.debug`. A run with `-configuration Release` would aim that write path at the real store and the release defaults domain.

Write it as a warning never to run the suite with `-configuration Release`, and say why in one line. This repo has already lost a real user's spaces and services to a careless run against live data, so the reason matters as much as the rule.

- [ ] **Step 4: Update the handoff note**

The handoff note is **git-ignored** (`.gitignore:23` ignores `.remember/`) and it does **not** exist inside this worktree — it lives only in the main checkout. So write to the absolute path `/Users/nicojan/dev/Chorus/.remember/remember.md`, and do **not** create a `.remember/` directory inside the worktree; that would be a stray ignored copy nobody reads.

Record where this landed, what is verified by test versus what still needs a hand pass, that the shared store path remains the open suspect for loss with no update involved, and that `.superpowers/sdd/2026-07-29-store-recovery-picker/progress.md` holds every ruling and deferred finding and is git-ignored scratch, so it should be read before the branch is deleted.

- [ ] **Step 5: Commit**

Do **not** try to stage the handoff note — it is git-ignored, and `git add` will refuse it.

```sh
git add CHANGELOG.md docs/internal/OPEN-ITEMS.md CLAUDE.md
git commit -m "docs: record the store recovery picker"
```

---

## Verification before calling this done

- [x] Full suite green: `xcodebuild test -project Chorus.xcodeproj -scheme Chorus -destination 'platform=macOS'` (no `-configuration Release`, per the rule added above) — 179 tests, 0 failures
- [x] The manual pass in Task 10 Step 5 done, including the deliberate-deletion case producing no banner. Run 2026-07-29/30 against the debug store only, with `Chorus-debug` and its defaults domain copied aside first and put back afterwards. It found one blocker (below), fixed in `b036fae`, after which steps 4 and 8 were run again against the fixed build.
- [x] `git status` clean, and `project.yml` and `.pbxproj` consistent
- [x] No `@Model` stored property changed: `git diff --stat main -- Chorus/Models/` reports no changes, and `testCurrentStoredShapeIsPinned` plus `testFrozenAppPreferencesMatchesLiveModel` are green

### What the by-hand pass found

**The blocker: "Restore and Restart" never restarted.** The pick was written and
the relaunch poller armed, and then nothing happened. AppKit will not terminate
while a sheet is attached, and it drops the request instead of deferring it, so
the app stayed up, the poller expired against its own 30-second bound, and the
restore landed only when the app was next opened by hand. Command-Q is inert in
the same state, which is what pinned the cause down; a `sample` of the process
showed an idle run loop, not a hang. Fixed by splitting arming from quitting:
the pick arms while the sheet is up, so a spawn failure can still be reported
there, and the quit runs from the sheet's `onDismiss`, waiting out any still
attached sheet up to a bound.

Two things the steps as written expected turned out differently, and neither is
a defect:

- **Step 3's preselection.** Emptying the live store with `DELETE FROM ZSPACE`
  leaves it *unusable*, not merely empty, so 1.5.15's automatic restore ran
  first and put the user's data back. Preselection is then correctly skipped —
  it only fires when the live store holds nothing of the user's. Preselection
  itself was confirmed in step 8, where the live store cannot be read at all.
- **Step 13's broken backup.** The picker will not let one be chosen: the row
  selects but the action stays disabled, which the step already names as the
  better outcome. The revert path underneath it was exercised anyway by writing
  the pending key directly, standing in for a backup that goes bad between the
  pick and the relaunch. The log named the revert, the store was untouched, and
  no foreign `-wal` was left behind.

Everything else passed as written: the record written at termination, the
`prepick-` aside in its own family, no banner when the record and the store
agree, no banner after a deliberate deletion even with fuller backups on disk,
the decline surviving a relaunch, the Settings sheet presenting in front (with
and without a main window), the button enabling on selection, current rather
than launch-time counts, and the "can't be read" live row leading to a restore
that works and keeps even the unreadable store as an aside.
