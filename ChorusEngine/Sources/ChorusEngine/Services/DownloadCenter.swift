import AppKit
import Foundation

/// Every download this session, from every service, in one list.
///
/// Chorus used to save files to Downloads with no word beyond a bounce of the
/// Dock stack. Nothing showed a file still coming in, one that failed, or which
/// service it came from, and there was no way to stop one. This is the list the
/// toolbar's download button shows.
///
/// It holds no `WKDownload`. The coordinator that owns the download hands over
/// its `Progress` and a way to cancel it, and reports how it ended. That keeps
/// WebKit out of the list's rules, so they are testable with a plain
/// `Progress`. The list lives in memory only: it is a session's record, and a
/// finished file is in Downloads whether or not the row survives a relaunch.
@MainActor
@Observable
public final class DownloadCenter {
    public enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    public struct Item: Identifiable, Equatable {
        public let id: UUID
        public let serviceID: UUID?
        public let serviceName: String?
        public var filename: String
        public var destination: URL?
        public var state: State
        /// 0...1 while running, nil when the size is unknown.
        public var fraction: Double?

        public var isRunning: Bool { state == .running }
    }

    public init() {}

    /// Newest first.
    public private(set) var items: [Item] = []

    /// How many rows the list keeps. Past this the oldest finished rows go;
    /// running ones always stay.
    static let maxItems = 50

    /// Resolves a service id to the name shown on its rows. Set by `AppState`.
    @ObservationIgnored public var serviceName: ((UUID) -> String?)?

    @ObservationIgnored private var cancelHandlers: [UUID: () -> Void] = [:]
    @ObservationIgnored private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    public var hasRunning: Bool { items.contains(where: \.isRunning) }

    /// The combined progress of the running downloads whose size is known, for
    /// the toolbar ring. Nil when none is running or no size is known.
    public var overallFraction: Double? {
        let known = items.filter(\.isRunning).compactMap(\.fraction)
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    /// Starts a row. Returns the id the coordinator reports the rest of the
    /// download's life under.
    @discardableResult
    func begin(
        serviceID: UUID?,
        filename: String,
        progress: Progress?,
        cancel: @escaping () -> Void
    ) -> UUID {
        let id = UUID()
        let name = serviceID.flatMap { serviceName?($0) }
        items.insert(
            Item(id: id, serviceID: serviceID, serviceName: name, filename: filename, destination: nil, state: .running, fraction: nil),
            at: 0
        )
        cancelHandlers[id] = cancel
        if let progress {
            progressObservations[id] = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                let fraction = Self.knownFraction(of: progress)
                Task { @MainActor [weak self] in self?.updateFraction(fraction, for: id) }
            }
        }
        trim()
        return id
    }

    /// The file's final name and place, once the coordinator has picked them.
    func setDestination(_ url: URL, for id: UUID) {
        update(id) { item in
            item.destination = url
            item.filename = url.lastPathComponent
        }
    }

    /// A row ends once. A late report for a row that already ended, such as a
    /// finish that crosses a Cancel, leaves it as it is.
    public func finish(_ id: UUID) {
        guard item(id)?.isRunning == true else { return }
        end(id, as: .finished)
    }

    func fail(_ id: UUID, message: String) {
        guard item(id)?.isRunning == true else { return }
        end(id, as: .failed(message))
    }

    public func cancel(_ id: UUID) {
        guard item(id)?.isRunning == true else { return }
        cancelHandlers[id]?()
        end(id, as: .cancelled)
    }

    /// Removes every row that is no longer running.
    public func clearFinished() {
        items.removeAll { !$0.isRunning }
    }

    public func reveal(_ id: UUID) {
        guard let url = item(id)?.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func open(_ id: UUID) {
        guard let item = item(id), item.state == .finished, let url = item.destination else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internals

    /// `fractionCompleted` reads 0 for a download of unknown size, which would
    /// draw a ring stuck at empty. Report "unknown" instead.
    nonisolated static func knownFraction(of progress: Progress) -> Double? {
        guard progress.totalUnitCount > 0 else { return nil }
        return min(max(progress.fractionCompleted, 0), 1)
    }

    private func item(_ id: UUID) -> Item? {
        items.first { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        items[index] = item
    }

    private func updateFraction(_ fraction: Double?, for id: UUID) {
        update(id) { item in
            guard item.isRunning else { return }
            item.fraction = fraction
        }
    }

    private func end(_ id: UUID, as state: State) {
        update(id) { item in
            item.state = state
            if state == .finished { item.fraction = 1 }
        }
        cancelHandlers.removeValue(forKey: id)
        progressObservations.removeValue(forKey: id)?.invalidate()
    }

    private func trim() {
        while items.count > Self.maxItems,
              let oldestDone = items.lastIndex(where: { !$0.isRunning }) {
            items.remove(at: oldestDone)
        }
    }
}
