import SwiftUI

/// Whether a service's page is up, coming up, or broken.
///
/// Chorus is entirely web views whose sessions expire without saying so, which
/// is the UX audit's complaint this answers: a service that failed to load, or
/// that is still loading, looked exactly like one sitting there working.
///
/// Three of the four states are reachable. `signedOut` is drawn and never set —
/// there is no general signal for it, since every service signs you out to its
/// own URL with its own markup, and the one precedent for per-service scraping
/// (`ServiceCSSDefaults`, which ships CSS for exactly one service in the whole
/// catalog) is the standing argument against pretending otherwise. The case
/// exists so the rail can draw it the day someone prices it per service.
enum ServiceHealth: Equatable, CaseIterable {
    /// Loaded and working. Draws nothing — a dot on every service would be noise.
    case live
    case loading
    case failed
    case signedOut

    /// What can happen to a service's page. Deliberately small: these are the
    /// three navigation callbacks the app already receives.
    enum Event: CaseIterable {
        case startedLoading
        case finishedLoading
        case failed
    }

    /// The state a navigation event moves this one to.
    ///
    /// Pure, so the transitions can be tested without a web view. Note that
    /// `startedLoading` beats a standing failure: a retry is genuinely in
    /// progress, and leaving the orange dot up through a successful reload
    /// would be a lie until the load finished.
    func next(_ event: Event) -> ServiceHealth {
        switch event {
        case .startedLoading: return .loading
        case .finishedLoading: return .live
        case .failed: return .failed
        }
    }

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
