import SwiftUI
import Observation
import UniformTypeIdentifiers

/// The plumbing the rails depend on: window dragging, reorder maths, the live
/// drag-and-drop reorder, the rail's width and its resize handles, and when to
/// draw keyboard focus. It lives in its own file so a rebuild of a rail view
/// cannot take it down with the view it happened to sit in.

enum ServiceReorderPlacement {
    case before
    case after
}

/// Sets whether the user can move the window by dragging its background.
///
/// With `.windowStyle(.hiddenTitleBar)` the top of the window stays a title-bar
/// drag band, 52 points tall since `TrafficLightsPositioner` grew it. In the
/// bar layout the rail sits in that band, so a click-drag on a tab was grabbed
/// by the window move before the tab's reorder drag could start — the window
/// slid instead of the tab reordering. A view nested in a
/// SwiftUI `ScrollView` can't opt out of that drag (the scroll view
/// short-circuits AppKit hit-testing, so a `mouseDownCanMoveWindow == false`
/// nested view is never consulted).
///
/// So we turn the OS window drag off for that layout and hand dragging to
/// explicit `WindowDragHandle`s instead (Chrome's model). The sidebar layout,
/// whose rail doesn't hold draggable tabs in the band, keeps the normal drag.
struct WindowMovableConfigurator: NSViewRepresentable {
    let isMovable: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        applyWhenAttached(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyWhenAttached(to: nsView)
    }

    private func applyWhenAttached(to view: NSView) {
        let isMovable = isMovable
        DispatchQueue.main.async {
            view.window?.isMovable = isMovable
        }
    }
}

/// A transparent strip that moves the window on click-drag, the way Chrome lets
/// you drag the empty part of its tab strip. Used to fill the reserved gap in
/// the top bar, where the OS window drag is off (see
/// `WindowMovableConfigurator`). A double-click zooms, matching a title bar.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                window.performZoom(nil)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

enum SpaceMove {
    /// The spaces a service can be moved into: every space except the ones it
    /// already belongs to. Moving into a space it's already in would just
    /// double-link it, and the current space is one of those memberships, so
    /// this naturally leaves it out too. Order follows `allSpaceIDs` (the
    /// sorted space list).
    static func eligibleSpaceIDs(allSpaceIDs: [UUID], memberSpaceIDs: Set<UUID>) -> [UUID] {
        allSpaceIDs.filter { !memberSpaceIDs.contains($0) }
    }
}

enum ServiceReorder {
    static func reorderedIDs(
        _ ids: [UUID],
        moving droppedID: UUID,
        relativeTo targetID: UUID,
        placement: ServiceReorderPlacement
    ) -> [UUID]? {
        guard droppedID != targetID,
              let fromIndex = ids.firstIndex(of: droppedID),
              let targetIndex = ids.firstIndex(of: targetID) else {
            return nil
        }

        var reordered = ids
        let moved = reordered.remove(at: fromIndex)

        var toIndex = targetIndex
        if placement == .after {
            toIndex += 1
        }
        if fromIndex < toIndex {
            toIndex -= 1
        }
        guard fromIndex != toIndex else {
            return nil
        }

        reordered.insert(moved, at: toIndex)
        return reordered
    }
}

/// Places a service membership in an ordered target group. Unlike
/// `ServiceReorder`, the moving id may come from another group and therefore
/// may not be present in `targetIDs` yet.
enum ServicePlacement {
    static func orderedIDs(
        _ targetIDs: [UUID],
        moving droppedID: UUID,
        relativeTo targetID: UUID?,
        placement: ServiceReorderPlacement
    ) -> [UUID]? {
        guard targetID != droppedID else { return nil }

        var reordered = targetIDs.filter { $0 != droppedID }
        let insertionIndex: Int
        if let targetID {
            guard let targetIndex = reordered.firstIndex(of: targetID) else { return nil }
            insertionIndex = placement == .after ? targetIndex + 1 : targetIndex
        } else {
            insertionIndex = 0
        }

        reordered.insert(droppedID, at: insertionIndex)
        return reordered == targetIDs ? nil : reordered
    }
}

/// Whether the rail draws service names, and where that answer is kept.
///
/// This is chrome visibility rather than user data, so it lives in defaults
/// instead of `AppPreferences`: a stored property there is a new schema version
/// and a migration (see CLAUDE.md), which a cosmetic toggle does not earn.
enum ServiceNameVisibility {
    static let defaultsKey = "showServiceNames"
}

/// The width of the space strip in the hybrid layout, and what that width
/// means.
///
/// The strip has two widths rather than a dragged range: it is 40-odd points
/// of chrome, the useful range is short, and the two widths that matter are
/// the two ends of it. Dragging its edge (`RailWidthHandle`) switches between
/// them, as the setting does.
enum SpaceStripMetrics {
    static let defaultsKey = "showSpaceNames"

    /// Wide enough to read a name beside the emoji.
    static let namedWidth: CGFloat = 180
    /// The emoji on their own.
    static let compactWidth: CGFloat = 52

    static func width(showingNames: Bool) -> CGFloat {
        showingNames ? namedWidth : compactWidth
    }

    /// The gap between spaces. The 32 point emoji tiles sit 40 points apart,
    /// the pitch of the 36 point service tabs in the bar beside them, so the
    /// two rows of icons read alike; the named rows keep the 2 of the service
    /// rows they are laid out like.
    static func spacing(showingNames: Bool) -> CGFloat {
        showingNames ? 2 : 8
    }

    /// How far the window's traffic lights reach in from the leading edge,
    /// with room after them. Centred in the 52 point band, they end at x 73.
    static let trafficLightsWidth: CGFloat = 82

    /// Leading inset the service bar needs so the window's traffic lights,
    /// which sit over the strip, do not land on the first tab. The lights are
    /// 82 points wide; the named strip swallows them whole and the bar starts
    /// flush, while the compact one leaves 30 points of them overhanging.
    static func barLeadingInset(stripWidth: CGFloat, lightsWidth: CGFloat) -> CGFloat {
        Swift.max(0, lightsWidth - stripWidth)
    }
}

/// Whether keyboard focus should be drawn, the way browsers answer
/// `:focus-visible`. A key press turns the marks on and a click turns them
/// off, so the ring that SwiftUI's first-responder pass put on the first rail
/// row at launch no longer shows until the keyboard is in use.
@MainActor
@Observable
final class FocusVisibility {
    static let shared = FocusVisibility()

    private(set) var isVisible = false
    @ObservationIgnored private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            let visible = FocusVisibility.visibility(after: event.type, modifiers: event.modifierFlags)
            MainActor.assumeIsolated {
                if let visible, FocusVisibility.shared.isVisible != visible {
                    FocusVisibility.shared.isVisible = visible
                }
            }
            return event
        }
    }

    /// What an event means for the marks: on after a key, off after a click,
    /// and no change for anything else. A Command or Control shortcut is not
    /// moving around the rail, so it leaves the marks alone, as browsers do;
    /// Option stays, since Option-arrow reorders a row.
    nonisolated static func visibility(after type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) -> Bool? {
        switch type {
        case .keyDown:
            return modifiers.intersection([.command, .control]).isEmpty ? true : nil
        case .leftMouseDown, .rightMouseDown: return false
        default: return nil
        }
    }
}

/// Spaces and services reorder live while you drag one: as the pointer
/// enters another row's slot, the dragged row moves into it, and the order is
/// saved as it goes. The old drop-to-place version decided before or after
/// from where the drop landed, and a drag downward never reached its drop
/// handler.
///
/// Each drag carries a type of Chorus's own, which no other app reads, so a
/// link or a file dragged over the rail can never move anything, and a space
/// drag and a service drag never mistake each other.
enum LiveReorder {
    static let spaceType = UTType(exportedAs: "com.nicojan.chorus.space-id")
    static let serviceType = UTType(exportedAs: "com.nicojan.chorus.service-link-id")
    /// A global service, by its service id: it has no membership link.
    static let globalServiceType = UTType(exportedAs: "com.nicojan.chorus.global-service-id")
    /// A divider, by its id. Started from AppKit rather than `onDrag`, since
    /// removing one depends on knowing where the drag ended. See
    /// `RailDividerDragSource`.
    static let dividerType = UTType(exportedAs: "com.nicojan.chorus.divider-id")
    /// A service group, by its id, dragged by its box: the whole run moves.
    static let groupType = UTType(exportedAs: "com.nicojan.chorus.service-group-id")

    /// The order after `dragged` takes the slot of `target`: it lands after
    /// the target when it came from above, and before it when it came from
    /// below. Nil when nothing would move.
    static func moving(_ dragged: UUID, over target: UUID, in ids: [UUID]) -> [UUID]? {
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target)
        else { return nil }
        var moved = ids
        moved.remove(at: from)
        moved.insert(dragged, at: to)
        return moved
    }

    /// What a drag carries: an id, under one of the Chorus-only types.
    /// The data goes in whole rather than through a loader callback: Xcode
    /// 16's SDK takes that callback as main-actor bound and will not compile
    /// it. The payload is only an id under a type nothing outside Chorus reads.
    nonisolated static func itemProvider(for id: UUID, type: UTType) -> NSItemProvider {
        NSItemProvider(item: Data(id.uuidString.utf8) as NSData, typeIdentifier: type.identifier)
    }
}

/// What is being dragged in any rail, shared by all of them. A rail row only
/// learns what is being dragged from here: the payload is an id under a
/// Chorus type, read as the drag starts rather than through a loader callback
/// (see `LiveReorder.itemProvider`). Keeping it per view meant a service
/// dragged from the hybrid bar could not land in the space strip beside it,
/// which is a different view that never saw the drag start.
@MainActor
@Observable
final class RailDragState {
    static let shared = RailDragState()
    var linkID: UUID?
    var globalID: UUID?
    var dividerID: UUID?
    /// The divider's list as it stood when its drag began, put back if
    /// Escape ends the drag, since the moves along the way are saved live.
    var dividerStartOrder: [UUID] = []
    var spaceID: UUID?
    /// The group whose box is being dragged.
    var groupID: UUID?
    /// Every list a service drag can change, as it stood when the drag began:
    /// the dragged row's own list and the global group. Escape puts them back
    /// (`RailEdits.restore`), since the moves along the way are saved live.
    var startSnapshot: [RailScope: [GroupEntry]] = [:]
    /// Set when a target refused the release (`performDrop` returned false),
    /// so the drag's end cancels instead of counting a release over the rail
    /// as a move. Cleared by `reset()`.
    var dropRefused = false
    /// The row the pointer has rested on long enough to group with.
    var pausedTargetID: UUID?
    /// The group whose box is lit, so a drop there joins it.
    var litGroupID: UUID?
    /// Which part of each row the pointer was last over, by row id.
    var zones: [UUID: GroupDrag.Zone] = [:]
    /// The wait before a row under the pointer becomes `pausedTargetID`.
    var pauseTask: Task<Void, Never>?
    /// The row `pauseTask` is waiting on.
    var pausingRowID: UUID?
    /// The wait before a drag resting on the space header opens the palette.
    var springTask: Task<Void, Never>?

    private init() {}

    /// Starts the wait on a row's middle, unless that row is already the
    /// target or already being waited on. Only one row waits at a time.
    func startPause(on rowID: UUID) {
        guard pausedTargetID != rowID, pausingRowID != rowID else { return }
        pauseTask?.cancel()
        pausedTargetID = nil
        pausingRowID = rowID
        pauseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: GroupDrag.pauseBeforeGrouping)
            guard !Task.isCancelled, let self, self.pausingRowID == rowID else { return }
            self.pausingRowID = nil
            self.pauseTask = nil
            self.pausedTargetID = rowID
        }
    }

    /// The pointer left a row's middle: its wait stops and it is no longer
    /// the target. Another row's wait is left alone, since the row being left
    /// can report it after the next one has begun.
    func endPause(on rowID: UUID) {
        if pausingRowID == rowID {
            pauseTask?.cancel()
            pauseTask = nil
            pausingRowID = nil
        }
        if pausedTargetID == rowID { pausedTargetID = nil }
    }

    /// Stops a wait that has not finished, leaving a row the pause already
    /// made the target as it is. A release calls it.
    func stopWaiting() {
        pauseTask?.cancel()
        pauseTask = nil
        pausingRowID = nil
    }

    /// Runs `open` once the drag has rested for `GroupDrag.pauseBeforeGrouping`,
    /// unless `stopSpring` comes first.
    func startSpring(_ open: @escaping @MainActor () -> Void) {
        springTask?.cancel()
        springTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: GroupDrag.pauseBeforeGrouping)
            guard !Task.isCancelled else { return }
            self?.springTask = nil
            open()
        }
    }

    func stopSpring() {
        springTask?.cancel()
        springTask = nil
    }

    /// Lights a group's box, or puts out the lit one for nil.
    func light(_ groupID: UUID?) {
        if litGroupID != groupID { litGroupID = groupID }
    }

    /// Puts out a group's box if it is the lit one.
    func unlight(_ groupID: UUID) {
        if litGroupID == groupID { litGroupID = nil }
    }

    /// Clears every drag field. The drag source's end handler calls it once
    /// per drag, however the drag ended (see `RailDragEnding`).
    func reset() {
        linkID = nil
        globalID = nil
        dividerID = nil
        dividerStartOrder = []
        spaceID = nil
        groupID = nil
        startSnapshot = [:]
        dropRefused = false
        pausedTargetID = nil
        litGroupID = nil
        zones = [:]
        pauseTask?.cancel()
        pauseTask = nil
        pausingRowID = nil
        stopSpring()
    }
}

/// The drop side of `LiveReorder`, put on each row. A row lists the kinds of
/// drag it takes, one `Lane` each: a space's heading in the all-services rail
/// takes a space (to reorder spaces) and a service (to move it into that
/// space). `move` runs as a drag of its kind moves over the row, for the moves
/// that are shown live; `drop` runs on release, for a move that must not
/// happen until then, such as a service going into another space, which a
/// cancelled drag must not leave behind.
///
/// A row that knows its `length` along the list is split into parts
/// (`GroupDrag.zone`): its two ends move the dragged entry before or after it,
/// and resting on its middle for `GroupDrag.pauseBeforeGrouping` makes it the
/// row a drop groups with (`RailDragState.pausedTargetID`). A row with no
/// length, such as a space's heading, takes the dragged entry's slot as the
/// drag enters it, and `move` gets no zone.
struct LiveReorderDropDelegate: DropDelegate {
    struct Lane {
        let type: UTType
        /// What is being dragged, read when it is needed rather than copied
        /// when the row was drawn, so a finished drag's id is never used.
        let draggingID: () -> UUID?
        /// Nil zone: the row has no length, so the entry takes its slot.
        var move: ((_ dragged: UUID, _ zone: GroupDrag.Zone?) -> Void)? = nil
        /// Whether the row took the drop. Nil means the live moves were all
        /// there was to do.
        var drop: ((_ dragged: UUID) -> Bool)? = nil
        /// Whether `dragged` may group with this row: a service of the same
        /// space. Nil, or false, and the row's middle neither swells nor
        /// lights its box.
        var groups: ((_ dragged: UUID) -> Bool)? = nil
        /// Whether the row takes `dragged` at all. False and the drag makes
        /// no move over it, and a release there is refused, so the drag goes
        /// back as for Escape.
        var accepts: ((_ dragged: UUID) -> Bool)? = nil
    }

    let lanes: [Lane]
    /// The row's id, which a pause makes the target. Nil for a row that is
    /// not a service.
    var rowID: UUID? = nil
    var axis: Axis = .vertical
    /// The row's length along the list, or nil when it is not measured.
    var length: CGFloat? = nil
    /// The group box the row is drawn in, lit while a service that may join
    /// it is over the row.
    var box: Box? = nil

    /// A group's box, and whether a dragged service may join it: one of its
    /// space that sits in its run or right next to either end.
    struct Box {
        let id: UUID
        let takes: (_ dragged: UUID) -> Bool
    }

    private var drag: RailDragState { .shared }

    private func lane(for info: DropInfo) -> Lane? {
        Self.lane(in: lanes) { info.hasItemsConforming(to: [$0]) }
    }

    /// The lane that takes the drag, or nil when no lane is of its kind or
    /// the one that is refuses it.
    static func lane(in lanes: [Lane], conformsTo conforms: (UTType) -> Bool) -> Lane? {
        guard let lane = lanes.first(where: { conforms($0.type) }) else { return nil }
        if let accepts = lane.accepts {
            guard let dragged = lane.draggingID(), accepts(dragged) else { return nil }
        }
        return lane
    }

    /// Whether the row takes part in a drag of this kind at all. A lane that
    /// refuses still does, so the release reaches `performDrop`, which flags
    /// the refusal and the drag goes back. Left out, the release would count
    /// as one over a gap and keep the live moves.
    static func validates(_ lanes: [Lane], conformsTo conforms: (UTType) -> Bool) -> Bool {
        lanes.contains { conforms($0.type) }
    }

    func validateDrop(info: DropInfo) -> Bool {
        Self.validates(lanes) { info.hasItemsConforming(to: [$0]) }
    }

    func dropEntered(info: DropInfo) {
        track(info, entering: true)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info, entering: false)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard let rowID else { return }
        drag.zones[rowID] = nil
        drag.endPause(on: rowID)
        if let box { drag.unlight(box.id) }
    }

    func performDrop(info: DropInfo) -> Bool {
        // Only a swell already showing groups: AppKit reports the drag's end
        // a moment after the release, and a wait must not finish in between.
        drag.stopWaiting()
        guard let lane = lane(for: info), let dragged = lane.draggingID() else {
            drag.dropRefused = true
            return false
        }
        // The row left last may have put the box out after this row lit it,
        // so the box at the release is decided again here.
        if rowID != nil { relight(lane, dragged) }
        let taken = lane.drop?(dragged) ?? true
        if !taken { drag.dropRefused = true }
        return taken
    }

    private func track(_ info: DropInfo, entering: Bool) {
        guard let lane = lane(for: info), let dragged = lane.draggingID() else { return }
        guard let rowID else {
            if entering { lane.move?(dragged, nil) }
            return
        }
        // A row built again mid-drag has no length until it is measured. Wait
        // for it rather than fall back to taking the slot.
        guard let length, length > 0 else { return }
        let groups = relight(lane, dragged)
        guard dragged != rowID else { return }

        let previous = drag.zones[rowID]
        let offset = axis == .vertical ? info.location.y : info.location.x
        let zone = GroupDrag.zone(at: offset, length: length, current: previous)
        if zone != previous { drag.zones[rowID] = zone }
        switch zone {
        case .before, .after:
            drag.endPause(on: rowID)
            lane.move?(dragged, zone)
        case .middle:
            if groups, previous != .middle { drag.startPause(on: rowID) }
        }
    }

    /// The box lights for a service that could join it, and a row outside any
    /// box puts it out. Returns whether the dragged entry may group here.
    @discardableResult
    private func relight(_ lane: Lane, _ dragged: UUID) -> Bool {
        let groups = lane.groups?(dragged) ?? false
        if groups { drag.light(box.flatMap { $0.takes(dragged) ? $0.id : nil }) }
        return groups
    }
}

/// Puts the drop delegate on a row, with the row's length along `axis`
/// measured as it is laid out.
private struct ZonedReorderDrop: ViewModifier {
    let lanes: [LiveReorderDropDelegate.Lane]
    let rowID: UUID
    let axis: Axis
    let box: LiveReorderDropDelegate.Box?
    @State private var length: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // A GeometryReader rather than `onGeometryChange`, as the rest of
            // the rail measures, which every supported Xcode builds.
            .background(
                GeometryReader { proxy in
                    Color.clear.onChange(of: axis == .vertical ? proxy.size.height : proxy.size.width, initial: true) { _, new in
                        length = new
                    }
                }
            )
            .onDrop(
                of: lanes.map(\.type),
                delegate: LiveReorderDropDelegate(lanes: lanes, rowID: rowID, axis: axis, length: length, box: box)
            )
    }
}

extension View {
    /// Makes this row a live-reorder drop target for the given lanes. It
    /// takes the dragged entry's slot as the drag enters it.
    func liveReorderDrop(_ lanes: [LiveReorderDropDelegate.Lane]) -> some View {
        onDrop(of: lanes.map(\.type), delegate: LiveReorderDropDelegate(lanes: lanes))
    }

    /// Makes this service row a live-reorder drop target split into parts:
    /// its ends move the dragged entry past it, and a pause on its middle
    /// groups. `box` is the group box the row is drawn in.
    func liveReorderDrop(
        _ lanes: [LiveReorderDropDelegate.Lane],
        row rowID: UUID,
        axis: Axis,
        box: LiveReorderDropDelegate.Box?
    ) -> some View {
        modifier(ZonedReorderDrop(lanes: lanes, rowID: rowID, axis: axis, box: box))
    }

    /// The box's own drop target, for its padding, its name and the gaps
    /// between its rows: a service that may join lights it there, and leaving
    /// the box puts it out. The rows inside take their own drags.
    func groupBoxDrop(_ box: LiveReorderDropDelegate.Box, draggingID: @escaping () -> UUID?) -> some View {
        onDrop(of: [LiveReorder.serviceType], delegate: GroupBoxDropDelegate(box: box, draggingID: draggingID))
    }
}

/// Opens something when a drag rests on it, the way Finder opens a folder:
/// the space header opens the palette, so a group can be let go on a space
/// that lives there. It takes no drop itself.
struct SpringLoadDropDelegate: DropDelegate {
    let types: [UTType]
    let open: @MainActor () -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: types) }
    func dropEntered(info: DropInfo) { RailDragState.shared.startSpring(open) }
    func dropExited(info: DropInfo) { RailDragState.shared.stopSpring() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        RailDragState.shared.stopSpring()
        RailDragState.shared.dropRefused = true
        return false
    }
}

/// See `groupBoxDrop`. A release here is taken, and the drag's end decides
/// what it means from the lit box.
struct GroupBoxDropDelegate: DropDelegate {
    let box: LiveReorderDropDelegate.Box
    let draggingID: () -> UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [LiveReorder.serviceType])
    }

    func dropEntered(info: DropInfo) { track() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        track()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        RailDragState.shared.unlight(box.id)
    }

    func performDrop(info: DropInfo) -> Bool {
        RailDragState.shared.stopWaiting()
        // A row's exit may have put the box out after this lit it.
        track()
        return true
    }

    private func track() {
        guard let dragged = draggingID() else { return }
        if box.takes(dragged) {
            RailDragState.shared.light(box.id)
        } else {
            RailDragState.shared.unlight(box.id)
        }
    }
}

/// The strip in the gap between a rail and the web card. Dragging it right
/// shows the rail's names and widens it, dragging it left hides them and
/// narrows it, the same as the setting in Settings. The rail has the two
/// widths only, so the drag switches between them once it has gone far
/// enough, and switches back if it returns within the same drag.
struct RailWidthHandle: View {
    @Binding var showsNames: Bool
    /// Room left at the top, so the handle stays out of the band the traffic
    /// lights and the nav row share.
    var topInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether names were on when this drag began.
    @State private var namesAtStart: Bool?

    static let width: CGFloat = ChorusCard.gutter
    /// How far the pointer has to travel before the rail changes width.
    nonisolated static let threshold: CGFloat = 36

    var body: some View {
        Color.clear
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .padding(.top, topInset)
            .resizeCursor()
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = namesAtStart ?? showsNames
                        namesAtStart = start
                        let target = Self.showsNames(startingFrom: start, dragged: value.translation.width)
                        guard target != showsNames else { return }
                        withAnimation(ChorusMotion.animation(ChorusMotion.sidebar, reduceMotion: reduceMotion)) {
                            showsNames = target
                        }
                    }
                    .onEnded { _ in namesAtStart = nil }
            )
            .help(showsNames ? "Drag left to hide names" : "Drag right to show names")
            .accessibilityHidden(true)
    }

    /// Names on or off after a drag of `dragged` points from a rail that
    /// started with `start`.
    nonisolated static func showsNames(startingFrom start: Bool, dragged: CGFloat) -> Bool {
        start ? dragged > -threshold : dragged > threshold
    }
}

/// The service rail's width. With names it can be any width from `minNamed`
/// to `maxNamed`, set by dragging its edge; below `collapseBelow` it gives up
/// its names and shrinks to the icon column, and a drag back out past
/// `expandAbove` brings them back. The named width is kept in UserDefaults
/// beside the names switch, so the Settings switch goes between the icons and
/// the width you left it at.
enum RailWidth {
    static let defaultsKey = "railNamedWidth"
    /// Room for an icon, a short name and a count.
    static let minNamed: CGFloat = 150
    static let maxNamed: CGFloat = 300
    /// `ServiceRowView.railWidth`, written out: a View's statics are main-actor
    /// isolated and these are not. A test holds the two together.
    static let defaultNamed: CGFloat = 240
    /// Where the edge has to be pulled to give up the names: 50 points past
    /// the narrowest named width, so it is a deliberate pull and not the end of
    /// a resize.
    static let collapseBelow: CGFloat = 100
    /// Where it has to be pushed to bring them back. Above `collapseBelow`, so
    /// the two never overlap: between them the rail stays as it is, and it
    /// cannot flip back and forth as the pointer wavers.
    static let expandAbove: CGFloat = 125

    static func clampNamed(_ width: CGFloat) -> CGFloat {
        Swift.min(Swift.max(width, minNamed), maxNamed)
    }

    /// Where a drag that puts the rail's edge at `proposed` leaves it: names on
    /// or off, and the named width when they are on.
    static func resolve(proposed: CGFloat, namesOn: Bool) -> (namesOn: Bool, namedWidth: CGFloat?) {
        if namesOn {
            return proposed < collapseBelow ? (false, nil) : (true, clampNamed(proposed))
        }
        return proposed > expandAbove ? (true, clampNamed(proposed)) : (false, nil)
    }
}

private struct RailWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = RailWidth.defaultNamed
}

extension EnvironmentValues {
    /// The width the vertical service rail takes from the window, gutter
    /// included. Rows, headers and headings size themselves from it.
    var railWidth: CGFloat {
        get { self[RailWidthKey.self] }
        set { self[RailWidthKey.self] = newValue }
    }
}

/// The strip in the gap between the service rail and the web card. Dragging
/// it resizes the rail live; past the narrowest named width the rail shrinks
/// to its icons with the chrome's sidebar animation, and back out again the
/// same way. See `RailWidth`.
struct RailResizeHandle: View {
    @Binding var showsNames: Bool
    @Binding var namedWidth: Double
    /// Room left at the top. See `RailWidthHandle.topInset`.
    var topInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The rail's width when this drag began.
    @State private var startWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: ChorusCard.gutter)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .padding(.top, topInset)
            .resizeCursor()
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? (showsNames ? RailWidth.clampNamed(CGFloat(namedWidth)) : ServiceRowView.compactRailWidth)
                        startWidth = start
                        let result = RailWidth.resolve(proposed: start + value.translation.width, namesOn: showsNames)
                        if result.namesOn != showsNames {
                            withAnimation(ChorusMotion.animation(ChorusMotion.sidebar, reduceMotion: reduceMotion)) {
                                if let width = result.namedWidth {
                                    namedWidth = Double(width)
                                } else if start >= RailWidth.minNamed {
                                    // Going to icons keeps the width this drag
                                    // began at, not the narrowest one the pull
                                    // passed on the way, so the names come back
                                    // at the width you had.
                                    namedWidth = Double(start)
                                }
                                showsNames = result.namesOn
                            }
                        } else if let width = result.namedWidth, Double(width) != namedWidth {
                            // Follows the pointer: no animation, or it lags.
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { namedWidth = Double(width) }
                        }
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .help(showsNames ? "Drag to resize. Pull it far to the left for icons only." : "Drag to the right to show names.")
            .accessibilityHidden(true)
    }
}

/// Shows the left-right resize arrow over a handle. It keeps count of its own
/// push, so a hover-out that never comes (the handle rebuilt or gone while the
/// pointer was on it) cannot leave the arrow stuck over the rest of the window.
private struct ResizeCursor: ViewModifier {
    @State private var isPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !isPushed {
                    NSCursor.resizeLeftRight.push()
                    isPushed = true
                } else if !inside, isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
            .onDisappear {
                if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
    }
}

extension View {
    fileprivate func resizeCursor() -> some View {
        modifier(ResizeCursor())
    }
}

/// A vertical list that softens its top or bottom edge while more of the list
/// lies past it. A rail longer than the window ran under the add buttons and
/// was cut mid-row, which reads as broken rather than as a list that scrolls.
/// At either end of the list that edge stays sharp, so the first and last rows
/// show in full.
struct FadingVerticalScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    @State private var viewportHeight: CGFloat = 0
    @State private var contentFrame: CGRect = .zero

    private static var fadeHeight: CGFloat { 24 }
    private static var space: String { "FadingVerticalScrollView" }

    var body: some View {
        // Measured with `onChange(of:initial:)` rather than a preference: an
        // `onPreferenceChange` action is not main-actor isolated under Swift 6.
        ScrollView(.vertical, showsIndicators: false) {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.frame(in: .named(Self.space)), initial: true) { _, frame in
                            contentFrame = frame
                        }
                    }
                )
        }
        .coordinateSpace(name: Self.space)
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                    viewportHeight = height
                }
            }
        )
        .mask {
            VStack(spacing: 0) {
                edgeFade(fadesTop, from: .top)
                Rectangle()
                edgeFade(fadesBottom, from: .bottom)
            }
        }
    }

    /// One point of slack so a list that sits exactly at an end, give or take
    /// rounding, keeps its sharp edge.
    private var fadesTop: Bool { contentFrame.minY < -1 }
    private var fadesBottom: Bool { contentFrame.maxY > viewportHeight + 1 }

    private func edgeFade(_ fades: Bool, from edge: VerticalEdge) -> some View {
        LinearGradient(
            colors: [.black.opacity(fades ? 0 : 1), .black],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: Self.fadeHeight)
        .animation(.easeOut(duration: 0.15), value: fades)
    }
}
