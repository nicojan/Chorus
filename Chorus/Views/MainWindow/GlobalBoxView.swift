import SwiftUI

/// The global services in a card of their own, as a column in a vertical rail
/// or a row in a bar. Every layout draws the global group through this one
/// view, wherever the placement puts it (see `GlobalPlacement`), so the card's
/// border is the same thing to grab in each of them.
///
/// The rows themselves stay with the rail that owns their drag, focus and
/// menus: it passes them in as `row`. Draws nothing while `items` is empty,
/// since dividers alone make no group.
struct GlobalBoxView<Row: View>: View {
    /// The global group as drawn: services and the dividers between them.
    let items: [RailItem]
    /// A column in a vertical rail, a row in a bar.
    let axis: Axis
    /// The rail's reorder spring, or nil under Reduce Motion.
    let reorderAnimation: Animation?
    @ViewBuilder let row: (RailItem) -> Row

    /// Rows sit 2 points apart in a column, the rail's 30 point pitch; tabs
    /// sit 4 apart, as the bar's own do.
    private var spacing: CGFloat { axis == .vertical ? 2 : 4 }

    var body: some View {
        if !items.isEmpty {
            stack
                // Only a reorder animates. See `ReorderKey`.
                .animation(reorderAnimation, value: ReorderKey(ids: items.map(\.id)))
                // Padded on every side so a row's 8 point fill sits inside the
                // card's 14 point corners, the same distance from each edge.
                .padding(ChorusCard.railPadding)
                .railCard()
        }
    }

    @ViewBuilder
    private var stack: some View {
        if axis == .vertical {
            VStack(spacing: spacing) {
                ForEach(items) { item in row(item) }
            }
        } else {
            HStack(spacing: spacing) {
                ForEach(items) { item in row(item) }
            }
        }
    }
}
