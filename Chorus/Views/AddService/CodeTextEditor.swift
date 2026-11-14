import AppKit
import SwiftUI

/// A plain-text editor for a service's Custom CSS and Custom JavaScript.
///
/// SwiftUI's `TextEditor` follows the Mac's typing settings, which turn `'`
/// into a curly quote and `--` into a dash. A script typed that way fails to
/// parse, so it never ran. This one turns every substitution off.
struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String

    /// The scroll view and its text view, set up for code. Tests type into
    /// the text view this returns.
    static func makeScrollView() -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular
        )
        textView.textContainerInset = NSSize(width: 2, height: 4)
        return scrollView
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = Self.makeScrollView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.string = text
            textView.delegate = context.coordinator
            textView.setAccessibilityLabel(label)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
