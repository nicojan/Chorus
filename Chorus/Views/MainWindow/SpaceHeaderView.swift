import SwiftUI

/// The spoken label for the space header. Split out from the view so the words
/// can be pinned by a test, the same way `ServiceAccessibility` is.
enum SpaceHeader {
    static func label(spaceName: String?, badgeCount: Int, isMuted: Bool) -> String {
        guard let spaceName, !spaceName.isEmpty else { return "No space" }
        var parts = [spaceName]
        if badgeCount > 0 {
            parts.append(badgeCount == 1 ? "1 unread" : "\(badgeCount) unread")
        }
        if isMuted { parts.append("muted") }
        return parts.joined(separator: ", ")
    }
}

/// The current space, drawn as a header on the service rail, and the click
/// target that opens the switcher.
///
/// This is the half of concept C that pays for dropping the second rail: the
/// space stops being a column of unlabelled emoji (`SpaceButton.verticalCell`,
/// the audit's severity 3 finding) and becomes one named row that says where
/// you are. The other spaces are one click away in `SpacePaletteView` rather
/// than always on screen, which is the price recorded with the pick.
///
/// Geometry comes off the `C · Rethink` frames on Figma page `08`: 224 by 36 at
/// radius 8 in the vertical rail, and 150 by 32 in the horizontal bar. Where the
/// header sits — y 38 down the rail, x 80 along the bar so it clears the traffic
/// lights — is the rail's business, not the header's, exactly as the row gutter
/// is in `ServiceRowView`.
struct SpaceHeaderView: View {
    let spaceName: String?
    let emoji: String
    var axis: Axis = .vertical
    var badgeCount: Int = 0
    /// A service in this space has a count waiting to be seen.
    var needsAttention: Bool = false
    var isMuted: Bool = false
    /// Whether the header carries the space's name. It follows the rail's
    /// service rows: a full-width header cannot sit above a 52 point column of
    /// icons. Only the vertical rail ever asks for this — the horizontal bar has
    /// the room and keeps its name.
    var showsName: Bool = true
    /// True while the palette this header opens is on screen. Held by the owner
    /// so the header can draw itself as pressed for as long as it is.
    var isPaletteOpen: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.railWidth) private var railWidth
    /// The nameless header matches the cells under it. See `RailIconSize`.
    @Environment(\.railIconSize) private var railIconSize

    static let headerHeight: CGFloat = 36
    /// The horizontal bar's header is a fixed width rather than hugging its
    /// name: it is the leftmost thing in the bar and a header that resized on
    /// every space switch would shove every service tab sideways.
    static let barHeaderWidth: CGFloat = 150
    static let barHeaderHeight: CGFloat = 32

    private static let cornerRadius: CGFloat = 8
    private static let gutter: CGFloat = 8

    var body: some View {
        Button(action: action) {
            content
                .background {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(fillStyle)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(displayName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SpaceHeader.label(
            spaceName: spaceName,
            badgeCount: badgeCount,
            isMuted: isMuted
        ))
        .accessibilityHint("Switch space")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var content: some View {
        if showsName {
            namedContent
        } else {
            compactContent
        }
    }

    /// The emoji alone, with the badge on its corner. The chevron goes: at this
    /// size it would be most of the cell, and the header is still the only thing
    /// in the rail that opens on click.
    private var compactContent: some View {
        Text(emoji)
            .font(.system(size: railIconSize.emojiSize))
            .opacity(isMuted ? 0.5 : 1.0)
            .accessibilityHidden(true)
            .frame(width: railIconSize.cellWidth, height: Swift.max(Self.headerHeight, railIconSize.cellHeight))
            .cornerBadge(badgeCount, needsAttention: needsAttention)
    }

    private var namedContent: some View {
        HStack(spacing: Self.gutter) {
            Text(emoji)
                .font(.system(size: axis == .vertical ? 16 : 15))
                .opacity(isMuted ? 0.5 : 1.0)
                .accessibilityHidden(true)

            Text(displayName)
                .font(ChorusType.label)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(spaceName == nil ? .secondary : .primary)

            Spacer(minLength: 0)

            if badgeCount > 0 {
                if axis == .vertical {
                    SidebarCount(count: badgeCount, needsAttention: needsAttention)
                } else {
                    BadgeCountView(count: badgeCount, needsAttention: needsAttention)
                }
            } else if isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            // Says the header does something. `chevron.up.chevron.down` is what
            // AppKit puts on a pop-up button, which is what this behaves like.
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Self.gutter)
        .frame(
            width: axis == .vertical ? ServiceRowView.rowWidth(forRail: railWidth) : Self.barHeaderWidth,
            height: axis == .vertical ? Self.headerHeight : Self.barHeaderHeight
        )
    }

    private var displayName: String {
        guard let spaceName, !spaceName.isEmpty else { return "No space" }
        return spaceName
    }

    /// No selected-state fill: the header is not one of a set you pick from, it
    /// is the one thing that is always true. It fills while the palette it owns
    /// is open, which is the pop-up button behaviour it borrows.
    private var fillStyle: AnyShapeStyle {
        if isPaletteOpen {
            return AnyShapeStyle(ChorusColor.selectedFill)
        } else if isHovering {
            return AnyShapeStyle(ChorusColor.hoverFill)
        }
        return AnyShapeStyle(Color.clear)
    }
}
