import SwiftUI

/// A service rendered as a bordered tab (icon + name + badge), used by the
/// top-bar and hybrid layouts. Every tab carries a hairline border so tabs read
/// as distinct elements; the selected tab gets an accent border and a lifted
/// surface. Icon resolution and the fallback palette are shared with the
/// vertical rail via `ServiceIconSquare`.
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
    private let cornerRadius: CGFloat = 7
    static let height: CGFloat = 30

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
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(borderStyle, lineWidth: isSelected ? 1.5 : 1)
            )
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

    /// Selected tab sits on a lifted surface (near-white in light, a lighter
    /// gray in dark) so it stands off the bar; hover is a faint wash.
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

    /// Accent border on the selected tab, a hairline separator on the rest, so
    /// every tab is delineated and the active one clearly reads.
    private var borderStyle: AnyShapeStyle {
        isSelected
            ? AnyShapeStyle(.tint)
            : AnyShapeStyle(Color(nsColor: .separatorColor))
    }
}
