import AppKit
import XCTest

/// Waits until `condition` holds, polling, so tests on debounced work do not sleep longer than needed.
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return XCTFail("timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// The first text view under `view`: the editor inside a rendered tab.
@MainActor
func textView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
        if let found = textView(in: subview) { return found }
    }
    return nil
}
