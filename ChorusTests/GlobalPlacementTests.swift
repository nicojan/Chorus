import XCTest
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

    func testChoosingASpotSavesIt() {
        let name = "GlobalPlacementTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        GlobalPlacement.standard.placing(.servicesBarRight).save(to: defaults)
        GlobalPlacement.choose(.railTop, in: defaults)
        XCTAssertEqual(GlobalPlacement.current(defaults), GlobalPlacement(edge: .start, bar: .services))
    }
}
