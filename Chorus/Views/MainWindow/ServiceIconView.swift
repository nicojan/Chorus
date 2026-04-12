import SwiftUI

struct ServiceIconView: View {
    let instance: ServiceInstance
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(backgroundColor)
                    .frame(width: 44, height: 44)

                iconContent
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .scaleEffect(isHovering ? 1.06 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovering)

            Text(instance.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 56)
        }
        .padding(.vertical, 4)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(instance.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var iconContent: some View {
        if let iconData = instance.customIconData,
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
            return Color.accentColor.opacity(0.15)
        } else if isHovering {
            return Color.primary.opacity(0.05)
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

    /// Deterministic hash that stays consistent across app launches
    /// (unlike Swift's randomized Hashable).
    private static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Int(hash % UInt64(Int.max))
    }
}
