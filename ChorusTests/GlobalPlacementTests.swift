import XCTest
import SwiftData
@testable import Chorus

/// Where the global services sit: the model that maps one saved choice onto
/// each rail layout.
final class GlobalPlacementTests: XCTestCase {
    func testDefaultIsTodaysArrangement() {
        XCTAssertEqual(GlobalPlacement(edgeRaw: "", barRaw: ""), .standard)
        XCTAssertEqual(GlobalPlacement.standard.spot(in: .hybrid), .spaceStripTop)
        XCTAssertEqual(GlobalPlacement.standard.spot(in: .sidebar), .railTop)
        XCTAssertEqual(GlobalPlacement.standard.spot(in: .topBars), .barLeft)
        XCTAssertEqual(GlobalPlacement.standard.spot(in: .allServices), .railTop)
    }

    func testSpotsPerLayout() {
        XCTAssertEqual(
            GlobalPlacement.spots(for: .hybrid),
            [.spaceStripTop, .spaceStripBottom, .servicesBarLeft, .servicesBarRight]
        )
        XCTAssertEqual(GlobalPlacement.spots(for: .sidebar), [.railTop, .railBottom])
        XCTAssertEqual(GlobalPlacement.spots(for: .allServices), [.railTop, .railBottom])
        XCTAssertEqual(GlobalPlacement.spots(for: .topBars), [.barLeft, .barRight])
    }

    func testEveryHybridCombinationResolves() {
        let table: [(GlobalEdge, GlobalBar, GlobalSpot)] = [
            (.start, .spaces, .spaceStripTop),
            (.end, .spaces, .spaceStripBottom),
            (.start, .services, .servicesBarLeft),
            (.end, .services, .servicesBarRight),
        ]
        for (edge, bar, spot) in table {
            XCTAssertEqual(GlobalPlacement(edge: edge, bar: bar).spot(in: .hybrid), spot)
        }
        for spot in GlobalPlacement.spots(for: .hybrid) {
            XCTAssertEqual(GlobalPlacement.standard.placing(spot).spot(in: .hybrid), spot)
        }
    }

    func testPlacementCarriesAcrossLayouts() {
        let p = GlobalPlacement.standard.placing(.servicesBarRight)
        XCTAssertEqual(p.spot(in: .sidebar), .railBottom)
        XCTAssertEqual(p.spot(in: .topBars), .barRight)
        XCTAssertEqual(p.placing(.railTop).spot(in: .hybrid), .servicesBarLeft)
        XCTAssertEqual(p.placing(.railBottom).spot(in: .hybrid), .servicesBarRight)
    }

    func testOrdering() {
        XCTAssertEqual(GlobalPlacement.standard.ordered(globals: [1, 2], rest: [3]), [1, 2, 3])
        XCTAssertEqual(
            GlobalPlacement.standard.placing(.railBottom).ordered(globals: [1, 2], rest: [3]),
            [3, 1, 2]
        )
    }

    func testSaveAndLoad() {
        let name = "GlobalPlacementTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let placement = GlobalPlacement.standard.placing(.spaceStripBottom)
        placement.save(to: defaults)
        XCTAssertEqual(GlobalPlacement.current(defaults), placement)
    }

    /// While the box is dragged, every spot of the layout but its own takes
    /// a drop.
    func testDropSpotsAreEveryOtherSpot() {
        let barRight = GlobalPlacement(edge: .end, bar: .services)
        XCTAssertEqual(barRight.dropSpots(in: .hybrid), [.spaceStripTop, .spaceStripBottom, .servicesBarLeft])
        XCTAssertEqual(barRight.dropSpots(in: .sidebar), [.railTop])
        XCTAssertEqual(barRight.dropSpots(in: .allServices), [.railTop])
        XCTAssertEqual(barRight.dropSpots(in: .topBars), [.barLeft])
        XCTAssertEqual(GlobalPlacement.standard.dropSpots(in: .hybrid), [.spaceStripBottom, .servicesBarLeft, .servicesBarRight])
        XCTAssertEqual(GlobalPlacement.standard.dropSpots(in: .topBars), [.barRight])
        for layout in RailLayout.allCases {
            for placement in [GlobalPlacement.standard, barRight] {
                XCTAssertFalse(placement.dropSpots(in: layout).contains(placement.spot(in: layout)))
                XCTAssertEqual(placement.dropSpots(in: layout).count, GlobalPlacement.spots(for: layout).count - 1)
            }
        }
    }

    /// The bar names its two ends by layout.
    func testBarEndsPerLayout() {
        XCTAssertEqual(GlobalSpot.barEnds(in: .hybrid), [.servicesBarLeft, .servicesBarRight])
        XCTAssertEqual(GlobalSpot.barEnds(in: .topBars), [.barLeft, .barRight])
    }

    /// A pinned box gets no cap until its rail is measured, then 40% of it.
    func testPinnedBoxCap() {
        XCTAssertNil(GlobalBoxCap.height(forRail: 0))
        XCTAssertEqual(GlobalBoxCap.height(forRail: 500), 200)
    }

    func testChoosingASpotSavesIt() {
        let name = "GlobalPlacementTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        GlobalPlacement.standard.placing(.servicesBarRight).save(to: defaults)
        GlobalPlacement.choose(.railTop, in: defaults)
        XCTAssertEqual(GlobalPlacement.current(defaults), GlobalPlacement(edge: .start, bar: .services))
    }

    func testShortcutDestinationsFollowPlacement() {
        let g = UUID(), s = UUID(), a = UUID(), b = UUID()
        let spaces = [(spaceID: s, services: [a, b])]
        XCTAssertEqual(
            ServiceShortcutNavigation.shortcutDestinations(globals: [g], spaces: spaces, placement: .standard),
            [
                ServiceShortcutDestination(spaceID: nil, serviceID: g),
                ServiceShortcutDestination(spaceID: s, serviceID: a),
                ServiceShortcutDestination(spaceID: s, serviceID: b)
            ]
        )
        XCTAssertEqual(
            ServiceShortcutNavigation.shortcutDestinations(
                globals: [g], spaces: spaces, placement: GlobalPlacement.standard.placing(.railBottom)),
            [
                ServiceShortcutDestination(spaceID: s, serviceID: a),
                ServiceShortcutDestination(spaceID: s, serviceID: b),
                ServiceShortcutDestination(spaceID: nil, serviceID: g)
            ]
        )
    }

    func testPickerChoicesMatchLayout() {
        let hybrid = GlobalPlacement.pickerChoices(for: .hybrid)
        XCTAssertEqual(hybrid.map(\.spot), GlobalPlacement.spots(for: .hybrid))
        XCTAssertEqual(hybrid.count, 4)
        XCTAssertEqual(hybrid.map(\.title), [
            "Above the spaces", "Below the spaces",
            "Left end of the services bar", "Right end of the services bar"
        ])
        for layout in RailLayout.allCases where layout != .hybrid {
            let choices = GlobalPlacement.pickerChoices(for: layout)
            XCTAssertEqual(choices.count, 2, "\(layout)")
            XCTAssertEqual(choices.map(\.title), choices.map(\.spot.title))
        }
    }
}

/// The order ⌘1–9, ⌘[ / ⌘], preload and launch restore walk in a space:
/// `AppState.railServices`, run on an in-memory store.
@MainActor
final class RailServicesOrderTests: XCTestCase {
    func testGlobalsFollowThePlacementEdge() throws {
        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext

        let space = Space(name: "Work", emoji: "📦", sortOrder: 0)
        let global = ServiceInstance(label: "Mail", url: "https://mail.example", isGlobal: true, globalSortOrder: 0)
        let own = ServiceInstance(label: "Slack", url: "https://slack.example")
        ctx.insert(space)
        ctx.insert(global)
        ctx.insert(own)
        try ctx.save()
        // Building the link wires both ends, which are already in the
        // context; a second insert is fatal on macOS 14.
        let link = SpaceServiceLink(sortOrder: 0, space: space, service: own)
        if link.modelContext == nil { ctx.insert(link) }
        try ctx.save()

        let start = AppState.railServices(
            forSpace: space.id, in: ctx, placement: GlobalPlacement(edge: .start, bar: .spaces))
        XCTAssertEqual(start.map(\.id), [global.id, own.id])

        let end = AppState.railServices(
            forSpace: space.id, in: ctx, placement: GlobalPlacement(edge: .end, bar: .services))
        XCTAssertEqual(end.map(\.id), [own.id, global.id])
    }
}
