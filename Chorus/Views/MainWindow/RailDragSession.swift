import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - How a drag ended

/// How a rail drag ended, from what AppKit says at its end. Services and
/// dividers both read it.
enum RailDragEnd: Equatable {
    /// A row took it, or it was let go over the rail, a gap included: the
    /// live moves stand.
    case dropped
    /// Escape: the moves made during the drag are undone.
    case cancelled
    /// Let go off the rail with nothing taking it. A divider is removed; a
    /// service or group goes back where it was, as for Escape.
    case endedOffRail

    /// `insideRail` is nil when there is no rail to ask, and then the drag
    /// counts as dropped.
    nonisolated static func classify(dropTaken: Bool, endedByKey: Bool, insideRail: Bool?) -> RailDragEnd {
        if endedByKey { return .cancelled }
        if dropTaken || insideRail ?? true { return .dropped }
        return .endedOffRail
    }

    /// Whether a service or group drag keeps its live moves and makes its one
    /// membership write. A release off the rail that nothing took, over the
    /// web view, outside the window or on a space that refused it, is no move
    /// the user meant, so it goes back like Escape.
    nonisolated var keepsServiceMoves: Bool { self == .dropped }
}

/// What runs when a service drag ends. The rail hands one to each row's drag
/// source; `RailDragSession` keeps it from the drag's start and calls it
/// exactly once, however the drag ends, even when the row that started it has
/// been torn down and built again on the way (a row moving into or out of a
/// group's box does that).
@MainActor
protocol RailDragEnding {
    func dragEnded(_ end: RailDragEnd)
}

/// The rail's end of a service drag. Escape, or a release off the rail that
/// nothing took, puts back every list the drag could have changed, from
/// `RailDragState.startSnapshot`. A drop makes the drag's one membership
/// write: the moves on the way only reorder. Every end then clears the drag
/// state.
struct RailServiceDragEnding: RailDragEnding {
    let appState: AppState
    let animation: Animation?

    func dragEnded(_ end: RailDragEnd) {
        let drag = RailDragState.shared
        if end.keepsServiceMoves {
            finish(drag)
        } else {
            let snapshot = drag.startSnapshot
            if !snapshot.isEmpty {
                withAnimation(animation) { _ = appState.restoreRail(snapshot) }
            }
        }
        drag.reset()
    }

    /// The one write. A row that took the drag into another space or the
    /// global group has asked first, and that question decides; turned down,
    /// the lists go back as the drag found them. A group's box has nothing
    /// more to write, since its live moves keep its run whole. For a service,
    /// a paused-on row groups with the dragged one, and failing that the box
    /// lit at the drop decides whether it is in a group (`RailEdits.finishDrag`).
    private func finish(_ drag: RailDragState) {
        // A release nothing took has no `performDrop` to stop the wait.
        drag.stopWaiting()
        if appState.pendingRailMove(isFromDragOf: drag.linkID, global: drag.globalID, group: drag.groupID) {
            appState.pendingRailMoveRestore = drag.startSnapshot
            return
        }
        guard let linkID = drag.linkID else { return }
        let target = drag.pausedTargetID
        let lit = drag.litGroupID
        withAnimation(animation) {
            if let target {
                _ = appState.groupLink(linkID, onto: target)
            } else {
                _ = appState.finishRailDrag(linkID, litGroup: lit)
            }
        }
    }
}

// MARK: - The drag source

/// Starts service drags from AppKit, so their end is known. SwiftUI's
/// `onDrag` never says when or how a drag ended, and Escape has to put back
/// the moves the drag saved along the way.
///
/// The rows keep their own SwiftUI clicks, menus, hover, focus and
/// accessibility: each carries a `RowDragSourceView` that takes no events at
/// all. This one object watches the app's mouse events instead. A press on a
/// registered view remembers it; the first move 3 points away starts a drag
/// from it, with this object as the source. Being one long-lived object rather
/// than the row's view, it is still there to hear the end when the row has
/// been rebuilt mid-drag.
@MainActor
final class RailDragSession: NSObject, NSDraggingSource {
    static let shared = RailDragSession()

    /// How far the pointer has to travel before a press becomes a drag, so a
    /// click still selects. The same as a divider's.
    private static let dragThreshold: CGFloat = 3

    private let views = NSHashTable<RowDragSourceView>.weakObjects()
    private var monitor: Any?
    /// The press that may become a drag, and the view it landed on.
    private var pending: (view: RowDragSourceView, event: NSEvent)?
    /// The handler of the drag under way, called once at its end.
    private var ending: (any RailDragEnding)?
    /// The rail the drag under way started in, asked at its end whether the
    /// pointer is still over it.
    private var zone: RailDropZone?

    private override init() {}

    func register(_ view: RowDragSourceView) {
        views.add(view)
        installMonitor()
    }

    func unregister(_ view: RowDragSourceView) {
        views.remove(view)
        if pending?.view === view { pending = nil }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            // `NSEvent` is not Sendable, so it cannot come back out of the
            // isolated closure; the decision does.
            let swallow = MainActor.assumeIsolated { RailDragSession.shared.handle(event) }
            return swallow ? nil : event
        }
    }

    /// Whether to swallow the event: only the move that starts a drag.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            pending = nil
            // A press cannot reach this monitor while a drag session runs, so
            // a drag still waiting on its end here is stale: AppKit never
            // reported it. No drop the user made, so it goes back, and later
            // drags start again.
            if let stale = ending {
                ending = nil
                zone = nil
                stale.dragEnded(.cancelled)
            }
            guard !event.modifierFlags.contains(.control) else { return false }
            if let view = sourceView(under: event) { pending = (view, event) }
            return false
        case .leftMouseDragged:
            guard let press = pending, press.view.window === event.window else {
                pending = nil
                return false
            }
            let start = press.event.locationInWindow
            let now = event.locationInWindow
            guard hypot(now.x - start.x, now.y - start.y) >= Self.dragThreshold else { return false }
            pending = nil
            return beginDrag(from: press.view, press: press.event)
        default:
            pending = nil
            return false
        }
    }

    /// The registered view under a press, when nothing is drawn over it: it
    /// has to sit inside whatever the window's own hit test finds there. Where
    /// views overlap, as a group's box does the rows inside it, the smallest
    /// wins, so a press on a row drags the row and one on the box's edge or
    /// name drags the box.
    private func sourceView(under event: NSEvent) -> RowDragSourceView? {
        guard let window = event.window, let content = window.contentView else { return nil }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = content.hitTest(point) else { return nil }
        let under = views.allObjects.filter { view in
            view.window === window
                && view.payload != nil
                && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
                && view.isDescendant(of: hit)
        }
        return under.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    private func beginDrag(from view: RowDragSourceView, press: NSEvent) -> Bool {
        guard let payload = view.payload else { return false }
        let item = NSPasteboardItem()
        item.setData(Data(payload.id.uuidString.utf8), forType: NSPasteboard.PasteboardType(payload.type.identifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = payload.image(view.window?.backingScaleFactor ?? 2) ?? NSImage(size: NSSize(width: 28, height: 28))
        let center = view.convert(press.locationInWindow, from: nil)
        dragging.setDraggingFrame(
            NSRect(
                x: center.x - image.size.width / 2,
                y: center.y - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            ),
            contents: image
        )

        ending = payload.ending
        zone = payload.zone
        payload.onDragStart()
        let session = view.beginDraggingSession(with: [dragging], event: press, source: self)
        // Escape and a release nothing took would otherwise slide the image
        // home first and report the end half a second later, so the list
        // would jump back only after the image had landed.
        session.animatesToStartingPositionsOnCancelOrFail = false
        return true
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Escape ends the drag while the button is still down, and the key
        // press is then the current event. A release never is.
        // Over the rail, a release nothing took (a gap, a box's padding) is
        // still a move; off it, the drag goes back.
        let end = RailDragEnd.classify(
            dropTaken: operation != [],
            endedByKey: NSApp.currentEvent?.type == .keyDown,
            insideRail: zone?.contains(screenPoint: screenPoint)
        )
        let handler = ending
        ending = nil
        zone = nil
        handler?.dragEnded(end)
    }
}

/// What a row's drag carries and how it starts, kept on its source view.
struct RowDragPayload {
    let id: UUID
    let type: UTType
    let ending: any RailDragEnding
    /// The rail the row sits in, from `.railDropZone()`. Nil when there is
    /// none to ask, and then every release counts as over the rail.
    let zone: RailDropZone?
    let onDragStart: @MainActor () -> Void
    let image: @MainActor (_ scale: CGFloat) -> NSImage?
}

/// A view laid over a row that marks it as something to drag. It takes no
/// clicks, draws nothing and is not an accessibility element, so the SwiftUI
/// row under it behaves as if it were not there. See `RailDragSession`.
final class RowDragSourceView: NSView {
    var payload: RowDragPayload?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            RailDragSession.shared.unregister(self)
        } else {
            RailDragSession.shared.register(self)
        }
    }
}

/// Makes a row draggable from AppKit. Put it on the row as
/// `.overlay(RowDragSource(...).allowsHitTesting(false).accessibilityHidden(true))`.
/// The id goes on the pasteboard under `type`, one of `LiveReorder`'s, so the
/// rows' `LiveReorderDropDelegate` lanes read it as before.
struct RowDragSource<Preview: View>: NSViewRepresentable {
    let id: UUID
    let type: UTType
    let ending: any RailDragEnding
    let onDragStart: @MainActor () -> Void
    @ViewBuilder let preview: @MainActor () -> Preview

    func makeNSView(context: Context) -> RowDragSourceView {
        let view = RowDragSourceView()
        view.payload = payload(zone: context.environment.railDropZone)
        return view
    }

    func updateNSView(_ nsView: RowDragSourceView, context: Context) {
        nsView.payload = payload(zone: context.environment.railDropZone)
    }

    private func payload(zone: RailDropZone?) -> RowDragPayload {
        let preview = preview
        return RowDragPayload(id: id, type: type, ending: ending, zone: zone, onDragStart: onDragStart) { scale in
            let renderer = ImageRenderer(content: preview())
            renderer.scale = scale
            return renderer.nsImage
        }
    }
}
