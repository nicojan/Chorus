import Foundation
import Network

/// Lightweight wrapper around NWPathMonitor exposing a SwiftUI-observable
/// `isOnline` flag. Used by ContentView to show an offline banner and by
/// AppState to suspend polling while the network is unreachable.
@MainActor
@Observable
public final class NetworkMonitor {
    /// Defaults to `true` until the monitor's first update, which NWPathMonitor
    /// sends as soon as it starts with the current state. A Mac that launches
    /// offline reads false from that first update, which is what shows the
    /// banner. After that, `onChange` fires only on an actual transition.
    public private(set) var isOnline: Bool = true

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.nicojan.Chorus.NetworkMonitor")

    /// Callback fired whenever connectivity toggles. Lets AppState pause and
    /// resume polling without polling the `isOnline` flag itself.
    public var onChange: ((Bool) -> Void)?

    public init() {
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
