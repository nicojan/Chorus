import Foundation

/// Which end of its row or column the global services take.
enum GlobalEdge: String, Sendable {
    /// Leading: top of a column, left end of a row.
    case start
    /// Trailing: bottom of a column, right end of a row.
    case end
}

/// Which bar holds the global services. Only the hybrid layout has two bars
/// to choose between; every other layout ignores it.
enum GlobalBar: String, Sendable {
    case spaces
    case services
}

/// A place the global services can sit, as the picker names it.
enum GlobalSpot: Hashable, CaseIterable, Sendable {
    case spaceStripTop
    case spaceStripBottom
    case servicesBarLeft
    case servicesBarRight
    case railTop
    case railBottom
    case barLeft
    case barRight

    /// The picker label.
    nonisolated var title: String {
        switch self {
        case .spaceStripTop: "Above the spaces"
        case .spaceStripBottom: "Below the spaces"
        case .servicesBarLeft: "Left end of the services bar"
        case .servicesBarRight: "Right end of the services bar"
        case .railTop: "Top of the rail"
        case .railBottom: "Bottom of the rail"
        case .barLeft: "Left end of the bar"
        case .barRight: "Right end of the bar"
        }
    }

    /// The end of its row or column this spot is at.
    nonisolated var edge: GlobalEdge {
        switch self {
        case .spaceStripTop, .servicesBarLeft, .railTop, .barLeft: .start
        case .spaceStripBottom, .servicesBarRight, .railBottom, .barRight: .end
        }
    }
}

/// Where the box of global services sits in the rail.
///
/// One saved choice (an edge and a bar) that every layout reads in its own
/// terms, so switching layout keeps the global services roughly where the
/// user put them. It lives in defaults rather than `AppPreferences`: a stored
/// property there is a new schema version (see CLAUDE.md), which a cosmetic
/// setting does not earn.
struct GlobalPlacement: Equatable, Sendable {
    let edge: GlobalEdge
    let bar: GlobalBar

    static let edgeKey = "globalServicesEdge"
    static let barKey = "globalServicesBar"

    /// Today's arrangement: first, in the space strip.
    static let standard = GlobalPlacement(edge: .start, bar: .spaces)

    init(edge: GlobalEdge, bar: GlobalBar) {
        self.edge = edge
        self.bar = bar
    }

    /// Builds a placement from saved strings. A value that is empty or
    /// unknown falls back to the standard one.
    init(edgeRaw: String, barRaw: String) {
        self.edge = GlobalEdge(rawValue: edgeRaw) ?? Self.standard.edge
        self.bar = GlobalBar(rawValue: barRaw) ?? Self.standard.bar
    }

    /// The spots a layout offers, in picker order.
    nonisolated static func spots(for layout: RailLayout) -> [GlobalSpot] {
        switch layout {
        case .hybrid: [.spaceStripTop, .spaceStripBottom, .servicesBarLeft, .servicesBarRight]
        case .sidebar, .allServices: [.railTop, .railBottom]
        case .topBars: [.barLeft, .barRight]
        }
    }

    /// The spot this placement resolves to in a layout.
    nonisolated func spot(in layout: RailLayout) -> GlobalSpot {
        switch layout {
        case .hybrid:
            switch (bar, edge) {
            case (.spaces, .start): .spaceStripTop
            case (.spaces, .end): .spaceStripBottom
            case (.services, .start): .servicesBarLeft
            case (.services, .end): .servicesBarRight
            }
        case .sidebar, .allServices:
            edge == .start ? .railTop : .railBottom
        case .topBars:
            edge == .start ? .barLeft : .barRight
        }
    }

    /// The placement after choosing a spot. A spot in a layout with one bar
    /// sets only the edge and keeps the bar, so the choice survives a trip
    /// through that layout.
    nonisolated func placing(_ spot: GlobalSpot) -> GlobalPlacement {
        switch spot {
        case .spaceStripTop, .spaceStripBottom:
            GlobalPlacement(edge: spot.edge, bar: .spaces)
        case .servicesBarLeft, .servicesBarRight:
            GlobalPlacement(edge: spot.edge, bar: .services)
        case .railTop, .railBottom, .barLeft, .barRight:
            GlobalPlacement(edge: spot.edge, bar: bar)
        }
    }

    /// Joins the global items and the rest in display order.
    nonisolated func ordered<T>(globals: [T], rest: [T]) -> [T] {
        edge == .start ? globals + rest : rest + globals
    }

    /// The saved placement, or the standard one when nothing is saved.
    nonisolated static func current(_ defaults: UserDefaults = .standard) -> GlobalPlacement {
        GlobalPlacement(
            edgeRaw: defaults.string(forKey: edgeKey) ?? "",
            barRaw: defaults.string(forKey: barKey) ?? ""
        )
    }

    /// Writes this placement to defaults.
    nonisolated func save(to defaults: UserDefaults = .standard) {
        defaults.set(edge.rawValue, forKey: Self.edgeKey)
        defaults.set(bar.rawValue, forKey: Self.barKey)
    }

    /// Saves the result of choosing a spot, on top of what is saved now.
    nonisolated static func choose(_ spot: GlobalSpot, in defaults: UserDefaults = .standard) {
        current(defaults).placing(spot).save(to: defaults)
    }
}
