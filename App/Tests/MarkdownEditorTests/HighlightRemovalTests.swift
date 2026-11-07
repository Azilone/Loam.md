import Foundation
import XCTest
@testable import MarkdownEditor

/// Taking a highlight off must also take its marker stroke off: the stroke is a display attribute the styling sets.
final class HighlightRemovalTests: XCTestCase {
    func testTheMarkerStrokeGoesWithTheHighlight() throws {
        let document = NoteDocument(markdown: "<mark>Je surligne</mark>\n")
        let storage = NSTextStorage(attributedString: BlockStorage.attributedString(of: document.blocks))
        let theme = MarkdownTheme()
        theme.styleBlocks(storage)
        XCTAssertNotNil(storage.attribute(.markdownHighlight, at: 0, effectiveRange: nil), "highlighted")

        let edit = try XCTUnwrap(BlockEditing.toggle(.highlight(color: nil), in: storage, selection: NSRange(location: 0, length: 5)))
        let edited = NSTextStorage(attributedString: edit.applied(to: storage))
        theme.styleBlocks(edited)
        XCTAssertNil(edited.attribute(.noteHighlight, at: 0, effectiveRange: nil))
        XCTAssertNil(edited.attribute(.markdownHighlight, at: 0, effectiveRange: nil), "the stroke is gone")
        XCTAssertNotNil(edited.attribute(.markdownHighlight, at: 8, effectiveRange: nil), "the rest stays highlighted")
    }
}
