import SwiftUI

/// Window-drag plumbing and the reorder maths the rail depends on.
///
/// All of it moved here verbatim when `ServiceSidebarView` and `SpaceStripView`
/// were replaced by `UnifiedRailView` (build step 5 of concept C). It is the
/// part the UX audit rated severity 0 — tested, and working — so it was moved
/// rather than rewritten, and it lives in its own file so the next rail rebuild
/// cannot take it down with the view it happened to sit in.

enum ServiceReorderPlacement {
    case before
    case after
}

/// Sets whether the user can move the window by dragging its background.
///
/// With `.windowStyle(.hiddenTitleBar)` the top ~32px stays a title-bar drag
/// band. In the bar layout the rail sits in that band, so a click-drag on a tab
/// was grabbed by the window move before SwiftUI's `.draggable` reorder could
/// start — the window slid instead of the tab reordering. A view nested in a
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
/// The strip has two widths rather than a dragged range. A drag handle was
/// tried first and felt bad: the strip is 40-odd points of chrome, the useful
/// range is short, and the two widths that matter are the two ends of it.
/// A toggle says the same thing and lands on the right width every time.
enum SpaceStripMetrics {
    static let defaultsKey = "showSpaceNames"

    /// Wide enough to read a name beside the emoji.
    static let namedWidth: CGFloat = 180
    /// The emoji on their own.
    static let compactWidth: CGFloat = 52

    static func width(showingNames: Bool) -> CGFloat {
        showingNames ? namedWidth : compactWidth
    }

    /// Leading inset the service bar needs so the window's traffic lights,
    /// which sit over the strip, do not land on the first tab. The lights are
    /// 72 points wide; the named strip swallows them whole and the bar starts
    /// flush, while the compact one leaves 20 points of them overhanging.
    static func barLeadingInset(stripWidth: CGFloat, lightsWidth: CGFloat) -> CGFloat {
        Swift.max(0, lightsWidth - stripWidth)
    }
}
