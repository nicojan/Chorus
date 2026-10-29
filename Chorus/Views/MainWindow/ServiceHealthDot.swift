import ChorusEngine
import SwiftUI

/// How the rail draws a service's health. The states and their transitions
/// live with the web engine (`ServiceHealth`); the look is Chorus's own.
extension ServiceHealth {
    /// Whether the rail draws a mark at all.
    var drawsDot: Bool { self != .live }

    /// The mark's silhouette, and the reason there is one.
    ///
    /// The drawn frame separates the three states by hue alone, at 9 points.
    /// That fails a red-green colour-blind user, and it fails the argument this
    /// app's own audit makes elsewhere, so each state takes a shape of its own
    /// as well: a ring for work in progress, a solid disc for a failure, a
    /// square for a session that ended. The colours stay as drawn.
    enum DotShape: Hashable {
        case ring
        case disc
        case square
    }

    var dotShape: DotShape {
        switch self {
        case .loading: return .ring
        case .failed: return .disc
        case .signedOut: return .square
        case .live: return .disc   // never drawn; `drawsDot` is false
        }
    }

    /// Straight off the drawn specimen.
    var dotColor: Color {
        switch self {
        case .loading: return Color(red: 0.557, green: 0.557, blue: 0.576)  // #8E8E93
        case .failed: return Color(red: 1.0, green: 0.624, blue: 0.039)     // #FF9F0A
        case .signedOut: return Color(red: 1.0, green: 0.231, blue: 0.188)  // #FF3B30
        case .live: return .clear
        }
    }

    /// What VoiceOver says. Empty for `live`, which has nothing to report.
    var spokenDescription: String {
        switch self {
        case .live: return ""
        case .loading: return "loading"
        case .failed: return "failed to load"
        case .signedOut: return "signed out"
        }
    }
}

/// The health mark on a service icon's bottom-right corner.
struct ServiceHealthDot: View {
    let health: ServiceHealth
    var size: CGFloat = 9

    var body: some View {
        if health.drawsDot {
            shape
                .frame(width: size, height: size)
                // A hairline of the window behind it, so the mark stays readable
                // against a dark service icon.
                .background(
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: size + 2, height: size + 2)
                )
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var shape: some View {
        switch health.dotShape {
        case .ring:
            Circle().strokeBorder(health.dotColor, lineWidth: 2)
        case .disc:
            Circle().fill(health.dotColor)
        case .square:
            RoundedRectangle(cornerRadius: 1.5).fill(health.dotColor)
        }
    }
}
