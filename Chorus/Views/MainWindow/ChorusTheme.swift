import SwiftUI

/// The look Chorus draws its own chrome in.
///
/// Six visual directions were drawn against concept C's sidebar and measured for
/// contrast (`docs/internal/UX-AUDIT.md`, section 3b). Editorial was picked on
/// 2026-08-24, and it is a choice rather than a replacement: the native look
/// stays the default and stays shipped, so a user who dislikes Editorial has
/// somewhere to go and the other five directions stay cheap to add.
///
/// A role is either `.system`, meaning AppKit decides and Apple has already done
/// the contrast arithmetic, or `.fixed`, meaning a direction drew the value and
/// this app owns proving it is legible. `ChorusTests` measures every `.fixed`
/// text role, so the audit's pass is a test rather than something someone did
/// once in August.

/// A colour as drawn: three components in 0...1, kept measurable rather than
/// collapsed straight into a `Color`, because the contrast floor is a promise
/// this app makes and a promise wants a test.
struct ThemeRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `ThemeRGB(0xC2410C)`, so a value can be read straight off the Figma
    /// variable without hand-converting it and introducing a typo.
    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// WCAG 2.1 relative luminance.
    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.1 contrast ratio, 1 to 21. Symmetric: which colour is the text and
    /// which the ground does not change the number.
    func contrastRatio(against other: ThemeRGB) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// One role's two appearances.
///
/// The `Chorus / Directions` collection has no light/dark axis — its modes *are*
/// the five directions, so each one is a single fixed palette. Editorial is
/// light throughout. Until the dark half is drawn, `init(_:)` puts the light
/// value in both slots and `ChorusTheme.hasDrawnDarkPalette` says so, so
/// Settings can warn instead of pretending.
struct ThemeColorPair: Equatable {
    let light: ThemeRGB
    let dark: ThemeRGB

    init(light: ThemeRGB, dark: ThemeRGB) {
        self.light = light
        self.dark = dark
    }

    /// A role whose dark appearance nobody has drawn yet.
    init(_ undrawnDark: ThemeRGB) {
        self.init(light: undrawnDark, dark: undrawnDark)
    }

    /// Resolves per appearance at draw time rather than being captured once, so
    /// the window follows a change of appearance without a relaunch.
    var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    }
}

/// Where a role's value comes from.
enum ThemeColor: Equatable {
    /// AppKit's, and left to it. The native look is not a palette this app
    /// invented and should not become one.
    case system(Color)
    /// Drawn, and this app's to justify.
    case fixed(ThemeColorPair)

    var color: Color {
        switch self {
        case .system(let color): return color
        case .fixed(let pair): return pair.color
        }
    }

    /// The pair, when there is one to measure. `nil` for a system role, which is
    /// the honest answer rather than a guess at what Apple resolved it to.
    var measurable: ThemeColorPair? {
        switch self {
        case .system: return nil
        case .fixed(let pair): return pair
        }
    }

    static func fixed(_ hex: UInt32) -> ThemeColor { .fixed(ThemeColorPair(ThemeRGB(hex))) }
}

/// Which look is on. Chrome, not user data, so it lives in defaults rather than
/// `AppPreferences` — a stored property there is a new schema version and a
/// migration (see CLAUDE.md), which a theme picker does not earn. Same reasoning
/// as `SpacesPresentation` and `SupportButtonVisibility`.
enum ChorusThemeChoice: String, CaseIterable {
    /// What ships today: concept C drawn in AppKit's own colours.
    case native
    /// Let type do the work. Page `09 Visual directions` in the Figma file.
    case editorial

    static let defaultsKey = "chorusTheme"

    var displayName: String {
        switch self {
        case .native: return "Native"
        case .editorial: return "Editorial"
        }
    }

    var theme: ChorusTheme {
        switch self {
        case .native: return .native
        case .editorial: return .editorial
        }
    }

    /// An unknown string means a build that wrote a case this one does not have.
    /// The safe landing is the shipped look, not a direction the user never
    /// picked.
    static func resolving(_ raw: String?) -> ChorusThemeChoice {
        guard let raw, let known = ChorusThemeChoice(rawValue: raw) else { return .native }
        return known
    }
}

/// Every role the chrome draws with, plus the geometry that a direction is
/// allowed to move.
///
/// Editorial is not a repaint. It changes the rail's width, the row's height and
/// contents, how a badge is written and how selection is marked, so those live
/// here beside the colours rather than being hardcoded in each view.
struct ChorusTheme {
    // MARK: Surfaces
    let window: ThemeColor
    let rail: ThemeColor
    let railAlt: ThemeColor
    let content: ThemeColor
    let separator: ThemeColor

    // MARK: Marks
    let selection: ThemeColor
    let onSelection: ThemeColor
    let accent: ThemeColor
    let badge: ThemeColor
    let badgeLabel: ThemeColor
    let statusOK: ThemeColor
    let statusWarn: ThemeColor
    let statusBad: ThemeColor

    // MARK: Text
    let textPrimary: ThemeColor
    let textSecondary: ThemeColor
    let textTertiary: ThemeColor

    // MARK: Geometry
    /// The vertical rail's width. Concept C reclaimed 161 points getting to one
    /// rail; Editorial spends 60 of them back on room for two lines of type.
    let railWidth: CGFloat
    /// The rail's inner horizontal padding.
    let railPadding: CGFloat
    /// One service row's height, and its pitch — Editorial's rows abut.
    let rowHeight: CGFloat
    /// How far the web view is inset from the content well on every side. Zero
    /// for the native look, which is edge to edge.
    let contentInset: CGFloat
    /// The inset card's corner radius. Costs the host `NSView` a `wantsLayer`
    /// and `masksToBounds`, and clips a page's fixed-position corner elements.
    let contentCornerRadius: CGFloat
    /// The hairline around the card. Editorial's card is white on a white
    /// window, so the border is the only thing that makes it a card at all:
    /// without it the inset reads as a margin and the framing disappears.
    let contentBorderWidth: CGFloat
    /// Whether the rail draws a hairline under each row and a border down its
    /// trailing edge.
    let railRules: Bool

    // MARK: Behaviour
    /// Whether the rail draws a service's brand mark. Editorial does not: the
    /// name carries identity, which is the answer its own note argues for and
    /// the one that actually separates two Slack workspaces.
    let showsServiceIcons: Bool
    /// Whether a row states its health in words on a second line. When it does,
    /// the corner dot is redundant and is not drawn.
    let statesHealthInWords: Bool
    /// Whether an unread count is a numeral in the accent rather than a filled
    /// red circle.
    let badgeIsNumeral: Bool
    /// Whether every role's dark appearance has been drawn and measured.
    let hasDrawnDarkPalette: Bool

    // MARK: Type
    let spaceKicker: Font
    let spaceKickerTracking: CGFloat
    let spaceName: Font
    let spaceNameTracking: CGFloat
    let spaceMeta: Font
    let rowName: Font
    let rowNameTracking: CGFloat
    let rowStatus: Font
    let badgeFont: Font
}

extension ChorusTheme {
    /// Concept C in AppKit's colours, which is what ships. Its geometry is the
    /// measured geometry of the built rail, not a proposal.
    static let native = ChorusTheme(
        window: .system(Color(nsColor: .windowBackgroundColor)),
        rail: .system(Color(nsColor: .windowBackgroundColor)),
        railAlt: .system(Color(nsColor: .underPageBackgroundColor)),
        content: .system(Color(nsColor: .windowBackgroundColor)),
        separator: .system(Color(nsColor: .separatorColor)),
        selection: .system(.accentColor),
        onSelection: .system(.white),
        accent: .system(.accentColor),
        badge: .system(ServiceIconPalette.badgeRed),
        badgeLabel: .system(.white),
        statusOK: .system(.green),
        statusWarn: .system(.orange),
        statusBad: .system(.red),
        textPrimary: .system(.primary),
        textSecondary: .system(.secondary),
        textTertiary: .system(Color(nsColor: .tertiaryLabelColor)),
        railWidth: 240,
        railPadding: 8,
        rowHeight: 34,
        contentInset: 0,
        contentCornerRadius: 0,
        contentBorderWidth: 0,
        railRules: false,
        showsServiceIcons: true,
        statesHealthInWords: false,
        badgeIsNumeral: false,
        hasDrawnDarkPalette: true,
        spaceKicker: .system(size: 11, weight: .semibold),
        spaceKickerTracking: 0,
        spaceName: .system(size: 13, weight: .semibold),
        spaceNameTracking: 0,
        spaceMeta: .system(size: 11),
        rowName: .system(size: 13),
        rowNameTracking: 0,
        rowStatus: .system(size: 11),
        badgeFont: .system(size: 11, weight: .semibold)
    )

    /// Editorial, measured off `Direction · Editorial / sidebar` on page
    /// `09 Visual directions` and the `Chorus / Directions` collection's
    /// Editorial mode. Light only, deliberately — see `ThemeColorPair`.
    static let editorial = ChorusTheme(
        window: .fixed(0xFFFFFF),
        rail: .fixed(0xFAFAF8),
        railAlt: .fixed(0xF2F2EF),
        content: .fixed(0xF4F4F2),
        separator: .fixed(0xE6E6E1),
        selection: .fixed(0x111111),
        onSelection: .fixed(0xFFFFFF),
        accent: .fixed(0xC2410C),
        badge: .fixed(0xC2410C),
        badgeLabel: .fixed(0xFFFFFF),
        statusOK: .fixed(0x1F7A3D),
        statusWarn: .fixed(0xB45309),
        statusBad: .fixed(0xB91C1C),
        textPrimary: .fixed(0x0A0A0A),
        textSecondary: .fixed(0x55555A),
        textTertiary: .fixed(0x6B6B70),
        railWidth: 300,
        railPadding: 28,
        rowHeight: 64,
        contentInset: 20,
        contentCornerRadius: 8,
        contentBorderWidth: 1,
        railRules: true,
        showsServiceIcons: false,
        statesHealthInWords: true,
        badgeIsNumeral: true,
        hasDrawnDarkPalette: false,
        spaceKicker: .system(size: 10, weight: .bold),
        spaceKickerTracking: 1.2,
        spaceName: .system(size: 30, weight: .bold),
        spaceNameTracking: -0.6,
        spaceMeta: .system(size: 12),
        rowName: .system(size: 15),
        rowNameTracking: -0.15,
        rowStatus: .system(size: 11),
        badgeFont: .system(size: 15, weight: .bold)
    )
}

// MARK: - Reaching the views

private struct ChorusThemeKey: EnvironmentKey {
    static let defaultValue = ChorusTheme.native
}

extension EnvironmentValues {
    var chorusTheme: ChorusTheme {
        get { self[ChorusThemeKey.self] }
        set { self[ChorusThemeKey.self] = newValue }
    }
}

/// Reads the stored choice and puts the matching theme in the environment.
///
/// A modifier rather than a job for each scene to do by hand: there are three
/// scene roots, and one that forgot would draw the native look inside an
/// Editorial window with no error anywhere.
private struct ChorusThemedModifier: ViewModifier {
    @AppStorage(ChorusThemeChoice.defaultsKey) private var raw = ChorusThemeChoice.native.rawValue

    func body(content: Content) -> some View {
        content.environment(\.chorusTheme, ChorusThemeChoice.resolving(raw).theme)
    }
}

extension View {
    func chorusThemed() -> some View { modifier(ChorusThemedModifier()) }
}
