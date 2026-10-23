import AppKit
import SwiftUI

/// A divider in a rail list: a hairline the user drags to move, and drags off
/// the rail to remove, the way an item comes off the Dock.
///
/// Removal hangs on knowing where a drag ended, and SwiftUI's `onDrag` never
/// says: it has no callback for the end of a drag at all. So the drag is
/// started from AppKit (`RailDividerDragSource`), whose
/// `draggingSession(_:endedAt:operation:)` does. It carries one pasteboard
/// type, `LiveReorder.dividerType`, which nothing outside Chorus reads, so no
/// other app or web page can take the drop. The rows it crosses reorder live
/// through the same `LiveReorderDropDelegate` lanes as services and spaces.
struct RailDividerView: View {
    let dividerID: UUID
    /// The direction the list runs. A vertical list draws a horizontal line.
    var axis: Axis = .vertical
    /// Length of the line across the list, for a vertical one. Nil fills it.
    var length: CGFloat? = nil
    /// Called as a drag of this divider starts, so the rows it crosses know
    /// what is moving.
    let onDragStart: () -> Void
    /// Removes the divider. Called when it is dragged off the rail and let go,
    /// from its context menu, and from VoiceOver.
    let onRemove: () -> Void
    /// Moves it one place up or down the list, for VoiceOver.
    let onMove: (_ forward: Bool) -> Void
    /// Whether this divider is the one being dragged. It then draws as a
    /// solid accent bar in the slot it would land in, so the eye can follow it
    /// as the rows slide past; a hairline moving is too faint to see.
    var isDragging: Bool = false
    /// Called when a drag of it ends, however it ends.
    var onDragEnd: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The divider's own thickness along the list: room to grab it, while
    /// reading as a line rather than a row.
    static let thickness: CGFloat = 11

    var body: some View {
        line
            .frame(
                width: axis == .vertical ? length : Self.thickness,
                height: axis == .vertical ? Self.thickness : ServiceRowView.tabHeight
            )
            .frame(maxWidth: axis == .vertical && length == nil ? .infinity : nil)
            .contentShape(Rectangle())
            .overlay(
                RailDividerDragSource(
                    dividerID: dividerID,
                    onDragStart: onDragStart,
                    onDragEnd: onDragEnd,
                    onRemove: onRemove
                )
            )
            .animation(ChorusMotion.animation(ChorusMotion.reorder, reduceMotion: reduceMotion), value: isDragging)
            .help("Drag to move. Drag off the rail to remove.")
            .accessibilityElement()
            .accessibilityLabel("Divider")
            .accessibilityAction(named: "Remove divider", onRemove)
            .accessibilityAction(named: "Move up") { onMove(false) }
            .accessibilityAction(named: "Move down") { onMove(true) }
    }

    @ViewBuilder
    private var line: some View {
        let style = isDragging ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(ChorusColor.hairline)
        let weight: CGFloat = isDragging ? 3 : 1
        if axis == .vertical {
            Capsule()
                .fill(style)
                .frame(height: weight)
                .padding(.horizontal, 8)
        } else {
            Capsule()
                .fill(style)
                .frame(width: weight, height: 18)
        }
    }
}

// MARK: - Where the rail is

/// The area a divider can be dragged within without being removed: the rail,
/// bar, strip or palette it belongs to. A container marks its area with
/// `.railDropZone()`, and the divider's drag source asks the zone in its
/// environment whether a point on screen is inside.
@MainActor
final class RailDropZone {
    /// The container's backing view, found by `RailDropZoneMarker`. Weak: the
    /// zone must not keep a torn-down rail's view alive.
    weak var view: NSView?

    /// Whether a point in screen coordinates is over the container, in the
    /// same window. A point over another window is outside even when the two
    /// overlap on screen.
    func contains(screenPoint: NSPoint) -> Bool {
        guard let view, let window = view.window, window.isVisible else { return false }
        // The frontmost window under the point has to be this one: another
        // window lying over the rail is not the rail.
        guard NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber else {
            return false
        }
        let local = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return view.bounds.contains(local)
    }
}

private struct RailDropZoneKey: EnvironmentKey {
    static let defaultValue: RailDropZone? = nil
}

extension EnvironmentValues {
    /// The rail a divider in this subtree belongs to. See `RailDropZone`.
    var railDropZone: RailDropZone? {
        get { self[RailDropZoneKey.self] }
        set { self[RailDropZoneKey.self] = newValue }
    }
}

/// Puts a plain `NSView` behind a container so the zone can measure it.
private struct RailDropZoneMarker: NSViewRepresentable {
    let zone: RailDropZone

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        zone.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        zone.view = nsView
    }

    /// Takes no clicks, so the container behaves as if it were not there.
    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct RailDropZoneModifier: ViewModifier {
    @State private var zone = RailDropZone()

    func body(content: Content) -> some View {
        content
            .background(RailDropZoneMarker(zone: zone))
            .environment(\.railDropZone, zone)
    }
}

extension View {
    /// Marks this view's area as a rail that dividers inside it may be dragged
    /// around without being removed. See `RailDividerView`.
    func railDropZone() -> some View {
        modifier(RailDropZoneModifier())
    }
}

// MARK: - The drag

/// The AppKit half of a divider: starts the drag on a mouse drag, and decides
/// at its end whether the divider came off the rail.
private struct RailDividerDragSource: NSViewRepresentable {
    let dividerID: UUID
    let onDragStart: () -> Void
    let onDragEnd: () -> Void
    let onRemove: () -> Void
    @Environment(\.railDropZone) private var zone

    func makeNSView(context: Context) -> DividerDragView {
        let view = DividerDragView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: DividerDragView, context: Context) {
        update(nsView)
    }

    private func update(_ view: DividerDragView) {
        view.dividerID = dividerID
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        view.onRemove = onRemove
        view.zone = zone
    }
}

final class DividerDragView: NSView, NSDraggingSource {
    var dividerID = UUID()
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onRemove: () -> Void = {}
    var zone: RailDropZone?

    private var mouseDownEvent: NSEvent?
    /// Whether the pointer was off the rail at the drag's last move.
    private var isOutside = false

    /// How far the pointer has to travel before a press becomes a drag, so a
    /// click on a divider does nothing.
    private static let dragThreshold: CGFloat = 3

    // The tab bar runs with the window's own drag off and drags the window from
    // empty space instead (see `WindowMovableConfigurator`). A divider is not
    // empty space: pressing it must start its own drag, not move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let start = convert(down.locationInWindow, from: nil)
        let now = convert(event.locationInWindow, from: nil)
        guard hypot(now.x - start.x, now.y - start.y) >= Self.dragThreshold else { return }
        mouseDownEvent = nil

        let item = NSPasteboardItem()
        item.setData(Data(dividerID.uuidString.utf8), forType: NSPasteboard.PasteboardType(LiveReorder.dividerType.identifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(bounds, contents: dragImage())

        isOutside = false
        onDragStart()
        beginDraggingSession(with: [dragging], event: down, source: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let remove = NSMenuItem(title: "Remove Divider", action: #selector(removeFromMenu), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc private func removeFromMenu() {
        onRemove()
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        let outside = !(zone?.contains(screenPoint: screenPoint) ?? true)
        guard outside != isOutside else {
            if outside { NSCursor.disappearingItem.set() }
            return
        }
        isOutside = outside
        // Off the rail, the pointer takes the cursor the Dock shows over an
        // item about to be removed, and a release there does not slide the
        // divider back to where it came from.
        session.animatesToStartingPositionsOnCancelOrFail = !outside
        if outside {
            NSCursor.disappearingItem.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NSCursor.arrow.set()
        onDragEnd()
        // A drop a row took is a move. A drop nothing took counts as a removal
        // only off the rail: let go over a gap between rows, or press Escape
        // over the rail, and the divider stays. With no zone to ask, keep it.
        guard operation == [], let zone, !zone.contains(screenPoint: screenPoint) else { return }
        onRemove()
    }

    /// The line itself as the drag image, drawn rather than captured: this view
    /// draws nothing, the SwiftUI line is in the hosting view behind it.
    private func dragImage() -> NSImage {
        let size = bounds.size
        return NSImage(size: size, flipped: false) { rect in
            let vertical = size.width >= size.height
            let line = vertical
                ? NSRect(x: 8, y: rect.midY - 1.5, width: max(rect.width - 16, 1), height: 3)
                : NSRect(x: rect.midX - 1.5, y: rect.midY - 9, width: 3, height: 18)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: line, xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
    }
}
