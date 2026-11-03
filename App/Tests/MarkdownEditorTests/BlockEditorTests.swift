import AppKit
import SwiftUI
import XCTest
@testable import MarkdownEditor

/// The block editor in the real text view, offscreen: the page holds only what it shows, and the note is written
/// back as Markdown, untouched where nothing was edited (docs/design/BLOCK-EDITOR.md).
@MainActor
final class BlockEditorTests: XCTestCase {
    private var window: NSWindow!
    private var textView: EditorTextView!
    private var controller: EditorController!
    /// What the editor last sent to be saved.
    private var saved: String?

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        textView = EditorTextView(usingTextLayoutManager: true)
        textView.frame = window.contentView!.bounds
        textView.isRichText = false
        textView.allowsUndo = true
        window.contentView!.addSubview(textView)
        controller = EditorController()
        controller.attach(textView)
        controller.useBlocks(in: textView)
        controller.onChange = { [weak self] text in self?.saved = text }
        window.makeFirstResponder(textView)
    }

    override func tearDown() async throws {
        window.close()
        BlockStorage.componentLanguages = []
    }

    private func load(_ markdown: String, title: String? = nil, caret: Int = 0) {
        textView.pageTitle = title
        controller.show(EditorContent(id: Int.random(in: 1...Int.max), text: markdown))
        textView.setSelectedRange(NSRange(location: caret, length: 0))
    }

    private func type(_ text: String) {
        for character in text { textView.insertText(String(character), replacementRange: textView.selectedRange()) }
    }

    private func press(_ selector: Selector) { textView.doCommand(by: selector) }

    private var markdown: String { controller.blockSession!.currentMarkdown() }

    func testALineOfOnlyANoteLinkKeepsATextLinesHeight() throws {
        load("- [[Meetings/Point/Summary|Point]]\n- [[Call]]\n\n[[Alone]]")
        let storage = try XCTUnwrap(textView.textStorage)
        var starts: [Int] = []
        (storage.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: storage.length), options: .byParagraphs) { _, range, _, _ in
            if range.length > 0 { starts.append(range.location) }
        }
        XCTAssertEqual(starts.count, 3)
        for at in starts {
            let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertGreaterThan(style.minimumLineHeight, 10, "its characters are near-empty: the line must not collapse onto the next")
        }
    }

    func testThePageHoldsNoSyntaxAndNoFrontmatter() {
        load("---\nstatus: To do\ntags: [a]\n---\n\n# Audit\n\nSome **bold**, a [link](x).\n\n- [ ] task\n> quote\n", title: "Audit")
        XCTAssertEqual(textView.string, "Some bold, a link.\ntask\nquote\n")
    }

    func testTypingAtTheVeryStartNeverTouchesTheFrontmatter() {
        load("---\nstatus: To do\n---\n\n# Audit\n\nText\n", title: "Audit", caret: 0)
        type("X")
        XCTAssertEqual(saved, "---\nstatus: To do\n---\n\n# Audit\n\nXText\n")
    }

    func testOpeningAndSavingChangesNothing() {
        let note = "---\nstatus: To do\n---\n\n# Audit\n\nSome   *odd*   spacing\n\n\n- a\n* b\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        load(note, title: "Audit")
        XCTAssertEqual(markdown, note)
    }

    func testReturnInAListStartsAnItemAndUndoTakesItBack() {
        load("- one\n", caret: 3)
        press(#selector(NSResponder.insertNewline(_:)))
        type("two")
        XCTAssertEqual(markdown, "- one\n- two\n")
        XCTAssertEqual(textView.string, "one\ntwo\n")
        controller.undo.undo()
        XCTAssertEqual(markdown, "- one\n")
    }

    func testAShortcutTypedAtTheStartMakesTheBlock() {
        load("Intro\n", caret: 5)
        press(#selector(NSResponder.insertNewline(_:)))
        type("# Heading")
        XCTAssertEqual(markdown, "Intro\n\n# Heading\n")
        XCTAssertEqual(textView.string, "Intro\nHeading\n")
    }

    func testBoldTypedWithAsterisksIsBoldAndTheAsterisksGo() {
        load("", caret: 0)
        type("a **b** c")
        XCTAssertEqual(textView.string, "a b c\n")
        XCTAssertEqual(markdown, "a **b** c\n")
    }

    func testBackspaceAtTheStartOfAHeadingMakesItText() {
        load("Intro\n\n## Title\n", caret: 6)
        press(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(markdown, "Intro\n\nTitle\n")
    }

    func testAClickOnATaskBoxChecksIt() {
        load("- [ ] todo\n")
        textView.onToggleBlockTask?(NSRange(location: 0, length: 5))
        XCTAssertEqual(markdown, "- [x] todo\n")
    }

    func testSelectAllThenDeleteKeepsTheFrontmatter() {
        load("---\na: b\n---\n\nText\n\n- item\n")
        textView.selectAll(nil)
        press(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(markdown, "---\na: b\n---\n")
    }

    func testAChangeFromOutsideToTheFrontmatterKeepsThePageAndTheCaret() {
        load("---\nstatus: To do\n---\n\nText here\n", caret: 4)
        controller.show(EditorContent(id: 999, text: "---\nstatus: Done\n---\n\nText here\n", keepsSelection: true))
        XCTAssertEqual(textView.selectedRange().location, 4)
        type("!")
        XCTAssertEqual(markdown, "---\nstatus: Done\n---\n\nText! here\n")
    }

    func testCopyingBlocksGivesTheirMarkdown() {
        load("# Title\n\n- [ ] task\n\nText\n")
        textView.selectAll(nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loam.test.block-copy"))
        let types = textView.writablePasteboardTypes
        pasteboard.declareTypes(types, owner: nil)
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: types))
        XCTAssertEqual(pasteboard.string(forType: .string), "# Title\n\n- [ ] task\n\nText\n")
    }

    func testInsertingMarkdownAtTheCaretMakesBlocks() {
        load("Text\n", caret: 4)
        controller.insertAtCaret("## Summary\n\n- point\n")
        XCTAssertEqual(markdown, "Text\n\n## Summary\n\n- point\n")
    }

    func testAPictureShowsInItsBlockAndItsWidthGoesIntoItsLink() async {
        controller.embeds = EmbedProvider(
            id: "test",
            identify: { link in link.destination.hasPrefix("assets/") ? link.destination : nil },
            render: { _ in Embed(content: .image(NSImage(size: NSSize(width: 400, height: 200))), size: NSSize(width: 400, height: 200)) }
        )
        load("Text\n\n![Sea](assets/sea.png)\n\nAfter\n")
        for _ in 0..<10 { await Task.yield() }
        let storage = textView.textStorage!
        var marks: [PictureMark] = []
        storage.enumerateAttribute(.markdownPicture, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let mark = value as? PictureMark { marks.append(mark) }
        }
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.destination, "assets/sea.png")
        XCTAssertNil(storage.attribute(.blockPlaceholder, at: 5, effectiveRange: nil), "the picture, not a card")
        controller.finishResizingPicture(line: 5, width: 300)
        XCTAssertEqual(markdown, "Text\n\n![Sea|300](assets/sea.png)\n\nAfter\n")
    }

    func testASelectedAddressBecomesALinkAndCmdBMakesBold() {
        load("Visit https://craft.do today\n")
        textView.setSelectedRange(NSRange(location: 6, length: 16))
        XCTAssertTrue(controller.perform(.link))
        XCTAssertEqual(markdown, "Visit <https://craft.do> today\n")
        textView.setSelectedRange(NSRange(location: 23, length: 5))
        XCTAssertTrue(controller.perform(.toggle(.bold)))
        XCTAssertEqual(markdown, "Visit <https://craft.do> **today**\n")
        XCTAssertTrue(controller.perform(.toggle(.bold)))
        XCTAssertEqual(markdown, "Visit <https://craft.do> today\n")
    }

    func testCmdBAboveATableMakesBoldAndKeepsTheSelection() throws {
        load("Inline `code span` in text and plain words.\n\n| A | B |\n|---|---|\n| one | two |\n")
        let words = (textView.string as NSString).range(of: "words")
        textView.setSelectedRange(words)
        // Cmd-B as the keyboard sends it, or a click on the format bar: an event is the current one while it formats.
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b",
            isARepeat: false, keyCode: 11
        ))
        NSApp.postEvent(key, atStart: true)
        XCTAssertNotNil(NSApp.nextEvent(matching: .keyDown, until: .distantFuture, inMode: .default, dequeue: true))
        XCTAssertEqual(NSApp.currentEvent?.type, .keyDown)
        XCTAssertTrue(controller.perform(.toggle(.bold)))
        // The table would take the keyboard on the next turn of the run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(markdown, "Inline `code span` in text and plain **words**.\n\n| A | B |\n|---|---|\n| one | two |\n")
        XCTAssertEqual(textView.selectedRange(), words)
        XCTAssertTrue(window.firstResponder === textView, "the caret stays on the text, not in the table")
        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: words.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testBoldAndItalicShowInAFamilyWithoutTheirCuts() throws {
        // Zapfino has one cut, as Gerstner Programm (the Dither themes') has no bold and no italic.
        var theme = MarkdownTheme()
        theme.bodyFamily = .named("Zapfino")
        controller.theme = theme
        load("Plain and **strong** and *slanted* and ***both*** text\n")
        let storage = try XCTUnwrap(textView.textStorage)
        let strong = (storage.string as NSString).range(of: "strong")
        let stroke = try XCTUnwrap(storage.attribute(.strokeWidth, at: strong.location, effectiveRange: nil) as? CGFloat)
        XCTAssertLessThan(stroke, 0, "a filled stroke thickens the letters")
        let slanted = (storage.string as NSString).range(of: "slanted")
        let slant = try XCTUnwrap(storage.attribute(.font, at: slanted.location, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(slant.textTransform.m21, 0, "no italic cut: the letters lean")
        let both = (storage.string as NSString).range(of: "both")
        XCTAssertNotNil(storage.attribute(.strokeWidth, at: both.location, effectiveRange: nil), "bold and italic: thickened")
        XCTAssertGreaterThan((storage.attribute(.font, at: both.location, effectiveRange: nil) as? NSFont)?.textTransform.m21 ?? 0, 0, "and slanted")
        XCTAssertNil(storage.attribute(.strokeWidth, at: 0, effectiveRange: nil), "the plain text stays as it is")
        XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.textTransform.m21, 0)
        // Bold off again: the letters thin back.
        textView.setSelectedRange(strong)
        XCTAssertTrue(controller.perform(.toggle(.bold)))
        XCTAssertNil(storage.attribute(.strokeWidth, at: strong.location, effectiveRange: nil))
    }

    func testCmdBOnAWholeLineAboveATableKeepsTheCaretOnTheText() throws {
        load("Inline `code span` in text and **bold** words.\n\n| A | B |\n|---|---|\n| one | two |\n")
        // A triple click: the paragraph with its line break.
        let line = (textView.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        textView.setSelectedRange(line)
        XCTAssertTrue(controller.perform(.toggle(.bold)))
        XCTAssertEqual(markdown, "**Inline `code span` in text and bold words.**\n\n| A | B |\n|---|---|\n| one | two |\n")
        XCTAssertTrue(window.firstResponder === textView, "the caret stays on the text, not in the table")
        XCTAssertEqual(textView.selectedRange(), line)
        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testASlashEntryTurnsTheBlockIntoItsKind() {
        load("Text\n", caret: 4)
        type(" /")
        let item = SlashMenu.standardItems.first { $0.id == "heading2" }!
        controller.blockSession!.run(item, replacing: NSRange(location: 5, length: 1))
        XCTAssertEqual(markdown, "## Text\n")
        XCTAssertEqual(textView.string, "Text \n")
    }

    func testATableIsItsComponentAndItsCellsWriteTheBlock() {
        load("Intro\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nAfter\n")
        XCTAssertEqual(textView.string, "Intro\n\u{FFFC}\nAfter\n")
        XCTAssertEqual(controller.tableBlocks.count, 1)
        let view = controller.tableBlocks[0].view
        var data = view.data
        data.rows[1][1] = "two"
        controller.tableView(view, edited: data, action: "Typing", coalescing: true)
        XCTAssertEqual(markdown, "Intro\n\n| a | b |\n| --- | --- |\n| 1 | two |\n\nAfter\n")
        controller.undo.undo()
        XCTAssertEqual(markdown, "Intro\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nAfter\n")
        controller.tableViewDelete(controller.tableBlocks[0].view)
        XCTAssertEqual(markdown, "Intro\n\nAfter\n")
    }

    func testADiagramIsItsPictureAndItsCodeIsEditedOnTheCodePage() async {
        controller.pictureRenderers = ["mermaid": { request in
            request.code.contains("fails") ? nil : NSImage(size: NSSize(width: 300, height: 100))
        }]
        load("Text\n\n```mermaid\ngraph TD\n```\n")
        XCTAssertEqual(textView.string, "Text\n\u{FFFC}\n", "the code is not in the page")
        for _ in 0..<20 { await Task.yield() }
        let storage = textView.textStorage!
        XCTAssertNotNil(storage.attribute(.markdownPicture, at: 5, effectiveRange: nil) as? PictureMark)
        let editing = controller.codeEditing(at: 5)
        XCTAssertEqual(editing?.code, "graph TD")
        editing?.commit("graph LR\nA --> B")
        XCTAssertEqual(markdown, "Text\n\n```mermaid\ngraph LR\nA --> B\n```\n")
        controller.undo.undo()
        XCTAssertEqual(markdown, "Text\n\n```mermaid\ngraph TD\n```\n")
    }

    func testACollectionIsItsLiveViewAndItsEditsWriteTheBlock() {
        controller.liveBlockProviders = ["base": { _ in AnyView(EmptyView()) }]
        load("```base\nviews: []\n```\n")
        XCTAssertEqual(textView.string, "\u{FFFC}\n")
        XCTAssertEqual(controller.liveBlocks.count, 1)
        XCTAssertEqual(controller.liveBlocks.first?.handle.code, "views: []")
        controller.liveBlocks[0].handle.replaceCode("views:\n  - type: table")
        XCTAssertEqual(markdown, "```base\nviews:\n  - type: table\n```\n")
    }

    func testAPluginAddedAfterTheNoteOpensTurnsItsBlocksIntoComponents() {
        load("```mermaid\ngraph TD\n```\n")
        XCTAssertEqual(textView.string, "graph TD\n", "code while no plugin draws it")
        controller.pictureRenderers = ["mermaid": { _ in nil }]
        XCTAssertEqual(textView.string, "\u{FFFC}\n")
        XCTAssertEqual(markdown, "```mermaid\ngraph TD\n```\n")
    }

    func testABlockSelectedByItsHandleGoesWholeAndKeysMoveBlocks() {
        load("- a\n  - a1\n- b\n\nText\n")
        let block = PageBlocks.blocks(in: textView.textStorage!)[0]
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        textView.blockSelection = EditorTextView.BlockSelection(block: block, range: textView.selectedRange())
        press(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(markdown, "- b\n\nText\n")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(controller.textView?.onMoveBlockByKey?(true) ?? false)
        XCTAssertEqual(markdown, "Text\n\n- b\n")
    }

    func testAHeadingFoldsWhatFollowsIt() {
        load("# A\n\nText\n\n# B\n")
        XCTAssertEqual(controller.foldSections.count, 1)
        controller.toggleFold(controller.foldSections[0])
        XCTAssertEqual(textView.foldedBodies, [NSRange(location: 2, length: 5)])
        XCTAssertEqual(markdown, "# A\n\nText\n\n# B\n", "folding changes nothing in the note")
    }

    func testPastedMarkdownBecomesBlocksAroundTheCaret() {
        load("Start end\n", caret: 6)
        controller.blockSession!.paste("one\n\n## Title\n\n- item\n\ntwo ")
        XCTAssertEqual(markdown, "Start one\n\n## Title\n\n- item\n\ntwo end\n")
        XCTAssertEqual(textView.string, "Start one\nTitle\nitem\ntwo end\n")
        XCTAssertEqual(textView.selectedRange().location, 25, "after what was pasted")
    }

    func testPastedTextInsideABlockKeepsItsMarksAndAnAddressLinksTheSelection() {
        load("Hello world\n", caret: 6)
        controller.blockSession!.paste("**big** ")
        XCTAssertEqual(markdown, "Hello **big** world\n")
        textView.setSelectedRange(NSRange(location: 10, length: 5))
        controller.blockSession!.paste("https://craft.do")
        XCTAssertEqual(markdown, "Hello **big** [world](https://craft.do)\n")
    }

    func testCodePastedInACodeBlockStaysCode() {
        load("```\nlet a = 1\n```\n", caret: 9)
        controller.blockSession!.paste("\nlet *b* = 2")
        XCTAssertEqual(markdown, "```\nlet a = 1\nlet *b* = 2\n```\n")
    }

    func testViewSourceShowsTheWholeFileAndBackToThePage() {
        load("---\na: b\n---\n\n# Title\n\nSome **bold**\n")
        controller.syntaxMode = .source
        XCTAssertEqual(textView.string, "---\na: b\n---\n\n# Title\n\nSome **bold**\n")
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count - 1, length: 0))
        type(" more")
        controller.syntaxMode = .rendered
        XCTAssertEqual(textView.string, "Title\nSome bold more\n")
        XCTAssertEqual(markdown, "---\na: b\n---\n\n# Title\n\nSome **bold** more\n")
    }

    func testAnAgentsChangeReplacesOnlyItsBlocksAndTheCaretStays() {
        load("One\n\nTwo\n\nThree\n", caret: 9)
        controller.show(EditorContent(id: 4242, text: "One\n\nTwo, edited by an agent\n\nThree\n", keepsSelection: true))
        XCTAssertEqual(textView.string, "One\nTwo, edited by an agent\nThree\n")
        XCTAssertEqual(textView.selectedRange().location, 29, "still in Three, after the longer block above")
        type("!")
        XCTAssertEqual(markdown, "One\n\nTwo, edited by an agent\n\nT!hree\n")
    }

    /// Typing in a long note stays quick: one keystroke styles its paragraph and writes the note.
    func testTypingInALongNoteIsQuick() {
        let paragraph = "A paragraph with **bold**, a [link](https://x.y) and some words to make it long enough.\n\n- item\n- [ ] task\n\n"
        load(String(repeating: paragraph, count: 500), caret: 10)
        let start = Date()
        type("abcdefghij")
        let perKey = Date().timeIntervalSince(start) / 10
        // 2,000 blocks: one paragraph read, styled and written again per key (about 13 ms alone, more while other tests run).
        XCTAssertLessThan(perKey, 0.05, "\(Int(perKey * 1000)) ms per key")
    }

    func testInsertPanelTilesMakeTheirBlocksAndALinkOpensItsField() {
        load("Text\n", caret: 4)
        press(#selector(NSResponder.insertNewline(_:)))
        let item = { (id: String) in SlashMenu.standardItems.first { $0.id == id }! }
        XCTAssertTrue(controller.insert(item("bullets")))
        type("point")
        XCTAssertEqual(markdown, "Text\n\n- point\n")
        XCTAssertTrue(controller.insert(item("link")))
        XCTAssertNotNil(controller.linkEditorPanel, "the address is typed in the link field")
        XCTAssertEqual(markdown, "Text\n\n- point[link](https://)\n")
    }

    func testTheOutlineFindsHeadingsByTheirLineInTheFile() {
        load("---\na: b\n---\n\n# Note\n\nIntro\n\n## Part\n", title: "Note")
        let offsets = controller.blockSession!.offsets(ofLines: [9])
        XCTAssertEqual(offsets, [6], "line 9 is `## Part`, the second paragraph of the page")
    }
}
