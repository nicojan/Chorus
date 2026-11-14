import AppKit

/// Asks the user about permissions a running extension requests, such as a
/// password manager asking for a site after you click its button.
@MainActor
enum ExtensionPermissionPrompt {
    static func ask(extensionName: String, lines: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(extensionName) wants more access"
        alert.informativeText = "It asks to:\n" + lines.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
