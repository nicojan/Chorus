import AppKit
import XCTest
@testable import Chorus

/// The download spinner runs in Core Animation; see `SpinningArc`.
final class SpinningArcTests: XCTestCase {
    /// Once on screen with a size, the arc turns by a layer animation, so
    /// SwiftUI does no work between frames.
    @MainActor
    func testArcSpinsInCoreAnimation() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 60, height: 60), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = SpinningArcView()
        window.contentView?.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        view.layoutSubtreeIfNeeded()

        let spin = view.arc.animation(forKey: SpinningArcView.animationKey) as? CABasicAnimation
        XCTAssertEqual(spin?.keyPath, "transform.rotation.z")
        XCTAssertEqual(spin?.duration, SpinningArc.period)
        XCTAssertEqual(spin?.repeatCount, .infinity)
        XCTAssertNotNil(view.arc.path)
    }

    /// Off screen it has nothing to turn.
    @MainActor
    func testArcWaitsForAWindow() {
        let view = SpinningArcView()
        view.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.arc.animation(forKey: SpinningArcView.animationKey))
    }
}
