import Foundation
import XCTest
@testable import MarkdownEditor

/// `‹…›` marks the selection, `|` the caret, in both the input and the expectation.
private func parse(_ marked: String) -> (String, NSRange) {
    let ns = marked as NSString
    let caret = ns.range(of: "|")
    if caret.location != NSNotFound {
        return (marked.replacingOccurrences(of: "|", with: ""), NSRange(location: caret.location, length: 0))
    }
    let open = ns.range(of: "‹").location
    let close = ns.range(of: "›").location
    let text = marked.replacingOccurrences(of: "‹", with: "").replacingOccurrences(of: "›", with: "")
    return (text, NSRange(location: open, length: close - open - 1))
}

private func show(_ text: String, _ selection: NSRange) -> String {
    let ns = text as NSString
    if selection.length == 0 { return ns.replacingCharacters(in: selection, with: "|") }
    return ns.replacingCharacters(in: selection, with: "‹" + ns.substring(with: selection) + "›")
}

final class InlineFormattingTests: XCTestCase {
    private func toggle(_ format: InlineFormat, _ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return InlineFormatting.toggle(format, in: text, selection: selection).map { show($0.applied(to: text), $0.selection) }
    }

    private func highlight(_ color: HighlightColor?, _ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return InlineFormatting.highlight(color, in: text, selection: selection)
            .map { show($0.applied(to: text), $0.selection) }
    }

    func testWrapsTheSelectionAndKeepsItOnTheText() {
        XCTAssertEqual(toggle(.bold, "a ‹word› b"), "a **‹word›** b")
        XCTAssertEqual(toggle(.italic, "‹word›"), "_‹word›_")
        XCTAssertEqual(toggle(.strikethrough, "‹word›"), "~~‹word›~~")
        XCTAssertEqual(toggle(.code, "‹x = 1›"), "`‹x = 1›`")
    }

    func testSpacesAtTheEndsStayOutside() {
        XCTAssertEqual(toggle(.bold, "a‹ word ›b"), "a **‹word›** b")
    }

    func testUnwrapsWhenAlreadyStyledAroundOrInside() {
        XCTAssertEqual(toggle(.bold, "a **‹word›** b"), "a ‹word› b")
        XCTAssertEqual(toggle(.bold, "a ‹**word**› b"), "a ‹word› b")
        XCTAssertEqual(toggle(.italic, "*‹word›*"), "‹word›")
        XCTAssertEqual(toggle(.code, "`‹x›`"), "‹x›")
    }

    func testItalicIsNotFooledByBold() {
        XCTAssertEqual(toggle(.italic, "**‹word›**"), "**_‹word›_**")
        XCTAssertTrue(InlineFormatting.isActive(.bold, in: "**word**", selection: NSRange(location: 2, length: 4)))
        XCTAssertFalse(InlineFormatting.isActive(.italic, in: "**word**", selection: NSRange(location: 2, length: 4)))
    }

    func testSeveralLinesAreStyledLineByLineAfterTheirBlockSyntax() {
        XCTAssertEqual(toggle(.bold, "# ‹Title\n- item\n- [ ] task›"), "# **‹Title**\n- **item**\n- [ ] **task›**")
        XCTAssertEqual(toggle(.bold, "‹**a**\n**b**›"), "‹a\nb›")
    }

    func testACaretGetsAnEmptyPair() {
        XCTAssertEqual(toggle(.bold, "a |b"), "a **|**b")
    }

    func testHighlightWritesAMarkElement() {
        XCTAssertEqual(highlight(.yellow, "a ‹word›"), "a <mark>‹word›</mark>")
        XCTAssertEqual(highlight(.blue, "‹word›"), #"<mark style="background: #a2c6fa">‹word›</mark>"#)
    }

    func testHighlightChangesColourOrGoesAway() {
        XCTAssertEqual(highlight(.red, "<mark>‹word›</mark>"), #"<mark style="background: #f2aaa6">‹word›</mark>"#)
        XCTAssertEqual(highlight(nil, #"<mark style="background: #a2c6fa">‹word›</mark>"#), "‹word›")
        XCTAssertNil(highlight(nil, "‹word›"))
    }

    func testLinkPutsTheCaretWhereTheDestinationGoes() {
        let (text, selection) = parse("see ‹docs›")
        let edit = InlineFormatting.link(in: text, selection: selection)
        XCTAssertEqual(show(edit.applied(to: text), edit.selection), "see [docs](|)")
        let (url, urlSelection) = parse("‹https://loam.app›")
        let urlEdit = InlineFormatting.link(in: url, selection: urlSelection)
        XCTAssertEqual(show(urlEdit.applied(to: url), urlEdit.selection), "[‹https://loam.app›](https://loam.app)")
    }
}
