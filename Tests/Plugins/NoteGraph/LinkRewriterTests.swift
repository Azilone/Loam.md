import XCTest
@testable import NoteGraphPlugin

final class LinkRewriterTests: XCTestCase {
    func testLinkToAMovedNoteIsRewrittenAndNothingElseChanges() {
        let text = "Intro [a](a.md#sec) and [b](b.md) *keep*  spacing\n"
        let result = LinkRewriter.rewrite(text, notePath: "n.md", newNotePath: "n.md", moves: ["a.md": "sub/Moved note.md"])
        XCTAssertEqual(result, "Intro [a](sub/Moved%20note.md#sec) and [b](b.md) *keep*  spacing\n")
    }

    func testRelativeLinksInsideAMovedNoteAreRecomputed() {
        let text = "[x](../ideas/x.md) [y](y.md)\n"
        let result = LinkRewriter.rewrite(
            text, notePath: "projects/p.md", newNotePath: "archive/2026/p.md", moves: ["projects/p.md": "archive/2026/p.md"]
        )
        XCTAssertEqual(result, "[x](../../ideas/x.md) [y](../../projects/y.md)\n")
    }

    func testLinksFromTheVaultRootFollowTheirFileNotTheNote() {
        let text = "![](assets/a%20b.png) [x](assets/zip.zip) ![](../assets/rel.png)\n"
        let present: Set<String> = ["assets/a b.png", "assets/zip.zip", "assets/rel.png"]
        let moved = LinkRewriter.rewrite(
            text, notePath: "Inbox/N.md", newNotePath: "Notes/N.md", moves: ["Inbox/N.md": "Notes/N.md"], exists: present.contains
        )
        XCTAssertEqual(moved, "![](assets/a%20b.png) [x](assets/zip.zip) ![](../assets/rel.png)\n", "the note moves, root links stay")
        let renamed = LinkRewriter.rewrite(
            text, notePath: "Inbox/N.md", newNotePath: "Inbox/N.md", moves: ["assets/a b.png": "assets/c.jpg"], exists: present.contains
        )
        XCTAssertEqual(renamed, "![](assets/c.jpg) [x](assets/zip.zip) ![](../assets/rel.png)\n")
    }

    func testNonAsciiTextBeforeALinkDoesNotShiftTheEdit() {
        let text = "Café déjà vu ☕ [a](a.md)\n"
        let result = LinkRewriter.rewrite(text, notePath: "n.md", newNotePath: "n.md", moves: ["a.md": "b.md"])
        XCTAssertEqual(result, "Café déjà vu ☕ [b](b.md)\n".replacingOccurrences(of: "[b]", with: "[a]"))
    }

    func testFrontmatterIsKeptAndTextWithoutLinksIsReturnedUnchanged() {
        let text = "---\ntitle: T\n---\n[a](a.md)\n"
        XCTAssertEqual(
            LinkRewriter.rewrite(text, notePath: "n.md", newNotePath: "n.md", moves: ["a.md": "z.md"]),
            "---\ntitle: T\n---\n[a](z.md)\n"
        )
        XCTAssertEqual(LinkRewriter.rewrite("plain\n", notePath: "n.md", newNotePath: "n.md", moves: ["a.md": "z.md"]), "plain\n")
    }

    func testLinkNestedInAnImageLinkOnlyChangesTheNoteDestination() {
        let text = "[![alt](img.png)](a.md)\n"
        XCTAssertEqual(
            LinkRewriter.rewrite(text, notePath: "n.md", newNotePath: "n.md", moves: ["a.md": "b.md"]),
            "[![alt](img.png)](b.md)\n"
        )
    }
}

final class LinkRewriterAttachmentTests: XCTestCase {
    func testImagesAndAttachmentsFollowMovesButFolderLinksAndURLsAreLeftAlone() {
        let text = "![i](img/a.png \"t\") [pdf](doc.pdf) [dir](img/) [web](https://x.org/a.png)\n"
        let result = LinkRewriter.rewrite(
            text, notePath: "n.md", newNotePath: "sub/n.md", moves: ["n.md": "sub/n.md", "img/a.png": "media/a.png"]
        )
        XCTAssertEqual(result, "![i](../media/a.png \"t\") [pdf](../doc.pdf) [dir](img/) [web](https://x.org/a.png)\n")
    }
}
