import ChorusEngine
import SwiftUI

/// Shared colors and helpers for service icons. Centralized so every surface
/// that draws a service — the rail's `ServiceRowView`, the space chips, the
/// quick switcher — renders identically and contrast is fixed in one place.
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
    /// A count you already know about, where there is no name to sit beside:
    /// grey, the same meaning as a grey count on a named row. #6B7280 clears
    /// 4.5:1 with white.
    static let badgeGrey = Color(red: 0.420, green: 0.447, blue: 0.502)

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
            // A Mac app that has been deleted or moved off this Mac shows grey.
            .saturation(isMissingApp ? 0 : 1)
            .opacity(isMissingApp ? 0.45 : 1)
    }

    private var isMissingApp: Bool {
        guard let bundleID = instance.nativeAppBundleID else { return false }
        return NativeApp.appURL(bundleID: bundleID) == nil
    }

    /// Decodes icon bytes, resolving to the largest representation available.
    ///
    /// `NSImage(data:)` on a multi-size `.ico` reports the size of the FIRST
    /// directory entry rather than the biggest. Notion's favicon lists its sizes
    /// smallest-first (16, 32, 48, 64), so the image arrived declaring 16×16 and
    /// `.resizable()` upscaled that thumbnail — the icon rendered blurry. Picking
    /// the largest rep and restating the size fixes it; for a single-rep PNG
    /// (every other bundled and fetched icon) the sizes already agree and this is
    /// a no-op.
    private static func iconImage(from data: Data) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        guard let largest = image.representations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }), largest.pixelsWide > Int(image.size.width) else { return image }
        image.size = NSSize(width: largest.pixelsWide, height: largest.pixelsHigh)
        return image
    }

    @ViewBuilder
    private var content: some View {
        if let data = instance.customIconData, let nsImage = Self.iconImage(from: data) {
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
        } else if let data = instance.fetchedIconData, let nsImage = Self.iconImage(from: data) {
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

/// Builds the spoken label for a service cell so the rail and the tabs read the
/// same to VoiceOver.
enum ServiceAccessibility {
    /// The group a service's row sits in, as VoiceOver says it: by its name,
    /// or, with none, by the other services in its box.
    enum GroupContext: Equatable {
        case named(String)
        case unnamed(others: [String])

        /// "in Google", or "in a group with Calendar and Drive".
        var spoken: String {
            switch self {
            case .named(let name): return "in \(name)"
            case .unnamed(let others): return "in a group with \(AppState.listed(others))"
            }
        }
    }

    /// A group's box as VoiceOver names it: by the group's name, or, with
    /// none, "Group: Gmail and Drive".
    static func groupLabel(name: String?, members: [String]) -> String {
        name ?? "Group: \(AppState.listed(members))"
    }

    static func label(
        name: String,
        badgeCount: Int,
        isHibernated: Bool,
        isMuted: Bool,
        cameraActive: Bool = false,
        micActive: Bool = false,
        micMuted: Bool = false,
        isPlayingAudio: Bool = false,
        health: ServiceHealth = .live,
        needsAttention: Bool = false,
        group: GroupContext? = nil
    ) -> String {
        var parts = [name]
        if badgeCount > 0 {
            parts.append(badgeCount == 1 ? "1 unread" : "\(badgeCount) unread")
            // What the pulse says to the eye, said to VoiceOver.
            if needsAttention { parts.append("new since you last looked") }
        }
        if isHibernated { parts.append("hibernated") }
        if isMuted { parts.append("muted") }
        // The health dot separates its states by shape as well as hue, but a dot
        // of any shape is still nothing to a screen reader — the state has to be
        // said.
        if health.drawsDot { parts.append(health.spokenDescription) }
        if cameraActive { parts.append("camera in use") }
        if micActive {
            parts.append("microphone in use")
        } else if micMuted {
            parts.append("microphone muted")
        }
        if isPlayingAudio { parts.append("playing audio") }
        // Last, so the state of the service comes first and the box after it.
        if let group { parts.append(group.spoken) }
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
    /// The count went up while you were elsewhere: red, and it pulses until
    /// seen. Otherwise grey, so a nameless badge keeps the same two meanings as
    /// a count on a named row.
    var needsAttention = false

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold))
            // Its own width, whatever it is offered: laid over an 18 point
            // icon, "99+" was cut down to an ellipsis.
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(
                Capsule()
                    .fill(needsAttention ? ServiceIconPalette.badgeRed : ServiceIconPalette.badgeGrey)
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
                    )
            )
            .countMotion(count, needsAttention: needsAttention)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Puts a count badge over this view's top-trailing corner, the way the
    /// Dock does: the badge's middle sits inside the corner, so it plainly
    /// overlaps the edge, a selection fill or a focus ring, instead of grazing
    /// it. Used on the nameless cells and tiles; rows with names carry their
    /// badge inline.
    func cornerBadge(_ count: Int, visible: Bool = true, needsAttention: Bool = false) -> some View {
        overlay(alignment: .topTrailing) {
            if visible && count > 0 {
                PoppingBadge(count: count, needsAttention: needsAttention)
                    .offset(x: 5, y: -5)
            }
        }
    }
}

/// What a service looks like under the pointer while it is dragged: its own
/// icon, a little larger than in the rail, on a soft shadow so it lifts off
/// whatever it passes over.
struct ServiceDragPreview: View {
    let service: ServiceInstance

    var body: some View {
        ServiceIconSquare(instance: service, size: 28, cornerRadius: 6)
            .padding(4)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

/// An unread count the way the Notes sidebar shows one: a plain number at the
/// end of a row that carries a name, in the row's own type, grey, and the
/// label's colour on the selected row. The badge is for places where there
/// is no name to sit beside: nameless cells, tiles and the tab bar; it is grey
/// or red by the same rule.
struct SidebarCount: View {
    let count: Int
    var isSelected = false
    /// The count went up while you were elsewhere: red, and pulsing until seen.
    var needsAttention = false

    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(ChorusType.label)
            .fontWeight(needsAttention ? .semibold : .regular)
            .monospacedDigit()
            .foregroundStyle(color)
            .fixedSize()
            .countMotion(count, needsAttention: needsAttention)
            .accessibilityHidden(true)
    }

    private var color: AnyShapeStyle {
        if needsAttention { return AnyShapeStyle(ServiceIconPalette.badgeRed) }
        return isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(ChorusColor.secondaryText)
    }
}

/// How a count moves: a quick flash when it goes up, and a slow pulse while
/// it waits to be seen (see `BadgeManager.attentionIDs`). Under Reduce Motion
/// it stays still; the red of a waiting count still marks it.
private struct CountMotion: ViewModifier {
    let count: Int
    let needsAttention: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFlashing = false
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            // One scale each, so the flash's spring never takes over the
            // pulse's repeating animation and leaves it frozen part way.
            .scaleEffect(isPulsing ? 1.12 : 1)
            .scaleEffect(isFlashing ? 1.25 : 1)
            .onChange(of: reduceMotion) { _, reduced in
                if reduced {
                    isPulsing = false
                } else if needsAttention {
                    startPulse()
                }
            }
            .onChange(of: count) { old, new in
                guard new > old, !reduceMotion else { return }
                withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { isFlashing = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { isFlashing = false }
                }
            }
            .onChange(of: needsAttention, initial: true) { _, waiting in
                guard !reduceMotion else { isPulsing = false; return }
                if waiting {
                    startPulse()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { isPulsing = false }
                }
            }
    }

    private func startPulse() {
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { isPulsing = true }
    }
}

extension View {
    /// Flashes this count when it goes up and pulses it while it waits to be
    /// seen. See `CountMotion`.
    func countMotion(_ count: Int, needsAttention: Bool) -> some View {
        modifier(CountMotion(count: count, needsAttention: needsAttention))
    }
}

/// A corner badge that springs up as it appears: when the rail shrinks to its
/// icons, and when a count arrives. It just appears under Reduce Motion.
private struct PoppingBadge: View {
    let count: Int
    let needsAttention: Bool
    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BadgeCountView(count: count, needsAttention: needsAttention)
            .scaleEffect(isShown ? 1 : 0.3)
            .opacity(isShown ? 1 : 0)
            .onAppear {
                if reduceMotion {
                    isShown = true
                } else {
                    // A beat after the rail starts to shrink, so the badges
                    // land once the icons are in place.
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.6).delay(0.12)) {
                        isShown = true
                    }
                }
            }
    }
}
