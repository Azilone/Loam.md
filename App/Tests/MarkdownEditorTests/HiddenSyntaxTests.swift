import XCTest
@testable import MarkdownEditor

/// The caret, selection and delete keys over hidden syntax, from the real styler's spans (no text view).
final class HiddenSyntaxTests: XCTestCase {
    private func syntax(_ text: String) -> HiddenSyntax {
        HiddenSyntax(spans: MarkdownStyler.spans(in: text), text: text)
    }

    private func caret(_ at: Int) -> NSRange { NSRange(location: at, length: 0) }

    private func apply(_ deletion: HiddenSyntax.Deletion, to text: String) -> String {
        var ns = text as NSString
        for range in deletion.ranges.reversed() { ns = ns.replacingCharacters(in: range, with: "") as NSString }
        return ns as String
    }

    // MARK: Caret

    func testTheCaretNeverRestsBetweenTheCharactersOfAMarker() {
        let s = syntax("a **bold** c")
        // A click inside the opening `**` lands before it; inside the closing one, after it.
        XCTAssertEqual(s.snap(caret(3), from: caret(11)), caret(2))
        XCTAssertEqual(s.snap(caret(9), from: caret(0)), caret(10))
    }

    func testAnArrowKeyNeverIsAKeystrokeWithoutMovement() {
        let s = syntax("a **bold** c")
        // Right from before `**` goes past the first letter, left from after it past the space before.
        XCTAssertEqual(s.snap(caret(3), from: caret(2)), caret(5))
        XCTAssertEqual(s.snap(caret(3), from: caret(4)), caret(1))
        // Right from the end of `bold`, over the closing `**`, to after the space.
        XCTAssertEqual(s.snap(caret(9), from: caret(8)), caret(11))
    }

    func testTheCaretGoesToWhereALinesTextStarts() {
        let s = syntax("intro\n## Title\n- [ ] todo\n> quote")
        for position in 6...9 { XCTAssertEqual(s.snap(caret(position), from: caret(0)), caret(9), "heading, caret \(position)") }
        for position in 15...20 { XCTAssertEqual(s.snap(caret(position), from: caret(0)), caret(21), "todo, caret \(position)") }
        for position in 26...27 { XCTAssertEqual(s.snap(caret(position), from: caret(0)), caret(28), "quote, caret \(position)") }
    }

    func testLeftFromTheStartOfALinesTextGoesToTheEndOfTheLineAbove() {
        let s = syntax("intro\n## Title")
        XCTAssertEqual(s.snap(caret(8), from: caret(9)), caret(5))
        XCTAssertEqual(syntax("## Title").snap(caret(2), from: caret(3)), caret(3), "nothing above the first line")
    }

    func testTheFrontmatterIsNotAPlaceForTheCaret() {
        let text = "---\nstatus: To do\n---\nBody"
        let s = syntax(text)
        let body = (text as NSString).range(of: "Body").location
        XCTAssertEqual(s.snap(caret(8), from: caret(body)), caret(0))
        XCTAssertEqual(s.snap(caret(8), from: caret(0)), caret(body), "a click goes to the nearer edge, after it when that is the way")
        XCTAssertEqual(s.snap(caret(1), from: caret(0)), caret(body + 1), "an arrow key goes past")
    }

    // MARK: Selection

    func testASelectionTakesWholeSyntax() {
        let s = syntax("a **bold** c")
        XCTAssertEqual(s.snap(NSRange(location: 3, length: 2), from: caret(0)), NSRange(location: 2, length: 3))
        XCTAssertEqual(s.snap(NSRange(location: 4, length: 5), from: caret(0)), NSRange(location: 4, length: 6))
    }

    func testSelectingALineKeepsItsHiddenStart() {
        let s = syntax("## Title\nbody")
        XCTAssertEqual(s.snap(NSRange(location: 0, length: 8), from: caret(0)), NSRange(location: 0, length: 8))
        XCTAssertEqual(s.snap(NSRange(location: 1, length: 7), from: caret(0)), NSRange(location: 0, length: 8))
    }

    func testShiftArrowOverSyntaxMovesTheSelection() {
        let s = syntax("a **bold** c")
        XCTAssertEqual(s.snap(NSRange(location: 2, length: 1), from: caret(2)), NSRange(location: 2, length: 3))
    }

    // MARK: Deleting

    func testBackspaceAtTheStartOfAHeadingMakesItAParagraph() throws {
        let text = "## Title"
        let deletion = try XCTUnwrap(syntax(text).deleteBackward(caret: 3))
        XCTAssertEqual(apply(deletion, to: text), "Title")
        XCTAssertEqual(deletion.caret, 0)
    }

    func testBackspaceAtTheStartOfATodoAndAQuote() throws {
        XCTAssertEqual(apply(try XCTUnwrap(syntax("- [x] done").deleteBackward(caret: 6)), to: "- [x] done"), "done")
        XCTAssertEqual(apply(try XCTUnwrap(syntax("> quote").deleteBackward(caret: 2)), to: "> quote"), "quote")
        XCTAssertEqual(apply(try XCTUnwrap(syntax("> > deep").deleteBackward(caret: 4)), to: "> > deep"), "> deep")
    }

    func testBackspaceDeletesTheCharacterThatShows() throws {
        let text = "a **bold** c"
        let afterClosing = try XCTUnwrap(syntax(text).deleteBackward(caret: 10))
        XCTAssertEqual(apply(afterClosing, to: text), "a **bol** c")
        let afterOpening = try XCTUnwrap(syntax(text).deleteBackward(caret: 4))
        XCTAssertEqual(apply(afterOpening, to: text), "a**bold** c")
    }

    func testDeletingTheLastCharacterOfAStyleRemovesItsMarkers() throws {
        let text = "a **b** c"
        let deletion = try XCTUnwrap(syntax(text).deleteBackward(caret: 5))
        XCTAssertEqual(apply(deletion, to: text), "a  c")
        XCTAssertEqual(deletion.caret, 2)
        let code = try XCTUnwrap(syntax("x `y` z").deleteBackward(caret: 4))
        XCTAssertEqual(apply(code, to: "x `y` z"), "x  z")
    }

    func testForwardDeleteSkipsHiddenSyntaxAndJoinsLinesWithoutALeftoverMark() throws {
        let text = "a **bold** c"
        let over = try XCTUnwrap(syntax(text).deleteForward(caret: 8))
        XCTAssertEqual(apply(over, to: text), "a **bold**c")
        let quote = "> a\n> b"
        XCTAssertEqual(apply(try XCTUnwrap(syntax(quote).deleteForward(caret: 3)), to: quote), "> ab")
        XCTAssertNil(syntax("abc").deleteForward(caret: 3))
        XCTAssertNil(syntax("abc").deleteBackward(caret: 0))
    }

    func testDeletingASelectionThroughHalfAStyleTakesTheOtherMarkerToo() {
        let text = "a **bold** c"
        let deletion = syntax(text).balanced(NSRange(location: 0, length: 6))
        XCTAssertEqual(apply(deletion, to: text), "ld c")
        XCTAssertEqual(deletion.ranges, [NSRange(location: 0, length: 6), NSRange(location: 8, length: 2)])
        let whole = syntax(text).balanced(NSRange(location: 2, length: 8))
        XCTAssertEqual(whole.ranges, [NSRange(location: 2, length: 8)])
    }

    func testALinkLosesItsDestinationWithItsText() {
        let text = "see [site](https://x.y) now"
        let deletion = syntax(text).balanced(NSRange(location: 0, length: 6))
        XCTAssertEqual(apply(deletion, to: text), "ite now")
        XCTAssertEqual(deletion.ranges.count, 2)
    }

    func testBackspaceOnTheBlankLineUnderAListItemDoesNotGlueThePicture() {
        let text = "- [x] task\n\n![](a.png)\n"
        let caret = ("- [x] task\n" as NSString).length
        XCTAssertEqual(syntax(text).deleteBackward(caret: caret), HiddenSyntax.Deletion(ranges: [], caret: caret - 1))
        // Two plain paragraphs still join.
        XCTAssertEqual(syntax("one\n\ntwo").deleteBackward(caret: 4)?.ranges, [NSRange(location: 3, length: 1)])
    }

    func testBackspaceRemovesTheBlankLineBesideAHeading() {
        // Nothing glues to a heading: the blank line under it, or over it, goes.
        let under = "## TL;DR\n\nThe meeting.\n"
        let caret = ("## TL;DR\n" as NSString).length
        XCTAssertEqual(apply(syntax(under).deleteBackward(caret: caret)!, to: under), "## TL;DR\nThe meeting.\n")
        let over = "- item\n\n## Next\n"
        XCTAssertEqual(apply(syntax(over).deleteBackward(caret: 7)!, to: over), "- item\n## Next\n")
    }

    func testBackspaceOnTheBlankLineBetweenTwoItemsClosesTheListUp() {
        let text = "- d\n\n- \n"
        XCTAssertEqual(apply(syntax(text).deleteBackward(caret: 4)!, to: text), "- d\n- \n")
        let tasks = "- [x] a\n\n    - [x] b\n"
        XCTAssertEqual(apply(syntax(tasks).deleteBackward(caret: 8)!, to: tasks), "- [x] a\n    - [x] b\n")
    }

    func testAnEmptyItemWithoutItsSpaceGoesLikeAnyOther() {
        // Backspace on the marker removes it, instead of gluing a `-` to the line above.
        XCTAssertEqual(syntax("- [x] a\n-\nb").deleteBackward(caret: 9)?.ranges, [NSRange(location: 8, length: 1)])
        // Backspace at the start of the line under it takes the empty item's line away.
        XCTAssertEqual(syntax("- [x] a\n-\nb").deleteBackward(caret: 10), HiddenSyntax.Deletion(ranges: [NSRange(location: 8, length: 2)], caret: 8))
        XCTAssertEqual(syntax("- \nb").deleteBackward(caret: 3), HiddenSyntax.Deletion(ranges: [NSRange(location: 0, length: 3)], caret: 0))
    }
}
