import AppKit
import XCTest
@testable import MarkdownEditor

/// A click opens a link only when it lands on the link's own characters; a click in the room past the end of a line
/// opens nothing there, and puts the caret at the line's end as it does beside any text. That room is where a note
/// read back differs from what was typed: the space typed after a link is not saved, so a note ending on an address
/// comes back with the address at its line's end, and a click after it used to open the address.
@MainActor
final class LinkClickTests: XCTestCase {
    private var window: NSWindow!
    private var textView: EditorTextView!
    private var controller: EditorController!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        textView = EditorTextView(usingTextLayoutManager: true)
        textView.frame = window.contentView!.bounds
        textView.isRichText = false
        textView.allowsUndo = true
        window.contentView!.addSubview(textView)
        controller = EditorController()
        controller.attach(textView)
        window.makeFirstResponder(textView)
    }

    override func tearDown() async throws {
        window.close()
    }

    private func load(_ text: String) {
        controller.show(EditorContent(id: 1, text: text))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if let layout = textView.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
    }

    /// The address a click at `point` would open, as `EditorTextView.mouseDown` looks it up.
    private func openedLink(at point: NSPoint) -> String? {
        let found: (String, NSRange)? = textView.hit(.markdownLink, at: point)
        return found?.0
    }

    /// Where the characters of `range` are drawn.
    private func letters(of range: NSRange) -> NSRect {
        textView.selectionBoxes(for: range).reduce(NSRect.null) { $0.union($1) }
    }

    func testAClickPastTheEndOfALinkThatEndsItsLineOpensNothing() {
        let text = "Read https://example.com\nNext line"
        load(text)
        let link = (text as NSString).range(of: "https://example.com")
        let box = letters(of: link)
        XCTAssertNil(openedLink(at: NSPoint(x: box.maxX + 40, y: box.midY)), "the room after the line belongs to no character")
    }

    func testAClickPastTheEndOfALinkEndingTheNoteOpensNothing() {
        let text = "Read https://example.com"
        load(text)
        let link = (text as NSString).range(of: "https://example.com")
        let box = letters(of: link)
        XCTAssertNil(openedLink(at: NSPoint(x: box.maxX + 40, y: box.midY)))
    }

    func testAClickOnTheLinkOpensIt() {
        let text = "Read https://example.com\nNext line"
        load(text)
        let link = (text as NSString).range(of: "https://example.com")
        let box = letters(of: link)
        XCTAssertEqual(openedLink(at: NSPoint(x: box.midX, y: box.midY)), "https://example.com")
        // The right half of its last letter, whose caret the click sets after it: still the link's own room.
        XCTAssertEqual(openedLink(at: NSPoint(x: box.maxX - 1, y: box.midY)), "https://example.com")
    }

    func testAClickOnTheWordBeforeTheLinkOpensNothing() {
        let text = "Read https://example.com\nNext line"
        load(text)
        let word = letters(of: (text as NSString).range(of: "Read"))
        XCTAssertNil(openedLink(at: NSPoint(x: word.midX, y: word.midY)))
    }
}
