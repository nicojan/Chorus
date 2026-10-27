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
    /// The most height a column pinned outside its rail's scrolling list may
    /// take, card and all. Past it the rows scroll inside the card, so the
    /// list keeps its room. Nil for no limit. See `GlobalBoxCap`.
    var maxHeight: CGFloat? = nil
    @ViewBuilder let row: (RailItem) -> Row

    /// Rows sit 2 points apart in a column, the rail's 30 point pitch; tabs
    /// sit 4 apart, as the bar's own do.
    private var spacing: CGFloat { axis == .vertical ? 2 : 4 }

    var body: some View {
        if !items.isEmpty {
            fitted
                // Only a reorder animates. See `ReorderKey`.
                .animation(reorderAnimation, value: ReorderKey(ids: items.map(\.id)))
                // Padded on every side so a row's 8 point fill sits inside the
                // card's 14 point corners, the same distance from each edge.
                .padding(ChorusCard.railPadding)
                .railCard()
                .modifier(GlobalBoxDragging(services: items.compactMap(\.service)))
                .modifier(GlobalBoxMenu())
                // One container to VoiceOver, as a group's box is.
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Global services")
        }
    }

    /// The rows, scrolling inside the card once a capped column outgrows its
    /// limit. While they fit, this is the plain stack.
    @ViewBuilder
    private var fitted: some View {
        if axis == .vertical, let maxHeight {
            HeightCap(height: max(0, maxHeight - 2 * ChorusCard.railPadding)) {
                ViewThatFits(in: .vertical) {
                    stack
                    FadingVerticalScrollView { stack }
                }
            }
        } else {
            stack
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

/// How tall a global box pinned outside its rail's scrolling list may grow.
enum GlobalBoxCap {
    /// The share of its rail's height a pinned column may take.
    static let pinnedShare: CGFloat = 0.4

    /// The limit for a column pinned in a rail `railHeight` tall, or nil
    /// before the rail has been measured.
    static func height(forRail railHeight: CGFloat) -> CGFloat? {
        railHeight > 0 ? railHeight * pinnedShare : nil
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
            // The box's own spot takes nothing. Kept as a precaution, so the
            // window knows the type before the drag starts, while the targets
            // elsewhere are not drawn yet; harmless if not needed.
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

/// The box's own menu: where the global services sit. It goes on the card, so
/// a right-click on a row inside still shows that row's menu.
private struct GlobalBoxMenu: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.contextMenu {
            GlobalPlacementMenu(layout: appState.railLayout)
        }
    }
}

/// "Move Global Services": the spots a layout offers, the current one
/// ticked. The box's menu shows it, and so does each global service's own,
/// since VoiceOver and the keyboard reach a row's menu but not the card's.
struct GlobalPlacementMenu: View {
    let layout: RailLayout
    @AppStorage(GlobalPlacement.edgeKey) private var edgeRaw = GlobalEdge.start.rawValue
    @AppStorage(GlobalPlacement.barKey) private var barRaw = GlobalBar.spaces.rawValue

    init(layout: RailLayout) {
        self.layout = layout
    }

    var body: some View {
        let here = GlobalPlacement(edgeRaw: edgeRaw, barRaw: barRaw).spot(in: layout)
        Menu("Move Global Services") {
            ForEach(GlobalPlacement.pickerChoices(for: layout), id: \.spot) { choice in
                Toggle(choice.title, isOn: Binding(
                    get: { choice.spot == here },
                    set: { _ in GlobalPlacement.choose(choice.spot) }
                ))
            }
        }
    }
}

/// Proposes its one subview no more than `height`, and takes the size the
/// subview chooses. Unlike a `frame(maxHeight:)`, it never grows past the
/// subview, so a column that fits looks as it did without the cap.
private struct HeightCap: Layout {
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(capped(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width, height: min(proposal.height ?? .infinity, height))
    }
}

extension View {
    /// Writes this view's laid-out height into `height` as it changes. A
    /// GeometryReader rather than `onGeometryChange`, as the rest of the rail
    /// measures.
    func measuringHeight(into height: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, new in
                    height.wrappedValue = new
                }
            }
        )
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
