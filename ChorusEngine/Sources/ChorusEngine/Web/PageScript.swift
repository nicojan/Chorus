import WebKit

/// Runs a script in a page without the wait keeping the page's web view alive.
///
/// `try await webView.evaluateJavaScript(...)` holds the web view until the
/// page answers, and a page whose process has stopped answering never does.
/// Neither cancelling the task nor tearing the page down ends that wait, so the
/// web view outlives its service, and WebKit keeps its data store in use:
/// removing it fails with "Data store is in use", and clearing it waits on the
/// stuck process. That is how removing Drive and adding a service back hung on
/// 2026-11-10.
///
/// Here the wait is a continuation parked in a table. WebKit's completion
/// handler, which holds no reference to the view, resumes it when the page
/// answers; `abandonPending(for:)`, which the pool calls when it tears a page
/// down, and cancelling the task resume it with `CancellationError`.
@MainActor
public enum PageScript {
    private typealias Waiter = CheckedContinuation<ScriptResult, Error>

    /// Parked waits by web view, then by call.
    private static var pending: [ObjectIdentifier: [UUID: Waiter]] = [:]

    public static func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        let view = ObjectIdentifier(webView)
        let call = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Waiter) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[view, default: [:]][call] = continuation
                webView.evaluateJavaScript(script) { value, error in
                    MainActor.assumeIsolated {
                        if let error {
                            finish(call, of: view, with: .failure(error))
                        } else {
                            finish(call, of: view, with: .success(ScriptResult(value: value)))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in finish(call, of: view, with: .failure(CancellationError())) }
        }
        return result.value
    }

    /// Ends every wait on `webView`'s page. Call it when the page is torn down.
    public static func abandonPending(for webView: WKWebView) {
        guard let waiters = pending.removeValue(forKey: ObjectIdentifier(webView)) else { return }
        for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
    }

    /// Resumes one wait, once: whichever of the answer, a cancel or a teardown
    /// comes first wins, and the others find nothing to resume.
    private static func finish(_ call: UUID, of view: ObjectIdentifier, with outcome: Result<ScriptResult, Error>) {
        guard let waiter = pending[view]?.removeValue(forKey: call) else { return }
        if pending[view]?.isEmpty == true { pending.removeValue(forKey: view) }
        waiter.resume(with: outcome)
    }

    /// Whether any wait is parked, for tests.
    static var hasPending: Bool { !pending.isEmpty }
}

/// A script's value, carried across the continuation. WebKit hands back plain
/// property-list values (strings, numbers, arrays, dictionaries), and every
/// hop here stays on the main actor.
private struct ScriptResult: @unchecked Sendable {
    let value: Any?
}
