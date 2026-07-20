import SwiftUI

/// Shared colors and helpers for service icons. Centralized so the vertical rail
/// (`ServiceIconView`) and the horizontal folder tabs (`ServiceTabView`) render
/// identically and so contrast is fixed in one place.
enum ServiceIconPalette {
    /// Fill colors for the letter-tile fallback. Each is dark enough to clear
    /// WCAG 4.5:1 against the white initial drawn on top (Tailwind 700-class
    /// shades). The previous `.blue/.orange/.teal/...` set failed that bar.
    static let tileColors: [Color] = [
        Color(red: 0.114, green: 0.306, blue: 0.847), // #1D4ED8
        Color(red: 0.427, green: 0.157, blue: 0.851), // #6D28D9
        Color(red: 0.082, green: 0.502, blue: 0.239), // #15803D
        Color(red: 0.761, green: 0.255, blue: 0.047), // #C2410C
        Color(red: 0.745, green: 0.094, blue: 0.365), // #BE185D
        Color(red: 0.059, green: 0.463, blue: 0.431), // #0F766E
        Color(red: 0.263, green: 0.220, blue: 0.792), // #4338CA
        Color(red: 0.725, green: 0.110, blue: 0.110), // #B91C1C
    ]

    /// Notification badge fill. #DC2626 clears 4.5:1 with white; pure system red
    /// does not.
    static let badgeRed = Color(red: 0.863, green: 0.149, blue: 0.149)

    static func color(for label: String) -> Color {
        tileColors[stableHash(label) % tileColors.count]
    }

    static func initial(for label: String) -> String {
        String(label.prefix(1)).uppercased()
    }

    static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Int(hash % UInt64(Int.max))
    }
}

/// The icon square for a service: custom icon → fetched favicon → letter-tile
/// fallback. One source of truth for icon resolution — sub-project B slots
/// bundled brand icons in here and every consumer picks them up.
struct ServiceIconSquare: View {
    let instance: ServiceInstance
    var size: CGFloat = 32
    var cornerRadius: CGFloat = 8

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    private var content: some View {
        if let data = instance.customIconData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let brand = brandAssetName {
            // Bundled brand mark. Monochrome logos are template assets and tint
            // to .primary so they stay visible in dark mode; colored logos are
            // "original" assets and ignore the tint.
            Image(brand)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
        } else if let data = instance.fetchedIconData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Text(ServiceIconPalette.initial(for: instance.label))
                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(ServiceIconPalette.color(for: instance.label))
        }
    }

    /// The bundled brand asset for this service (`brand-<catalogEntryID>`), or
    /// nil when there's no catalog match or no bundled icon — falling through to
    /// the fetched favicon and then the letter tile.
    private var brandAssetName: String? {
        guard let id = instance.catalogEntryID else { return nil }
        let name = "brand-\(id)"
        return NSImage(named: name) != nil ? name : nil
    }
}

struct ServiceIconView: View {
    let instance: ServiceInstance
    let isSelected: Bool
    var badgeCount: Int = 0
    var isHibernated: Bool = false
    var isMuted: Bool = false
    var cameraActive: Bool = false
    var micActive: Bool = false
    var micMuted: Bool = false

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            // Selection indicator — matches the space strip's accent pill
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tint)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 3, height: 28)

            ZStack(alignment: .topTrailing) {
                ServiceIconSquare(instance: instance, size: 32, cornerRadius: 8)
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

                if isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: 18)
                        .accessibilityHidden(true)
                }

                MediaIndicatorGlyph(cameraActive: cameraActive, micActive: micActive, micMuted: micMuted)
                    .offset(x: -12, y: 18)
            }
            .frame(width: 40, height: 40)
            .opacity(isHibernated ? 0.5 : (isMuted ? 0.75 : 1.0))
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 3)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
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

    private var backgroundColor: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(.tint.opacity(0.20))
        } else if isHovering {
            return AnyShapeStyle(Color.primary.opacity(0.06))
        }
        return AnyShapeStyle(Color.clear)
    }
}

/// Builds the spoken label for a service cell so the rail and the tabs read the
/// same to VoiceOver.
enum ServiceAccessibility {
    static func label(
        name: String,
        badgeCount: Int,
        isHibernated: Bool,
        isMuted: Bool,
        cameraActive: Bool = false,
        micActive: Bool = false,
        micMuted: Bool = false
    ) -> String {
        var parts = [name]
        if badgeCount > 0 {
            parts.append(badgeCount == 1 ? "1 unread" : "\(badgeCount) unread")
        }
        if isHibernated { parts.append("hibernated") }
        if isMuted { parts.append("muted") }
        if cameraActive { parts.append("camera in use") }
        if micActive {
            parts.append("microphone in use")
        } else if micMuted {
            parts.append("microphone muted")
        }
        return parts.joined(separator: ", ")
    }
}

/// The camera/microphone "in use" glyph shown on a service cell. Camera takes
/// precedence (video implies the mic is live too); a muted-only mic shows the
/// slash. Renders nothing when nothing is live.
struct MediaIndicatorGlyph: View {
    let cameraActive: Bool
    let micActive: Bool
    let micMuted: Bool

    var body: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(3)
                .background(Circle().fill(tint))
                .accessibilityHidden(true)
        }
    }

    private var symbol: String? {
        if cameraActive { return "video.fill" }
        if micActive { return "mic.fill" }
        if micMuted { return "mic.slash.fill" }
        return nil
    }

    /// Green while genuinely live; orange when the only thing engaged is a muted
    /// mic (a call you've muted yourself into).
    private var tint: Color {
        (micMuted && !cameraActive && !micActive) ? .orange : .green
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
                    .fill(ServiceIconPalette.badgeRed)
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
                    )
            )
            .accessibilityHidden(true)
    }
}
