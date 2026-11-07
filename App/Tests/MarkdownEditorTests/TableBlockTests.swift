import AppKit
import XCTest
@testable import MarkdownEditor

/// Tables shown as components in a real window: the lines hidden and out of the text's reach, the view in the room
/// made for it, edits written back as GFM, undone with the text's own undo.
@MainActor
final class TableBlockTests: XCTestCase {
    private var window: NSWindow!
    private var textView: EditorTextView!
    private var controller: EditorController!
    private var saved = ""

    private let text = "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nEnd"

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        textView = EditorTextView(usingTextLayoutManager: true)
        textView.frame = scrollView.bounds
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        window.contentView!.addSubview(scrollView)
        controller = EditorController()
        controller.attach(textView)
        controller.onChange = { [unowned self] in saved = $0 }
    }

    override func tearDown() async throws {
        window.close()
    }

    private func settle() {
        for _ in 0..<6 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func load(_ text: String? = nil) {
        controller.show(EditorContent(id: 1, text: text ?? self.text, initialState: EditorViewState(caret: 0, scrollY: 0)))
        settle()
    }

    private var storage: NSTextStorage { textView.textStorage! }
    private var view: TableBlockView { controller.tableBlocks[0].view }
    private var editor: TableCellEditor { view.editor }

    private func type(_ string: String) {
        editor.insertText(string, replacementRange: editor.selectedRange())
    }

    private func command(_ selector: Selector) {
        XCTAssertTrue(view.textView(editor, doCommandBy: selector))
    }

    func testTheTableIsAViewInItsRoomAndItsLinesAreHidden() throws {
        load()
        XCTAssertEqual(controller.tableBlocks.count, 1)
        let lines = (textView.string as NSString).range(of: "| A | B |\n| --- | --- |\n| 1 | 2 |")
        let font = try XCTUnwrap(storage.attribute(.font, at: lines.location + 3, effectiveRange: nil) as? NSFont)
        XCTAssertLessThan(font.pointSize, 1, "the source takes no room")
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: NSMaxRange(lines) - 1, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.paragraphSpacing, view.tableHeight + 2 * PictureMark.margin, accuracy: 0.01)
        XCTAssertTrue(view.superview === textView)
        let (_, frame) = try XCTUnwrap((textView.blockFrames(.markdownTableBlock) as [(TableMark, NSRect)]).first)
        XCTAssertEqual(view.tableRect.width, textView.columnWidth, accuracy: 1)
        XCTAssertEqual(view.frame.minX + view.tableRect.minX, frame.minX, accuracy: 1)
        XCTAssertEqual(view.frame.minY + view.tableRect.minY, frame.minY, accuracy: 1)
        XCTAssertEqual(view.data.rows, [["A", "B"], ["1", "2"]])
    }

    func testTypingInACellWritesGFMToTheNote() {
        load()
        view.focus(TableCell(row: 1, column: 1), caret: .end)
        type("0")
        XCTAssertEqual(saved, "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 20 |\n\nEnd")
        type("|")
        XCTAssertTrue(saved.contains("| 20\\| |"), "a pipe in a cell is escaped: \(saved)")
        XCTAssertEqual(view.data.rows[1][1], "20|", "and the cell still shows it")
    }

    func testAKeystrokeRunUndoesAsOneAndRedoes() {
        load()
        view.focus(TableCell(row: 1, column: 0), caret: .end)
        type("a")
        type("b")
        type("c")
        XCTAssertTrue(saved.contains("| 1abc |"))
        controller.undo.undo()
        XCTAssertEqual(textView.string, text, "the whole run of typing is one step")
        XCTAssertEqual(view.data.rows[1][0], "1", "the view follows")
        controller.undo.redo()
        XCTAssertTrue(textView.string.contains("| 1abc |"))
    }

    func testShapeChangesAreUndoable() {
        load()
        view.insertColumn(at: 2)
        XCTAssertEqual(textView.string, "Intro\n\n| A | B |  |\n| --- | --- | --- |\n| 1 | 2 |  |\n\nEnd")
        XCTAssertEqual(view.data.columnCount, 3)
        settle()  // the end of the event: one undo step
        view.addRowAtEnd()
        XCTAssertEqual(view.data.rowCount, 3)
        settle()
        controller.undo.undo()
        XCTAssertEqual(view.data.rowCount, 2)
        controller.undo.undo()
        XCTAssertEqual(textView.string, text)
        XCTAssertEqual(view.data.columnCount, 2)
    }

    func testTabWalksTheCellsAndAddsARowAtTheEnd() {
        load()
        view.focus(TableCell(row: 0, column: 0))
        command(#selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(view.editing, TableCell(row: 0, column: 1))
        command(#selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(view.editing, TableCell(row: 1, column: 0), "the end of a row goes to the next row")
        command(#selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(view.editing, TableCell(row: 0, column: 1))
        view.focus(TableCell(row: 1, column: 1))
        command(#selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(view.data.rowCount, 3, "Tab in the last cell adds a row")
        XCTAssertEqual(view.editing, TableCell(row: 2, column: 0))
        XCTAssertTrue(textView.string.contains("| 1 | 2 |\n|  |  |"))
    }

    func testReturnAndTheArrowsMoveBetweenCells() {
        load()
        view.focus(TableCell(row: 0, column: 1))
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(view.editing, TableCell(row: 1, column: 1), "Return goes down")
        command(#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(view.editing, TableCell(row: 0, column: 1))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        command(#selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(view.editing, TableCell(row: 0, column: 0), "left at the start of a cell goes to the cell before")
        XCTAssertEqual(editor.selectedRange().location, 1, "with the caret at its end")
        command(#selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(view.editing, TableCell(row: 0, column: 1))
        command(#selector(NSResponder.moveToEndOfDocument(_:)))
        XCTAssertEqual(view.editing, TableCell(row: 1, column: 1), "Cmd-Down jumps to the edge")
        command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(view.data.rowCount, 3, "Return in the last row adds one")
    }

    func testLeavingTheTableLandsTheCaretOnTheLinesAroundIt() {
        load()
        view.focus(TableCell(row: 0, column: 0))
        command(#selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0), "the empty line above")
        XCTAssertTrue(window.firstResponder === textView)
        view.focus(TableCell(row: 1, column: 0), caret: .end)
        command(#selector(NSResponder.moveDown(_:)))
        let end = (textView.string as NSString).range(of: "\n\nEnd").location + 1
        XCTAssertEqual(textView.selectedRange(), NSRange(location: end, length: 0), "the empty line below")
    }

    func testATableAtTheEndOfTheNoteGetsALineToLeaveTo() {
        load("| A |\n| - |\n| 1 |")
        view.focus(TableCell(row: 1, column: 0))
        command(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(textView.string, "| A |\n| - |\n| 1 |\n\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: (textView.string as NSString).length, length: 0))
        controller.undo.undo()
        XCTAssertEqual(textView.string, "| A |\n| - |\n| 1 |")
    }

    func testTheTextCannotEditTheHiddenLines() {
        load()
        let inside = (text as NSString).range(of: "| 1 | 2 |").location + 3
        XCTAssertFalse(controller.textView(textView, shouldChangeTextIn: NSRange(location: inside, length: 0), replacementString: "x"))
        XCTAssertFalse(controller.textView(textView, shouldChangeTextIn: NSRange(location: 4, length: 12), replacementString: ""),
                       "nor a selection that reaches into it")
        let table = (text as NSString).range(of: "| A | B |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertTrue(controller.textView(textView, shouldChangeTextIn: table, replacementString: ""), "but a selection of the whole table")
        XCTAssertTrue(controller.textView(textView, shouldChangeTextIn: NSRange(location: 2, length: 0), replacementString: "x"))
    }

    func testASelectionReachingIntoATableTakesItWhole() {
        load()
        let table = (text as NSString).range(of: "| A | B |\n| --- | --- |\n| 1 | 2 |")
        let partial = NSRange(location: 3, length: table.location + 4 - 3)
        XCTAssertEqual(
            controller.adjustSelectionForTables(from: NSRange(location: 3, length: 0), to: partial),
            NSRange(location: 3, length: NSMaxRange(table) - 3)
        )
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        XCTAssertTrue(view.isSelectedAsText, "Select All shows the table selected")
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertFalse(view.isSelectedAsText)
    }

    func testSelectingCellsRowsColumnsAndEverything() {
        load("| A | B |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |")
        view.selectAll(nil)
        XCTAssertEqual(view.selection?.kind, .all)
        view.select(TableSelection(kind: .cells, anchor: TableCell(row: 1, column: 0), head: TableCell(row: 2, column: 1)))
        let pasteboard = NSPasteboard.general
        view.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "1\t2\n3\t4")
        view.cut(nil)
        XCTAssertEqual(view.data.rows, [["A", "B"], ["", ""], ["", ""]])
        XCTAssertEqual(saved, "| A | B |\n| --- | --- |\n|  |  |\n|  |  |")
        view.paste(nil)
        XCTAssertEqual(view.data.rows, [["A", "B"], ["1", "2"], ["3", "4"]], "pasted where the selection starts")
    }

    func testDeletingARowOrAColumnFromTheSelection() {
        load("| A | B |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |")
        view.select(TableSelection(kind: .rows, anchor: TableCell(row: 1, column: 0), head: TableCell(row: 1, column: 0)))
        view.deleteSelection()
        XCTAssertEqual(saved, "| A | B |\n| --- | --- |\n| 3 | 4 |")
        settle()
        view.select(TableSelection(kind: .columns, anchor: TableCell(row: 0, column: 0), head: TableCell(row: 0, column: 0)))
        view.deleteSelection()
        XCTAssertEqual(saved, "| B |\n| --- |\n| 4 |")
        settle()
        view.selectAll(nil)
        view.deleteSelection()
        XCTAssertEqual(saved, "", "the whole table goes")
        settle()
        controller.undo.undo()
        XCTAssertEqual(textView.string, "| B |\n| --- |\n| 4 |")
    }

    func testAlignmentAndColumnMovesAreWritten() {
        load("| A | B |\n| - | - |\n| 1 | 2 |")
        view.align(1...1, .right)
        XCTAssertEqual(saved, "| A | B |\n| --- | --: |\n| 1 | 2 |")
        view.moveColumns(1...1, by: -1)
        XCTAssertEqual(saved, "| B | A |\n| --: | --- |\n| 2 | 1 |")
    }

    func testTheMenuOffersWhatTheSelectionCanDo() {
        load()
        let menu = view.menu(for: TableSelection(kind: .cells, anchor: TableCell(row: 0, column: 0), head: TableCell(row: 0, column: 0)))
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        let items = all(menu)
        let titles = items.map(\.title)
        XCTAssertEqual(menu.items.first?.title, "Edit Table", "the shape changes are in a submenu, as in Craft")
        XCTAssertTrue(titles.contains("Insert Row Below"))
        XCTAssertTrue(titles.contains("Center"), "alignment is in its own submenu")
        XCTAssertTrue(titles.contains("Reset Column Size"))
        XCTAssertEqual(items.first { $0.title == "Delete Row" }?.isEnabled, false, "the header is not a row to delete")
        XCTAssertEqual(items.first { $0.title == "Insert Row Above" }?.isEnabled, false)
    }

    func testCmdReturnAddsARowAndShiftCmdReturnAColumn() {
        load()
        view.focus(TableCell(row: 0, column: 0))
        view.insertRowBelowActive()
        XCTAssertEqual(view.data.rowCount, 3)
        XCTAssertEqual(view.editing, TableCell(row: 1, column: 0))
        view.insertColumnAfterActive()
        XCTAssertEqual(view.data.columnCount, 3)
        XCTAssertEqual(view.editing, TableCell(row: 1, column: 1))
        XCTAssertEqual(saved, "Intro\n\n| A |  | B |\n| --- | --- | --- |\n|  |  |  |\n| 1 |  | 2 |\n\nEnd")
    }

    func testResizingAColumnIsKeptWhileTheTableIsEdited() {
        load()
        view.fractions = [0.7, 0.3]
        view.relayout()
        XCTAssertEqual(view.columnWidths[0] / view.tableRect.width, 0.7, accuracy: 0.001)
        view.focus(TableCell(row: 1, column: 0), caret: .end)
        type("x")
        XCTAssertEqual(view.columnWidths[0] / view.tableRect.width, 0.7, accuracy: 0.001, "typing does not reset the sizes")
        view.resetColumnSizes()
        XCTAssertEqual(view.columnWidths[0], view.columnWidths[1], accuracy: 0.001)
    }

    func testAnotherNoteDropsTheViews() {
        load()
        XCTAssertEqual(controller.tableBlocks.count, 1)
        controller.show(EditorContent(id: 2, text: "Nothing here", initialState: EditorViewState(caret: 0, scrollY: 0)))
        settle()
        XCTAssertTrue(controller.tableBlocks.isEmpty)
        XCTAssertTrue(textView.subviews.allSatisfy { !($0 is TableBlockView) })
    }

    func testAWideCellGrowsItsRow() {
        load()
        let before = view.tableHeight
        view.focus(TableCell(row: 1, column: 0), caret: .end)
        type(String(repeating: "word ", count: 80))
        XCTAssertGreaterThan(view.tableHeight, before + 20, "the row wraps its text")
    }
}
