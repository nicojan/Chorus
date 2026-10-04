import AppKit
import XCTest

/// Helpers shared by the mail-routing test files.
@MainActor
extension XCTestCase {
    func button(named title: String, in view: NSView?) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view?.subviews.lazy.compactMap { self.button(named: title, in: $0) }.first
    }

    func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}
