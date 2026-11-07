import AppKit
import XCTest
@testable import MarkdownEditor

/// The note is Markdown, the page shows no syntax: whatever the caret or the selection does, no Markdown character is
/// visible (docs/design/CLEAN-RENDER.md lists every leak these tests close). Drives the real text view offscreen.
@MainActor
final class CleanRenderTests: XCTestCase {
    private var window: NSWindow!
    private var textView: EditorTextView!
    private var controller: EditorController!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
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

    private func load(_ text: String, caret: Int? = nil) {
        controller.show(EditorContent(id: 1, text: text))
        textView.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
    }

    private func select(_ range: NSRange) { textView.setSelectedRange(range) }

    /// The characters of `range` that take room and show: not hidden by a vanishing font or a clear colour.
    private func visibleText(in range: NSRange? = nil) -> String {
        let storage = textView.textStorage!
        let ns = storage.string as NSString
        var result = ""
        let whole = range ?? NSRange(location: 0, length: ns.length)
        storage.enumerateAttributes(in: whole) { attributes, subrange, _ in
            let font = attributes[.font] as? NSFont
            let color = attributes[.foregroundColor] as? NSColor
            let hidden = (font?.pointSize ?? 12) < 1 || color == NSColor.clear
            if !hidden { result += ns.substring(with: subrange) }
        }
        return result
    }

    private func hiddenText() -> String {
        let storage = textView.textStorage!
        let ns = storage.string as NSString
        var result = ""
        storage.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attributes, subrange, _ in
            let font = attributes[.font] as? NSFont
            if (font?.pointSize ?? 12) < 1 { result += ns.substring(with: subrange) }
        }
        return result
    }

    // MARK: Frontmatter

    func testSelectAllNeverShowsTheFrontmatter() {
        load("---\nstatus: To do\n---\nBody\n")
        select(NSRange(location: 0, length: textView.string.utf16.count))
        XCTAssertEqual(visibleText().trimmingCharacters(in: .whitespacesAndNewlines), "Body")
    }

    func testTheCaretInTheFrontmatterIsNotAPlaceToType() {
        load("---\nstatus: To do\n---\nBody\n", caret: 8)
        XCTAssertEqual(visibleText().trimmingCharacters(in: .whitespacesAndNewlines), "Body")
    }

    func testTheFrontmatterTakesNoRoomTagsIncluded() {
        load("---\nstatus: To do\ntags: [a, b]\n---\nBody\n")
        XCTAssertTrue(controller.liveBlocks.isEmpty)
        XCTAssertEqual(visibleText().trimmingCharacters(in: .whitespacesAndNewlines), "Body")
        XCTAssertEqual(hiddenText(), "---\nstatus: To do\ntags: [a, b]\n---\n")
    }

    func testViewSourceShowsTheYAML() {
        load("---\nstatus: To do\n---\nBody\n")
        controller.syntaxMode = .source
        XCTAssertTrue(visibleText().contains("status: To do"))
        controller.syntaxMode = .rendered
        XCTAssertFalse(visibleText().contains("status"))
    }

    // MARK: Selection

    private let sample = """
    ## Heading

    Some **bold**, *it*, `code`, ~~gone~~ and [a link](https://example.com) here.

    - [ ] zzd
    - [x] zd

    - bullet

    > quote
    > more

    > [!NOTE]
    > callout

    ---

    """

    func testSelectAllShowsNoSyntaxAnywhere() {
        load(sample)
        select(NSRange(location: 0, length: textView.string.utf16.count))
        let shown = visibleText()
        for syntax in ["##", "**", "[x]", "[ ]", "`", "~~", "](", "[!NOTE]", "> ", "---", "- "] {
            XCTAssertFalse(shown.contains(syntax), "\(syntax) shows: \(shown)")
        }
        XCTAssertTrue(shown.contains("Heading"))
        XCTAssertTrue(shown.contains("zzd"))
    }

    func testASelectionOnlyHighlightsSoClearCharactersStayClear() {
        // The selection's own text colour would draw a task's `[ ]`, a bullet's `-` and a divider's `---` again.
        XCTAssertNil(textView.selectedTextAttributes[.foregroundColor])
        XCTAssertNotNil(textView.selectedTextAttributes[.backgroundColor])
    }

    func testNoSystemButtonFloatsOverASelection() {
        XCTAssertEqual(textView.writingToolsBehavior, .none)
    }

    func testSelectingATodoShowsNoBox() {
        load("- [ ] zzd\n- [x] zd\n")
        select(NSRange(location: 6, length: 12))
        XCTAssertEqual(visibleText().split(whereSeparator: \.isWhitespace).joined(separator: " "), "zzd zd")
    }

    func testTheCaretOnBoldTextShowsNoMarker() {
        load("a **bold** c", caret: 5)
        XCTAssertEqual(visibleText(), "a bold c")
        select(NSRange(location: 3, length: 0))
        XCTAssertEqual(visibleText(), "a bold c")
    }

    func testTheRestOfTheSyntaxIsHiddenToo() {
        load("Escaped \\*star\\* and ***both*** and ![pic](a.png) image.\n\n[ref]: https://example.com\n\n<!-- note -->\n\nLast\n")
        select(NSRange(location: 0, length: textView.string.utf16.count))
        let shown = visibleText().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertEqual(shown, "Escaped *star* and both and pic image. Last")
    }

    func testViewSourceShowsEverythingAndRenderedHidesItAgain() {
        load("a **bold** c")
        controller.syntaxMode = .source
        XCTAssertEqual(visibleText(), "a **bold** c")
        controller.syntaxMode = .rendered
        XCTAssertEqual(visibleText(), "a bold c")
    }

    // MARK: Caret

    func testClickingInsideAMarkerPutsTheCaretNextToIt() {
        load("a **bold** c", caret: 11)
        select(NSRange(location: 3, length: 0))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        select(NSRange(location: 9, length: 0))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 10, length: 0))
    }

    func testArrowsStepOverMarkersWithoutAStallingKeystroke() {
        load("a **bold** c", caret: 2)
        textView.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(textView.selectedRange().location, 5, "past the `**` and the `b`")
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(textView.selectedRange().location, 11, "past the closing `**` and the space")
    }

    func testTheCaretIsNeverBeforeAHeadingsHiddenStart() {
        load("## Title\nbody", caret: 8)
        textView.doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
        XCTAssertEqual(textView.selectedRange().location, 3)
        textView.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(textView.selectedRange().location, 3, "nothing above")
    }

    func testTypingAtTheStartOfAHeadingGoesInTheHeading() {
        load("## Title", caret: 0)
        textView.insertText("X", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "## XTitle")
    }

    // MARK: Deleting

    func testBackspaceAtTheStartOfAHeadingMakesItAParagraph() {
        load("## Title", caret: 3)
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(textView.string, "Title")
        XCTAssertEqual(textView.selectedRange().location, 0)
    }

    func testBackspaceAtTheStartOfATodoTurnsItIntoAParagraph() {
        load("- [ ] zzd\n- [x] zd", caret: 16)
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(textView.string, "- [ ] zzd\nzd")
    }

    func testBackspaceAfterBoldRemovesTheLastLetterAndKeepsTheMarkersBalanced() {
        load("a **bold** c", caret: 10)
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(textView.string, "a **bol** c")
        XCTAssertEqual(visibleText(), "a bol c")
    }

    func testDeletingTheOnlyLetterOfABoldRemovesItsMarkers() {
        load("a **b** c", caret: 5)
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(textView.string, "a  c")
    }

    func testTypingOverHalfOfABoldLeavesNoLoneMarker() {
        load("a **bold** c")
        select(NSRange(location: 0, length: 6))
        textView.insertText("Z", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "Zld c")
        XCTAssertEqual(visibleText(), "Zld c")
    }

    func testDeletingASelectionThroughHalfALinkTakesItsDestination() {
        load("see [site](https://x.y) now")
        select(NSRange(location: 0, length: 6))
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(textView.string, "ite now")
    }

    func testUndoBringsBackWhatADeleteTookInOneStep() {
        load("a **bold** c")
        select(NSRange(location: 0, length: 6))
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(textView.string, "ld c")
        controller.undo.undo()
        XCTAssertEqual(textView.string, "a **bold** c")
    }

    // MARK: Copy

    func testCopyGivesTheMarkdownAndTheRenderedRichText() throws {
        load("## Title\n\nSome **bold** and [a link](https://example.com)\n\n- [ ] todo\n- bullet\n")
        select(NSRange(location: 0, length: textView.string.utf16.count))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loam.test.copy"))
        let types = textView.writablePasteboardTypes
        pasteboard.declareTypes(types, owner: nil)
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: types))
        XCTAssertEqual(pasteboard.string(forType: .string), textView.string, "Markdown, as it is stored")
        let data = try XCTUnwrap(pasteboard.data(forType: .rtf))
        let rich = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let words = rich.string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertEqual(words, "Title Some bold and a link ☐ todo • bullet")
        var link: Any?
        rich.enumerateAttribute(.link, in: NSRange(location: 0, length: rich.length)) { value, _, _ in if value != nil { link = value } }
        XCTAssertNotNil(link, "the link stays a link")
    }

    // MARK: Links

    func testALinkIsMadeInAFieldNotByTypingItsSyntax() throws {
        load("see site now")
        select(NSRange(location: 4, length: 4))
        XCTAssertTrue(controller.perform(.link))
        let panel = try XCTUnwrap(controller.linkEditorPanel)
        XCTAssertFalse(panel.model.isExisting)
        panel.model.onCommit?("https://example.com")
        XCTAssertEqual(textView.string, "see [site](https://example.com) now")
        XCTAssertEqual(visibleText(), "see site now")
    }

    func testALinkEditedInTheFieldKeepsItsText() throws {
        load("see [site](https://old.example) now", caret: 7)
        XCTAssertTrue(controller.perform(.link))
        let panel = try XCTUnwrap(controller.linkEditorPanel)
        XCTAssertTrue(panel.model.isExisting)
        XCTAssertEqual(panel.model.text, "https://old.example")
        panel.model.onCommit?("https://new.example/a b")
        XCTAssertEqual(textView.string, "see [site](<https://new.example/a b>) now")
    }

    func testALinkIsRemovedFromTheFieldLeavingItsText() throws {
        load("see [site](https://old.example) now", caret: 7)
        XCTAssertTrue(controller.perform(.link))
        try XCTUnwrap(controller.linkEditorPanel).model.onRemove?()
        XCTAssertEqual(textView.string, "see site now")
    }

    func testASelectedAddressLinksToItselfAtOnce() {
        load("go to https://example.com now")
        select(NSRange(location: 6, length: 19))
        XCTAssertTrue(controller.perform(.link))
        XCTAssertEqual(textView.string, "go to [https://example.com](https://example.com) now")
    }

    func testNothingSelectedAndNoLinkDoesNothing() {
        load("plain text", caret: 3)
        XCTAssertFalse(controller.perform(.link))
        XCTAssertEqual(textView.string, "plain text")
    }
}
