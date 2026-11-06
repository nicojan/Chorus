import SwiftUI
import AppKit

/// How much of the desktop the window lets through behind its chrome.
///
/// The look is Paguro's (see `THIRD_PARTY_NOTICES.md`); the code is Chorus's
/// own. Kept in UserDefaults rather than `AppPreferences`, so it costs no schema
/// version.
///
/// Off is the default and the only style below macOS 26: there, the window is
/// the flat canvas grey. Both glass styles keep a heavy canvas tint over the
/// frost, so the rail stays close to neutral grey whatever the wallpaper is.
/// The web view never takes part: it sits on an opaque card above all of this.
enum WindowGlassStyle: String, CaseIterable, Identifiable {
    case off
    case clear
    case regular

    static let defaultsKey = "windowGlassStyle"
    static let defaultStyle: WindowGlassStyle = .off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .clear: return "Clear"
        case .regular: return "Regular"
        }
    }

    /// Whether this Mac can draw the glass styles at all: macOS 26 and later.
    static var isGlassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// What the window actually draws. Below macOS 26 every style is Off, and
    /// Reduce Transparency turns glass off everywhere.
    func effective(reduceTransparency: Bool) -> WindowGlassStyle {
        guard Self.isGlassAvailable, !reduceTransparency else { return .off }
        return self
    }

    /// How strongly the canvas grey covers the frost. 1 is solid.
    var tintOpacity: CGFloat {
        switch self {
        case .off: return 1
        case .clear: return 0.62
        case .regular: return 0.78
        }
    }

    /// Reads a stored raw value, falling back to the default for anything
    /// unrecognised.
    static func resolve(_ raw: String?) -> WindowGlassStyle {
        raw.flatMap(WindowGlassStyle.init(rawValue:)) ?? defaultStyle
    }
}

/// The layers behind the whole window: frost, glass on macOS 26, and the canvas
/// tint on top. Placed as the root view's background.
struct WindowBackdrop: NSViewRepresentable {
    let style: WindowGlassStyle

    func makeNSView(context: Context) -> WindowBackdropView {
        WindowBackdropView()
    }

    func updateNSView(_ nsView: WindowBackdropView, context: Context) {
        nsView.apply(style)
    }
}

final class WindowBackdropView: NSView {
    private let frostView = NSVisualEffectView()
    private let tintView = CanvasTintView()
    /// The Liquid Glass layer, macOS 26 only. Held as a plain `NSView` because a
    /// stored property cannot name a type the deployment target lacks.
    private var glassView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        frostView.frame = bounds
        frostView.autoresizingMask = [.width, .height]
        frostView.material = .underWindowBackground
        frostView.blendingMode = .behindWindow
        frostView.state = .followsWindowActiveState
        addSubview(frostView)

        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.frame = bounds
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = 0
            addSubview(glass, positioned: .above, relativeTo: frostView)
            glassView = glass
        }

        tintView.frame = bounds
        tintView.autoresizingMask = [.width, .height]
        addSubview(tintView, positioned: .above, relativeTo: glassView ?? frostView)

        apply(.off)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Clicks go to whatever the window puts in front, never to the backdrop.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ style: WindowGlassStyle) {
        frostView.isHidden = style == .off
        glassView?.isHidden = style == .off

        if #available(macOS 26, *), let glass = glassView as? NSGlassEffectView {
            glass.style = style == .clear ? .clear : .regular
        }

        tintView.opacity = style.tintOpacity
    }
}

/// The canvas grey at a given strength. Drawn through the layer so a change of
/// appearance or of style repaints it.
private final class CanvasTintView: NSView {
    var opacity: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { opacity >= 1 }
    override var allowsVibrancy: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = ChorusColor.canvasNSColor(isDark: isDark).withAlphaComponent(opacity).cgColor
    }
}
