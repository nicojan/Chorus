import SwiftUI

/// A service rendered as a horizontal folder tab (icon + name + badge), used by
/// the top-bar and hybrid layouts. The selected tab sits on a neutral surface
/// with an accent underline so selection reads by position and shape, not color
/// alone. Icon resolution and the fallback palette are shared with the vertical
/// rail via `ServiceIconSquare`.
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
    static let height: CGFloat = 36

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
            .clipShape(.rect(topLeadingRadius: 8, topTrailingRadius: 8))
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(.tint)
                        .frame(height: 2)
                }
            }
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

    @ViewBuilder
    private var background: some View {
        if isSelected {
            // A clearly-lifted chip (Chrome-style active tab). primary.opacity
            // reads in both modes: a light lift on the dark bar, a darker chip
            // on the light bar — the underline alone wasn't enough contrast.
            Color.primary.opacity(0.14)
        } else if isHovering {
            Color.primary.opacity(0.06)
        } else {
            Color.clear
        }
    }
}
