import MarkdownEditor
import XCTest
@testable import MarkdownEditorUI

/// `[[Note#Heading]]`: the heading a link names, and the line of the note that says it.
final class NoteLinksTests: XCTestCase {
    func testTheHeadingOfANoteLink() {
        XCTAssertEqual(NoteLinks.heading(of: MarkdownTheme.noteLinkScheme + "Plan#Goals "), "Goals")
        XCTAssertNil(NoteLinks.heading(of: MarkdownTheme.noteLinkScheme + "Plan"))
        XCTAssertNil(NoteLinks.heading(of: "Plan.md#Goals"), "only a note link")
    }

    func testTheLineOfAHeadingIgnoresCaseClosingHashesAndCode() {
        let text = "---\ntitle: x\n---\n# Plan\n\n```\n## Goals\n```\n\n## goals ##\n\nText\n"
        XCTAssertEqual(NoteLinks.line(ofHeading: "Goals", in: text), 10)
        XCTAssertNil(NoteLinks.line(ofHeading: "Missing", in: text))
    }
}
