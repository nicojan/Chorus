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

/// How bad a notice is. Three, and the fill is the same weight for all of them:
/// the tone is carried by the icon and the rule under the strip, not by shouting
/// with the background. This replaces two raw SwiftUI yellows and a solid red
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

/// The one notice strip: a tinted band with a rule under it.
///
/// The window-drag handle is part of the shape rather than left to each caller.
/// A notice sits at the very top of the window, inside the title-bar drag band,
/// and the bar layout turns the OS window drag off (see
/// `WindowMovableConfigurator`). Without a handle the strip is dead to dragging,
/// and because it also pushes the rail's own handle down out of the band, the
/// window could not be moved by its top edge at all while a notice was up. The
/// handle goes behind the content and in front of the fill, so buttons still
/// take their own clicks.
struct NoticeStrip<Content: View>: View {
    let severity: NoticeSeverity
    /// Overrides the severity's own icon where a notice is about something more
    /// specific than its seriousness.
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: systemImage ?? severity.systemImage)
                    .foregroundStyle(severity.tint)
                    .accessibilityHidden(true)

                content()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(severity.tint)
                .frame(height: 1)
        }
        .background(WindowDragHandle())
        .background(severity.tint.opacity(severity.fillOpacity))
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
        case .selected: return AnyShapeStyle(.tint.opacity(0.12))
        case .hover: return AnyShapeStyle(Color.primary.opacity(0.06))
        case .none: return AnyShapeStyle(Color.clear)
        }
    }
}
