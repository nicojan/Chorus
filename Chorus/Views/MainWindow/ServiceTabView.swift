import SwiftUI

/// A service rendered as a tab for the top-bar and hybrid layouts. The active
/// service is marked with an accent border and a faint accent wash; unselected
/// tabs are plain and blend into the strip. Icon resolution and the fallback
/// palette are shared with the vertical rail via `ServiceIconSquare`.
///
/// `iconOnly` drops the name to a compact icon tab (Chrome-style), which frees
/// room in the strip for a window-drag gap; the name still shows as a tooltip.
struct ServiceTabView: View {
    let instance: ServiceInstance
    let isSelected: Bool
    var badgeCount: Int = 0
    var isHibernated: Bool = false
    var isMuted: Bool = false
    var iconOnly: Bool = false
    var cameraActive: Bool = false
    var micActive: Bool = false
    var micMuted: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    private let minWidth: CGFloat = 120
    private let maxWidth: CGFloat = 220
    private let cornerRadius: CGFloat = 7
    static let height: CGFloat = 30

    var body: some View {
        Button(action: action) {
            content
                .frame(height: Self.height)
                .opacity(isHibernated ? 0.6 : (isMuted ? 0.8 : 1.0))
                // Fill + clip only the background to the rounded shape — do NOT
                // wrap `content` in a whole-view clipShape: the icon-only badge
                // sits at a small top-trailing negative offset and a view clip
                // would shave its corner. The border is a stroke overlay (no clip).
                .background(fillStyle, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear),
                            lineWidth: 1.5
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(iconOnly ? instance.label : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ServiceAccessibility.label(
            name: instance.label,
            badgeCount: badgeCount,
            isHibernated: isHibernated,
            isMuted: isMuted,
            cameraActive: cameraActive,
            micActive: micActive,
            micMuted: micMuted
        ))
        .accessibilityAddTraits([.isButton, isSelected ? .isSelected : []])
    }

    @ViewBuilder
    private var content: some View {
        if iconOnly {
            ZStack(alignment: .topTrailing) {
                ServiceIconSquare(instance: instance, size: 18, cornerRadius: 4)
                    .padding(.horizontal, 8)
                    .frame(height: Self.height)

                if badgeCount > 0 && instance.showBadge {
                    BadgeCountView(count: badgeCount).offset(x: 2, y: -2)
                } else if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }

                MediaIndicatorGlyph(cameraActive: cameraActive, micActive: micActive, micMuted: micMuted)
                    .offset(x: -10, y: 8)
            }
        } else {
            HStack(spacing: 8) {
                ServiceIconSquare(instance: instance, size: 18, cornerRadius: 4)

                Text(instance.label)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer(minLength: 0)

                if badgeCount > 0 && instance.showBadge {
                    BadgeCountView(count: badgeCount)
                } else if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: minWidth, maxWidth: maxWidth)
        }
    }

    private var fillStyle: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(.tint.opacity(0.10))
        } else if isHovering {
            return AnyShapeStyle(Color.primary.opacity(0.06))
        }
        return AnyShapeStyle(Color.clear)
    }
}
