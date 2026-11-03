import Foundation
import XCTest
@testable import MarkdownEditor

/// The block editor's keys, from the Markdown of a note and a caret (`|` in the visible text) to the Markdown the note
/// is written as afterwards and where the caret is.
final class BlockEditingTests: XCTestCase {
    /// The note's blocks as the storage holds them, and the caret's offset where `|` is in the page's text (the blocks'
    /// texts, one paragraph each).
    private func storage(_ markdown: String, caret: String) -> (NSMutableAttributedString, NoteDocument, Int) {
        let document = NoteDocument(markdown: markdown)
        let storage = BlockStorage.attributedString(of: document.blocks)
        let marked = caret.replacingOccurrences(of: "|", with: "")
        XCTAssertEqual(marked, storage.string, "the page's text")
        let offset = (caret as NSString).range(of: "|").location
        return (storage, document, offset)
    }

    /// The Markdown of the document with the storage's blocks, and the page's text with `|` at the caret.
    private func result(_ storage: NSAttributedString, _ document: NoteDocument, _ selection: NSRange) -> (String, String) {
        var written = document
        written.blocks = BlockStorage.blocks(of: storage)
        let page = (storage.string as NSString).replacingCharacters(in: NSRange(location: selection.location, length: 0), with: "|")
        return (written.markdown, page)
    }

    private func press(
        _ key: (NSAttributedString, NSRange) -> BlockEdit?, _ markdown: String, caret: String,
        file line: UInt = #line
    ) -> (String, String)? {
        let (storage, document, offset) = storage(markdown, caret: caret)
        guard let edit = key(storage, NSRange(location: offset, length: 0)) else { return nil }
        let edited = edit.applied(to: storage)
        BlockStorage.normalize(edited, around: NSRange(location: 0, length: edited.length))
        return result(edited, document, edit.selection)
    }

    private let returnKey = { (s: NSAttributedString, r: NSRange) in BlockEditing.newline(in: s, selection: r) }
    private let backspace = { (s: NSAttributedString, r: NSRange) in BlockEditing.deleteBackward(in: s, selection: r) }
    private let delete = { (s: NSAttributedString, r: NSRange) in BlockEditing.deleteForward(in: s, selection: r) }
    private let tab = { (s: NSAttributedString, r: NSRange) in BlockEditing.indent(in: s, selection: r, outdent: false) }
    private let shiftTab = { (s: NSAttributedString, r: NSRange) in BlockEditing.indent(in: s, selection: r, outdent: true) }

    // MARK: Storage

    func testTheStorageHoldsOnlyTheVisibleText() {
        let document = NoteDocument(markdown: "# Title\n\nSome **bold** [link](x).\n\n- [ ] task\n\n---\n")
        let storage = BlockStorage.attributedString(of: document.blocks)
        XCTAssertEqual(storage.string, "Title\nSome bold link.\ntask\n\u{FFFC}\n")
        XCTAssertNotNil(storage.attribute(.noteStrong, at: 11, effectiveRange: nil))
        XCTAssertEqual((storage.attribute(.noteLink, at: 16, effectiveRange: nil) as? LinkAttribute)?.destination, "x")
    }

    func testStorageBackToTheSameFile() {
        for markdown in NoteDocumentTests.corpus {
            var document = NoteDocument(markdown: markdown)
            document.blocks = BlockStorage.blocks(of: BlockStorage.attributedString(of: document.blocks))
            XCTAssertEqual(document.markdown, markdown, markdown.debugDescription)
        }
    }

    func testTypingInABlockRewritesOnlyThatBlock() {
        let (storage, document, offset) = storage("Keep   *this*.\n\nEdit me\n", caret: "Keep   this.\nEdit| me\n")
        storage.replaceCharacters(in: NSRange(location: offset, length: 0), with: "ed")
        BlockStorage.normalize(storage, around: NSRange(location: offset, length: 2))
        XCTAssertEqual(result(storage, document, NSRange(location: offset + 2, length: 0)).0, "Keep   *this*.\n\nEdited me\n")
    }

    func testAParagraphTypedWithoutABlockBecomesAParagraph() {
        let storage = NSMutableAttributedString(string: "typed\n")
        BlockStorage.normalize(storage, around: NSRange(location: 0, length: 6))
        XCTAssertEqual(BlockStorage.blocks(of: storage).map(\.kind), [.paragraph])
    }

    // MARK: Return

    func testReturnSplitsAParagraph() {
        let (markdown, page) = press(returnKey, "Hello world\n", caret: "Hello| world\n")!
        XCTAssertEqual(markdown, "Hello\n\nworld\n")
        XCTAssertEqual(page, "Hello\n| world\n")
    }

    func testReturnContinuesAListAndKeepsItsMarks() {
        let (markdown, page) = press(returnKey, "- one **two**\n", caret: "one **|two**\n".replacingOccurrences(of: "**", with: ""))!
        XCTAssertEqual(markdown, "- one\n- **two**\n")
        XCTAssertEqual(page, "one \n|two\n")
    }

    func testReturnAfterACheckedTaskStartsAnOpenOne() {
        let (markdown, _) = press(returnKey, "- [x] done\n", caret: "done|\n")!
        XCTAssertEqual(markdown, "- [x] done\n- [ ]\n")
    }

    func testReturnOnAnEmptyNestedItemMovesItOut() {
        let document = NoteDocument(markdown: "- a\n  - b\n")
        var blocks = document.blocks
        blocks.append(NoteBlock(id: 77, kind: .bullet, depth: 1))
        let storage = BlockStorage.attributedString(of: blocks)
        let edit = BlockEditing.newline(in: storage, selection: NSRange(location: storage.length - 1, length: 0))!
        var written = document
        written.blocks = BlockStorage.blocks(of: edit.applied(to: storage))
        XCTAssertEqual(written.markdown, "- a\n  - b\n- \n".replacingOccurrences(of: "- \n", with: "-\n"))
    }

    func testReturnOnAnEmptyTopItemEndsTheList() {
        let document = NoteDocument(markdown: "- a\n")
        var blocks = document.blocks
        blocks.append(NoteBlock(id: 78, kind: .bullet))
        let storage = BlockStorage.attributedString(of: blocks)
        let edit = BlockEditing.newline(in: storage, selection: NSRange(location: storage.length - 1, length: 0))!
        XCTAssertEqual(BlockStorage.blocks(of: edit.applied(to: storage)).map(\.kind), [.bullet, .paragraph])
    }

    func testReturnAfterAHeadingStartsAParagraph() {
        let (markdown, page) = press(returnKey, "# Title\n", caret: "Title|\n")!
        XCTAssertEqual(markdown, "# Title\n")
        XCTAssertEqual(page, "Title\n|\n")
        let (storage, _, _) = storage("# Title\n", caret: "Title|\n")
        let edit = BlockEditing.newline(in: storage, selection: NSRange(location: 5, length: 0))!
        XCTAssertEqual(BlockStorage.blocks(of: edit.applied(to: storage)).map(\.kind), [.heading(level: 1), .paragraph])
    }

    func testReturnAtTheStartOfABlockPutsAnEmptyOneAboveAndKeepsItsLines() {
        let (markdown, page) = press(returnKey, "Intro\n\n#  Odd   heading\n", caret: "Intro\n|Odd   heading\n")!
        XCTAssertEqual(markdown, "Intro\n\n#  Odd   heading\n")
        XCTAssertEqual(page, "Intro\n\n|Odd   heading\n")
    }

    func testReturnInCodeIsALineAndOnAnEmptyLastLineLeavesTheCode() {
        XCTAssertNil(press(returnKey, "```\nlet a\n```\n", caret: "let a|\n"))
        let document = NoteDocument(markdown: "```\nlet a\n```\n")
        var blocks = document.blocks
        blocks[0].text = InlineText("let a\u{2028}")
        let storage = BlockStorage.attributedString(of: blocks)
        let edit = BlockEditing.newline(in: storage, selection: NSRange(location: 6, length: 0))!
        var written = document
        written.blocks = BlockStorage.blocks(of: edit.applied(to: storage))
        XCTAssertEqual(written.markdown, "```\nlet a\n```\n")
        XCTAssertEqual(BlockStorage.blocks(of: edit.applied(to: storage)).map(\.kind), [.code(language: ""), .paragraph])
    }

    func testReturnBesideADividerAddsAParagraph() {
        let (markdown, page) = press(returnKey, "A\n\n---\n", caret: "A\n\u{FFFC}|\n")!
        XCTAssertEqual(markdown, "A\n\n---\n")
        XCTAssertEqual(page, "A\n\u{FFFC}\n|\n")
    }

    // MARK: Backspace and Delete

    func testBackspaceAtTheStartOfAHeadingMakesItAParagraph() {
        let (markdown, page) = press(backspace, "Intro\n\n## Title\n", caret: "Intro\n|Title\n")!
        XCTAssertEqual(markdown, "Intro\n\nTitle\n")
        XCTAssertEqual(page, "Intro\n|Title\n")
    }

    func testBackspaceAtTheStartOfAnItemMakesItTextThenJoinsTheBlockAbove() {
        let (first, _) = press(backspace, "- a\n- b\n", caret: "a\n|b\n")!
        XCTAssertEqual(first, "- a\n\nb\n")
        let (second, page) = press(backspace, "- a\n\nb\n", caret: "a\n|b\n")!
        XCTAssertEqual(second, "- ab\n")
        XCTAssertEqual(page, "a|b\n")
    }

    func testBackspaceInsideTextIsTheTextViews() {
        XCTAssertNil(press(backspace, "Hello\n", caret: "Hel|lo\n"))
    }

    func testBackspaceAtTheStartOfAQuoteLeavesTheQuote() {
        let (markdown, _) = press(backspace, "> Quoted\n", caret: "|Quoted\n")!
        XCTAssertEqual(markdown, "Quoted\n")
    }

    func testBackspaceUnderADividerSelectsIt() {
        let (storage, _, offset) = storage("---\n\nText\n", caret: "\u{FFFC}\n|Text\n")
        let edit = BlockEditing.deleteBackward(in: storage, selection: NSRange(location: offset, length: 0))!
        XCTAssertEqual(edit.selection, NSRange(location: 0, length: 1))
        XCTAssertEqual(edit.applied(to: storage).string, storage.string)
    }

    func testBackspaceAtTheStartOfTheFirstBlockDoesNothing() {
        XCTAssertNil(press(backspace, "Hello\n", caret: "|Hello\n"))
    }

    func testDeleteAtTheEndOfABlockJoinsTheNext() {
        let (markdown, page) = press(delete, "# A\n\nb *c*\n", caret: "A|\nb c\n")!
        XCTAssertEqual(markdown, "# Ab *c*\n")
        XCTAssertEqual(page, "A|b c\n")
    }

    // MARK: Tab

    func testTabNestsAnItemUnderTheOneAboveAndNoDeeper() {
        let (once, _) = press(tab, "- a\n- b\n", caret: "a\n|b\n")!
        XCTAssertEqual(once, "- a\n  - b\n")
        let (twice, _) = press(tab, "- a\n  - b\n", caret: "a\n|b\n")!
        XCTAssertEqual(twice, "- a\n  - b\n")
    }

    func testShiftTabBringsAnItemOut() {
        let (markdown, _) = press(shiftTab, "1. a\n   - b\n", caret: "a\n|b\n")!
        XCTAssertEqual(markdown, "1. a\n- b\n")
    }

    func testTabOutsideAListIsTheTextViews() {
        XCTAssertNil(press(tab, "Text\n", caret: "Te|xt\n"))
    }

    // MARK: Shortcuts

    private func typing(_ typed: String, into markdown: String = "", file: StaticString = #filePath, line: UInt = #line) -> (String, String) {
        let document = NoteDocument(markdown: markdown)
        let storage = BlockStorage.attributedString(of: document.blocks)
        var selection = NSRange(location: storage.length, length: 0)
        if storage.length > 0 { selection.location -= 1 }
        for character in typed {
            // Typed with the paragraph's block and no mark, as the editor's typing attributes are after a shortcut.
            let block = selection.location > 0 ? storage.attribute(.noteBlock, at: selection.location - 1, effectiveRange: nil) : nil
            let attributes: [NSAttributedString.Key: Any] = (block as? BlockAttribute).map { [.noteBlock: $0] } ?? [:]
            storage.replaceCharacters(in: selection, with: NSAttributedString(string: String(character), attributes: attributes))
            BlockStorage.normalize(storage, around: NSRange(location: selection.location, length: 1))
            selection = NSRange(location: selection.location + String(character).utf16.count, length: 0)
            if let edit = BlockEditing.shortcut(in: storage, at: selection.location) {
                storage.replaceCharacters(in: edit.range, with: edit.replacement)
                selection = edit.selection
            }
        }
        if storage.string.isEmpty || !storage.string.hasSuffix("\n") {
            storage.append(NSAttributedString(string: "\n"))
            BlockStorage.normalize(storage, around: NSRange(location: 0, length: storage.length))
        }
        return result(storage, document, selection)
    }

    func testMarkdownShortcutsTypedAtTheStartBecomeTheBlock() {
        XCTAssertEqual(typing("# Title").0, "# Title\n")
        XCTAssertEqual(typing("### Small").0, "### Small\n")
        XCTAssertEqual(typing("- item").0, "- item\n")
        XCTAssertEqual(typing("* item").0, "- item\n")
        XCTAssertEqual(typing("1. first").0, "1. first\n")
        XCTAssertEqual(typing("4) four").0, "4. four\n")
        XCTAssertEqual(typing("[] todo").0, "- [ ] todo\n")
        XCTAssertEqual(typing("- [ ] todo").0, "- [ ] todo\n")
        XCTAssertEqual(typing("> quoted").0, "> quoted\n")
    }

    func testAShortcutInTheMiddleOfTextStaysText() {
        XCTAssertEqual(typing("a # b - c").0, "a # b - c\n")
    }

    func testThreeDashesMakeADivider() {
        let (markdown, page) = typing("---")
        XCTAssertEqual(markdown, "***\n")
        XCTAssertEqual(page, "\u{FFFC}\n|\n")
    }

    func testInlineShortcutsMarkTheTextAndDropTheMarkers() {
        XCTAssertEqual(typing("a **bold** b").0, "a **bold** b\n")
        XCTAssertEqual(typing("a **bold** b").1, "a bold b|\n")
        XCTAssertEqual(typing("an *it* x").1, "an it x|\n")
        XCTAssertEqual(typing("an _it_ x").0, "an *it* x\n")
        XCTAssertEqual(typing("the `code` x").0, "the `code` x\n")
        XCTAssertEqual(typing("~~gone~~").0, "~~gone~~\n")
        XCTAssertEqual(typing("2 * 3 * 4").0, "2 \\* 3 \\* 4\n")
    }

    func testThreeBackticksThenReturnMakeACodeBlock() {
        let document = NoteDocument(markdown: "```swift\n")
        let storage = BlockStorage.attributedString(of: document.blocks)
        XCTAssertEqual(storage.string, "\n", "an empty code block")
        let typed = NSMutableAttributedString(attributedString: BlockStorage.attributedString(of: [NoteBlock(id: 5, kind: .paragraph, text: "```swift")]))
        let edit = BlockEditing.fence(in: typed, selection: NSRange(location: 8, length: 0))!
        XCTAssertEqual(BlockStorage.blocks(of: edit.applied(to: typed)).map(\.kind), [.code(language: "swift")])
    }
}
