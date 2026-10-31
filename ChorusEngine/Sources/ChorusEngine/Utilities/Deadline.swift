import Foundation

/// Runs `operation` and returns its result, or `fallback` once `seconds` pass,
/// whichever comes first.
///
/// For WebKit calls that can hang. A wedged WebContent process can leave
/// `evaluateJavaScript`'s continuation pending forever, and it isn't
/// cancellation-aware, so a structured `withTaskGroup` can't bound it: the group
/// implicitly awaits every child before returning, and `cancelAll()` wouldn't
/// unstick the call. So this races two unstructured main-actor tasks — the
/// operation and a timer — and resumes with whichever answers first, abandoning
/// (not awaiting) the loser. A leaked wedged call lingers until the OS reaps the
/// process.
@MainActor
public func withDeadline<T: Sendable>(
    seconds: Double,
    fallback: T,
    _ operation: @escaping @MainActor () async -> T
) async -> T {
    await withCheckedContinuation { continuation in
        let gate = OneShotGate()
        Task { @MainActor in
            let value = await operation()
            if gate.claim() { continuation.resume(returning: value) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if gate.claim() { continuation.resume(returning: fallback) }
        }
    }
}

/// Lets exactly one of `withDeadline`'s two racing tasks resume the
/// continuation. Both racers are `@MainActor`, so the plain flag is only ever
/// touched on the main actor and needs no lock.
@MainActor
private final class OneShotGate {
    private var used = false
    func claim() -> Bool {
        if used { return false }
        used = true
        return true
    }
}
