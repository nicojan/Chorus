import SwiftUI

/// One service in the rail, drawn the way Editorial draws it.
///
/// Measured off `Direction · Editorial / sidebar` on Figma page
/// `09 Visual directions`: a 248 by 64 row inside a 300 point rail, two lines of
/// type and no icon at all. The name carries identity, a second line says in
/// words whether the page is up, an unread count is a numeral in the accent
/// rather than a filled red circle, and selection is a 3 by 16 rule on the
/// leading edge instead of a fill.
///
/// Dropping the icon is the direction's central bet, and it is less reckless
/// than it sounds: the audit's severity 4 finding was that two Slack workspaces
/// drew two identical squares, and `Slack · Design` beside `Slack · Client` is
/// exactly the case a brand mark cannot answer.
///
/// `ServiceRowView` picks between this and its own row off the theme, so every
/// call site stays as it was and there is one place the choice is made.
struct EditorialServiceRow: View {
    let instance: ServiceInstance
    let isSelected: Bool
    var badgeCount: Int = 0
    var isHibernated: Bool = false
    var isMuted: Bool = false
    var health: ServiceHealth = .live
    var isFocused: Bool = false
    let action: () -> Void

    @Environment(\.chorusTheme) private var theme
    @State private var isHovering = false

    /// The selection rule, and the gutter it sits in.
    ///
    /// The gutter is reserved on every row, not only the selected one. The drawn
    /// frame shifts the name 11 points right when a row is selected, which would
    /// make every name jump sideways on click; the frames were drawn one row at
    /// a time and never showed that transition. Holding the gutter open costs
    /// nothing and removes the jitter. Worth a look in the by-eye pass.
    private static let ruleWidth: CGFloat = 3
    private static let ruleHeight: CGFloat = 16
    private static let ruleGutter: CGFloat = 11
    private static let lineGap: CGFloat = 3

    private var nameColor: Color {
        (isSelected ? theme.textPrimary : theme.textSecondary).color
    }

    private var statusColor: Color {
        switch health.statusRole {
        case .neutral: return theme.textTertiary.color
        case .warn: return theme.statusWarn.color
        case .bad: return theme.statusBad.color
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 0) {
                selectionRule

                VStack(alignment: .leading, spacing: Self.lineGap) {
                    firstLine
                    secondLine
                }

                Spacer(minLength: 0)
            }
            // 13 top, 13 bottom, 3 between the lines, straight off the frame's
            // auto-layout.
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: theme.rowHeight, alignment: .topLeading)
            .opacity(isHibernated ? 0.6 : (isMuted ? 0.85 : 1.0))
            .contentShape(Rectangle())
            // Focus is a hairline, not the 2 point ring the native row draws.
            // At full weight in the accent it swamped the 3 point selection
            // rule and the row read as a focused text field — seen in the Debug
            // build on 2026-08-24. Selection is still the rule; focus is still
            // its own mark, which is what `RowMark` argues for. It is just
            // quieter, because Editorial's selection mark is quiet too.
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: ChorusRadius.control)
                        .strokeBorder(theme.accent.color.opacity(0.45), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .background(isHovering && !isSelected ? theme.railAlt.color : .clear)
        // A hairline under every row, which is half of what makes the rail read
        // as a list rather than floating text. The frame draws it as a 1 point
        // bottom stroke on the row itself, inside its bounds.
        .overlay(alignment: .bottom) {
            if theme.railRules {
                Rectangle()
                    .fill(theme.separator.color)
                    .frame(height: 1)
            }
        }
        .accessibilityLabel(ServiceAccessibility.label(
            name: instance.label,
            badgeCount: badgeCount,
            isHibernated: isHibernated,
            isMuted: isMuted,
            health: health
        ))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // The rail's 28 point gutter. Applied here rather than by the rail so
        // the hairline stops where the frame stops it, at the row's own width,
        // instead of running the full 300 points.
        .padding(.horizontal, theme.railPadding)
    }

    private var selectionRule: some View {
        // Always the same width, so the names line up whether or not the rule is
        // drawn. See `ruleGutter`.
        HStack(spacing: 0) {
            Rectangle()
                .fill(isSelected ? theme.accent.color : .clear)
                .frame(width: Self.ruleWidth, height: Self.ruleHeight)
            Spacer(minLength: 0)
        }
        .frame(width: Self.ruleGutter, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var firstLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(instance.label)
                .font(theme.rowName)
                .fontWeight(isSelected ? .bold : .regular)
                .tracking(theme.rowNameTracking)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // A numeral in the accent, not a disc. The count still has to be
            // readable at a glance, so it keeps the row's own type size.
            if badgeCount > 0, !isMuted {
                Text(badgeCount > 99 ? "99+" : String(badgeCount))
                    .font(theme.badgeFont)
                    .foregroundStyle(theme.badge.color)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 20)
    }

    private var secondLine: some View {
        HStack(spacing: 6) {
            Text(health.statusLine)
                .font(theme.rowStatus)
                .foregroundStyle(statusColor)
                .lineLimit(1)

            if isMuted {
                Text("Muted")
                    .font(theme.rowStatus)
                    .foregroundStyle(theme.textTertiary.color)
            }
            if isHibernated {
                Text("Asleep")
                    .font(theme.rowStatus)
                    .foregroundStyle(theme.textTertiary.color)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}
