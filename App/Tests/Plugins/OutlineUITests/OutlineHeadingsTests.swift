import XCTest
@testable import OutlineUI

/// Heading extraction, without a plugin.
final class OutlineHeadingsTests: XCTestCase {
    private func extract(_ text: String) -> [OutlineHeading] { OutlineHeadings.extract(from: text) }

    func testATXHeadingsWithLevelsAndLines() {
        let text = "# Title\n\nIntro\n\n## Part ##\n### Detail\n###### Six\n####### Seven is text\n"
        XCTAssertEqual(extract(text), [
            OutlineHeading(level: 1, text: "Title", line: 1),
            OutlineHeading(level: 2, text: "Part", line: 5),
            OutlineHeading(level: 3, text: "Detail", line: 6),
            OutlineHeading(level: 6, text: "Six", line: 7),
        ])
    }

    func testSetextHeadings() {
        let text = "Big\n===\n\nSmaller\n---\n\nText\n"
        XCTAssertEqual(extract(text), [
            OutlineHeading(level: 1, text: "Big", line: 1),
            OutlineHeading(level: 2, text: "Smaller", line: 4),
        ])
    }

    func testCodeBlocksAreSkipped() {
        let text = "# Real\n\n```bash\n# a comment\n```\n\n~~~\n## Not either\n~~~\n\n    # indented code\n\n## After\n"
        XCTAssertEqual(extract(text).map(\.text), ["Real", "After"])
        XCTAssertEqual(extract(text).last?.line, 13)
    }

    func testFrontmatterIsSkippedAndLinesStillMatchTheNote() {
        let text = "---\ntitle: Plan\ntags: [a]\n---\n# Plan\n\nText\n\n---\n"
        XCTAssertEqual(extract(text), [OutlineHeading(level: 1, text: "Plan", line: 5)])
        // Without frontmatter, a `---` after a paragraph is a setext underline.
        XCTAssertEqual(extract("Text\n---\n"), [OutlineHeading(level: 2, text: "Text", line: 1)])
    }

    func testInlineFormattingIsStripped() {
        let text = "## **Bold**, *em*, `code` and [a link](Other.md) ![pic](p.png) <b>x</b> #tag\n# \n#\n"
        XCTAssertEqual(extract(text), [OutlineHeading(level: 2, text: "Bold, em, code and a link pic x #tag", line: 1)])
    }

    func testHeadingsInsideQuotesAndCRLF() {
        XCTAssertEqual(extract("# One\r\n\r\n> ## Quoted\r\n"), [
            OutlineHeading(level: 1, text: "One", line: 1),
            OutlineHeading(level: 2, text: "Quoted", line: 3),
        ])
    }
}
