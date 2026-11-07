import AppKit
import XCTest
@testable import MarkdownEditor

/// Image links alone on their line, shown as the host's embeds, with a fake host standing in for the plugins'.
@MainActor
final class EditorEmbedTests: XCTestCase {
    private var window: NSWindow!
    private var textView: EditorTextView!
    private var controller: EditorController!
    private var rendered: [EmbedLink] = []
    /// What the fake host shows: a picture of this size, a view, or nothing.
    private var content: (NSSize, Bool)? = (NSSize(width: 300, height: 200), false)

    private let text = "Intro\n![A bridge](assets/a.png)\nAfter"
    private var line: NSRange { (text as NSString).range(of: "![A bridge](assets/a.png)") }

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
        controller.embeds = EmbedProvider(
            id: "test",
            identify: { link in link.destination.hasPrefix("assets/") ? link.destination : nil },
            render: { [weak self] link in
                self?.rendered.append(link)
                guard let (size, isView) = self?.content else { return nil }
                if isView { return Embed(content: .view { NSView() }, size: size, isInteractive: true) }
                return Embed(content: .image(NSImage(size: size)), size: size)
            }
        )
        window.makeFirstResponder(textView)
    }

    override func tearDown() async throws {
        window.close()
    }

    private var loads = 0

    private func load(_ text: String? = nil, caret: Int) async {
        loads += 1
        controller.show(EditorContent(id: loads, text: text ?? self.text, initialState: EditorViewState(caret: caret, scrollY: 0)))
        await settle()
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private var storage: NSTextStorage { textView.textStorage! }
    private var marks: [PictureMark] {
        var found: [PictureMark] = []
        storage.enumerateAttribute(.markdownPicture, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let mark = value as? PictureMark { found.append(mark) }
        }
        return found
    }

    func testOutsideTheLineTheEmbedTakesThePlaceOfTheLink() async throws {
        await load(caret: 0)
        XCTAssertEqual(rendered, [EmbedLink(destination: "assets/a.png", alt: "A bridge")])
        let mark = try XCTUnwrap(storage.attribute(.markdownPicture, at: NSMaxRange(line) - 1, effectiveRange: nil) as? PictureMark)
        XCTAssertEqual(mark.size, NSSize(width: 300, height: 200))
        XCTAssertEqual(mark.caret, NSMaxRange(line), "a click puts the caret at the end of the link")
        XCTAssertEqual(mark.destination, "assets/a.png", "a double click opens it")
        XCTAssertEqual(mark.caption, "A bridge")
        let font = try XCTUnwrap(storage.attribute(.font, at: line.location + 3, effectiveRange: nil) as? NSFont)
        XCTAssertLessThan(font.pointSize, 1, "the link is hidden")
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.paragraphSpacing, 200 + 2 * PictureMark.margin, "room for the picture under the line")
        XCTAssertEqual(textView.pictureFrames().first?.1.size, NSSize(width: 300, height: 200))
    }

    func testTheCaretOnTheLineNeverShowsTheLinkButViewSourceDoes() async throws {
        for caret in [line.location, line.location + 4, NSMaxRange(line)] {
            await load(caret: caret)
            XCTAssertNotNil(try XCTUnwrap(marks.first).caret, "caret at \(caret)")
            let font = try XCTUnwrap(storage.attribute(.font, at: line.location + 3, effectiveRange: nil) as? NSFont)
            XCTAssertLessThan(font.pointSize, 1, "the link stays hidden with the caret at \(caret)")
        }
        controller.syntaxMode = .source
        XCTAssertNil(marks.first?.caret)
        let font = try XCTUnwrap(storage.attribute(.font, at: line.location + 3, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(font.pointSize, 5, "View Source shows the link")
        controller.syntaxMode = .rendered
        XCTAssertNotNil(marks.first?.caret)
        XCTAssertEqual(rendered.count, 1, "without asking the host again")
    }

    func testLinksTheHostDoesNotShowOrCannotShowStayText() async throws {
        await load("Intro\n![](https://example.com/a.png)\n", caret: 0)
        XCTAssertTrue(rendered.isEmpty)
        XCTAssertTrue(marks.isEmpty)
        content = nil
        await load(caret: 0)
        XCTAssertEqual(rendered.count, 1)
        XCTAssertTrue(marks.isEmpty)
        let font = try XCTUnwrap(storage.attribute(.font, at: line.location + 3, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(font.pointSize, 5)
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertEqual(rendered.count, 1, "a link that cannot be shown is not asked for again")
    }

    func testAWidePictureIsScaledToTheColumnAndATallOneCapped() async throws {
        content = (NSSize(width: 4000, height: 2000), false)
        await load(caret: 0)
        let wide = try XCTUnwrap(marks.first)
        XCTAssertEqual(wide.size.width, textView.columnWidth, accuracy: 1)
        XCTAssertEqual(wide.size.height, 2000 * textView.columnWidth / 4000, accuracy: 1)
        XCTAssertEqual(Embed(content: .image(NSImage()), size: NSSize(width: 400, height: 2000)).displaySize(in: 700),
                       NSSize(width: 112, height: 560))
        XCTAssertEqual(Embed(content: .image(NSImage()), size: NSSize(width: 10_000, height: 96), keepsHeight: true).displaySize(in: 700),
                       NSSize(width: 700, height: 96))
    }

    func testAWrittenWidthSizesThePictureAndIsNotTheCaption() async throws {
        let text = "Intro\n![A bridge|150](assets/a.png)\nAfter"
        await load(text, caret: 0)
        XCTAssertEqual(rendered, [EmbedLink(destination: "assets/a.png", alt: "A bridge")], "the host sees the caption only")
        let mark = try XCTUnwrap(marks.first)
        XCTAssertEqual(mark.size, NSSize(width: 150, height: 100))
        XCTAssertEqual(mark.caption, "A bridge")
        XCTAssertNotNil(mark.resizableLine)
    }

    func testDraggingAHandleResizesTheSelectedPictureAndWritesTheWidthOnce() async throws {
        await load(caret: line.location)
        let mark = try XCTUnwrap(marks.first)
        let line = try XCTUnwrap(mark.resizableLine)
        controller.resizePicture(line: line, to: 120)
        XCTAssertEqual(marks.first?.size, NSSize(width: 120, height: 80))
        XCTAssertEqual(textView.string, text, "the note is untouched while dragging")

        controller.finishResizingPicture(line: line, width: 120)
        XCTAssertEqual(textView.string, "Intro\n![A bridge|120](assets/a.png)\nAfter")
        XCTAssertEqual(marks.first?.size, NSSize(width: 120, height: 80))
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, text, "one undo puts the size back")
    }

    func testThePictureWithTheCaretOnItsLineIsSelectedAndShowsItsHandles() async throws {
        await load(caret: 0)
        XCTAssertNil(textView.selectedResizablePicture(), "no handles while the caret is elsewhere")
        textView.setSelectedRange(NSRange(location: NSMaxRange(line), length: 0))
        XCTAssertEqual(marks.first?.isSelected, true, "a click on a picture puts the caret at its line's end")
        XCTAssertNotNil(textView.selectedResizablePicture())
    }

    private func click(_ point: NSPoint) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: textView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        textView.mouseDown(with: event)
    }

    func testAClickOnAPictureEndingTheNoteSelectsIt() async throws {
        // Its line has no break after it, where the syntax a picture reveals reaches: the restyle asked for a paragraph
        // past the text's end, an exception in the middle of the click.
        let text = "Intro\n![A bridge](assets/a.png)"
        await load(text, caret: 0)
        let frame = try XCTUnwrap(textView.pictureFrames().first?.1)
        try click(NSPoint(x: frame.midX, y: frame.midY))
        await settle()
        XCTAssertEqual(textView.selectedRange(), NSRange(location: (text as NSString).length, length: 0))
        XCTAssertNotNil(textView.selectedResizablePicture(), "selected, with its handles")
    }

    func testAClickBesideAPictureGoesToTheLineUnderIt() async throws {
        await load(caret: NSMaxRange(line))
        XCTAssertNotNil(textView.selectedResizablePicture())
        let frame = try XCTUnwrap(textView.pictureFrames().first?.1)
        XCTAssertNil(textView.pictureLine(beside: NSPoint(x: frame.midX, y: frame.midY)), "on the picture itself")
        try click(NSPoint(x: frame.maxX + 40, y: frame.midY))
        await settle()
        XCTAssertEqual(textView.selectedRange(), NSRange(location: (text as NSString).range(of: "After").location, length: 0))
        XCTAssertEqual(textView.string, text)
        XCTAssertNil(textView.selectedResizablePicture(), "the picture is let go")
    }

    func testAClickUnderAPictureThatEndsTheNoteGivesALineToWriteOn() async throws {
        let text = "Intro\n![A bridge](assets/a.png)"
        await load(text, caret: 0)
        let frame = try XCTUnwrap(textView.pictureFrames().first?.1)
        try click(NSPoint(x: frame.midX, y: frame.maxY + 80))
        await settle()
        XCTAssertEqual(textView.string, text + "\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: (text as NSString).length + 1, length: 0))
        XCTAssertNil(textView.selectedResizablePicture())
    }

    func testABlocksBoxTakesThePictureDrawnUnderIt() async throws {
        await load(caret: 0)
        let frame = try XCTUnwrap(textView.pictureFrames().first?.1)
        let box = try XCTUnwrap(textView.blockBox(for: line))
        XCTAssertGreaterThanOrEqual(box.maxY, frame.maxY, "a drop line goes past the picture, not through it")
        XCTAssertLessThan(try XCTUnwrap(textView.lineBox(for: line)).maxY, frame.maxY)
    }

    func testACancelledDragLeavesTheNoteAlone() async throws {
        await load(caret: line.location)
        let line = try XCTUnwrap(marks.first?.resizableLine)
        controller.resizePicture(line: line, to: 100)
        controller.finishResizingPicture(line: line, width: nil)
        XCTAssertEqual(textView.string, text)
        XCTAssertEqual(marks.first?.size, NSSize(width: 300, height: 200))
    }

    func testOnlyPicturesCanBeResized() async throws {
        content = (NSSize(width: 640, height: 360), true)
        await load(caret: line.location)
        XCTAssertNil(marks.first?.resizableLine, "a player keeps its controls")
    }

    func testAViewEmbedIsHostedAndKeptWhileItsLineStays() async throws {
        content = (NSSize(width: 640, height: 360), true)
        await load(caret: 0)
        XCTAssertEqual(textView.embedViews.count, 1)
        let view = try XCTUnwrap(textView.embedViews.values.first)
        XCTAssertTrue(view.superview === textView)

        // Typing elsewhere keeps the very same view (a playing video keeps playing).
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText(" more", replacementRange: textView.selectedRange())
        await settle()
        XCTAssertTrue(textView.embedViews.values.first === view)

        // Deleting the line takes the view away.
        let shown = (textView.string as NSString).range(of: "![A bridge](assets/a.png)\n")
        textView.setSelectedRange(shown)
        textView.insertText("", replacementRange: shown)
        await settle()
        XCTAssertTrue(textView.embedViews.isEmpty)
        XCTAssertNil(view.superview)
    }

    func testARestoredScrollPositionIsReachedOnceTheEmbedsAreIn() async throws {
        // As the app hosts it: the text view in a scroll view, the window shorter than the note.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let scrolled = EditorTextView(usingTextLayoutManager: true)
        scrolled.isVerticallyResizable = true
        scrolled.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrolled.autoresizingMask = [.width]
        scrolled.textContainer?.widthTracksTextView = true
        scrollView.documentView = scrolled
        window.contentView!.addSubview(scrollView)
        let editor = EditorController()
        editor.attach(scrolled)
        editor.embeds = controller.embeds
        let text = (1...8).map { "Line \($0)\n![](assets/\($0).png)" }.joined(separator: "\n")
        editor.show(EditorContent(id: 1, text: text, initialState: EditorViewState(caret: 0, scrollY: 1200)))
        for _ in 0..<40 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertGreaterThan(scrolled.frame.height, 1600, "the page has the embeds' height")
        XCTAssertEqual(scrollView.contentView.bounds.minY, 1200, accuracy: 1, "where the tab was")
    }

    func testANonInteractiveViewLetsClicksThroughToTheText() {
        let host = EmbedHostView(NSView(), isInteractive: false, cornerRadius: 6)
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(host.hitTest(NSPoint(x: 10, y: 10)))
        let player = EmbedHostView(NSView(), isInteractive: true, cornerRadius: 6)
        player.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNotNil(player.hitTest(NSPoint(x: 10, y: 10)))
    }

    // MARK: Drops and pastes

    func testDroppedFilesGoOnLinesOfTheirOwnWhenTheHostAnswers() async throws {
        var received: [[DroppedFile]] = []
        controller.onDropFiles = { files in
            received.append(files)
            return "![](assets/b.png)\n![](assets/c.png)"
        }
        await load("Hello world", caret: 0)
        XCTAssertNotNil(textView.fileDropHandler)
        XCTAssertTrue(textView.acceptableDragTypes.contains(.fileURL))
        let file = URL(fileURLWithPath: "/tmp/b.png")
        textView.fileDropHandler?([.file(file)], 5)
        await settle()
        XCTAssertEqual(received, [[.file(file)]])
        XCTAssertEqual(textView.string, "Hello\n![](assets/b.png)\n![](assets/c.png)\n world")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "Hello world", "undone as typing is")
    }

    func testDroppedFilesOverATableGoAfterIt() async throws {
        controller.onDropFiles = { _ in "![](assets/b.png)" }
        let table = "Intro\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\nEnd"
        await load(table, caret: 0)
        let inCell = (table as NSString).range(of: "| 1").location + 3
        textView.fileDropHandler?([.file(URL(fileURLWithPath: "/tmp/b.png"))], inCell)
        await settle()
        XCTAssertEqual(textView.string, "Intro\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n![](assets/b.png)\n\nEnd")
    }

    func testWithoutAHostTheEditorTakesNoFiles() async {
        await load("Hello", caret: 0)
        XCTAssertNil(textView.fileDropHandler)
        XCTAssertEqual(textView.acceptableDragTypes, [.string])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loam.tests.\(UUID().uuidString)"))
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.png") as NSURL])
        XCTAssertFalse(textView.pasteFiles(from: pasteboard))
        pasteboard.releaseGlobally()
    }

    func testTypingWhileFilesAreImportedMovesWhereTheyGo() async throws {
        var finish: CheckedContinuation<Void, Never>?
        controller.onDropFiles = { _ in
            await withCheckedContinuation { finish = $0 }
            return "![](assets/b.png)"
        }
        await load("One\nTwo", caret: 0)
        controller.dropFiles([.file(URL(fileURLWithPath: "/tmp/b.png"))], at: 4)
        await settle()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("Zero ", replacementRange: textView.selectedRange())
        finish?.resume()
        await settle()
        XCTAssertEqual(textView.string, "Zero One\n![](assets/b.png)\nTwo")
    }

    func testAClosedEditorStillHandsTheLinkOfADropToItsNote() async throws {
        var lost: [String] = []
        var finish: CheckedContinuation<Void, Never>?
        var editor: EditorController? = EditorController()
        editor?.onDropFiles = { _ in
            await withCheckedContinuation { finish = $0 }
            return "![](assets/b.png)"
        }
        editor?.onLostDrop = { lost.append($0) }
        editor?.dropFiles([.file(URL(fileURLWithPath: "/tmp/b.png"))], at: 0)
        await settle()
        editor = nil
        finish?.resume()
        await settle()
        XCTAssertEqual(lost, ["![](assets/b.png)"])
    }

    func testAnotherNoteInTheEditorStillGetsTheLinkOfADrop() async throws {
        var lost: [String] = []
        var finish: CheckedContinuation<Void, Never>?
        controller.onDropFiles = { _ in
            await withCheckedContinuation { finish = $0 }
            return "![](assets/b.png)"
        }
        controller.onLostDrop = { lost.append($0) }
        await load("One", caret: 0)
        controller.dropFiles([.file(URL(fileURLWithPath: "/tmp/b.png"))], at: 0)
        await settle()
        controller.show(EditorContent(id: 2, text: "Other", initialState: EditorViewState(caret: 0, scrollY: 0)))
        finish?.resume()
        await settle()
        XCTAssertEqual(lost, ["![](assets/b.png)"])
        XCTAssertEqual(textView.string, "Other")
    }

    func testAPastedPictureGoesToTheHostAtTheCaret() async throws {
        var received: [DroppedFile] = []
        controller.onDropFiles = { files in
            received = files
            return "![](assets/shot.png)"
        }
        await load("Text", caret: 4)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loam.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(Data([1, 2, 3]), forType: .png)
        XCTAssertTrue(textView.pasteFiles(from: pasteboard))
        await settle()
        XCTAssertEqual(received, [.data(Data([1, 2, 3]), pathExtension: "png")])
        XCTAssertEqual(textView.string, "Text\n![](assets/shot.png)\n")
    }
}

/// The pieces of embeds and drops that need no window.
@MainActor
final class EmbedLogicTests: XCTestCase {
    func testAnImageAloneOnItsLineIsAnEmbed() {
        func embeds(_ text: String) -> [StyleSpan] {
            MarkdownStyler.spans(in: text).filter { if case .embed = $0.style { true } else { false } }
        }
        let text = "Intro\n\n![Alt *text*](../assets/My%20photo.png)  \n![](<assets/my file.png>)\nSee ![](a.png) here\n- ![](b.png)"
        let found = embeds(text)
        XCTAssertEqual(found.map(\.style), [
            .embed(destination: "../assets/My%20photo.png", alt: "Alt text"),
            .embed(destination: "assets/my file.png", alt: ""),
        ])
        XCTAssertEqual(found.first?.range, (text as NSString).range(of: "![Alt *text*](../assets/My%20photo.png)  "))
        // The line and the line breaks around it.
        let second = (text as NSString).range(of: "![](<assets/my file.png>)")
        XCTAssertEqual(found.last?.revealRange, NSRange(location: second.location - 1, length: second.length + 2))
        XCTAssertEqual(embeds("![](a.png)").first?.revealRange, NSRange(location: 0, length: 11))
    }

    func testDroppedLinksGoOnLinesOfTheirOwn() {
        func insert(_ text: String, at location: Int) -> String {
            EditorController.blockInsertion("![](a.png)", at: location, in: text).applied(to: text)
        }
        XCTAssertEqual(insert("", at: 0), "![](a.png)\n")
        XCTAssertEqual(insert("Hello", at: 5), "Hello\n![](a.png)\n")
        XCTAssertEqual(insert("Hello\nNext", at: 5), "Hello\n![](a.png)\nNext")
        XCTAssertEqual(insert("Hello", at: 0), "![](a.png)\nHello")
        XCTAssertEqual(insert("Hel lo", at: 3), "Hel\n![](a.png)\n lo")
        XCTAssertEqual(insert("A\n\nB", at: 2), "A\n![](a.png)\nB", "on an empty line, the line itself")
        let edit = EditorController.blockInsertion("![](a.png)", at: 5, in: "Hello\nNext")
        XCTAssertEqual(edit.selection, NSRange(location: 17, length: 0), "the caret goes to the line after")
    }

    func testALateLinkLeavesTheCaretWhereTheUserIsTyping() {
        // `![](a.png)` pasted at 0, then "B" typed at the caret: the link lands before it and the caret stays after "B".
        let text = "B"
        let insertion = EditorController.blockInsertion("![](a.png)", at: 0, in: text)
        let typed = EditorController.keepingCaret(insertion, caret: NSRange(location: 1, length: 0), droppedAt: 0)
        XCTAssertEqual(typed.applied(to: text), "![](a.png)\nB")
        XCTAssertEqual(typed.selection, NSRange(location: 12, length: 0), "after B, not after the link")
        // Nothing typed: the caret goes after the link, as for a quick drop.
        let idle = EditorController.keepingCaret(insertion, caret: NSRange(location: 0, length: 0), droppedAt: 0)
        XCTAssertEqual(idle.selection, insertion.selection)
        // Typing before the drop point: the caret is before the link and stays put.
        let before = EditorController.blockInsertion("![](a.png)", at: 5, in: "Hello world")
        XCTAssertEqual(EditorController.keepingCaret(before, caret: NSRange(location: 2, length: 0), droppedAt: 5).selection,
                       NSRange(location: 2, length: 0))
    }

    func testTheDropPointFollowsTheEditsMadeMeanwhile() {
        let anchor = DropAnchor(location: 10)
        anchor.follow(NSRange(location: 2, length: 0), replacementLength: 3)
        XCTAssertEqual(anchor.location, 13, "typed before")
        anchor.follow(NSRange(location: 13, length: 0), replacementLength: 2)
        XCTAssertEqual(anchor.location, 13, "typed at it: stays")
        anchor.follow(NSRange(location: 20, length: 4), replacementLength: 0)
        XCTAssertEqual(anchor.location, 13, "after it: stays")
        anchor.follow(NSRange(location: 10, length: 3), replacementLength: 0)
        XCTAssertEqual(anchor.location, 10, "deleted just before")
        anchor.follow(NSRange(location: 8, length: 5), replacementLength: 1)
        XCTAssertEqual(anchor.location, 9, "around it: at the end of the edit")
    }

    func testThePasteboardGivesFilesOrAPicture() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loam.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.pdf")]
        pasteboard.writeObjects(urls as [NSURL])
        XCTAssertEqual(FilePasteboard.files(on: pasteboard, forPaste: true), urls.map { .file($0) })

        // A picture copied from an app comes as TIFF and is saved as PNG.
        pasteboard.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        pasteboard.setData(try XCTUnwrap(image.tiffRepresentation), forType: .tiff)
        guard case .data(let data, "png")? = FilePasteboard.files(on: pasteboard, forPaste: true)?.first else {
            return XCTFail("no picture")
        }
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "PNG bytes")

        // A cell copied from a spreadsheet carries its text and a picture of it: the text wins a paste.
        pasteboard.clearContents()
        pasteboard.setString("42", forType: .string)
        pasteboard.setData(Data([1]), forType: .png)
        XCTAssertNil(FilePasteboard.files(on: pasteboard, forPaste: true))
        XCTAssertNotNil(FilePasteboard.files(on: pasteboard, forPaste: false), "a drop of it is the picture")
        // A browser's Copy Image: the picture and its address.
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/a.png", forType: .string)
        pasteboard.setData(Data([1]), forType: .png)
        XCTAssertEqual(FilePasteboard.files(on: pasteboard, forPaste: true), [.data(Data([1]), pathExtension: "png")])

        // Plain text, or a note dragged from the sidebar (a private type), is not files.
        pasteboard.clearContents()
        pasteboard.setString("Hello", forType: .string)
        XCTAssertNil(FilePasteboard.files(on: pasteboard, forPaste: false))
        pasteboard.clearContents()
        pasteboard.setData(Data("loam-resource:file/a.md".utf8), forType: NSPasteboard.PasteboardType("dyn.ah62d4rv4ge8085xtqz4hk"))
        XCTAssertNil(FilePasteboard.files(on: pasteboard, forPaste: false))
    }

    func testTheCacheRemembersWhatCouldNotBeShown() {
        var cache = EmbedCache()
        XCTAssertTrue(cache.needs("a"))
        cache.pending.insert("a")
        XCTAssertFalse(cache.needs("a"))
        cache.store(nil, for: "a")
        XCTAssertFalse(cache.needs("a"))
        cache.store(Embed(content: .image(NSImage()), size: NSSize(width: 1, height: 1)), for: "b")
        XCTAssertNotNil(cache.embed(for: "b"))
    }
}
