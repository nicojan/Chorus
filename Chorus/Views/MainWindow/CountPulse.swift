import AppKit
import QuartzCore
import SwiftUI

/// The slow pulse on a count that waits to be seen, run by Core Animation.
///
/// A SwiftUI `repeatForever` animation makes SwiftUI update the view graph on
/// every frame, and each update made the window lay itself out again to find
/// its minimum size: about a third of a core for as long as one count waited,
/// against under 3% with none (measured 2026-11-05). A layer animation is
/// drawn by the window server, so SwiftUI does no work between frames.
///
/// The count is hosted in its own `NSHostingView`, so it does not see the
/// SwiftUI environment around it. The two counts that use this set their font
/// and colors themselves, and dynamic colors follow the window's appearance.
/// Pulses `content` while `isOn`, unless Reduce Motion is on.
struct AttentionPulse<Content: View>: View {
    let isOn: Bool
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isOn && !reduceMotion {
            CountPulse(content: content)
        } else {
            content
        }
    }
}

struct CountPulse<Content: View>: NSViewRepresentable {
    let content: Content

    static var scale: CGFloat { 1.12 }
    static var halfPeriod: CFTimeInterval { 0.8 }

    func makeNSView(context: Context) -> PulseView<Content> {
        PulseView(rootView: content)
    }

    func updateNSView(_ view: PulseView<Content>, context: Context) {
        view.controller.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: PulseView<Content>, context: Context) -> CGSize? {
        // Not `fittingSize`: with no sizing options it is zero, the frame
        // collapses, and the count spills from its corner into the rail's clip.
        view.controller.sizeThatFits(in: proposal.replacingUnspecifiedDimensions(by: CGSize(width: 1_000, height: 1_000)))
    }

    /// The scale around the center of a view whose layer is anchored at its
    /// bottom-left corner, as AppKit anchors them. Both parts move linearly
    /// with `scale`, so Core Animation's interpolation between this and the
    /// identity stays a scale about the center at every frame.
    static func transform(scale: CGFloat, center: CGPoint) -> CATransform3D {
        var t = CATransform3DMakeTranslation(center.x, center.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -center.x, -center.y, 0)
    }
}

final class PulseView<Content: View>: NSView {
    let controller: NSHostingController<Content>
    private static var animationKey: String { "chorus.countPulse" }
    private var pulsedSize: CGSize = .zero

    init(rootView: Content) {
        controller = NSHostingController(rootView: rootView)
        // The count must not size the window: that is the work this view exists to avoid.
        controller.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(controller.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        controller.view.frame = bounds
        startPulse()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pulsedSize = .zero
        startPulse()
    }

    /// Adds the animation, or replaces it when the size, and so the center,
    /// has changed. A view with no window or no size has nothing to pulse.
    private func startPulse() {
        guard let layer, window != nil, bounds.size != .zero else { return }
        guard bounds.size != pulsedSize || layer.animation(forKey: Self.animationKey) == nil else { return }
        pulsedSize = bounds.size

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let pulse = CABasicAnimation(keyPath: "transform")
        pulse.fromValue = CATransform3DIdentity
        pulse.toValue = CountPulse<Content>.transform(scale: CountPulse<Content>.scale, center: center)
        pulse.duration = CountPulse<Content>.halfPeriod
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        layer.add(pulse, forKey: Self.animationKey)
    }
}
