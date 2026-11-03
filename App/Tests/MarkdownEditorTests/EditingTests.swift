import Foundation
import XCTest
@testable import MarkdownEditor

/// Writes `|` for the caret, or `‹…›` for a selection, so expectations read like the editor.
private func show(_ text: String, _ selection: NSRange) -> String {
    let ns = text as NSString
    if selection.length == 0 { return ns.replacingCharacters(in: selection, with: "|") }
    return ns.replacingCharacters(in: selection, with: "‹" + ns.substring(with: selection) + "›")
}

/// Reads a string with `|` as the caret.
private func parse(_ marked: String) -> (String, NSRange) {
    let location = (marked as NSString).range(of: "|").location
    return (marked.replacingOccurrences(of: "|", with: ""), NSRange(location: location, length: 0))
}

final class QuoteEditingTests: XCTestCase {
    private func newline(_ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return QuoteEditing.newline(in: text, selection: selection).map { show($0.applied(to: text), $0.selection) }
    }

    func testReturnKeepsWritingInTheQuote() {
        XCTAssertEqual(newline("> one|"), "> one\n> |")
        XCTAssertEqual(newline("> [!NOTE] Title|"), "> [!NOTE] Title\n> |")
        XCTAssertEqual(newline(">one|"), ">one\n> |")
        XCTAssertEqual(newline("> > nested|"), "> > nested\n> > |")
        XCTAssertEqual(newline("> ab|cd"), "> ab\n> |cd")
    }

    func testReturnOnAnEmptyQuoteLineLeavesTheQuote() {
        XCTAssertEqual(newline("> one\n> |"), "> one\n\n|")
        XCTAssertEqual(newline("> one\n>|"), "> one\n\n|")
    }

    func testReturnOutsideAQuoteIsNormal() {
        XCTAssertNil(newline("plain|"))
        XCTAssertNil(newline("|> one"))
    }
}

final class ListEditingTests: XCTestCase {
    private func newline(_ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return ListEditing.newline(in: text, selection: selection).map { show($0.applied(to: text), $0.selection) }
    }

    private func tab(_ marked: String, outdent: Bool = false) -> String? {
        let (text, selection) = parse(marked)
        return ListEditing.indent(in: text, selection: selection, outdent: outdent)
            .map { show($0.applied(to: text), $0.selection) }
    }

    func testReturnOnABareEmptyItemEndsTheList() {
        XCTAssertEqual(newline("- one\n-|"), "- one\n|")
        XCTAssertEqual(newline("- one\n-|\n- two"), "- one\n|\n- two")
        XCTAssertEqual(newline("- [ ] one\n- [ ]|"), "- [ ] one\n|")
        XCTAssertEqual(newline("1. one\n2.|"), "1. one\n|")
    }

    func testReturnContinuesBulletsNumbersAndTasks() {
        XCTAssertEqual(newline("- one|"), "- one\n- |")
        XCTAssertEqual(newline("  * one|"), "  * one\n  * |")
        XCTAssertEqual(newline("9. nine|"), "9. nine\n10. |")
        XCTAssertEqual(newline("1) a|"), "1) a\n2) |")
        XCTAssertEqual(newline("- [x] done|"), "- [x] done\n- [ ] |")
    }

    func testReturnInTheMiddleSplitsTheItem() {
        XCTAssertEqual(newline("- ab|cd"), "- ab\n- |cd")
    }

    func testReturnOnAnEmptyItemEndsTheList() {
        XCTAssertEqual(newline("- one\n- |"), "- one\n|")
        XCTAssertEqual(newline("- one\n- [ ] |"), "- one\n|")
    }

    func testReturnOnAnEmptyNestedItemMovesItOut() {
        XCTAssertEqual(newline("- a\n  - |\n- b"), "- a\n- |\n- b")
        XCTAssertEqual(newline("- [x] a\n    - [x] b\n        - [ ] |"), "- [x] a\n    - [x] b\n    - [ ] |")
    }

    func testReturnOutsideAListIsNormal() {
        XCTAssertNil(newline("plain|"))
        XCTAssertNil(newline("-|"))
        XCTAssertNil(newline("|- one"))
    }

    func testTabNestsUnderTheMarkerWidth() {
        XCTAssertEqual(tab("- a\n- b|"), "- a\n  - b|")
        XCTAssertEqual(tab("1. a\n1. b|"), "1. a\n   1. b|")
    }

    func testShiftTabMovesBackToTheParent() {
        XCTAssertEqual(tab("- a\n  - b|", outdent: true), "- a\n- b|")
        XCTAssertEqual(tab("- a\n- b|", outdent: true), nil)
    }

    func testTabOutsideAListIsNormal() {
        XCTAssertNil(tab("plain|"))
    }

    func testTabIndentsEverySelectedItem() {
        let text = "- a\n- b\n- c"
        let selection = NSRange(location: 4, length: 7)
        let edit = ListEditing.indent(in: text, selection: selection, outdent: false)!
        XCTAssertEqual(show(edit.applied(to: text), edit.selection), "- a\n‹  - b\n  - c›")
    }
}

final class SlashMenuTests: XCTestCase {
    private func choose(_ id: String, _ marked: String) -> String {
        let (text, caret) = parse(marked)
        let slash = (text as NSString).range(of: "/", options: .backwards, range: NSRange(location: 0, length: caret.location))
        let trigger = NSRange(location: slash.location, length: caret.location - slash.location)
        let item = SlashMenu.standardItems.first { $0.id == id }!
        let edit = item.makeEdit(text, trigger)
        return show(edit.applied(to: text), edit.selection)
    }

    func testFilterMatchesTitlesAndKeywordsInMenuOrder() {
        let ids = { (query: String) in SlashMenu.filter(SlashMenu.standardItems, query: query).map(\.id) }
        XCTAssertEqual(ids(""), SlashMenu.standardItems.map(\.id))
        XCTAssertEqual(ids("head"), ["heading1", "heading2", "heading3"])
        XCTAssertEqual(ids("h2"), ["heading2"])
        XCTAssertEqual(ids("todo"), ["tasks"])
        XCTAssertEqual(ids("TAB"), ["table"])
        XCTAssertEqual(ids("zzz"), [])
    }

    func testMenuOpensAtLineStartOrAfterASpace() {
        XCTAssertTrue(SlashMenu.opensMenu(in: "", at: 0))
        XCTAssertTrue(SlashMenu.opensMenu(in: "a\n", at: 2))
        XCTAssertTrue(SlashMenu.opensMenu(in: "a ", at: 2))
        XCTAssertFalse(SlashMenu.opensMenu(in: "a/b", at: 1))
    }

    func testLinePrefixReplacesTheTriggerAndAnyExistingPrefix() {
        XCTAssertEqual(choose("heading1", "/h1|"), "# |")
        XCTAssertEqual(choose("heading2", "Hello /head|"), "## Hello |")
        XCTAssertEqual(choose("tasks", "- item /|\nnext"), "- [ ] item |\nnext")
        XCTAssertEqual(choose("quote", "## Title /q|"), "> Title |")
    }

    func testBlocksGoOnTheirOwnLine() {
        XCTAssertEqual(choose("code", "/code|"), "```\n|\n```")
        XCTAssertEqual(choose("divider", "para\n/|"), "para\n\n---\n|")
        XCTAssertEqual(choose("divider", "para /|"), "para \n\n---\n|")
        XCTAssertEqual(choose("table", "/table|"), "| ‹Column› | Column |\n| --- | --- |\n|  |  |")
        XCTAssertEqual(choose("alert", "/|"), "> [!NOTE]\n> |")
    }

    func testInlineEntriesSelectTheirPlaceholder() {
        XCTAssertEqual(choose("link", "see /link|"), "see [‹text›](https://)")
        XCTAssertEqual(choose("image", "/img|"), "![‹description›](image.png)")
    }
}
