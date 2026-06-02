import SwiftUI

struct ServiceIconView: View {
    let instance: ServiceInstance
    let isSelected: Bool
    var badgeCount: Int = 0
    var isHibernated: Bool = false

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            // Selection indicator — matches the space strip's accent pill
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? Color.accentColor : .clear)
                .frame(width: 3, height: 28)

            ZStack(alignment: .topTrailing) {
                iconContent
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(backgroundColor)
                            .frame(width: 40, height: 40)
                    )

                if badgeCount > 0 && instance.showBadge {
                    BadgeCountView(count: badgeCount)
                        .offset(x: 4, y: -4)
                }

                if isHibernated {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .offset(x: -12, y: -4)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 40, height: 40)
            .opacity(isHibernated ? 0.5 : 1.0)
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 3)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel({
            var label = instance.label
            if badgeCount > 0 { label += ", \(badgeCount) unread" }
            if isHibernated { label += ", hibernated" }
            return label
        }())
        .accessibilityAddTraits([.isButton, isSelected ? .isSelected : []])
    }

    @ViewBuilder
    private var iconContent: some View {
        if let iconData = instance.customIconData,
           let nsImage = NSImage(data: iconData) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let iconData = instance.fetchedIconData,
                  let nsImage = NSImage(data: iconData) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Text(serviceInitial)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(serviceColor)
                )
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.12)
        } else if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }

    private var serviceInitial: String {
        String(instance.label.prefix(1)).uppercased()
    }

    private var serviceColor: Color {
        let colors: [Color] = [
            .blue, .purple, .green, .orange, .pink, .teal, .indigo, .red
        ]
        let hash = Self.stableHash(instance.label)
        return colors[hash % colors.count]
    }

    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Int(hash % UInt64(Int.max))
    }
}

struct BadgeCountView: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(
                Capsule()
                    .fill(.red)
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
                    )
            )
            .accessibilityHidden(true)
    }
}
