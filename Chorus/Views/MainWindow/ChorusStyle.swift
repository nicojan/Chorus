import SwiftUI

/// The three corner radii the app is allowed to draw, and the one notice shape.
///
/// Build step 7 of concept C, which is mostly the baseline's own list: eight
/// radii collapsed to three, three hand-rolled banners collapsed to one, and
/// keyboard focus given a mark of its own instead of being switched off.

/// Eight values down to three, named by what they wrap rather than by number.
/// A fourth value is the thing to argue about, not to add quietly.
enum ChorusRadius {
    /// Service icons and other small squares.
    static let icon: CGFloat = 4
    /// Chips, tabs, rows, buttons, fields — anything you click.
    static let control: CGFloat = 8
    /// Sheets, popovers, palettes: the surfaces those things sit on.
    static let surface: CGFloat = 14

    static let allValues: [CGFloat] = [icon, control, surface]
}

/// The window's neutral greys and the ink fills drawn on them.
///
/// Taken from Paguro's look (see `THIRD_PARTY_NOTICES.md`): three flat greys
/// that step up in brightness from the window to what sits on it, and fills made
/// of the text colour at low strength rather than of the accent. A selected row
/// is grey with a black or white name; blue is kept for the keyboard focus ring,
/// which is the one mark that has to stand out from selection (see `RowMark`).
enum ChorusColor {
    /// The window itself, behind the rail card and the web card.
    static let canvas = dynamic(light: canvasNSColor(isDark: false), dark: canvasNSColor(isDark: true))
    /// Chrome that sits on the canvas: the rail card. Ink rather than an opaque
    /// grey, so it lands on EC / 20 over the flat canvas and still lets the
    /// frost through when a glass style is on.
    static let surface = ink(light: 0.035, dark: 0.035, contrastLight: 0.06, contrastDark: 0.06)
    /// What sits on a surface, and the web view's own backing.
    static let card = dynamic(light: .white, dark: grey(40))
    /// The one-pixel edge round a card.
    static let hairline = ink(light: 0.08, dark: 0.10, contrastLight: 0.30, contrastDark: 0.35)
    /// The rule that ends the global services, set off from the hairline of a
    /// divider someone added: it marks where the services shown in every space
    /// stop and one space's begin.
    static let groupRule = ink(light: 0.20, dark: 0.26, contrastLight: 0.45, contrastDark: 0.50)

    /// A selected row. Strong enough to hold without the accent.
    static let selectedFill = ink(light: 0.10, dark: 0.16, contrastLight: 0.20, contrastDark: 0.28)
    /// A row under the pointer: half the weight of selection.
    static let hoverFill = ink(light: 0.05, dark: 0.08, contrastLight: 0.10, contrastDark: 0.14)
    /// Text that is not the thing you are reading. Stronger than
    /// `secondaryLabelColor`, which is too faint on these greys.
    static let secondaryText = ink(light: 0.60, dark: 0.62, contrastLight: 0.80, contrastDark: 0.82)

    static func canvasNSColor(isDark: Bool) -> NSColor {
        grey(isDark ? 24 : 245)
    }

    static func grey(_ level: CGFloat) -> NSColor {
        NSColor(srgbRed: level / 255, green: level / 255, blue: level / 255, alpha: 1)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    static func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Black or white at the given strength, stronger under Increase Contrast.
    static func ink(light: CGFloat, dark: CGFloat, contrastLight: CGFloat, contrastDark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua,
                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
            ])
            switch match {
            case .accessibilityHighContrastAqua: return .black.withAlphaComponent(contrastLight)
            case .accessibilityHighContrastDarkAqua: return .white.withAlphaComponent(contrastDark)
            case .darkAqua: return .white.withAlphaComponent(dark)
            default: return .black.withAlphaComponent(light)
            }
        })
    }
}

/// Type sizes for the chrome. Nothing a person reads is set below 12 points;
/// the system's own caption and subheadline styles are 10 and 11 on macOS, which
/// is why they no longer appear in the rail. The numbers in a badge are the one
/// exception: they sit in a 16 point circle and are read as a count, not text.
enum ChorusType {
    /// The smallest text: headings over a group, notes, secondary labels.
    static let captionSize: CGFloat = 12
    /// Row and tab names.
    static let labelSize: CGFloat = 13

    static let caption = Font.system(size: captionSize)
    static let label = Font.system(size: labelSize)
}

/// The two movements the chrome makes, and the rule that Reduce Motion turns
/// both off.
enum ChorusMotion {
    /// The rail opening, closing or changing width.
    static let sidebar = Animation.easeInOut(duration: 0.25)
    /// A row or tab settling into its new place after a reorder.
    static let reorder = Animation.spring(response: 0.28, dampingFraction: 0.78)

    /// `animation`, or none when Reduce Motion is on.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// A list's order, compared so that only a reorder counts as a change: the
/// same rows in a new order. Rows arriving or leaving, as when the space
/// changes, compare equal, so `.animation(_:value:)` lets them appear without
/// the reorder spring. The comparison is not transitive, which is fine for
/// what SwiftUI does with it: it only ever compares the old value with the new.
struct ReorderKey: Equatable {
    let ids: [UUID]

    static func == (lhs: ReorderKey, rhs: ReorderKey) -> Bool {
        lhs.ids == rhs.ids || lhs.ids.count != rhs.ids.count || Set(lhs.ids) != Set(rhs.ids)
    }
}

/// How bad a notice is. Three, and the fill is the same weight for all of them:
/// the icon and the card's edge say how bad it is, and the background stays
/// quiet. This replaces two raw SwiftUI yellows and a solid red
/// bar that read as three unrelated designs.
enum NoticeSeverity: CaseIterable {
    /// Something is offered, and nothing is wrong.
    case info
    /// Something is degraded and will probably fix itself.
    case warning
    /// Something is wrong and will not fix itself.
    case error

    var systemImage: String {
        switch self {
        case .info: return "clock.arrow.circlepath"
        case .warning: return "wifi.slash"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return ServiceIconPalette.badgeRed
        }
    }

    /// One weight for all three, on purpose. See the type's note.
    var fillOpacity: Double { 0.12 }
}

/// The one notice shape: a card above the web card, with the severity's tint in
/// its fill and on its edge. It used to be a strip across the top of the
/// window, in the band the traffic lights share. See `WindowNotices`.
struct NoticeCard<Content: View>: View {
    let severity: NoticeSeverity
    /// Overrides the severity's own icon where a notice is about something more
    /// specific than its seriousness.
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChorusRadius.surface, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: systemImage ?? severity.systemImage)
                .foregroundStyle(severity.tint)
                .accessibilityHidden(true)

            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(ChorusColor.card)
            shape.fill(severity.tint.opacity(severity.fillOpacity))
        }
        .overlay(
            shape
                .strokeBorder(severity.tint.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }
}

/// Which mark a rail row draws, worked out apart from the drawing so the rule
/// can be tested and stated once.
///
/// The audit's finding was that 1.5.10 fixed a doubled focus box by suppressing
/// the system ring, which removed the signal rather than reshaping it. This is
/// the reshape: selection is a fill, focus is a ring, and they are never the
/// same mark. The rail is 240 points wide now instead of 52, so the ring that
/// used to be clipped has room.
struct RowMark: Equatable {
    enum Fill: Equatable {
        case none
        case hover
        case selected
    }

    let fill: Fill
    let ring: Bool

    init(fill: Fill, ring: Bool) {
        self.fill = fill
        self.ring = ring
    }

    init(isSelected: Bool, isFocused: Bool, isHovering: Bool = false) {
        if isSelected {
            fill = .selected
        } else if isHovering {
            fill = .hover
        } else {
            fill = .none
        }
        ring = isFocused
    }

    var fillStyle: AnyShapeStyle {
        switch fill {
        case .selected: return AnyShapeStyle(ChorusColor.selectedFill)
        case .hover: return AnyShapeStyle(ChorusColor.hoverFill)
        case .none: return AnyShapeStyle(Color.clear)
        }
    }
}

/// The window's 8 point gutter and the inset cards the rail and the web view
/// sit on.
enum ChorusCard {
    /// The gap between the window edge, the rail card and the web card.
    static let gutter: CGFloat = 8
    /// The rail cards' corners. Their rows nest inside at 14 less the padding.
    static let cornerRadius = ChorusRadius.surface
    /// The web card's corners, set to follow a page's scroll bar: its thumb is
    /// 11 points wide, so its end is a 5.5 point round, and it runs 3 points in
    /// from the card's edge. 5.5 and 3 make the card's 8 (measured on
    /// macOS 26 with "Always show scroll bars" on).
    static let webCornerRadius = ChorusRadius.control
    /// The band along the top of every layout: the traffic lights, centred in
    /// it by `TrafficLightsPositioner`, then the bar or the nav row, and the
    /// donation button. The cards start under it, so their top edges line up.
    static let topBand: CGFloat = 52
    /// Space between the rail card's edge and the rows inside it. Six, so a
    /// row's corner nests inside the card's: 14 less 6 is the rows' 8.
    static let railPadding: CGFloat = 6
}

/// The nav buttons in the top band.
enum ChorusNav {
    /// Each button's circle.
    static let buttonSize: CGFloat = 28
    /// Space between two circles.
    static let spacing: CGFloat = 6
}

extension View {
    /// A nav button's 28 point circle: Liquid Glass on macOS 26, a material
    /// below it, and a hairline edge on both. Both follow Reduce Transparency
    /// on their own. The glass does not depend on the window's glass style:
    /// that setting is about the window's backdrop, and a button reads the same
    /// on either. The hairline is what keeps the circle there on the Regular
    /// backdrop, where glass sits on glass and has nothing to show.
    @ViewBuilder
    func navCircle() -> some View {
        let sized = frame(width: ChorusNav.buttonSize, height: ChorusNav.buttonSize)
            .contentShape(Circle())
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            sized.glassEffect(.regular.interactive(), in: Circle()).circleEdge()
        } else {
            sized.background(.regularMaterial, in: Circle()).circleEdge()
        }
        #else
        sized.background(.regularMaterial, in: Circle()).circleEdge()
        #endif
    }

    fileprivate func circleEdge() -> some View {
        overlay(
            Circle()
                .strokeBorder(ChorusColor.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    /// Draws this view as the rail card: the translucent surface behind it,
    /// continuous 14 point corners and a hairline edge. Neither layer takes
    /// clicks, so a window-drag handle behind the card still gets them. A card
    /// whose rows touch its side edges passes the rows' own radius instead.
    func railCard(cornerRadius: CGFloat = ChorusCard.cornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(ChorusColor.surface).allowsHitTesting(false))
            .overlay(
                shape
                    .strokeBorder(ChorusColor.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }

    /// Places a vertical rail's content in its column: the card's width, the
    /// gutter to the window's leading and bottom edges, and `topInset` above
    /// it for the traffic lights. `carded` draws the card itself; a rail that
    /// is one list leaves it off and sits on the window, and the all-services
    /// rail draws a card per space instead.
    @ViewBuilder
    func railCardFrame(width: CGFloat, topInset: CGFloat, carded: Bool = true) -> some View {
        let column = frame(width: width)
        Group {
            if carded {
                column.railCard()
            } else {
                column
            }
        }
        .padding(.leading, ChorusCard.gutter)
        .padding(.top, topInset)
        .padding(.bottom, ChorusCard.gutter)
    }

    /// Draws this view as the inset content card: the card grey behind it,
    /// continuous corners that follow the page's scroll bar (see
    /// `ChorusCard.webCornerRadius`) and a hairline edge. The page itself is also
    /// clipped by `WebViewHostView`'s layer, because a SwiftUI clip is not
    /// promised to reach into a hosted `NSView`.
    func contentCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: ChorusCard.webCornerRadius, style: .continuous)
        return background(ChorusColor.card)
            .clipShape(shape)
            .overlay(
                shape
                    .strokeBorder(ChorusColor.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

/// The hover and press marks for the chrome's own buttons: the add buttons,
/// the nav circles, and the like. The pointer over one draws the same faint
/// ink fill a hovered row gets, a press draws the selection's, and a disabled
/// button draws neither and is greyed out. The custom style takes over from
/// SwiftUI's own dimming, so it has to do that greying itself. A row-shaped button takes the fill behind its label;
/// a nav circle takes it over its glass or material, which would otherwise
/// hide it.
struct ChromeButtonStyle<S: Shape>: ButtonStyle {
    let shape: S
    var overLabel = false

    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonBody(configuration: configuration, shape: shape, overLabel: overLabel)
    }
}

private struct ChromeButtonBody<S: Shape>: View {
    let configuration: ButtonStyleConfiguration
    let shape: S
    let overLabel: Bool
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let mark = shape.fill(fill).allowsHitTesting(false)
        Group {
            if overLabel {
                // A disabled circle keeps its circle and greys its glyph, the
                // way a toolbar button does.
                configuration.label
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .overlay(mark)
            } else {
                configuration.label
                    .opacity(isEnabled ? 1 : 0.45)
                    .background(mark)
            }
        }
        .contentShape(shape)
        .onHover { isHovering = $0 }
    }

    private var fill: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(Color.clear) }
        if configuration.isPressed { return AnyShapeStyle(ChorusColor.selectedFill) }
        if isHovering { return AnyShapeStyle(ChorusColor.hoverFill) }
        return AnyShapeStyle(Color.clear)
    }
}

extension ButtonStyle where Self == ChromeButtonStyle<RoundedRectangle> {
    /// A row-shaped chrome button, such as Add service.
    static var chromeRow: Self {
        ChromeButtonStyle(shape: RoundedRectangle(cornerRadius: ChorusRadius.control, style: .continuous))
    }
}

extension ButtonStyle where Self == ChromeButtonStyle<Circle> {
    /// A nav circle in the top band.
    static var chromeCircle: Self {
        ChromeButtonStyle(shape: Circle(), overLabel: true)
    }
}
