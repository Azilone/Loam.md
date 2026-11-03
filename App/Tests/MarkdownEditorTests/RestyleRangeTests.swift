import AppKit
import XCTest
@testable import MarkdownEditor

@MainActor
final class RestyleRangeTests: XCTestCase {
    private func styling(_ text: String) -> EditorController.Styling {
        (Array(text.utf16), MarkdownStyler.spans(in: text), [])
    }

    /// A typed character restyles its paragraph, not the rest of the note: spans after the edit only moved, and the
    /// ones holding an offset of their own (a fenced block's code) must count as unchanged when they moved with it.
    func testATypedCharacterDoesNotRestyleTheFencedBlocksAfterIt() {
        let block = "```swift\nlet x = 1\n```\n"
        let text = "# Title\n\nfirst paragraph\n\n" + String(repeating: "para\n\n" + block + "\n", count: 20)
        let edit = (text as NSString).range(of: "first paragraph")
        let edited = (text as NSString).replacingCharacters(in: NSRange(location: NSMaxRange(edit), length: 0), with: "x")
        let range = EditorController.restyleRange(
            from: styling(text), to: styling(edited), in: edited as NSString
        )
        XCTAssertGreaterThan(range.length, 0)
        XCTAssertLessThan(range.length, 40, "the paragraph of the edit, not \(range.length) characters")
    }

    /// A line typed inside a code block restyles the whole block: restyled alone, the line got a card of its own.
    func testALineTypedInACodeBlockRestylesTheWholeBlock() {
        let text = "Intro\n\n```\nzdzdz\nzdzd\n```\n\nAfter\n"
        let at = NSMaxRange((text as NSString).range(of: "zdzd\n```")) - 4
        let edited = (text as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: "\nabc")
        let range = EditorController.restyleRange(from: styling(text), to: styling(edited), in: edited as NSString)
        let block = (edited as NSString).range(of: "```\nzdzdz\nzdzd\nabc\n```")
        XCTAssertEqual(NSIntersectionRange(range, block), block)
    }

    /// Return on an empty last item takes its `- ` off the end of the note: something is restyled, so its drawn bullet
    /// goes too.
    func testEndingAListAtTheEndRestylesTheLineBefore() {
        let range = EditorController.restyleRange(from: styling("- milk\n- "), to: styling("- milk\n"), in: "- milk\n")
        XCTAssertEqual(range, NSRange(location: 0, length: 7))
    }
}
