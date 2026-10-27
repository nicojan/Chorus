import SwiftUI

/// The global services in a card of their own, as a column in a vertical rail
/// or a row in a bar. Every layout draws the global group through this one
/// view, wherever the placement puts it (see `GlobalPlacement`), so the card
/// is the same thing to grab in each of them: a press on its padding drags the
/// whole box to another spot (`GlobalSpotDropTarget`), while a press on a row
/// still drags that one service.
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
                .modifier(GlobalBoxDragging(services: items.compactMap(\.service)))
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

/// Makes the box draggable by its padding. The rows inside carry smaller drag
/// sources of their own, which win a press on them (see `RailDragSession`),
/// so only a press between or round them drags the box.
private struct GlobalBoxDragging: ViewModifier {
    let services: [ServiceInstance]

    func body(content: Content) -> some View {
        content
            // The padding is empty, and the card's fill takes no hits, so a
            // press there would fall through to the window-drag handle behind
            // a top bar and move the window. The shape keeps it on the box.
            .contentShape(RoundedRectangle(cornerRadius: ChorusCard.cornerRadius, style: .continuous))
            // The box's own spot takes nothing, but listing its type here
            // keeps the window registered for it from before a drag starts,
            // when the targets elsewhere are not drawn yet.
            .onDrop(of: [LiveReorder.globalBoxType], delegate: GlobalBoxRefusal())
            .overlay(dragSource)
    }

    private var dragSource: some View {
        RowDragSource(
            id: GlobalBoxDrag.id,
            type: LiveReorder.globalBoxType,
            ending: GlobalBoxDrag(),
            onDragStart: {
                let drag = RailDragState.shared
                drag.reset()
                drag.globalBoxDragging = true
            },
            preview: { GroupDragPreview(services: services) }
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The end of a box drag. A target that took it has already saved the new
/// spot; whatever the end, the targets go away.
struct GlobalBoxDrag: RailDragEnding {
    /// What the drag carries. There is one box, so nothing reads it.
    static let id = UUID()

    func dragEnded(_ end: RailDragEnd) {
        RailDragState.shared.reset()
    }
}

/// The box over its own spot: letting go there leaves it where it is.
private struct GlobalBoxRefusal: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool { false }
    func performDrop(info: DropInfo) -> Bool { false }
}

/// A spot the box can be let go on, at one end of a rail, a strip or a bar.
/// Draws and takes nothing until the box is being dragged; then it is a thin
/// accent bar across the list, the colour a group's box lights in, which
/// darkens while the box is over it. Letting go there moves the box.
struct GlobalSpotDropTarget: View {
    let spot: GlobalSpot
    /// The direction of the list it sits in. The bar runs across it.
    let axis: Axis

    @State private var isTargeted = false
    private var drag: RailDragState { .shared }

    /// The bar's thickness, and the room the target takes along the list:
    /// a row's height, so it is easy to hit.
    private static let thickness: CGFloat = 3
    private static let length: CGFloat = ServiceRowView.rowHeight

    var body: some View {
        if drag.globalBoxDragging {
            indicator
                .contentShape(Rectangle())
                .onDrop(
                    of: [LiveReorder.globalBoxType],
                    delegate: GlobalSpotDropDelegate(spot: spot) { isTargeted = $0 }
                )
                .accessibilityHidden(true)
        }
    }

    /// The bar, centred in a slot a row long, the full width of the list.
    @ViewBuilder
    private var indicator: some View {
        let bar = Capsule().fill(.tint).opacity(isTargeted ? 1 : 0.35)
        if axis == .vertical {
            bar.frame(height: Self.thickness)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: Self.length)
        } else {
            bar.frame(width: Self.thickness)
                .padding(.vertical, 8)
                .frame(maxHeight: .infinity)
                .frame(width: Self.length)
        }
    }
}

/// Saves the spot a box drag is let go on.
private struct GlobalSpotDropDelegate: DropDelegate {
    let spot: GlobalSpot
    let setTargeted: @MainActor (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [LiveReorder.globalBoxType])
    }

    func dropEntered(info: DropInfo) { setTargeted(true) }
    func dropExited(info: DropInfo) { setTargeted(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        setTargeted(false)
        GlobalPlacement.choose(spot)
        RailDragState.shared.globalBoxDragging = false
        return true
    }
}
