import SwiftUI

/// One service in the rail, drawn as a labelled row in either axis.
///
/// This replaces the two unlabelled cells the rail used to draw — an 18 point
/// icon tab in the horizontal bar and a 32 point icon in the 52 point vertical
/// rail — which the UX audit rated its severity 4 finding: two Slack workspaces
/// were two identical squares and the name lived only in a tooltip. Both axes
/// now carry the name.
///
/// Geometry: a 28 point row as wide as the rail allows (220 at the default
/// width), an 18 point icon
/// at x 8, the label at x 34, and the badge trailing. The horizontal tab keeps
/// the same parts and hugs its label instead of taking a fixed width.
///
/// Icon resolution, the spoken label, the badge and the media glyph are all
/// shared with the rest of the app through `ServiceIconView.swift`.
struct ServiceRowView: View {
    let instance: ServiceInstance
    let isSelected: Bool
    var axis: Axis = .vertical
    var badgeCount: Int = 0
    /// The count went up while you were elsewhere. See `BadgeManager.attentionIDs`.
    var needsAttention: Bool = false
    var isHibernated: Bool = false
    var isMuted: Bool = false
    var cameraActive: Bool = false
    var micActive: Bool = false
    var micMuted: Bool = false
    /// The page is making sound. Drawn as a speaker so a tune that keeps playing
    /// after you switch away can be traced back to its service.
    var isPlayingAudio: Bool = false
    var health: ServiceHealth = .live
    /// Whether the row carries the service's name. Off, it is the icon alone in
    /// a compact cell — the pre-audit shape, offered back as a setting for
    /// people who know their own services by their icons and would rather have
    /// the room. Nothing becomes unreachable: the name is still in the tooltip
    /// and the spoken label, and so is every accessory the compact cell drops.
    var showsName: Bool = true
    /// Optional group context for layouts that show the same service in more
    /// than one space. Compact tooltips and VoiceOver include it.
    var spaceName: String? = nil
    /// The service group this row's box stands for, if it is in one. VoiceOver
    /// and the compact tooltip end with it.
    var group: ServiceAccessibility.GroupContext? = nil
    /// Whether the keyboard is on this row. Drawn as a ring, never as the fill
    /// selection uses — see `RowMark`.
    var isFocused: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    /// The rail's width, which the named row fills. See `RailWidth`.
    @Environment(\.railWidth) private var railWidth

    /// The rail's default width with names, gutter included; the rail itself can
    /// be dragged from 150 to 300 (see `RailWidth`). A row is that less the 8
    /// point gutter and 6 points of padding each side, 220 at the default. The
    /// gap between the rail and the web card is the web card's own gutter.
    static let railWidth: CGFloat = 240
    static let rowWidth: CGFloat = rowWidth(forRail: railWidth)

    /// A named row's width in a rail `rail` points wide: less the gutter and
    /// the card's padding.
    static func rowWidth(forRail rail: CGFloat) -> CGFloat {
        rail - ChorusCard.gutter - 2 * ChorusCard.railPadding
    }
    /// Row height in the vertical rail. The rail stacks these at 2 point spacing,
    /// which is the drawn 30 point pitch.
    static let rowHeight: CGFloat = 28
    /// Tab height in the horizontal bar.
    static let tabHeight: CGFloat = 32
    /// The nameless tab in the horizontal bar: the icon plus its 9 point
    /// gutters.
    static let compactCellWidth: CGFloat = 36
    /// The nameless cell in the vertical rail: what the 44 point card leaves
    /// inside its padding.
    static let compactRailCellWidth: CGFloat = compactRailWidth - ChorusCard.gutter - 2 * ChorusCard.railPadding
    /// Width of the vertical rail when the rows carry no name: the gutter, and
    /// a 44 point card round the 32 point cell.
    static let compactRailWidth: CGFloat = 52

    /// The rail card's width: the rail's footprint less the gutter beside it.
    static func railCardWidth(showsName: Bool) -> CGFloat {
        (showsName ? railWidth : compactRailWidth) - ChorusCard.gutter
    }

    private static let cornerRadius = ChorusRadius.control
    private static let iconSize: CGFloat = 18
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
        // With a name on the row the tooltip is only there for the case the row
        // truncates it. Without one it is carrying the whole cell — the name and
        // the accessories the compact form has no room to draw — so it speaks
        // the full spoken label instead.
        .help(showsName ? instance.label : spokenLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits([.isButton, isSelected ? .isSelected : []])
    }

    /// What VoiceOver reads, and what the compact cell's tooltip borrows.
    private var spokenLabel: String {
        let label = ServiceAccessibility.label(
            name: instance.label,
            badgeCount: badgeCount,
            isHibernated: isHibernated,
            isMuted: isMuted,
            cameraActive: cameraActive,
            micActive: micActive,
            micMuted: micMuted,
            isPlayingAudio: isPlayingAudio,
            health: health,
            needsAttention: needsAttention
        )
        let parts = [label, spaceName, group?.spoken].compactMap { $0 }
        return parts.joined(separator: ", ")
    }

    /// The two forms cross-fade when the rail changes between them.
    @ViewBuilder
    private var content: some View {
        if showsName {
            namedContent
                .transition(.opacity)
        } else {
            compactContent
                .transition(.opacity)
        }
    }

    /// The icon alone, with the badge back on its corner where it lived before
    /// the row grew a name. The moon, the bell and the media glyph do not come
    /// with it: four things on an 18 point icon is what the audit called
    /// unreadable, and all three are still in the tooltip and the spoken label.
    private var compactContent: some View {
        ServiceIconSquare(
            instance: instance,
            size: Self.iconSize,
            cornerRadius: Self.iconCornerRadius
        )
        .overlay(alignment: .bottomTrailing) {
            ServiceHealthDot(health: health)
                .offset(x: 3, y: 3)
        }
        .frame(
            width: axis == .vertical ? Self.compactRailCellWidth : Self.compactCellWidth,
            height: axis == .vertical ? Self.rowHeight : Self.tabHeight
        )
        // On the cell, not the icon, so it sits over the corner that the
        // selection fill and the focus ring are drawn on.
        .cornerBadge(badgeCount, visible: instance.showBadge, needsAttention: needsAttention)
    }

    private var namedContent: some View {
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
                .font(ChorusType.label)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)

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
            width: axis == .vertical ? Self.rowWidth(forRail: railWidth) : nil,
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

            if isPlayingAudio {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
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
                // Down the side, a Notes-style number; in the tab bar the red
                // badge, which reads at a glance across a row of tabs.
                if axis == .vertical {
                    SidebarCount(count: badgeCount, isSelected: isSelected, needsAttention: needsAttention)
                } else {
                    BadgeCountView(count: badgeCount, needsAttention: needsAttention)
                }
            }
        }
    }

}
