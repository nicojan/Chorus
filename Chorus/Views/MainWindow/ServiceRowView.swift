import SwiftUI

/// One service in the rail, drawn as a labelled row in either axis.
///
/// This replaces the two unlabelled cells the rail used to draw — an 18 point
/// icon tab in the horizontal bar and a 32 point icon in the 52 point vertical
/// rail — which the UX audit rated its severity 4 finding: two Slack workspaces
/// were two identical squares and the name lived only in a tooltip. Both axes
/// now carry the name.
///
/// Geometry comes off the `C · Rethink` frames on Figma page `08`: a 224 by 34
/// row inside a 240 point rail, a 20 point icon at x 8, the label at x 36, and
/// the badge trailing. The horizontal tab keeps the same parts and hugs its
/// label instead of taking a fixed width.
///
/// Icon resolution, the spoken label, the badge and the media glyph are all
/// shared with the rest of the app through `ServiceIconView.swift`.
struct ServiceRowView: View {
    let instance: ServiceInstance
    let isSelected: Bool
    var axis: Axis = .vertical
    var badgeCount: Int = 0
    var isHibernated: Bool = false
    var isMuted: Bool = false
    var cameraActive: Bool = false
    var micActive: Bool = false
    var micMuted: Bool = false
    var health: ServiceHealth = .live
    /// Whether the keyboard is on this row. Drawn as a ring, never as the fill
    /// selection uses — see `RowMark`.
    var isFocused: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    /// Width of the vertical rail, and of a row inside it. The 8 point gutter on
    /// each side is applied by the rail, not by the row.
    static let railWidth: CGFloat = 240
    static let rowWidth: CGFloat = 224
    /// Row height in the vertical rail. The rail stacks these at 2 point spacing,
    /// which is the drawn 36 point pitch.
    static let rowHeight: CGFloat = 34
    /// Tab height in the horizontal bar.
    static let tabHeight: CGFloat = 32
    /// Roughly what a labelled tab measures. Used only as the drop-midpoint
    /// fallback before the first geometry pass records a real width.
    static let tabTypicalWidth: CGFloat = 120

    private static let cornerRadius = ChorusRadius.control
    private static let iconSize: CGFloat = 20
    private static let iconCornerRadius = ChorusRadius.icon
    private static let gutter: CGFloat = 8

    var body: some View {
        Button(action: action) {
            content
                .opacity(isHibernated ? 0.6 : (isMuted ? 0.85 : 1.0))
                .background {
                    let mark = RowMark(isSelected: isSelected, isFocused: isFocused, isHovering: isHovering)
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(mark.fillStyle)
                        .overlay(
                            RoundedRectangle(cornerRadius: Self.cornerRadius)
                                .strokeBorder(
                                    mark.ring ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear),
                                    lineWidth: 2
                                )
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // The name is on the row now, so the tooltip is only there for the case
        // the row truncates it.
        .help(instance.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ServiceAccessibility.label(
            name: instance.label,
            badgeCount: badgeCount,
            isHibernated: isHibernated,
            isMuted: isMuted,
            cameraActive: cameraActive,
            micActive: micActive,
            micMuted: micMuted,
            health: health
        ))
        .accessibilityAddTraits([.isButton, isSelected ? .isSelected : []])
    }

    private var content: some View {
        HStack(spacing: Self.gutter) {
            ServiceIconSquare(
                instance: instance,
                size: Self.iconSize,
                cornerRadius: Self.iconCornerRadius
            )
            // The health mark sits on the icon's bottom-right corner, as drawn.
            // It is the one thing that stayed on the icon when the badge, bell,
            // moon and camera dot moved inline: it is about the icon's page, and
            // there is no room for a fifth thing on the trailing edge.
            .overlay(alignment: .bottomTrailing) {
                ServiceHealthDot(health: health)
                    .offset(x: 3, y: 3)
            }

            Text(instance.label)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? .primary : .secondary)

            if axis == .vertical {
                // Pushes the accessories to the trailing edge of the fixed-width
                // row. The horizontal tab has no fixed width to push against, so
                // it leaves this out and the accessories sit after the name.
                Spacer(minLength: 0)
            }

            accessories
        }
        .padding(.horizontal, Self.gutter)
        .frame(
            width: axis == .vertical ? Self.rowWidth : nil,
            height: axis == .vertical ? Self.rowHeight : Self.tabHeight
        )
        // The tab takes exactly the width its label needs and no more. Left
        // free to grow rather than capped: a cap only bites when something
        // proposes an unbounded width, which the horizontal scroll view does,
        // and there it would stretch every short tab to the cap instead of
        // trimming the long ones. `ViewThatFits` in the strip already hands
        // overflow to that scroll view, so a wide tab costs scrolling, not
        // layout.
        .fixedSize(horizontal: axis == .horizontal, vertical: false)
    }

    /// State that used to hang off the icon's corners, now inline where there is
    /// room for it. Ordered so the badge — the one thing that changes on its own
    /// while you are not looking — always lands last, on the trailing edge.
    private var accessories: some View {
        HStack(spacing: 4) {
            // Asked for by hand rather than let through unconditionally: the
            // glyph draws nothing when nothing is live, but an HStack still
            // spends a spacing slot on it and the row picks up 4 dead points.
            if cameraActive || micActive || micMuted {
                MediaIndicatorGlyph(cameraActive: cameraActive, micActive: micActive, micMuted: micMuted)
            }

            if isHibernated {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            if isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            if badgeCount > 0 && instance.showBadge {
                BadgeCountView(count: badgeCount)
            }
        }
    }

}
