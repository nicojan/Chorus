import QuartzCore
import SwiftUI
import XCTest
@testable import Chorus

/// The pulse on a waiting count runs in Core Animation; see `CountPulse`.
final class CountPulseTests: XCTestCase {
    private typealias Pulse = CountPulse<EmptyView>

    /// AppKit anchors a layer at its bottom-left corner, so the transform has
    /// to hold the center still or the count drifts up and right as it grows.
    func testPulseScalesAboutTheCenter() {
        let center = CGPoint(x: 11, y: 8)
        for scale in [1.0, 1.06, Pulse.scale] {
            let t = CATransform3DGetAffineTransform(Pulse.transform(scale: scale, center: center))
            XCTAssertEqual(center.applying(t).x, center.x, accuracy: 0.0001)
            XCTAssertEqual(center.applying(t).y, center.y, accuracy: 0.0001)
            let corner = CGPoint.zero.applying(t)
            XCTAssertEqual(corner.x, center.x * (1 - scale), accuracy: 0.0001)
            XCTAssertEqual(corner.y, center.y * (1 - scale), accuracy: 0.0001)
        }
    }

    /// The pulse keeps the size and pace it had as a SwiftUI animation.
    func testPulseKeepsItsLook() {
        XCTAssertEqual(Pulse.scale, 1.12)
        XCTAssertEqual(Pulse.halfPeriod, 0.8)
    }

    /// The hosted count must not feed the window's minimum size: that layout
    /// on every frame is the cost the layer animation exists to avoid.
    @MainActor
    func testHostedCountDoesNotSizeTheWindow() {
        let view = PulseView(rootView: Text("3"))
        XCTAssertEqual(view.controller.sizingOptions, [])
    }

    /// The hosted count ignores the window's safe area. In the tab bar, which
    /// sits in the titlebar band, the inset pushed a red count down under its
    /// icon.
    @MainActor
    func testHostedCountIgnoresTheSafeArea() {
        let view = PulseView(rootView: Text("3"))
        XCTAssertEqual(view.controller.safeAreaRegions, [])
    }

    /// A pulsing badge takes the size a still one takes. Measured with
    /// `fittingSize`, the hosted badge came out 0 by 0, and the red count
    /// drew from its corner and was cut off by the rail. `CountPulse` is used
    /// directly: `AttentionPulse` skips it under Reduce Motion, which a test
    /// machine may have on.
    @MainActor
    func testPulsingBadgeKeepsTheStillBadgesSize() {
        let badge = BadgeCountView(count: 5, needsAttention: false)
        let still = NSHostingView(rootView: badge.fixedSize()).fittingSize
        let pulsing = NSHostingView(rootView: CountPulse(content: badge).fixedSize()).fittingSize
        XCTAssertEqual(still, CGSize(width: 16, height: 16))
        XCTAssertEqual(pulsing, still)
    }

    /// The same for the plain count at the end of a named row.
    @MainActor
    func testPulsingRowCountKeepsTheStillCountsSize() {
        func size(needsAttention: Bool) -> CGSize {
            let host = NSHostingView(rootView: SidebarCount(count: 12, needsAttention: needsAttention).fixedSize())
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let still = size(needsAttention: false)
        XCTAssertGreaterThan(still.width, 0)
        XCTAssertEqual(size(needsAttention: true).height, still.height, accuracy: 0.5)
        // Semibold when waiting, so it may be a little wider; never collapsed.
        XCTAssertEqual(size(needsAttention: true).width, still.width, accuracy: 2)
    }
}
