import Foundation
import XCTest
@testable import MarkdownEditor

/// The block editor's blocks for the handles, the moves and the folds: from a note's Markdown to the Markdown written
/// after a block moved.
final class PageBlocksTests: XCTestCase {
    private func page(_ markdown: String) -> (NSMutableAttributedString, NoteDocument) {
        let document = NoteDocument(markdown: markdown)
        return (BlockStorage.attributedString(of: document.blocks), document)
    }

    private func written(_ storage: NSAttributedString, _ document: NoteDocument) -> String {
        var copy = document
        copy.blocks = BlockStorage.blocks(of: storage)
        return copy.markdown
    }

    func testAnItemHoldsWhatIsNestedUnderIt() {
        let (storage, _) = page("- a\n  - b\n  - c\n- d\n\nText\n")
        let blocks = PageBlocks.blocks(in: storage)
        XCTAssertEqual(blocks.map { (storage.string as NSString).substring(with: $0.range) }, ["a\nb\nc\n", "b\n", "c\n", "d\n", "Text\n"])
        XCTAssertEqual(blocks.map(\.listIndent), [0, 1, 1, 0, nil])
    }

    func testMovingABlockDownAndUp() {
        let (storage, document) = page("One\n\nTwo\n\nThree\n")
        let edit = PageBlocks.move(NSRange(location: 0, length: 4), before: storage.length, in: storage)!
        let moved = edit.applied(to: storage)
        XCTAssertEqual(written(moved, document), "Two\n\nThree\n\nOne\n")
        let back = PageBlocks.move(NSRange(location: 10, length: 4), before: 0, in: moved)!
        XCTAssertEqual(written(back.applied(to: moved), document), "One\n\nTwo\n\nThree\n")
    }

    func testAnItemMovedWithItsChildren() {
        let (storage, document) = page("- a\n  - a1\n- b\n")
        let blocks = PageBlocks.blocks(in: storage)
        let edit = PageBlocks.move(blocks[0].range, before: storage.length, in: storage)!
        XCTAssertEqual(written(edit.applied(to: storage), document), "- b\n- a\n  - a1\n")
    }

    func testANestedItemMovedOutOfItsListComesToTheTop() {
        let (storage, document) = page("Intro\n\n- a\n  - nested\n")
        let blocks = PageBlocks.blocks(in: storage)
        let edit = PageBlocks.move(blocks[2].range, before: 0, in: storage)!
        XCTAssertEqual(written(edit.applied(to: storage), document), "- nested\n\nIntro\n\n- a\n")
    }

    func testOptionCommandArrowsMoveOverTheNeighbourOfTheSameLevel() {
        let (storage, _) = page("- a\n  - a1\n- b\n- c\n")
        let blocks = PageBlocks.blocks(in: storage)
        let b = blocks[2]
        XCTAssertEqual(PageBlocks.keyboardDestination(for: b, up: true, in: blocks, length: storage.length), 0)
        XCTAssertEqual(PageBlocks.keyboardDestination(for: b, up: false, in: blocks, length: storage.length), storage.length)
        XCTAssertNil(PageBlocks.keyboardDestination(for: blocks[3], up: false, in: blocks, length: storage.length))
    }

    func testAHeadingFoldsUpToTheNextOfItsLevel() {
        let (storage, _) = page("# A\n\nText\n\n## A1\n\nMore\n\n# B\n\nEnd\n")
        let sections = PageBlocks.sections(in: storage)
        let ns = storage.string as NSString
        XCTAssertEqual(sections.map { ns.substring(with: $0.heading) }, ["A", "A1", "B"])
        XCTAssertEqual(sections.map { ns.substring(with: $0.body) }, ["Text\nA1\nMore\n", "More\n", "End\n"])
    }
}
