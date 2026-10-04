import AppKit
import WebKit

/// Presents provider dialogs without logging their contents. Both inbox and
/// standalone compose views must answer these; WebKit otherwise cancels them.
@MainActor
enum WebViewDialogs {
    static func alert(_ message: String, over webView: WKWebView, completion: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        present(alert, over: webView, session: DialogSession(cancelValue: (), completion)) { _ in () }
    }

    static func confirm(_ message: String, over webView: WKWebView, completion: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, over: webView, session: DialogSession(cancelValue: false, completion)) {
            $0 == .alertFirstButtonReturn
        }
    }

    static func prompt(_ message: String, defaultText: String?, over webView: WKWebView, completion: @escaping @MainActor (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        present(alert, over: webView, session: DialogSession(cancelValue: String?.none, completion)) {
            $0 == .alertFirstButtonReturn ? field.stringValue : nil
        }
    }

    private static func present<T>(
        _ alert: NSAlert, over webView: WKWebView, session: DialogSession<T>,
        map: @escaping (NSApplication.ModalResponse) -> T
    ) {
        if let window = webView.window {
            session.observeClose(of: window)
            alert.beginSheetModal(for: window) { session.finish(map($0)) }
        } else {
            session.finish(map(alert.runModal()))
        }
    }
}

/// Resolves WebKit's blocked script exactly once, including when its host closes
/// before the sheet answers. The sheet retains this session until it completes.
@MainActor
private final class DialogSession<T> {
    private var completion: (@MainActor (T) -> Void)?
    private var closeObserver: NSObjectProtocol?
    private let cancelValue: T

    init(cancelValue: T, _ completion: @escaping @MainActor (T) -> Void) {
        self.cancelValue = cancelValue
        self.completion = completion
    }

    func observeClose(of window: NSWindow) {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.finish(self.cancelValue)
            }
        }
    }

    func finish(_ value: T) {
        guard let completion else { return }
        self.completion = nil
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        completion(value)
    }
}
