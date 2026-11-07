import AppKit
import XCTest
@testable import MarkdownEditor

/// Drives the real text view and controller in an offscreen window, the way typing does: text goes through
/// `insertText`, keys such as Return and Tab through `doCommand(by:)`.
@MainActor
final class EditorControllerTests: XCTestCase {
    private var window: NSWindow!
    private var textView: EditorTextView!
    private var controller: EditorController!
    private var changes: [String] = []

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        textView = EditorTextView(usingTextLayoutManager: true)
        textView.frame = window.contentView!.bounds
        textView.isRichText = false
        textView.allowsUndo = true
        window.contentView!.addSubview(textView)
        controller = EditorController()
        controller.attach(textView)
        controller.onChange = { [weak self] in self?.changes.append($0) }
        window.makeFirstResponder(textView)
    }

    override func tearDown() async throws {
        window.close()
    }

    private func load(_ text: String, id: Int = 1) {
        controller.show(EditorContent(id: id, text: text))
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    private func type(_ text: String) {
        for character in text {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
        }
    }

    private func press(_ selector: Selector) {
        textView.doCommand(by: selector)
    }

    private var menu: SlashMenuPanel? { window.childWindows?.compactMap { $0 as? SlashMenuPanel }.first }

    /// The run a click on character `index` toggles, and the run plain `effectiveRange` lookups give there.
    private func taskBoxRuns(at index: Int) -> (whole: NSRange?, partial: NSRange) {
        var partial = NSRange()
        _ = textView.textStorage!.attribute(.markdownTaskBox, at: index, effectiveRange: &partial)
        let run: (Bool, NSRange)? = textView.attributeRun(.markdownTaskBox, at: index)
        return (run?.1, partial)
    }

    func testATaskBoxIsOneRunOfThreeCharactersWhereverTheCaretIs() {
        for caret in [0, 3, 6, 12] {
            load("- [ ] **zd** end\n- [x] two\n")
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            for index in 2...4 {
                let runs = taskBoxRuns(at: index)
                XCTAssertEqual(runs.whole, NSRange(location: 2, length: 3), "caret \(caret), index \(index): \(runs.partial)")
            }
        }
    }

    func testLoadingStylesWithoutReportingAChange() {
        load("# Title")
        XCTAssertEqual(textView.string, "# Title")
        XCTAssertEqual(changes, [])
        let font = textView.textStorage!.attribute(.font, at: 3, effectiveRange: nil) as! NSFont
        XCTAssertGreaterThan(font.pointSize, MarkdownTheme().fontSize)
    }

    func testRevealPutsTheCaretAtTheStartOfALine() {
        load("# One\n\nsun\n## Four\n")
        XCTAssertTrue(controller.reveal(line: 3))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 7, length: 0))
        // A heading's `#`s are hidden: the caret goes where its text starts.
        XCTAssertTrue(controller.reveal(line: 4))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 14, length: 0))
        XCTAssertTrue(controller.reveal(line: 1))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertFalse(controller.reveal(line: 0))
        XCTAssertFalse(controller.reveal(line: 6))
        XCTAssertEqual(changes, [], "moving the caret is not an edit")
    }

    func testLineOffsetsAreUTF16() {
        XCTAssertEqual(EditorController.offset(ofLine: 1, in: ""), 0)
        XCTAssertEqual(EditorController.offset(ofLine: 2, in: "a\n"), 2)
        XCTAssertNil(EditorController.offset(ofLine: 3, in: "a\n"))
        XCTAssertEqual(EditorController.offset(ofLine: 2, in: "😀\nb"), 3)
        XCTAssertEqual(EditorController.offset(ofLine: 2, in: "a\r\nb"), 3)
    }

    func testSeveralLineOffsetsMatchOneByOne() {
        let text = "# A\n\n😀 b\n## C\nd\n"
        let lines = [4, 1, 3, 7, 6, 0]
        XCTAssertEqual(EditorController.offsets(ofLines: lines, in: text), lines.map { EditorController.offset(ofLine: $0, in: text) })
        XCTAssertEqual(EditorController.offsets(ofLines: [], in: text), [])
    }

    func testTypingRestylesAndReportsTheText() {
        load("")
        type("**hi**")
        XCTAssertEqual(changes.last, "**hi**")
        let font = textView.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testReturnContinuesAndEndsAList() {
        load("- milk")
        press(#selector(NSResponder.insertNewline(_:)))
        type("bread")
        press(#selector(NSResponder.insertNewline(_:)))
        press(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(textView.string, "- milk\n- bread\n")
    }

    /// The height of the line the caret is on, which the caret takes.
    private func caretLineHeight() -> CGFloat {
        let layout = textView.textLayoutManager!
        textView.layoutSubtreeIfNeeded()
        layout.ensureLayout(for: layout.documentRange)
        var height: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { fragment in
            height = fragment.textLineFragments.last?.typographicBounds.height ?? 0
            return false
        }
        return height
    }

    func testReturnsInAQuoteKeepTheCaretVisible() {
        for (id, quote) in ["> a", "> [!NOTE]\n> a"].enumerated() {
            load(quote, id: id + 10)
            press(#selector(NSResponder.insertNewline(_:)))
            XCTAssertGreaterThan(caretLineHeight(), 10, "after one Return in \(quote)")
            press(#selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(textView.string, quote + "\n\n")
            XCTAssertGreaterThan(caretLineHeight(), 10, "after two Returns in \(quote)")
            let font = textView.typingAttributes[.font] as? NSFont
            XCTAssertGreaterThan(font?.pointSize ?? 0, 10)
        }
    }

    func testManyReturnsAfterAQuoteKeepTheCaretOnANormalLine() {
        for (id, quote) in ["> a", "> [!NOTE]\n> a"].enumerated() {
            load(quote, id: id + 20)
            for count in 1...5 {
                press(#selector(NSResponder.insertNewline(_:)))
                XCTAssertGreaterThan(caretLineHeight(), 10, "after \(count) Returns in \(quote)")
                let storage = textView.textStorage!
                let font = textView.typingAttributes[.font] as? NSFont
                XCTAssertGreaterThan(font?.pointSize ?? 0, 10, "typing font after \(count) Returns")
                if count >= 2 {
                    let last = storage.length - 1
                    let style = storage.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle
                    XCTAssertEqual(style?.headIndent, 0, "quote style leaked after \(count) Returns in \(quote)")
                    XCTAssertEqual(style?.minimumLineHeight, 0, "quote style leaked after \(count) Returns in \(quote)")
                    XCTAssertGreaterThan((storage.attribute(.font, at: last, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 10)
                }
            }
        }
    }

    func testCaretIndicatorStaysTheHeightOfItsLineWhenTheSystemPlacesItTooSmall() {
        load("> a")
        press(#selector(NSResponder.insertNewline(_:)))
        press(#selector(NSResponder.insertNewline(_:)))
        let line = textView.caretLineRect()
        XCTAssertNotNil(line)
        // The system computed the caret against the line as it was before the quote ended: a hair high.
        let indicator = NSTextInsertionIndicator(frame: NSRect(x: 45, y: 40, width: 1, height: 0.3))
        textView.addSubview(indicator)
        let fitted = indicator.frame
        XCTAssertGreaterThan(fitted.height, 10)
        XCTAssertEqual(fitted.maxY, line!.maxY, accuracy: 1)
    }

    func testReturnInsideCodeIsPlain() {
        load("```\n- not a list")
        press(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(textView.string, "```\n- not a list\n")
    }

    func testTabNestsAListItemAndUndoRestoresIt() {
        load("- a\n- b")
        press(#selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(textView.string, "- a\n  - b")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "- a\n- b")
    }

    func testSlashMenuFiltersAndInsertsTheChoice() throws {
        load("Intro\n")
        type("/hea")
        let panel = try XCTUnwrap(menu)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.model.items.map(\.id), ["heading1", "heading2", "heading3"])
        press(#selector(NSResponder.moveDown(_:)))
        press(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(textView.string, "Intro\n## ")
        XCTAssertFalse(panel.isVisible)
        type("Next")
        XCTAssertEqual(textView.string, "Intro\n## Next")
    }

    func testSlashMenuClosesOnEscapeAndSpace() {
        load("")
        type("/")
        XCTAssertEqual(menu?.isVisible, true)
        press(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertNotEqual(menu?.isVisible, true)
        type(" and/or ")
        XCTAssertNotEqual(menu?.isVisible, true)
        XCTAssertEqual(textView.string, "/ and/or ")
    }

    func testSlashMenuClosesWhenTheEditorLeavesItsWindow() {
        load("")
        type("/")
        XCTAssertEqual(menu?.isVisible, true)
        textView.removeFromSuperview()
        XCTAssertNil(menu)
    }

    func testSlashMenuClosesWhenTheEditorLosesTheFocus() {
        load("")
        type("/")
        XCTAssertEqual(menu?.isVisible, true)
        window.makeFirstResponder(nil)
        XCTAssertNil(menu)
    }

    func testSlashMenuClosesWhenTheWindowStopsBeingKey() {
        load("")
        type("/")
        XCTAssertEqual(menu?.isVisible, true)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertNil(menu)
    }

    func testSlashMenuClosesWhenTheEditorIsDismantled() {
        load("")
        type("/")
        XCTAssertEqual(menu?.isVisible, true)
        controller.closePanels()
        XCTAssertNil(menu)
    }

    func testSlashMenuClosesWhenTheSlashIsDeleted() {
        load("")
        type("/a")
        XCTAssertEqual(menu?.isVisible, true)
        press(#selector(NSResponder.deleteBackward(_:)))
        press(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertNil(menu)
    }

    /// A stand-in `@` source: "tom" offers one day, anything else none.
    private func days(_ query: String) -> [SlashMenuItem] {
        guard "tomorrow".hasPrefix(query) || "next week".hasPrefix(query) else { return [] }
        return [SlashMenuItem(id: "d", title: "Tomorrow", symbol: "calendar", section: "Days") { _, trigger in
            TextEdit(range: trigger, replacement: "📅 2026-10-20 ", selection: NSRange(location: trigger.location + 14, length: 0))
        }]
    }

    func testMentionMenuOffersDaysAndInsertsTheChoice() throws {
        controller.mentionItems = { [unowned self] in self.days($0) }
        load("- [ ] Call ")
        type("@to")
        let panel = try XCTUnwrap(menu)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.model.items.map(\.section), ["Days"])
        press(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(textView.string, "- [ ] Call 📅 2026-10-20 ")
        XCTAssertFalse(panel.isVisible)
    }

    func testMentionMenuWaitsThroughWordsWithoutAMatch() throws {
        controller.mentionItems = { [unowned self] in self.days($0) }
        load("")
        type("@next")
        XCTAssertEqual(menu?.isVisible, true)
        type(" w")
        XCTAssertEqual(menu?.isVisible, true, "spaces are part of the words")
        type("x")
        XCTAssertNotEqual(menu?.isVisible, true, "nothing matches: hidden")
        press(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(textView.string, "@next wx\n", "Return is a plain new line while hidden")
        XCTAssertNotEqual(menu?.isVisible, true)
    }

    func testMentionInsideAWordDoesNotOpenTheMenu() {
        controller.mentionItems = { [unowned self] in self.days($0) }
        load("kevin")
        type("@to")
        XCTAssertNotEqual(menu?.isVisible, true)
    }

    /// A stand-in `[[` source: one note, whatever is typed.
    private func notes(_ query: String) -> [SlashMenuItem] {
        [SlashMenuItem(id: "n", title: "Plan", symbol: "doc.text", section: "Notes") { _, trigger in
            TextEdit(range: trigger, replacement: "[Plan](Plan.md) ", selection: NSRange(location: trigger.location + 16, length: 0))
        }]
    }

    func testDoubleBracketOpensTheNoteMenuAndInsertsTheChoice() throws {
        var queries: [String] = []
        controller.linkItems = { [unowned self] in queries.append($0); return self.notes($0) }
        load("See ")
        type("[")
        XCTAssertNotEqual(menu?.isVisible, true, "one bracket is a plain bracket")
        type("[pl")
        let panel = try XCTUnwrap(menu)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(queries.last, "pl")
        press(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(textView.string, "See [Plan](Plan.md) ")
        XCTAssertFalse(panel.isVisible)
    }

    func testDoubleBracketInsideAWordDoesNotOpenTheMenu() {
        controller.linkItems = { [unowned self] in self.notes($0) }
        load("array")
        type("[[pl")
        XCTAssertNotEqual(menu?.isVisible, true)
    }

    func testClosingBracketsCloseTheNoteMenu() {
        controller.linkItems = { [unowned self] in self.notes($0) }
        load("")
        type("[[pl")
        XCTAssertEqual(menu?.isVisible, true)
        type("]")
        XCTAssertNotEqual(menu?.isVisible, true)
    }

    func testASelectedDatePillStaysAPill() throws {
        load("- [ ] Call 📅 2026-10-20\nnext")
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertNotNil(storage.attribute(.markdownDate, at: 11, effectiveRange: nil))
        textView.setSelectedRange(NSRange(location: 11, length: 13))
        XCTAssertNotNil(storage.attribute(.markdownDate, at: 11, effectiveRange: nil), "selected, the pill stays: no syntax shows")
        controller.syntaxMode = .source
        XCTAssertNil(storage.attribute(.markdownDate, at: 11, effectiveRange: nil), "View Source shows the text")
    }

    func testSlashInsideWordsOrCodeDoesNotOpenTheMenu() {
        load("and")
        type("/")
        XCTAssertNotEqual(menu?.isVisible, true)
        load("```\n", id: 2)
        type("/")
        XCTAssertNotEqual(menu?.isVisible, true)
    }

    func testReloadingTheSameNoteKeepsTheCaret() {
        load("hello world")
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        controller.show(EditorContent(id: 2, text: "hello there world", keepsSelection: true))
        XCTAssertEqual(textView.string, "hello there world")
        XCTAssertEqual(textView.selectedRange().location, 5)
    }

    func testAFieldSetFromOutsideKeepsTheCaretOnItsWord() {
        load("---\nstatus: To do\n---\nBody text\n")
        let body = ("---\nstatus: To do\n---\nBody " as NSString).length
        textView.setSelectedRange(NSRange(location: body, length: 0))
        controller.show(EditorContent(id: 2, text: "---\nstatus: In progress\n---\nBody text\n", keepsSelection: true))
        XCTAssertEqual(textView.string, "---\nstatus: In progress\n---\nBody text\n")
        XCTAssertEqual(textView.selectedRange().location, ("---\nstatus: In progress\n---\nBody " as NSString).length)
    }

    func testDifferenceIsTheChangedMiddle() {
        let change = EditorController.difference(from: "a 😀 b", to: "a 😃 b")
        XCTAssertEqual(change.old, NSRange(location: 2, length: 2))
        XCTAssertEqual(change.new, "😃")
        XCTAssertEqual(EditorController.difference(from: "same", to: "same").old.length, 0)
    }

    /// Restyling only what changed leaves the same attributes as restyling everything.
    func testRestylingWhatChangedMatchesRestylingEverything() {
        let text = """
        # Title

        Some **bold** and a [link](https://example.com).

        - item
        - [ ] task

        | A | B |
        | --- | --- |
        | one | two |

        > quote

        ```
        code
        ```

        Last line.
        """
        load(text)
        func check(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            let incremental = NSAttributedString(attributedString: textView.textStorage!)
            controller.restyle(everything: true)
            let full = textView.textStorage!
            XCTAssertTrue(incremental.isEqual(to: full), step, file: file, line: line)
        }
        func caret(after needle: String) {
            let range = (textView.string as NSString).range(of: needle)
            textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        }
        caret(after: "# Title")
        type(" more")
        check("typing in the title")
        caret(after: "Some ")
        type("more ")
        check("typing before a table")
        caret(after: "Some ")
        type("**")
        check("opening bold")
        caret(after: "Last line.")
        type("\n```")
        check("opening a code block at the end")
        caret(after: "- item")
        press(#selector(NSResponder.insertNewline(_:)))
        type("next")
        check("continuing a list")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        press(#selector(NSResponder.deleteForward(_:)))
        check("deleting the heading's #")
    }

    func testTheCodeBarSetsTheLanguageAndCopiesTheCode() {
        load("Intro\n\n```\nlet a = 1\n```\n")
        let start = ("Intro\n\n" as NSString).length
        controller.setCodeLanguage(ofBlockAt: start, to: "swift")
        XCTAssertEqual(textView.string, "Intro\n\n```swift\nlet a = 1\n```\n")
        controller.setCodeLanguage(ofBlockAt: start, to: "")
        XCTAssertEqual(textView.string, "Intro\n\n```\nlet a = 1\n```\n")
        controller.copyCode(of: NSRange(location: start, length: ("```\nlet a = 1\n```" as NSString).length))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "let a = 1")
        XCTAssertEqual(CodeBlockBar.title(of: "js"), "js")
        XCTAssertEqual(CodeBlockBar.title(of: "swift"), "Swift")
        XCTAssertEqual(CodeBlockBar.title(of: ""), "Plain text")
    }

    func testANestedItemsDropLineStandsUnderItsParentsTextNotThroughIt() throws {
        load("- [ ] dzd\n- [ ] zdzd\n    - [x] fef\n    - [ ] ef\n")
        let text = textView.string as NSString
        let blocks = BlockMoving.blocks(in: textView.string)
        let moving = try XCTUnwrap(blocks.first { text.substring(with: $0.firstLine) == "    - [ ] ef" })
        let nested = try XCTUnwrap(blocks.first { text.substring(with: $0.firstLine) == "    - [x] fef" })
        let parent = try XCTUnwrap(textView.lineBox(for: text.range(of: "zdzd")))
        let child = try XCTUnwrap(textView.lineBox(for: text.range(of: "fef")))
        let target = textView.dropTarget(for: moving, at: NSPoint(x: 100, y: child.minY + 2))
        XCTAssertEqual(target, .some(nested))
        let line = textView.dropLine.frame
        XCTAssertGreaterThanOrEqual(line.midY, parent.maxY - 0.5, "under the parent's text, not through it")
        XCTAssertLessThanOrEqual(line.midY, child.maxY)
    }

    /// Whether TextKit's selection highlight view is hidden; nil when there is none.
    private var highlightHidden: Bool? {
        textView.subviews.first { NSStringFromClass(Swift.type(of: $0)).contains("Selection") }.map { $0.alphaValue == 0 }
    }

    func testABlockSelectedByItsHandleShowsNoTextHighlightAndDeletesWhole() throws {
        load("- [ ] one\n- [ ] two\n- [ ] three\n")
        let block = try XCTUnwrap(BlockMoving.blocks(in: textView.string).first { $0.firstLine.location == 10 })
        textView.setSelectedRange(NSRange(location: 10, length: 9))
        textView.blockSelection = .init(block: block, range: textView.selectedRange())
        XCTAssertEqual(highlightHidden, true, "the block's tint instead")
        press(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(textView.string, "- [ ] one\n- [ ] three\n", "its line goes whole, no empty line left")
        XCTAssertNil(textView.blockSelection)
        XCTAssertEqual(highlightHidden, true, "the editor draws a text selection's highlight itself")
    }

    func testABlockSelectionEndsWithTheSelection() throws {
        load("- [ ] one\n- [ ] two\n")
        let block = try XCTUnwrap(BlockMoving.blocks(in: textView.string).first)
        textView.setSelectedRange(NSRange(location: 0, length: 9))
        textView.blockSelection = .init(block: block, range: textView.selectedRange())
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(textView.blockSelection)
        XCTAssertEqual(highlightHidden, true, "the editor draws a text selection's highlight itself")
        press(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(textView.string.components(separatedBy: "\n").count, 3, "a plain backspace deletes no block")
    }
}

/// Fenced code blocks of a language the host renders are drawn as pictures, with a fake renderer standing in for
/// the host's.
@MainActor
final class EditorPictureTests: XCTestCase {
    private var window: NSWindow!
    private var textView: EditorTextView!
    private var controller: EditorController!
    private var requests: [PictureRequest] = []
    /// The size of the pictures the fake renderer draws; nil draws none (invalid code).
    private var pictureSize: NSSize? = NSSize(width: 300, height: 120)

    private let text = "Intro\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\nAfter"

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        textView = EditorTextView(usingTextLayoutManager: true)
        textView.frame = window.contentView!.bounds
        // As the editor sets it up: `-->` must stay `-->`.
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        window.contentView!.addSubview(textView)
        controller = EditorController()
        // Each test draws on its own, not from what another test left in the shared cache.
        controller.pictures = PictureCache()
        controller.attach(textView)
        controller.pictureRenderers = ["mermaid": { [weak self] request in
            self?.requests.append(request)
            guard let size = self?.pictureSize else { return nil }
            return NSImage(size: size)
        }]
    }

    override func tearDown() async throws {
        window.close()
    }

    /// Shows `text` with the caret at `caret`, and lets the renderer answer.
    private func load(caret: Int) async {
        controller.show(EditorContent(id: 1, text: text, initialState: EditorViewState(caret: caret, scrollY: 0)))
        for _ in 0..<5 { await Task.yield() }
    }

    private var storage: NSTextStorage { textView.textStorage! }
    private var block: NSRange { (text as NSString).range(of: "```mermaid\nflowchart LR\n  A --> B\n```") }
    /// The picture of the block, wherever it ends now.
    private var mark: PictureMark? {
        var found: PictureMark?
        storage.enumerateAttribute(.markdownPicture, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            found = found ?? value as? PictureMark
        }
        return found
    }

    func testOutsideTheBlockThePictureTakesThePlaceOfTheCode() async throws {
        await load(caret: 0)
        XCTAssertEqual(requests.map(\.code), ["flowchart LR\n  A --> B"])
        XCTAssertEqual(requests.first?.language, "mermaid")
        let mark = try XCTUnwrap(storage.attribute(.markdownPicture, at: NSMaxRange(block) - 1, effectiveRange: nil) as? PictureMark)
        XCTAssertEqual(mark.size, NSSize(width: 300, height: 120))
        XCTAssertEqual(mark.caret, block.location + 11, "a click shows the code")
        let font = try XCTUnwrap(storage.attribute(.font, at: block.location + 12, effectiveRange: nil) as? NSFont)
        XCTAssertLessThan(font.pointSize, 1, "the code is hidden")
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: NSMaxRange(block) - 1, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.paragraphSpacing, 120 + 2 * PictureMark.margin, "room for the picture under the block")
        let frame = try XCTUnwrap(textView.pictureFrames().first?.1)
        XCTAssertEqual(frame.size, NSSize(width: 300, height: 120))
    }

    func testTheHiddenCodeTakesNoRoomAboveThePicture() async throws {
        await load(caret: 0)
        let frame = try XCTUnwrap(textView.pictureFrames().first?.1)
        let blank = try XCTUnwrap(textView.lineBox(for: NSRange(location: block.location - 1, length: 1)))
        XCTAssertEqual(frame.minY - blank.maxY, PictureMark.margin, accuracy: 2, "the picture comes right under the blank line")
        // A click between the two is beside the picture, not in its hidden code, which it would show.
        XCTAssertNotNil(textView.pictureLine(beside: NSPoint(x: frame.midX, y: blank.maxY + 1)))
        // The block's handle stands by the top of the picture, not by the hidden fence above it.
        textView.updateBlockHandle(at: NSPoint(x: frame.midX, y: frame.midY))
        // The handle follows the first row, so it sits lower the taller the line.
        XCTAssertEqual(textView.blockHandle.frame.midY, frame.minY + 8, accuracy: 12)
    }

    func testInsideTheBlockTheCodeShowsWithThePictureUnderIt() async throws {
        await load(caret: block.location + 14)
        let mark = try XCTUnwrap(mark)
        XCTAssertNil(mark.caret)
        let font = try XCTUnwrap(storage.attribute(.font, at: block.location + 14, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(font.pointSize, 5, "the code shows")

        // Leaving the block hides the code again, without drawing it again.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNotNil(self.mark?.caret)
        XCTAssertEqual(requests.count, 1)
    }

    func testTypingKeepsTheLastPictureUntilTheNewOneComes() async throws {
        await load(caret: block.location + 14)
        pictureSize = nil
        textView.setSelectedRange(NSRange(location: NSMaxRange(block) - 4, length: 0))
        textView.insertText(" -->", replacementRange: textView.selectedRange())
        XCTAssertNotNil(mark, "the last picture stands in while the code is being typed")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(requests.map(\.code).last, "flowchart LR\n  A --> B -->")
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotNil(mark, "and while it does not draw")

        // Out of the block, code that does not draw stays code.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(mark)
        let font = try XCTUnwrap(storage.attribute(.font, at: block.location + 14, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(font.pointSize, 5)
    }

    func testANoteOpenedAgainShowsItsPicturesWithoutDrawingThemAgain() async throws {
        await load(caret: 0)
        XCTAssertEqual(requests.count, 1)
        // Back to the note: a new editor, sharing the cache of the first.
        let second = EditorController()
        second.pictures = controller.pictures
        let view = EditorTextView(usingTextLayoutManager: true)
        view.frame = textView.frame
        window.contentView!.addSubview(view)
        second.attach(view)
        second.pictureRenderers = controller.pictureRenderers
        second.show(EditorContent(id: 1, text: text, initialState: EditorViewState(caret: 0, scrollY: 0)))
        XCTAssertNotNil(view.textStorage!.attribute(.markdownPicture, at: NSMaxRange(block) - 1, effectiveRange: nil), "shown at once")
        XCTAssertEqual(requests.count, 1, "not drawn again")
    }

    func testAWiderPictureIsScaledToTheColumn() async throws {
        pictureSize = NSSize(width: 4000, height: 400)
        await load(caret: 0)
        let mark = try XCTUnwrap(mark)
        XCTAssertEqual(mark.size.width, textView.columnWidth, accuracy: 0.5)
        XCTAssertEqual(mark.size.height, 400 * textView.columnWidth / 4000, accuracy: 0.5)
    }

    func testOtherLanguagesStayCode() async {
        controller.pictureRenderers = [:]
        await load(caret: 0)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(mark)
    }

    func testTheCacheForgetsTheLeastRecentlyUsedPictures() {
        let cache = PictureCache(limit: 2)
        let colors = PictureColors(text: "", secondaryText: "", accent: "", background: "", codeBackground: "", separator: "")
        let requests = (0..<3).map { PictureRequest(language: "m", code: "\($0)", isDark: false, colors: colors, fontFamily: "", fontSize: 15) }
        cache.store(NSImage(), for: requests[0])
        cache.store(NSImage(), for: requests[1])
        XCTAssertNotNil(cache.image(for: requests[0]))
        cache.store(NSImage(), for: requests[2])
        XCTAssertNil(cache.image(for: requests[1]))
        XCTAssertNotNil(cache.image(for: requests[0]))
        cache.store(nil, for: requests[1])
        XCTAssertFalse(cache.needs(requests[1]), "a failure is not drawn again")
    }
}

/// A new theme restyles the open text at once: colours, fonts and the column.
@MainActor
final class EditorThemeTests: XCTestCase {
    func testChangingTheThemeRestylesTheText() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.frame = scrollView.bounds
        scrollView.documentView = textView
        window.contentView!.addSubview(scrollView)
        let controller = EditorController()
        controller.attach(textView)
        controller.show(EditorContent(id: 1, text: "# Title\n\nBody `code`"))
        XCTAssertEqual(textView.textStorage!.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor, MarkdownTheme.pageTextColor)

        var theme = MarkdownTheme()
        theme.textColor = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        theme.backgroundColor = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.8, alpha: 1)
        theme.codeBackgroundColor = NSColor(srgbRed: 0.8, green: 0.8, blue: 0.7, alpha: 1)
        theme.bodyFamily = .system(.serif)
        theme.columnWidth = 400
        controller.theme = theme

        let storage = textView.textStorage!
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor, theme.textColor)
        XCTAssertEqual(textView.theme.codeBackgroundColor, theme.codeBackgroundColor, "drawn behind the code")
        XCTAssertNotNil(storage.attribute(.markdownInlineCode, at: 16, effectiveRange: nil))
        let body = try XCTUnwrap(storage.attribute(.font, at: 10, effectiveRange: nil) as? NSFont)
        XCTAssertNotEqual(body.fontName, NSFont.systemFont(ofSize: 16).fontName, "the serif design")
        XCTAssertEqual(scrollView.backgroundColor, theme.backgroundColor)
        XCTAssertEqual(textView.textContainerInset.width, floor((textView.frame.width - 400) / 2))
    }

}

/// The editor in a scroll view, as the app shows it.
@MainActor
final class EditorScrollingTests: XCTestCase {
    func testTypingAtTheBottomKeepsTheCaretWellAboveThePageEdge() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.frame = scrollView.bounds
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        window.contentView!.addSubview(scrollView)
        let controller = EditorController()
        controller.attach(textView)
        let text = (1...40).map { "Line \($0)" }.joined(separator: "\n")
        controller.show(EditorContent(id: 1, text: text))
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        for _ in 0..<3 {
            textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            textView.insertText("more", replacementRange: textView.selectedRange())
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let screen = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let caret = textView.convert(window.convertFromScreen(screen), from: nil)
        let visible = scrollView.contentView.documentVisibleRect
        XCTAssertGreaterThan(caret.minY, visible.minY)
        XCTAssertLessThan(caret.maxY, visible.maxY - 60, "the caret stays clear of the bottom edge")
        window.close()
    }
}

@MainActor
final class TitleHeadingTests: XCTestCase {
    func testAFirstHeadingSayingTheTitleIsFoundWithTheBlankLineAfterIt() {
        XCTAssertEqual(EditorController.titleHeading(in: "# My Note\n\nBody", title: "my note"), NSRange(location: 0, length: 11))
        XCTAssertEqual(EditorController.titleHeading(in: "---\ntags: [a]\n---\n# Note\nBody", title: "Note"), NSRange(location: 18, length: 7))
        XCTAssertEqual(EditorController.titleHeading(in: "---\ntags: [a]\n---\n\n# Note\n\nBody", title: "Note"), NSRange(location: 18, length: 9), "blank lines after the frontmatter go with it")
        XCTAssertNil(EditorController.titleHeading(in: "# Other\n\nBody", title: "Note"))
        XCTAssertNil(EditorController.titleHeading(in: "Intro\n# Note", title: "Note"))
        XCTAssertNil(EditorController.titleHeading(in: "# Note", title: nil))
    }
}
