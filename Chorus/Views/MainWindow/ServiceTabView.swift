import SwiftUI

/// A service rendered as a folder tab (icon + name + badge) for the top-bar and
/// hybrid layouts. The selected tab sits on a raised surface with a rounded top
/// and an accent "spine", and its bottom is flush with the bar so it reads as
/// part of the content below; unselected tabs stay recessed in the bar. Icon
/// resolution and the fallback palette are shared with the vertical rail via
/// `ServiceIconSquare`.
struct ServiceTabView: View {
    let instance: ServiceInstance
    let isSelected: Bool
    var badgeCount: Int = 0
    var isHibernated: Bool = false
    var isMuted: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    private let minWidth: CGFloat = 120
    private let maxWidth: CGFloat = 220
    private let cornerRadius: CGFloat = 8
    static let height: CGFloat = 32

    var body: some View {
        Button(action: action) {
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
            .frame(height: Self.height)
            .opacity(isHibernated ? 0.6 : (isMuted ? 0.8 : 1.0))
            .background(background)
            .overlay(alignment: .top) {
                // Accent spine along the selected tab's top edge — the folder-tab
                // cue. Drawn before the clip so it follows the rounded corners.
                if isSelected {
                    Rectangle()
                        .fill(.tint)
                        .frame(height: 2.5)
                }
            }
            .clipShape(.rect(topLeadingRadius: cornerRadius, topTrailingRadius: cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ServiceAccessibility.label(
            name: instance.label,
            badgeCount: badgeCount,
            isHibernated: isHibernated,
            isMuted: isMuted
        ))
        .accessibilityAddTraits([.isButton, isSelected ? .isSelected : []])
    }

    /// The bar matches the title-bar shade, so the selected tab takes the
    /// content surface (controlBackgroundColor) to stand off it and read as part
    /// of the page: lighter than the bar in light mode, darker in dark mode.
    /// Inactive tabs are transparent so they blend into the top chrome; hover is
    /// a faint wash.
    @ViewBuilder
    private var background: some View {
        if isSelected {
            Color(nsColor: .controlBackgroundColor)
        } else if isHovering {
            Color.primary.opacity(0.06)
        } else {
            Color.clear
        }
    }
}
