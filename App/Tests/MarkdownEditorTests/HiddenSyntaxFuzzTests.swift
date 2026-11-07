import Foundation
import XCTest
@testable import MarkdownEditor

/// Backspace and forward delete at any caret, in notes of every kind of block, ask for an edit the text view can make:
/// ranges inside the text, in order, apart, and a caret inside the text after the edit.
final class HiddenSyntaxFuzzTests: XCTestCase {
    private let pieces = [
        "# Heading", "A **bold** and *italic* `code` ~~strike~~ [link](https://a.b)", "- item", "- [ ] task\n  - [x] nested",
        "1. first\n2. second", "> a quote\n> more", "> [!NOTE]\n> callout", "```swift\nlet a = 1\n```", "---",
        "![](picture.png)", "Plain ==mark== line", "",
    ]

    func testEveryDeletionIsAnEditTheTextViewCanMake() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            var text = Bool.random(using: &generator) ? "---\ntags: [a]\n---\n" : ""
            for index in 0..<Int.random(in: 1...6, using: &generator) {
                if index > 0 { text += Bool.random(using: &generator) ? "\n\n" : "\n" }
                text += pieces.randomElement(using: &generator)!
            }
            let syntax = HiddenSyntax(spans: MarkdownStyler.spans(in: text), text: text)
            let length = (text as NSString).length
            for caret in 0...length {
                for deletion in [syntax.deleteBackward(caret: caret), syntax.deleteForward(caret: caret)].compactMap({ $0 }) {
                    let context = "caret \(caret) in \(text.debugDescription): \(deletion)"
                    var end = 0
                    for range in deletion.ranges {
                        XCTAssertGreaterThanOrEqual(range.location, end, "ranges in order and apart, \(context)")
                        XCTAssertLessThanOrEqual(NSMaxRange(range), length, "range inside the text, \(context)")
                        end = NSMaxRange(range)
                    }
                    let removed = deletion.ranges.reduce(0) { $0 + $1.length }
                    XCTAssertTrue((0...(length - removed)).contains(deletion.caret), "caret inside the new text, \(context)")
                    if deletion.ranges.isEmpty { XCTAssertNotEqual(deletion.caret, caret, "a deletion that does nothing, \(context)") }
                }
            }
        }
    }
}
