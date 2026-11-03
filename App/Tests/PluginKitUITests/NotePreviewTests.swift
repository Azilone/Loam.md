import CoreGraphics
@testable import PluginKitUI
import XCTest

final class NotePreviewTests: XCTestCase {
    /// A fence with a language is one block a card may draw; a bare fence stays code lines.
    func testFencedBlocks() {
        let text = "Intro\n```mermaid\nflowchart LR\n  A --> B\n```\n```\nplain\n```\nEnd"
        XCTAssertEqual(NotePreview.parse(text, title: "x").blocks, [
            .paragraph("Intro"),
            .fenced(language: "mermaid", code: "flowchart LR\n  A --> B"),
            .code("plain"),
            .paragraph("End"),
        ])
    }

    /// A fence left open at the end of the note still makes its block.
    func testUnclosedFence() {
        XCTAssertEqual(NotePreview.parse("```Base\nviews:\n", title: "x").blocks, [.fenced(language: "base", code: "views:\n")])
    }

    /// A base's tile names its first view.
    func testViewTitle() {
        let code = "filters:\n  and:\n    - file.ext == \"md\"\nviews:\n- type: kanban\n  name: Kanban\n  groupBy:\n    property: status"
        let title = CodeBlockPreviews.viewTitle(of: code)
        XCTAssertEqual(title.name, "Kanban")
        XCTAssertEqual(title.kind, "kanban")
        XCTAssertNil(CodeBlockPreviews.viewTitle(of: "filters:\n  name: nope").name)
    }

    /// A picture wider than a card's is shrunk, keeping its proportions.
    func testThumbnail() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2000, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let small = CodeBlockPreviews.thumbnail(image)
        XCTAssertEqual(small.width, 640)
        XCTAssertEqual(small.height, 160)
    }

    /// Two cards asking for one diagram draw it once, and the picture is kept.
    @MainActor func testDrawsOnceAndKeeps() async {
        let previews = CodeBlockPreviews()
        var calls = 0
        let context = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        _ = previews.add(CodeBlockRenderer(id: "t", languages: ["mermaid"]) { _ in
            calls += 1
            return RenderedCodeBlock(image: image, size: CGSize(width: 5, height: 5))
        })
        let request = CodeBlockRequest(language: "mermaid", code: "a")
        async let first = previews.draw(request)
        async let second = previews.draw(request)
        _ = await (first, second)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(previews.picture(for: request))
        XCTAssertTrue(previews.drawsPicture("mermaid"))
        XCTAssertFalse(previews.showsView("mermaid"))
    }
}
