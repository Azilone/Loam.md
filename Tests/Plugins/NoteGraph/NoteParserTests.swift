import XCTest
import PluginKit
@testable import NoteGraphPlugin

final class NoteParserTests: XCTestCase {
    func testFrontmatterTitleTagsAndLinks() {
        let text = """
        ---
        title: Plan
        tags: [work, "#urgent"]
        due: 2026-10-18
        done: false
        count: 3
        ---
        # Heading
        See [other](../ideas/Other%20Note.md#top) and [site](https://example.com) and [here](#local).
        Also a #draft tag, `#notatag` and a [mail](mailto:a@b.c).

        ```
        #alsonot [x](code.md)
        ```
        """
        let info = NoteParser.parse(path: "projects/plan.md", text: text)
        XCTAssertEqual(info.title, "Plan")
        XCTAssertEqual(info.tags, ["work", "urgent", "draft"])
        XCTAssertEqual(info.properties["due"], .string("2026-10-18"))
        XCTAssertEqual(info.properties["done"], .bool(false))
        XCTAssertEqual(info.properties["count"], .number(3))
        XCTAssertEqual(info.links, [NoteLink(text: "other", target: "ideas/Other Note.md")])
    }

    func testTitleIsTheFileNameNotTheFirstHeading() {
        XCTAssertEqual(NoteParser.parse(path: "a/b.md", text: "# From heading\n").title, "b")
        XCTAssertEqual(NoteParser.parse(path: "a/Some note.md", text: "No heading\n").title, "Some note")
    }

    func testAnExcalidrawDrawingIsTitledByItsFile() {
        let drawing = "---\nexcalidraw-plugin: parsed\n---\n\n# Excalidraw Data\n\n## Text Elements\nHi ^abcdefgh\n"
        XCTAssertEqual(NoteParser.parse(path: "Ideas/Plan.excalidraw.md", text: drawing).title, "Plan")
    }

    func testInvalidYamlGivesNoPropertiesButStillParsesTheBody() {
        let info = NoteParser.parse(path: "n.md", text: "---\nkey: [unclosed\n---\n# T\n[a](b.md)\n")
        XCTAssertEqual(info.properties, [:])
        XCTAssertEqual(info.title, "n")
        XCTAssertEqual(info.links.map(\.target), ["b.md"])
    }

    func testLinksLeavingTheVaultAreIgnored() {
        let info = NoteParser.parse(path: "n.md", text: "[x](../../outside.md)\n")
        XCTAssertEqual(info.links, [])
    }

    func testHeadingMarkIsNotATag() {
        XCTAssertEqual(NoteParser.parse(path: "n.md", text: "# Title\n## Sub\n").tags, [])
    }
}
