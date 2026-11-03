import AppKit
import BuiltinPlugins
import CanvasPlugin
import MindmapUI
import PDFKit
import PluginKit
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import CanvasUI

/// The whiteboard's pieces beyond cards: free text, shapes, frames and slides, free lines, ink, export.
@MainActor
final class BoardWhiteboardTests: XCTestCase {
    private let logicPlugins = builtinPlugins.filter { $0.manifest.id == "canvas" }

    private func harness(_ board: CanvasDocument = CanvasDocument()) throws -> UIPluginHarness {
        try UIPluginHarness(logicPlugins: logicPlugins, uiPlugins: [CanvasUIPlugin.self],
                            files: ["Boards/White.canvas": board.text])
    }

    private func model(_ harness: UIPluginHarness) throws -> BoardModel {
        let store = try XCTUnwrap(harness.kernel.services.service(CanvasUIPlugin.storeKey))
        let model = store.model(for: ViewContext(resource: .file("Boards/White.canvas")))
        model.camera.scale = 1
        model.camera.offset = .zero
        return model
    }

    private func saved(_ harness: UIPluginHarness, _ model: BoardModel) throws -> CanvasDocument {
        model.flush()
        return try CanvasDocument(text: try harness.vault.read("Boards/White.canvas"))
    }

    // MARK: Free text

    func testFreeTextIsAsBigAsItsTextAndHasNoCard() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let id = try XCTUnwrap(model.addText(at: CanvasPoint(x: 100, y: 100)))
        model.editing?.draft = "Hello board"
        let typing = model.frame(of: try XCTUnwrap(model.node(id)))
        XCTAssertGreaterThan(typing.width, 100, "grows as it is typed")
        model.commitEditing()
        let node = try XCTUnwrap(try saved(harness, model).node(id))
        XCTAssertTrue(node.isFreeText)
        XCTAssertEqual(node.border, .invisible, "written as Advanced Canvas's invisible border")
        XCTAssertEqual(node.fontSize, BoardModel.freeTextFontSize)
        let one = BoardText.freeSize(of: "Hello board", fontSize: 20)
        XCTAssertEqual(node.width, one.width)
        XCTAssertEqual(node.height, one.height)
        XCTAssertLessThan(node.height, 50, "one line")

        model.beginEditing(.node(id))
        model.editing?.draft = ""
        model.commitEditing()
        XCTAssertNil(model.node(id), "emptied, it goes away")
    }

    /// Free text hugs what is written at any size: no room past the last letter that grows with the font.
    func testFreeTextIsAsWideAsItsText() throws {
        for size in [20.0, 91, 200] {
            let font = NSFont.systemFont(ofSize: size)
            let text = ("this is some text" as NSString).size(withAttributes: [.font: font]).width
            let width = BoardText.freeSize(of: "this is some text", fontSize: size).width
            XCTAssertGreaterThanOrEqual(width, Double(text) + Double(BoardStyle.freeTextPadding) * 2, "at \(size)")
            XCTAssertLessThanOrEqual(width, Double(text) + Double(BoardStyle.freeTextPadding) * 2 + 4, "at \(size)")
        }
    }

    func testResizingFreeTextScalesItsFont() throws {
        var node = CanvasNode(id: "t", kind: .text, x: 0, y: 0, width: 0, height: 0, text: "Title", fontSize: 20)
        node.border = .invisible
        let size = BoardText.freeSize(of: "Title", fontSize: 20)
        node.width = size.width
        node.height = size.height
        let harness = try harness(CanvasDocument(nodes: [node]))
        defer { harness.close() }
        let model = try model(harness)
        model.selection = ["t"]
        model.beginResize(node, handle: .bottomRight)
        // Dragged mostly sideways: the text still keeps its proportions.
        model.updateResize(CGSize(width: size.width, height: 3))
        let during = try XCTUnwrap(model.resizing?.frame)
        XCTAssertEqual(during.width / during.height, size.width / size.height, accuracy: 0.05)
        model.endResize()
        let resized = try XCTUnwrap(try saved(harness, model).node("t"))
        XCTAssertEqual(resized.fontSize ?? 0, 40, accuracy: 1.5, "twice as wide: twice the size")
        XCTAssertEqual(resized.x, 0)
        XCTAssertEqual(resized.y, 0, "the opposite corner stays put")
        XCTAssertEqual(resized.width, BoardText.freeSize(of: "Title", fontSize: resized.fontSize!).width)

        model.beginResize(resized, handle: .topLeft)
        model.updateResize(CGSize(width: 10_000, height: 10_000))
        model.endResize()
        XCTAssertEqual(model.node("t")?.fontSize ?? 0, 7, accuracy: 1.01, "it stops at a tiny size, never below")
        XCTAssertEqual(model.node("t")?.frame.maxX ?? 0, resized.frame.maxX, accuracy: 1)
    }

    func testCardsAndFreeTextTurnIntoEachOther() throws {
        let harness = try harness(CanvasDocument(nodes: [
            CanvasNode(id: "c", kind: .text, x: 0, y: 0, width: 260, height: 80, text: "A card"),
        ]))
        defer { harness.close() }
        let model = try model(harness)
        model.selection = ["c"]
        model.makeFreeText()
        XCTAssertTrue(model.node("c")?.isFreeText == true)
        XCTAssertLessThan(model.node("c")?.width ?? 999, 200)
        XCTAssertTrue(model.selectionIsFreeText)
        model.clearShape()
        XCTAssertFalse(model.node("c")?.isFreeText == true)
        XCTAssertNil(model.node("c")?.border)
    }

    func testShortPastedTextIsFreeTextLongTextACard() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.paste("A thought", at: CanvasPoint(x: 0, y: 0))
        XCTAssertTrue(model.document.nodes.last?.isFreeText == true)
        model.paste("First paragraph.\n\nSecond paragraph.", at: CanvasPoint(x: 0, y: 500))
        XCTAssertFalse(model.document.nodes.last?.isFreeText == true)
    }

    func testDropsBecomeCardsWhereTheyLand() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let note = NSPasteboard(name: .init("loam-test-drop-note"))
        note.clearContents()
        note.setData(Data(DragPayload.resource(.file("Welcome.md")).string.utf8),
                     forType: .init(DragPayload.type.identifier))
        XCTAssertTrue(model.drop(note, at: CanvasPoint(x: 40, y: 60)))
        XCTAssertEqual(model.document.nodes.last?.file, "Welcome.md", "a note from the sidebar becomes its card")
        let text = NSPasteboard(name: .init("loam-test-drop-text"))
        text.clearContents()
        text.setString("A thought", forType: .string)
        XCTAssertTrue(model.drop(text, at: CanvasPoint(x: 0, y: 400)))
        XCTAssertEqual(model.document.nodes.last?.text, "A thought")
        let empty = NSPasteboard(name: .init("loam-test-drop-empty"))
        empty.clearContents()
        XCTAssertFalse(model.drop(empty, at: .init(x: 0, y: 0)), "nothing the board takes")
    }

    // MARK: Shapes

    func testShapesAreAddedAndChanged() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let id = try XCTUnwrap(model.addShape(.diamond, at: CanvasPoint(x: 0, y: 0)))
        XCTAssertEqual(model.lastShape, .diamond)
        model.commitEditing()
        XCTAssertNotNil(model.node(id), "an empty shape stays on the board")
        XCTAssertEqual(model.node(id)?.width, CanvasNodeShape.diamond.defaultSize.width)
        model.selection = [id]
        XCTAssertEqual(model.selectedShape, .diamond)
        model.setShape(.circle)
        model.setBorder(.dashed)
        let node = try XCTUnwrap(try saved(harness, model).node(id))
        XCTAssertEqual(node.shape, .circle)
        XCTAssertEqual(node.border, .dashed)
        XCTAssertEqual(node.styleAttribute("shape"), .string("circle"))

        let rectangle = try XCTUnwrap(model.addShape(.rectangle, at: CanvasPoint(x: 600, y: 0), editNow: false))
        XCTAssertNil(model.node(rectangle)?.shape, "a rectangle is a card")
        XCTAssertEqual(model.node(rectangle)?.textAlign, .center, "with its text in the middle")
        model.selection = [rectangle]
        XCTAssertEqual(model.selectedShape, .rectangle)
    }

    func testTextInAShapeNeedsMoreRoom() {
        let text = "A rather long sentence that needs a few lines to be read"
        let card = BoardText.height(of: text, fontSize: 16, width: 240, shape: nil)
        let diamond = BoardText.height(of: text, fontSize: 16, width: 240, shape: .diamond)
        XCTAssertGreaterThan(diamond, card * 1.8)
    }

    // MARK: Frames and presenting

    func testFramesAreSlidesPresentedInOrder() throws {
        let harness = try harness(CanvasDocument(nodes: [
            CanvasNode(id: "a", kind: .text, x: 0, y: 0, width: 200, height: 100, text: "One"),
            CanvasNode(id: "b", kind: .text, x: 2000, y: 0, width: 200, height: 100, text: "Two"),
        ]))
        defer { harness.close() }
        let model = try model(harness)
        _ = model.camera.viewResized(CGSize(width: 1000, height: 700))
        model.selection = ["a"]
        let first = try XCTUnwrap(model.addFrame(at: CanvasPoint(x: 0, y: 0)))
        model.selection = ["b"]
        let second = try XCTUnwrap(model.addFrame(at: CanvasPoint(x: 0, y: 0)))
        let board = try saved(harness, model)
        XCTAssertEqual(board.startNode, first)
        XCTAssertEqual(board.node(second)?.label, "Slide 2")
        XCTAssertTrue(CanvasRect(CGRect(board.node(second)!.frame)).contains(board.node("b")!.frame))
        XCTAssertEqual(model.slideNumbers, [first: 1, second: 2])

        let before = model.camera.offset
        model.present()
        XCTAssertEqual(model.presentation?.current, second, "from the selected frame")
        model.stopPresenting()
        model.selection = []
        model.present()
        XCTAssertEqual(model.presentation?.current, first)
        let shown = model.camera.screenRect(CGRect(board.node(first)!.frame))
        XCTAssertEqual(shown.midX, 500, accuracy: 1, "the slide fills the middle of the view")
        XCTAssertEqual(shown.width, 1000 - 56, accuracy: 1)
        model.nextSlide()
        XCTAssertEqual(model.presentation?.current, second)
        model.nextSlide()
        XCTAssertEqual(model.presentation?.index, 1, "stops at the last slide")
        model.stopPresenting()
        XCTAssertNil(model.presentation)
        XCTAssertEqual(model.camera.offset, before, "the board comes back where it was")

        model.makeStartSlide(second)
        model.selection = []
        model.present()
        XCTAssertEqual(model.presentation?.current, second)
    }

    func testResizingAFrameKeepsItsProportions() throws {
        var document = CanvasDocument()
        document.addFrame(CanvasRect(x: 0, y: 0, width: 1280, height: 720))
        let harness = try harness(document)
        defer { harness.close() }
        let model = try model(harness)
        let frame = try XCTUnwrap(model.document.nodes.first)
        model.beginResize(frame, handle: .right)
        model.updateResize(CGSize(width: 320, height: 0))
        model.endResize()
        let resized = try XCTUnwrap(model.node(frame.id))
        XCTAssertEqual(resized.width / resized.height, 16.0 / 9, accuracy: 0.01)
    }

    // MARK: Mindmaps

    func testSeveralMindmapsLiveOnABoardAtTheirOwnSize() throws {
        let map = { (title: String) in "---\nmindmap-plugin: basic\n---\n\n# \(title)\n\n- One\n- Two\n" }
        let board = CanvasDocument(nodes: [
            CanvasNode(id: "a", kind: .file, x: 0, y: 0, width: 400, height: 300, file: "Boards/A.md"),
            CanvasNode(id: "b", kind: .file, x: 900, y: 0, width: 400, height: 300, file: "Boards/B.md"),
        ])
        let harness = try UIPluginHarness(logicPlugins: logicPlugins, uiPlugins: [CanvasUIPlugin.self, MindmapPlugin.self],
                                          files: ["Boards/White.canvas": board.text, "Boards/A.md": map("A"),
                                                  "Boards/B.md": map("B")])
        defer { harness.close() }
        let model = try model(harness)
        let a = try XCTUnwrap(model.node("a")), b = try XCTUnwrap(model.node("b"))
        XCTAssertTrue(model.isBare(a), "a map stands on the board with no card round it")
        XCTAssertEqual(model.store.embeddedViewType(for: "Boards/A.md")?.sizesToContent, true)

        // The map says where its content is: the card takes its size, then follows its origin as it grows.
        model.embedContentChanged("a", bounds: CGRect(x: -30, y: -20, width: 300, height: 120))
        XCTAssertEqual(model.node("a")?.frame, CanvasRect(x: 0, y: 0, width: 300, height: 120))
        model.embedContentChanged("a", bounds: CGRect(x: -130, y: -20, width: 400, height: 120))
        XCTAssertEqual(model.node("a")?.frame, CanvasRect(x: -100, y: 0, width: 400, height: 120),
                       "grown to the left: the card moves left, the map stays put")

        let contextA = try XCTUnwrap(model.embedContext(for: a)), contextB = try XCTUnwrap(model.embedContext(for: b))
        model.tap(b, count: 2, extend: false)
        XCTAssertTrue(contextB.isActive)
        XCTAssertFalse(contextA.isActive, "only the map entered takes the keyboard")
        _ = harness.render(AnyView(BoardView(model: model)), size: CGSize(width: 1400, height: 800))
        XCTAssertNotNil(contextA.contentBounds, "drawn, an embedded map says how big it is")
    }

    func testANewMindmapIsANoteBesideTheBoard() throws {
        let harness = try UIPluginHarness(logicPlugins: logicPlugins, uiPlugins: [CanvasUIPlugin.self, MindmapPlugin.self],
                                          files: ["Boards/White.canvas": CanvasDocument().text])
        defer { harness.close() }
        let model = try model(harness)
        let first = try XCTUnwrap(model.addMindmap(at: CanvasPoint(x: 0, y: 0)))
        let second = try XCTUnwrap(model.addMindmap(at: CanvasPoint(x: 800, y: 0)))
        XCTAssertEqual(model.node(first)?.file, "Boards/White mindmap.md")
        XCTAssertEqual(model.node(second)?.file, "Boards/White mindmap 2.md")
        XCTAssertTrue(try harness.vault.read("Boards/White mindmap.md").contains("mindmap-plugin: basic"))
        XCTAssertEqual(model.activeEmbed, second, "entered, ready to type")
    }

    // MARK: Tables

    func testResizingALabelCardScalesItsText() throws {
        var node = CanvasNode(id: "s", kind: .text, x: 0, y: 0, width: 200, height: 120, text: "Label", fontSize: 16)
        // As the toolbar's rectangle makes it: a card with its text centred.
        node.textAlign = .center
        let harness = try harness(CanvasDocument(nodes: [node]))
        defer { harness.close() }
        let model = try model(harness)
        model.selection = ["s"]
        model.beginResize(node, handle: .bottomRight)
        model.updateResize(CGSize(width: 200, height: 120))
        XCTAssertEqual(model.scaledFontSize(of: node, in: try XCTUnwrap(model.resizing?.frame)) ?? 0, 32, accuracy: 0.5,
                       "shown at its new size while dragged")
        model.endResize()
        let resized = try XCTUnwrap(try saved(harness, model).node("s"))
        XCTAssertEqual(resized.width, 400)
        XCTAssertEqual(resized.fontSize ?? 0, 32, accuracy: 0.5, "twice as big: twice the text")

        let plain = CanvasNode(id: "p", kind: .text, x: 0, y: 0, width: 200, height: 120, text: "Flowing text")
        XCTAssertNil(model.scaledFontSize(of: plain, in: CanvasRect(x: 0, y: 0, width: 400, height: 240)),
                     "a card whose text flows rewraps instead")
    }

    func testTypingOnASelectedShapeWritesInIt() throws {
        var shape = CanvasNode(id: "s", kind: .text, x: 0, y: 0, width: 160, height: 100, text: "")
        shape.textAlign = .center
        let harness = try harness(CanvasDocument(nodes: [shape]))
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertFalse(model.typeIntoSelection("f"), "nothing selected: F stays the frame key")
        model.selection = ["s"]
        XCTAssertFalse(model.typeIntoSelection(" "), "Space still pans")
        XCTAssertFalse(model.typeIntoSelection("\u{F702}"), "an arrow key still nudges")
        XCTAssertTrue(model.typeIntoSelection("f"))
        XCTAssertEqual(model.editing?.target, .node("s"))
        XCTAssertEqual(model.editing?.draft, "f")
        XCTAssertEqual(model.document.nodes.count, 1, "no frame added")
    }

    func testAnArrowDragThatNeverEndedIsLetGoOnTheNextClick() throws {
        let a = CanvasNode(id: "a", kind: .text, x: 0, y: 0, width: 200, height: 100, text: "A")
        let harness = try harness(CanvasDocument(nodes: [a]))
        defer { harness.close() }
        let model = try model(harness)
        model.beginLink(from: a, side: .right)
        XCTAssertNotNil(model.link)
        model.tapBackground(at: CGPoint(x: 900, y: 900), count: 1)
        XCTAssertNil(model.link)
    }

    func testATableGrowsFromItsBars() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let id = try XCTUnwrap(model.addTable(at: CanvasPoint(x: 0, y: 0)))
        model.commitEditing()
        let table = try XCTUnwrap(model.node(id)?.table)
        model.appendTableRow(try XCTUnwrap(model.node(id)))
        model.appendTableColumn(try XCTUnwrap(model.node(id)))
        let grown = try XCTUnwrap(try saved(harness, model).node(id)?.table)
        XCTAssertEqual(grown.rowCount, table.rowCount + 1)
        XCTAssertEqual(grown.columnCount, table.columnCount + 1)
    }

    func testATablesMenuNamesTheRowAndColumnUnderThePointer() throws {
        let table = CanvasNode(id: "tb", kind: .text, x: 0, y: 0, width: 300, height: 120,
                               text: "| City | People |\n| --- | --- |\n| Paris | 2 |\n| Lyon | 1 |")
        let harness = try harness(CanvasDocument(nodes: [table]))
        defer { harness.close() }
        let model = try model(harness)
        let node = try XCTUnwrap(model.node("tb"))
        let layout = try XCTUnwrap(model.store.tableLayout(node.text ?? "", fontSize: node.effectiveFontSize))
        // The pointer on the second column of the last row, in the card's view points.
        let point = CGPoint(x: (layout.columns[0] + layout.columns[1] / 2) * model.camera.scale,
                            y: (layout.rows[0] + layout.rows[1] + layout.rows[2] / 2) * model.camera.scale)
        model.setHovered("tb")
        model.hoverPoint = point
        let names = model.tableMenuNames(node)
        XCTAssertEqual(names.row, "“Lyon”")
        XCTAssertEqual(names.column, "“People”")
        model.removeTableRow(node)
        XCTAssertEqual(model.node("tb")?.table?.rowCount, 2)
        XCTAssertEqual(model.node("tb")?.table?[1, 0], "Paris", "the row named went, not another")
    }

    /// Pictures of the selection's handles: a table's bars, an arrow's ends, free text being written.
    func testSnapshotsOfTheHandles() throws {
        guard let folder = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] else { throw XCTSkip("no folder") }
        var free = CanvasNode(id: "t", kind: .text, x: 40, y: 40, width: 120, height: 36, text: "zdzdzd", fontSize: 24)
        free.border = .invisible
        var a = CanvasNode(id: "a", kind: .text, x: 40, y: 160, width: 200, height: 140, text: "effefef")
        a.textAlign = .center
        var b = CanvasNode(id: "b", kind: .text, x: 420, y: 60, width: 200, height: 140, text: "effefef")
        b.textAlign = .center
        var table = CanvasNode(id: "tb", kind: .text, x: 420, y: 300, width: 1, height: 1,
                               text: "| Column 1 | efefe |\n| --- | --- |\n| fef | efe |")
        let fitted = BoardTableLayout.make(try XCTUnwrap(table.table), fontSize: table.effectiveFontSize).size
        table.width = fitted.width
        table.height = fitted.height
        let harness = try harness(CanvasDocument(nodes: [free, a, b, table],
                                                 edges: [CanvasEdge(id: "e", fromNode: "a", toNode: "b", label: "lbl")]))
        defer { harness.close() }
        let model = try model(harness)
        let size = CGSize(width: 900, height: 600)
        for (name, setup) in [
            ("table", { (m: BoardModel) in m.selection = ["tb"] }),
            ("edge", { (m: BoardModel) in m.selection = []; m.selectedEdge = "e" }),
            ("text", { (m: BoardModel) in m.selectedEdge = nil; m.selection = ["t"]; m.beginEditing(.node("t")) }),
        ] as [(String, (BoardModel) -> Void)] {
            model.viewResized(size)
            setup(model)
            let view = harness.render(AnyView(BoardView(model: model).environment(\.themeTokens, .standard)), size: size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("handles-\(name).png"))
        }
    }

    func testATableIsWrittenCellByCell() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let id = try XCTUnwrap(model.addTable(at: CanvasPoint(x: 0, y: 0)))
        XCTAssertEqual(model.editing?.target, .cell(id, 0, 0), "the first header cell is being written")
        model.editing?.draft = "Idiom"
        model.moveCell(by: 1)
        XCTAssertEqual(model.editing?.target, .cell(id, 0, 1))
        model.editing?.draft = "Meaning"
        model.moveCellDown()
        XCTAssertEqual(model.editing?.target, .cell(id, 1, 1))
        model.moveCell(by: -1)
        model.editing?.draft = "Break the ice"
        // Tab from the last cell adds a row.
        model.commitEditing()
        model.beginEditing(.cell(id, 2, 2))
        model.moveCell(by: 1)
        XCTAssertEqual(model.editing?.target, .cell(id, 3, 0))
        model.commitEditing()

        let node = try XCTUnwrap(try saved(harness, model).node(id))
        let table = try XCTUnwrap(node.table)
        XCTAssertEqual(table.rows[0], ["Idiom", "Meaning", "Column 3"])
        XCTAssertEqual(table[1, 0], "Break the ice")
        XCTAssertEqual(table.rowCount, 4)
        XCTAssertTrue(node.text!.hasPrefix("| Idiom "), "plain GFM, any Markdown reader shows it")
        let layout = try XCTUnwrap(model.store.tableLayout(node.text!, fontSize: node.effectiveFontSize))
        XCTAssertEqual(node.width, Double(layout.size.width), "the card is as big as its table")
        XCTAssertEqual(node.height, Double(layout.size.height))
        XCTAssertGreaterThan(layout.columns[0], layout.columns[2], "a column is as wide as its words")

        // A double-click writes in the cell under it.
        let cell = layout.rect(row: 1, column: 1)
        model.tap(node, count: 2, extend: false, at: CGPoint(x: cell.midX, y: cell.midY))
        XCTAssertEqual(model.editing?.target, .cell(id, 1, 1))
        model.cancelEditing()
        model.insertTableColumn(node)
        XCTAssertEqual(model.node(id)?.table?.rows[0], ["Idiom", "Meaning", "Column 4", "Column 3"],
                       "added beside the cell last clicked")
        model.removeTableRow(try XCTUnwrap(model.node(id)))
        XCTAssertEqual(model.node(id)?.table?.rowCount, 3)

        // Deleting the column of the cell being written stops writing it: the view never asks for a lost column.
        model.tap(try XCTUnwrap(model.node(id)), count: 2, extend: false, at: CGPoint(x: cell.midX, y: cell.midY))
        model.removeTableColumn(try XCTUnwrap(model.node(id)))
        XCTAssertNil(model.editing)
        XCTAssertEqual(model.node(id)?.table?.columnCount, 3)
    }

    func testResizingATableScalesItsText() throws {
        var node = CanvasNode(id: "t", kind: .text, x: 0, y: 0, width: 300, height: 100,
                              text: CanvasTable.empty().markdown, fontSize: 14)
        node.border = .invisible
        let harness = try harness(CanvasDocument(nodes: [node]))
        defer { harness.close() }
        let model = try model(harness)
        let fitted = try XCTUnwrap(model.node("t"))
        XCTAssertNotEqual(fitted.width, 300, "fitted to its table when the board opens")
        model.beginResize(fitted, handle: .bottomRight)
        model.updateResize(CGSize(width: fitted.width, height: fitted.height))
        model.endResize()
        XCTAssertEqual(model.node("t")?.fontSize ?? 0, 28, accuracy: 1.5)
    }

    // MARK: Drawing

    private func stroke(_ model: BoardModel, _ points: [(Double, Double)]) {
        model.beginStroke(at: CanvasPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() { model.continueStroke(to: CanvasPoint(x: point.0, y: point.1)) }
        model.endStroke()
    }

    func testPenStrokesNearEachOtherAreOneDrawing() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.tool = .pen
        model.inkColor = "1"
        stroke(model, [(0, 0), (20, 10), (40, 0), (60, 10)])
        stroke(model, [(70, 0), (90, 20)])
        XCTAssertEqual(model.document.nodes.count, 1, "the second stroke joins the first drawing")
        stroke(model, [(2000, 2000), (2050, 2020)])
        XCTAssertEqual(model.document.nodes.count, 2, "far away, a new drawing")
        model.tool = .highlighter
        stroke(model, [(0, 40), (80, 40)])
        XCTAssertEqual(model.document.nodes.count, 3, "another tool, another drawing")

        let board = try saved(harness, model)
        let first = try XCTUnwrap(board.nodes.first?.drawing)
        XCTAssertEqual(first.strokes.count, 2)
        XCTAssertEqual(first.strokes[0].color, "1")
        XCTAssertEqual(first.strokes[0].points.first, CanvasPoint(x: 0, y: 0), "kept in board units")
        XCTAssertLessThan(board.nodes[2].drawing?.strokes[0].opacity ?? 1, 1, "a highlighter is see-through")
        XCTAssertTrue(board.nodes[0].text!.hasPrefix("<svg"), "an SVG any Markdown reader shows")

        model.tool = .eraser
        stroke(model, [(80, 10), (80, 12)])
        XCTAssertEqual(model.document.nodes.first?.drawing?.strokes.count, 1, "the stroke under the eraser goes")
        stroke(model, [(30, 5), (30, 6), (2025, 2010)])
        XCTAssertEqual(model.document.nodes.count, 1, "drawings left with no stroke go; the highlight stays")
    }

    func testFreeArrowsAndLines() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.tool = .arrow
        stroke(model, [(0, 0), (50, 3), (200, 100)])
        let node = try XCTUnwrap(model.document.nodes.first)
        let arrow = try XCTUnwrap(node.drawing)
        XCTAssertEqual(arrow.kind, .line)
        XCTAssertTrue(arrow.endArrow)
        XCTAssertEqual(arrow.ends?.0, CanvasPoint(x: 0, y: 0))
        XCTAssertEqual(arrow.ends?.1, CanvasPoint(x: 200, y: 100))
        XCTAssertTrue(node.frame.contains(CanvasRect(x: 0, y: 0, width: 200, height: 100)))

        model.tool = .line
        stroke(model, [(0, 300), (3, 302)])
        XCTAssertEqual(model.document.nodes.count, 1, "a click is not a line")

        model.tool = .select
        model.selection = [node.id]
        XCTAssertNotNil(model.selectedLine)
        model.beginLineEnd(node, movesStart: false)
        model.updateLineEnd(to: CanvasPoint(x: 300, y: 10), snaps: true)
        model.endLineEnd()
        let moved = try XCTUnwrap(model.node(node.id)?.drawing?.ends)
        XCTAssertEqual(moved.1.y, 0, accuracy: 0.01, "Shift keeps it level")
        model.setLineHeads(start: true, end: true)
        model.toggleLineDashed()
        model.setColor("4")
        let styled = try XCTUnwrap(model.node(node.id)?.drawing)
        XCTAssertTrue(styled.startArrow && styled.endArrow)
        XCTAssertTrue(styled.strokes[0].dashed)
        XCTAssertEqual(styled.strokes[0].color, "4")
        XCTAssertNil(model.node(node.id)?.color, "the colour is the stroke's, not the card's")
    }

    /// A line's end dragged far past its frame is still drawn there, not cut off at the old frame.
    func testADraggedLineEndIsDrawnOutsideTheLinesFrame() throws {
        let ink = CanvasInk(kind: .line, strokes: [CanvasInkStroke(points: [CanvasPoint(x: 0, y: 0),
                                                                            CanvasPoint(x: 100, y: 0)], width: 4)])
        let node = try XCTUnwrap(CanvasNode.drawing(id: "line", ink))
        let ends = (CanvasPoint(x: 0 - node.x, y: 0 - node.y), CanvasPoint(x: 300 - node.x, y: 0 - node.y))
        let size = CGSize(width: 600, height: 200)
        let view = NSHostingView(rootView: ZStack(alignment: .topLeading) {
            BoardInkView(node: node, ink: ink, ends: ends)
                .frame(width: node.width, height: node.height)
                .offset(x: 100 + node.x, y: 100 + node.y)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.themeTokens, .standard))
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        func alpha(_ x: CGFloat) -> CGFloat { bitmap.colorAt(x: Int(x * scale), y: Int(100 * scale))?.alphaComponent ?? 0 }
        XCTAssertGreaterThan(alpha(150), 0.5, "inside the frame")
        XCTAssertGreaterThan(alpha(370), 0.5, "past the frame, near the dragged end")
    }

    func testStickyNotes() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let id = try XCTUnwrap(model.addSticky(at: CanvasPoint(x: 0, y: 0)))
        model.commitEditing()
        let node = try XCTUnwrap(try saved(harness, model).node(id))
        XCTAssertTrue(node.isSticky, "an empty sticky note stays")
        XCTAssertEqual(node.color, "3")
        XCTAssertEqual(node.styleAttribute("sticky"), .bool(true))
        XCTAssertFalse(node.isFreeText)
    }

    // MARK: Export

    func testExportsAPictureAndSlides() async throws {
        var board = CanvasDocument(nodes: [
            CanvasNode(id: "t", kind: .text, x: 0, y: 0, width: 260, height: 80, text: "Hello"),
        ])
        board.addFrame(CanvasRect(x: -100, y: -100, width: 640, height: 360))
        let harness = try harness(board)
        defer { harness.close() }
        let png = try await harness.run("canvas.export", ["path": "Boards/White.canvas"])
        XCTAssertEqual(png, "Boards/White.png")
        let image = try XCTUnwrap(NSImage(data: try Data(contentsOf: harness.vault.rootURL.appendingPathComponent(png))))
        XCTAssertEqual(image.size.width, 640 + BoardExport.margin * 2, accuracy: 1)
        let pdf = try await harness.run("canvas.export", ["path": "Boards/White.canvas", "slides": "true"])
        XCTAssertEqual(pdf, "Boards/White slides.pdf")
        let document = try XCTUnwrap(PDFDocument(url: harness.vault.rootURL.appendingPathComponent(pdf)))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 640, accuracy: 1)
    }

    func testStartersOfAnEmptyBoard() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let kanban = model.addKanban(at: CanvasPoint(x: 0, y: 0))
        XCTAssertEqual(kanban.count, 4)
        XCTAssertEqual(model.document.nodes.filter { $0.kind == .group }.map(\.label), ["To do", "Doing", "Done"])
        let group = try XCTUnwrap(model.node(kanban[0])), sticky = try XCTUnwrap(model.node(kanban[3]))
        XCTAssertTrue(group.frame.contains(sticky.frame), "the first task is in To do")
        let stickies = model.addStickies(at: CanvasPoint(x: 0, y: 2000))
        XCTAssertEqual(stickies.count, 3)
        XCTAssertEqual(model.editing?.target, .node(stickies[0]), "the first is being written")
        model.commitEditing()
        XCTAssertNotNil(model.node(stickies[0]))
        _ = harness.render(AnyView(BoardEmptyState(model: model)), size: CGSize(width: 900, height: 600))
    }

    /// Narrow, the empty state keeps within the board: the starters become a list, the keys go on several lines.
    func testTheEmptyStateFitsANarrowBoard() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        for width in [300.0, 460.0, 900.0] {
            let host = NSHostingController(rootView: BoardEmptyState(model: model)
                .environment(\.themeTokens, .standard).fixedSize(horizontal: false, vertical: true))
            let size = host.sizeThatFits(in: CGSize(width: width, height: 2000))
            XCTAssertLessThanOrEqual(size.width, width + 0.5, "no wider than a \(Int(width)) pt board")
            if let folder = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
                let view = harness.render(AnyView(BoardEmptyState(model: model).environment(\.themeTokens, .standard)
                    .frame(width: width).background(Color(white: 0.45))), size: CGSize(width: width, height: size.height))
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("empty-\(Int(width)).png"))
            }
        }
    }

    // MARK: Presenting

    /// A map made smaller by hand keeps its size when its view comes back (scrolled into view, presented), and
    /// grows at its scale; resized, it keeps its proportions.
    func testAMapResizedByHandKeepsItsSize() throws {
        let map = "---\nmindmap-plugin: basic\n---\n\n# Map\n\n- One\n- Two\n"
        let board = CanvasDocument(nodes: [
            CanvasNode(id: "a", kind: .file, x: 0, y: 0, width: 400, height: 300, file: "Boards/A.md"),
            CanvasNode(id: "b", kind: .file, x: 0, y: 500, width: 250, height: 100, file: "Boards/A.md"),
        ])
        let harness = try UIPluginHarness(logicPlugins: logicPlugins, uiPlugins: [CanvasUIPlugin.self, MindmapPlugin.self],
                                          files: ["Boards/White.canvas": board.text, "Boards/A.md": map])
        defer { harness.close() }
        let model = try model(harness)
        let content = CGRect(x: -30, y: -20, width: 300, height: 120)
        model.embedContentChanged("a", bounds: content)
        XCTAssertEqual(model.node("a")?.frame, CanvasRect(x: 0, y: 0, width: 300, height: 120), "a new card takes the map's size")

        model.beginResize(try XCTUnwrap(model.node("a")), handle: .right)
        model.updateResize(CGSize(width: -150, height: 0))
        model.endResize()
        XCTAssertEqual(model.node("a")?.frame, CanvasRect(x: 0, y: 30, width: 150, height: 60), "scaled as a whole")

        model.embedContentChanged("a", bounds: content)
        XCTAssertEqual(model.node("a")?.frame.width, 150, "shown again, the map keeps the size it was given")
        model.embedContentChanged("a", bounds: CGRect(x: -130, y: -20, width: 400, height: 120))
        XCTAssertEqual(model.node("a")?.frame, CanvasRect(x: -50, y: 30, width: 200, height: 60), "grows at its scale")

        // Seen for the first time (the board opened again), a card in the map's proportions was scaled by hand.
        model.embedContentChanged("b", bounds: content)
        XCTAssertEqual(model.node("b")?.frame, CanvasRect(x: 0, y: 500, width: 250, height: 100))
    }

    /// Changing slide does not fly across the board: the camera is on the new slide at once, which comes in from the
    /// side while the old one is pushed out; going back, the other way. Under Reduce Motion the old one fades.
    func testChangingSlidePushesTheOldOneOut() throws {
        var document = CanvasDocument()
        let first = document.addFrame(CanvasRect(x: 0, y: 0, width: 1280, height: 720))
        let second = document.addFrame(CanvasRect(x: 3000, y: 2000, width: 1280, height: 720))
        let harness = try harness(document)
        defer { harness.close() }
        let model = try model(harness)
        model.viewResized(CGSize(width: 1000, height: 700))
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        model.present()
        let slideScale = model.camera.scale
        model.nextSlide()
        let shown = model.camera.screenRect(CGRect(try XCTUnwrap(model.node(second)).frame))
        XCTAssertEqual(shown.midX, 500, accuracy: 1, "the camera is on the new slide at once")
        XCTAssertEqual(model.camera.scale, slideScale, accuracy: 0.001)
        XCTAssertEqual(model.presentShift, 1000, "the new slide starts a screen to the right")
        XCTAssertEqual(model.slideChange?.slide, first, "the old one is drawn where it was")
        XCTAssertEqual(model.slideChange?.screen.midX ?? 0, 500, accuracy: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(model.presentShift, 0, "then both move")
        XCTAssertNotEqual(model.slideChange?.shift, 0, "the old one too (or it is already gone)")

        model.previousSlide()
        XCTAssertEqual(model.presentShift, -1000, "going back, the slide comes from the left")
        XCTAssertEqual(model.slideChange?.slide, second)

        Motion.reduceMotionOverride = true
        model.nextSlide()
        XCTAssertEqual(model.presentShift, 0, "Reduce Motion: nothing moves")
        XCTAssertEqual(model.slideChange?.slide, first, "the old slide fades out over the new one")
        model.stopPresenting()
        XCTAssertNil(model.slideChange)
    }
}
