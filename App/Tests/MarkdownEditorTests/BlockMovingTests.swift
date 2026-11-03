import Foundation
import XCTest
@testable import MarkdownEditor

final class BlockMovingTests: XCTestCase {
    /// The first line of each block, to read the cut at a glance.
    private func firsts(_ text: String) -> [String] {
        BlockMoving.blocks(in: text).map { (text as NSString).substring(with: $0.firstLine) }
    }

    private func block(_ text: String, _ first: String) -> MarkdownBlock {
        BlockMoving.blocks(in: text).first { (text as NSString).substring(with: $0.firstLine) == first }!
    }

    private func move(_ text: String, _ first: String, before target: String?) -> String? {
        let moving = block(text, first)
        return BlockMoving.move(moving, before: target.map { block(text, $0) }, in: text).map { $0.applied(to: text) }
    }

    func testCutsTheNoteIntoBlocks() {
        let text = """
        ---
        tags: [a]
        ---
        # Title

        One line
        and its next line.
        - item
          - nested
        - other
        > quote
        > more

        ```swift
        let a = 1

        let b = 2
        ```
        | a | b |
        |---|---|
        ---
        """
        XCTAssertEqual(firsts(text), ["# Title", "One line", "- item", "  - nested", "- other", "> quote", "```swift", "| a | b |", "---"])
        let item = block(text, "- item")
        XCTAssertEqual((text as NSString).substring(with: item.range), "- item\n  - nested\n")
    }

    func testTheBlocksLeftBehindDoNotGlue() {
        // Taking the item out from between a list and a quote keeps the quote apart from the callout above it.
        let text = "> [!NOTE]\n> a\n\n- [ ] task\n> b\n\nend\n"
        XCTAssertEqual(move(text, "- [ ] task", before: nil), "> [!NOTE]\n> a\n\n> b\n\nend\n\n- [ ] task\n")
    }

    func testTheFirstBlockTakesTheBlankLinesAboveIt() {
        let text = "\n\nfirst\n\nsecond\n"
        XCTAssertEqual(move(text, "first", before: nil), "second\n\nfirst\n")
    }

    func testDeletingABlockTakesItsLinesWhole() {
        func delete(_ text: String, _ first: String) -> String { BlockMoving.delete(block(text, first), in: text).applied(to: text) }
        XCTAssertEqual(delete("- [ ] a\n- [ ] b\n- [ ] c\n", "- [ ] b"), "- [ ] a\n- [ ] c\n", "no empty line in its place")
        XCTAssertEqual(delete("- [ ] a\n    - [x] b\n    - [ ] c\n", "- [ ] a"), "", "the items nested in it go too")
        XCTAssertEqual(delete("One\n\nTwo\n\nThree\n", "Two"), "One\n\nThree\n", "one blank line stays between its neighbours")
        XCTAssertEqual(delete("One\n\nTwo", "Two"), "One\n", "the last line takes the break before it")
        XCTAssertEqual(delete("One\n\nTwo\n", "Two"), "One\n", "no blank line left trailing")
        let edit = BlockMoving.delete(block("- a\n- b\n", "- b"), in: "- a\n- b\n")
        XCTAssertEqual(edit.selection, NSRange(location: 4, length: 0), "the caret where the block was")
    }

    func testAnItemDroppedUnderTheListsLastItemJoinsTheList() {
        let text = "- [ ] a\n- [ ] b\n- [x] c\n\nAfter\n"
        XCTAssertEqual(move(text, "- [ ] a", before: "After"), "- [ ] b\n- [x] c\n- [ ] a\n\nAfter\n")
        XCTAssertEqual(move(text, "- [ ] b", before: "After"), "- [ ] a\n- [x] c\n- [ ] b\n\nAfter\n")
    }

    func testMovesAParagraphAboveAnother() {
        XCTAssertEqual(move("one\n\ntwo\n\nthree\n", "three", before: "one"), "three\n\none\n\ntwo\n")
        XCTAssertEqual(move("one\n\ntwo\n\nthree\n", "one", before: "three"), "two\n\none\n\nthree\n")
    }

    func testMovesToTheEnd() {
        XCTAssertEqual(move("one\n\ntwo\n\nthree", "one", before: nil), "two\n\nthree\n\none\n")
        XCTAssertEqual(move("# A\n\ntext\n", "# A", before: nil), "text\n\n# A\n")
    }

    func testDoesNotMoveOntoItself() {
        XCTAssertNil(move("one\n\ntwo\n", "one", before: "two"))
        XCTAssertNil(move("one\n\ntwo\n", "two", before: nil))
        XCTAssertNil(move("- a\n  - b\n- c\n", "- a", before: "  - b"))
    }

    func testListItemsStayTight() {
        XCTAssertEqual(move("- a\n- b\n- c\n", "- c", before: "- a"), "- c\n- a\n- b\n")
        XCTAssertEqual(move("- a\n  - b\n- c\n", "- a", before: nil), "- c\n- a\n  - b\n")
    }

    func testAParagraphDoesNotGlueToAList() {
        XCTAssertEqual(move("text\n\n- a\n- b\n", "text", before: "- b"), "- a\n\ntext\n\n- b\n")
    }

    func testAListClosesUpBehindAParagraphLeavingIt() {
        XCTAssertEqual(move("- a\n\ntext\n\n- b\n", "text", before: nil), "- a\n- b\n\ntext\n")
    }

    func testAnItemTakesTheIndentOfWhereItLands() {
        XCTAssertEqual(move("- a\n  - b\n- c\n", "  - b", before: "- c"), "- a\n- b\n- c\n")
        XCTAssertEqual(move("- a\n  - b\n\ntext\n", "  - b", before: "text"), "- a\n- b\n\ntext\n")
    }

    func testAHeadingMovedAwayAndBackLeavesNoBlankLine() {
        // A meeting summary's heading sits right on its text: dropped under the text, then back above it.
        let text = "![](audio.m4a)\n\n## TL;DR\nThe meeting.\n\n## Decisions\nNone.\n"
        let down = move(text, "## TL;DR", before: "## Decisions")!
        XCTAssertEqual(down, "![](audio.m4a)\n\nThe meeting.\n\n## TL;DR\n## Decisions\nNone.\n")
        XCTAssertEqual(move(down, "## TL;DR", before: "The meeting."), text)
    }

    func testABlockKeepsItsOwnSpacing() {
        // Spaced out, it stays spaced out; set right on its neighbours, it lands right on its new ones.
        XCTAssertEqual(move("# A\n\ntext\n\n# B\n\nmore\n", "# B", before: "# A"), "# B\n\n# A\n\ntext\n\nmore\n")
        XCTAssertEqual(move("## H\nfoo\n\nbar\n", "bar", before: "foo"), "## H\nbar\n\nfoo\n")
        // A paragraph taken from between a heading and another one leaves them as they were, with no blank line.
        XCTAssertEqual(move("## A\ntext\n## B\nend\n", "text", before: nil), "## A\n## B\nend\n\ntext\n")
    }

    func testKeyboardTargets() {
        let text = "one\n\n- a\n  - b\n- c\n\ntwo\n"
        let a = block(text, "- a")
        XCTAssertEqual(BlockMoving.keyboardTarget(for: a, up: true, in: text)??.firstLine, block(text, "one").firstLine)
        XCTAssertEqual(BlockMoving.keyboardTarget(for: a, up: false, in: text)??.firstLine, block(text, "two").firstLine)
        let two = block(text, "two")
        XCTAssertNotNil(BlockMoving.keyboardTarget(for: two, up: true, in: text))
        XCTAssertNil(BlockMoving.keyboardTarget(for: two, up: false, in: text))
        let lastMove = BlockMoving.keyboardTarget(for: block(text, "- c"), up: false, in: text)
        XCTAssertNotNil(lastMove)
        XCTAssertNil(lastMove!)
    }
}
