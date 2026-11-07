import XCTest
@testable import MarkdownEditor

/// The width an image keeps in its alt text, `![caption|300](path)`.
final class ImageSizeTests: XCTestCase {
    func testTheWidthIsReadAfterTheLastPipe() {
        XCTAssertEqual(ImageSize.split("A bridge|300").caption, "A bridge")
        XCTAssertEqual(ImageSize.split("A bridge|300").width, 300)
        XCTAssertEqual(ImageSize.split("|120").caption, "")
        XCTAssertEqual(ImageSize.split("|120").width, 120)
        XCTAssertEqual(ImageSize.split("a|b|42").caption, "a|b")
        XCTAssertEqual(ImageSize.split("a|b|42").width, 42)
        XCTAssertEqual(ImageSize.split("A bridge|300x200").width, 300, "a height is left to the ratio")
    }

    func testAltTextWithoutAWidthIsLeftAlone() {
        for alt in ["", "A bridge", "a|b", "a|", "a|0", "a|-3", "a|3x", "a|x3", "a|3.5", "a|12px"] {
            XCTAssertEqual(ImageSize.split(alt).caption, alt, alt)
            XCTAssertNil(ImageSize.split(alt).width, alt)
        }
    }

    func testAWidthIsSetReplacedOrRemoved() {
        XCTAssertEqual(ImageSize.alt("A bridge", width: 300), "A bridge|300")
        XCTAssertEqual(ImageSize.alt("A bridge|300", width: 450), "A bridge|450")
        XCTAssertEqual(ImageSize.alt("", width: 80), "|80")
        XCTAssertEqual(ImageSize.alt("A bridge|300", width: nil), "A bridge")
    }

    func testOnlyTheAltTextOfTheLineChanges() {
        XCTAssertEqual(ImageSize.setting(width: 300, inImageLine: "![A bridge](../assets/My%20clip.png)"), "![A bridge|300](../assets/My%20clip.png)")
        XCTAssertEqual(ImageSize.setting(width: 300, inImageLine: "![](a.png)"), "![|300](a.png)")
        XCTAssertEqual(ImageSize.setting(width: 90, inImageLine: "  ![x|300](a.png \"title\")  "), "  ![x|90](a.png \"title\")  ")
        XCTAssertEqual(ImageSize.setting(width: nil, inImageLine: "![x|300](a.png)"), "![x](a.png)")
        XCTAssertNil(ImageSize.setting(width: 300, inImageLine: "Some text ![x](a.png)"))
        XCTAssertNil(ImageSize.setting(width: 300, inImageLine: "No image here"))
    }

    func testHandlesKeepTheWidthInTheColumn() {
        XCTAssertEqual(ResizeHandle.right.width(from: 200, dragging: 50, maxWidth: 700), 250)
        XCTAssertEqual(ResizeHandle.left.width(from: 200, dragging: 50, maxWidth: 700), 150, "the left handle pulls the right edge in")
        XCTAssertEqual(ResizeHandle.right.width(from: 200, dragging: 900, maxWidth: 700), 700)
        XCTAssertEqual(ResizeHandle.right.width(from: 200, dragging: -900, maxWidth: 700), PictureMark.minWidth)
    }

    func testARequestedWidthScalesTheEmbedKeepingItsRatio() {
        let embed = Embed(content: .image(NSImage()), size: NSSize(width: 400, height: 2000))
        XCTAssertEqual(embed.displaySize(in: 700, requested: 200), NSSize(width: 200, height: 1000), "wider than the usual height cap")
        XCTAssertEqual(embed.displaySize(in: 150, requested: 200), NSSize(width: 150, height: 750), "never wider than the column")
        let card = Embed(content: .image(NSImage()), size: NSSize(width: 10_000, height: 96), keepsHeight: true)
        XCTAssertEqual(card.displaySize(in: 700, requested: 200), NSSize(width: 700, height: 96))
    }
}
