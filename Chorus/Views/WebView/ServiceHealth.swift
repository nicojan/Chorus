import Foundation

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
        /// A load that ended without finishing or failing: the user pressed
        /// Stop, another navigation replaced it, or it turned into a download.
        case stoppedLoading
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
        // The ring comes down; the page that was on screen before the load is
        // still there. A failure standing from earlier stays up.
        case .stoppedLoading: return self == .failed ? .failed : .live
        case .failed: return .failed
        }
    }
}
