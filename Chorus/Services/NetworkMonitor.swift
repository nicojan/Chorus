import Foundation
import Network

/// Lightweight wrapper around NWPathMonitor exposing a SwiftUI-observable
/// `isOnline` flag. Used by ContentView to show an offline banner and by
/// NotificationManager to suspend polling while the network is unreachable.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline: Bool = true

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.nicojan.Chorus.NetworkMonitor")

    /// Callback fired whenever connectivity toggles. Lets NotificationManager
    /// pause/resume polling without polling the `isOnline` flag itself.
    var onChange: ((Bool) -> Void)?

    init() {
        self.monitor = NWPathMonitor()
        self.monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isOnline != online else { return }
                self.isOnline = online
                self.onChange?(online)
            }
        }
        self.monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
