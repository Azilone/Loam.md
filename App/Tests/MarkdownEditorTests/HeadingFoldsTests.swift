import XCTest
@testable import MarkdownEditor

/// What folding a heading hides, from the real styler's spans (no text view).
final class HeadingFoldsTests: XCTestCase {
    private let note = "# Title\n\n## A\n\nText a.\n\n### A1\n\nDeep.\n\n## B\n\nText b.\n\n## Empty\n\n## Code\n\n```\n# not a heading\n```\n"

    private func sections(_ text: String) -> [HeadingFolds.Section] {
        HeadingFolds.sections(in: MarkdownStyler.spans(in: text), text: text as NSString)
    }

    private func hidden(_ text: String, folding headings: [String]) -> [String] {
        let all = sections(text)
        var folds = HeadingFolds()
        for section in all where headings.contains((text as NSString).substring(with: section.heading)) { folds.toggle(section) }
        return folds.bodies(of: all).map { (text as NSString).substring(with: $0) }
    }

    func testAHeadingHidesUpToTheNextHeadingOfItsLevelKeepingTheBlankLineBeforeIt() {
        XCTAssertEqual(hidden(note, folding: ["## A"]), ["\nText a.\n\n### A1\n\nDeep.\n"])
        XCTAssertEqual(hidden(note, folding: ["### A1"]), ["\nDeep.\n"])
    }

    func testAHeadingWithNothingUnderItDoesNotFold() {
        XCTAssertFalse(sections(note).map { (note as NSString).substring(with: $0.heading) }.contains("## Empty"))
    }

    func testAHashInCodeIsNotAHeading() {
        XCTAssertEqual(hidden(note, folding: ["## Code"]), ["\n```\n# not a heading\n```\n"])
    }

    func testAFoldInsideAFoldedHeadingAddsNothing() {
        XCTAssertEqual(hidden(note, folding: ["## A", "### A1"]), ["\nText a.\n\n### A1\n\nDeep.\n"])
    }

    func testFoldsFollowTheTextAndDropAHeadingEditedAway() {
        let all = sections(note)
        let b = try! XCTUnwrap(all.first { (note as NSString).substring(with: $0.heading) == "## B" })
        var folds = HeadingFolds()
        folds.toggle(b)
        // Typing above moves the fold with its heading.
        folds.follow(NSRange(location: 0, length: 0), replacementLength: 3)
        let moved = "abc" + note
        folds.keep(sections(moved))
        XCTAssertEqual(folds.bodies(of: sections(moved)).map { (moved as NSString).substring(with: $0) }, ["\nText b.\n"])
        // Deleting the heading's start unfolds it.
        folds.follow(NSRange(location: b.heading.location + 3, length: 2), replacementLength: 0)
        XCTAssertTrue(folds.isEmpty)
    }
}
