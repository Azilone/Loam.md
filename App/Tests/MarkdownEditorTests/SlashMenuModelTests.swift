import AppKit
import XCTest
@testable import MarkdownEditor

/// The `/` menu's highlight: the arrow keys move it, and the list scrolling under a still pointer does not take it
/// back.
@MainActor
final class SlashMenuModelTests: XCTestCase {
    func testAStillPointerDoesNotTakeTheHighlightBackAfterAnArrowKey() {
        let model = SlashMenuModel()
        model.items = SlashMenu.standardItems
        let pointer = NSEvent.mouseLocation
        model.move(1)
        model.move(1)
        model.hover(0, pointer: pointer)
        XCTAssertEqual(model.selected, 2, "the rows moved under the pointer, the pointer did not move")
        model.hover(0, pointer: NSPoint(x: pointer.x + 5, y: pointer.y))
        XCTAssertEqual(model.selected, 0, "a pointer that moves chooses the row")
    }
}
