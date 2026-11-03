import BuiltinPlugins
import CanvasPlugin
import MindmapUI
import PluginKit
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import CanvasUI

@MainActor
final class CanvasUITests: XCTestCase {
    private let logicPlugins = builtinPlugins.filter { $0.manifest.id == "canvas" }

    private let board = CanvasDocument(
        nodes: [
            CanvasNode(id: "note", kind: .file, x: 0, y: 0, width: 400, height: 400, file: "Projects/Trip.md"),
            CanvasNode(id: "text", kind: .text, x: 500, y: 0, width: 260, height: 80, color: "3", text: "**Dates**"),
            CanvasNode(id: "group", kind: .group, x: -40, y: -40, width: 900, height: 500, label: "Plan"),
        ],
        edges: [CanvasEdge(id: "e", fromNode: "note", toNode: "text", label: "when")]
    ).text

    private func harness(files: [String: String] = [:]) throws -> UIPluginHarness {
        try UIPluginHarness(logicPlugins: logicPlugins, uiPlugins: [CanvasUIPlugin.self], files: [
            "Projects/Trip.md": "# Trip\n\n- Pack\n- Book the train\n", "Boards/Trip.canvas": board,
        ].merging(files) { $1 })
    }

    private func model(_ harness: UIPluginHarness, _ path: String = "Boards/Trip.canvas") throws -> BoardModel {
        let store = try XCTUnwrap(harness.kernel.services.service(CanvasUIPlugin.storeKey))
        return store.model(for: ViewContext(resource: .file(path)))
    }

    func testOpensCanvasFilesAndUnloadsCleanly() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("canvas-ui"), "\(harness.report)")
        XCTAssertEqual(harness.views.viewTypes(for: .file("Boards/Trip.canvas")).map(\.id), ["canvas.board"])
        XCTAssertTrue(harness.views.viewTypes(for: .file("Projects/Trip.md")).isEmpty)
        harness.host.deactivateAll()
        XCTAssertTrue(harness.views.all.isEmpty)
        XCTAssertNil(harness.kernel.commands.command(id: "canvas.new-board"))
    }

    func testDoesNotStartWithoutTheCanvasService() throws {
        let harness = try UIPluginHarness(uiPlugins: [CanvasUIPlugin.self])
        defer { harness.close() }
        XCTAssertFalse(harness.host.isActive("canvas-ui"))
    }

    func testNewBoardCommandCreatesAndOpensABoard() async throws {
        let harness = try harness()
        defer { harness.close() }
        harness.workspace.activeResource = .file("Projects/Trip.md")
        let path = try await harness.run("canvas.new-board", ["title": "Ideas"])
        XCTAssertEqual(path, "Projects/Ideas.canvas")
        XCTAssertEqual(harness.workspace.opened.last?.resource, .file(path))
        XCTAssertEqual(try CanvasDocument(text: try harness.vault.read(path)), CanvasDocument())
    }

    func testEditsAreSavedAndUndone() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        XCTAssertEqual(model.document.nodes.count, 3)

        undo.beginUndoGrouping()
        let id = try XCTUnwrap(model.addText(at: CanvasPoint(x: 2000, y: 2000), text: "Hello", editNow: false))
        undo.endUndoGrouping()
        model.flush()
        let saved = try CanvasDocument(text: try harness.vault.read("Boards/Trip.canvas"))
        XCTAssertEqual(saved.node(id)?.text, "Hello")
        XCTAssertEqual(saved.node("note")?.file, "Projects/Trip.md", "the rest of the board is kept")

        undo.undo()
        model.flush()
        XCTAssertNil(try CanvasDocument(text: try harness.vault.read("Boards/Trip.canvas")).node(id))
    }

    func testMovingAGroupMovesItsCards() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.beginDrag(try XCTUnwrap(model.node("group")), extend: false)
        model.camera.scale = 1
        model.updateDrag(CGSize(width: 100, height: 50))
        XCTAssertEqual(model.frame(of: try XCTUnwrap(model.node("note"))).x, 100, "drawn moved while dragging")
        model.endDrag()
        XCTAssertEqual(model.node("note")?.x, 100)
        XCTAssertEqual(model.node("text")?.y, 50)
        XCTAssertEqual(model.node("group")?.x, 60)
    }

    func testDrawingAnArrowConnectsTwoCards() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.camera.scale = 1
        model.camera.offset = .zero
        model.beginLink(from: try XCTUnwrap(model.node("text")), side: .bottom)
        model.updateLink(to: CGPoint(x: 200, y: 395))
        XCTAssertEqual(model.link?.target, "note")
        model.endLink()
        let edge = try XCTUnwrap(model.document.edges.last)
        XCTAssertEqual([edge.fromNode, edge.toNode], ["text", "note"])
        XCTAssertEqual(edge.toSide, .bottom, "enters by the side nearest the pointer")
    }

    func testCopyPasteAndDelete() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.selection = ["note", "text"]
        let copied = try XCTUnwrap(model.copySelection())
        model.paste(copied, at: CanvasPoint(x: 3000, y: 3000))
        XCTAssertEqual(model.document.nodes.count, 5)
        XCTAssertEqual(model.document.edges.count, 2, "the arrow between the copied cards comes along")
        model.paste("https://jsoncanvas.org", at: CanvasPoint(x: -3000, y: 0))
        XCTAssertEqual(model.document.nodes.last?.url, "https://jsoncanvas.org")
        model.selection = ["note"]
        model.deleteSelection()
        XCTAssertNil(model.node("note"))
        XCTAssertFalse(model.document.edges.contains { $0.fromNode == "note" })
    }

    func testEditingATextCardAndEmptyingIt() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.beginEditing(.node("text"))
        model.editing?.draft = "**Dates**: May\nand June\nand July\nand August"
        model.commitEditing()
        XCTAssertEqual(model.node("text")?.text, "**Dates**: May\nand June\nand July\nand August")
        XCTAssertGreaterThan(model.node("text")?.height ?? 0, 80, "the card grows with its text")
        model.beginEditing(.node("text"))
        model.editing?.draft = "  "
        model.commitEditing()
        XCTAssertNil(model.node("text"), "an emptied card is removed")
    }

    private func freeBoard() -> String {
        CanvasDocument(nodes: [
            CanvasNode(id: "a", kind: .text, x: 0, y: 0, width: 200, height: 100, text: "A"),
            CanvasNode(id: "b", kind: .text, x: 400, y: 300, width: 200, height: 100, text: "B"),
            CanvasNode(id: "c", kind: .text, x: 800, y: 40, width: 200, height: 100, text: "C"),
        ], edges: [CanvasEdge(id: "e", fromNode: "a", toNode: "b")]).text
    }

    func testADraggedCardMovesFreelyWithoutGuides() throws {
        let harness = try harness(files: ["Boards/Free.canvas": freeBoard()])
        defer { harness.close() }
        let model = try model(harness, "Boards/Free.canvas")
        model.viewResized(CGSize(width: 1400, height: 900))
        model.camera.scale = 1
        model.camera.offset = .zero
        model.beginDrag(try XCTUnwrap(model.node("b")), extend: false)
        // 4 points from lining its left edge up with the card above it: it does not jump there.
        model.updateDrag(CGSize(width: -396, height: -258))
        XCTAssertEqual(model.dragDelta, CGSize(width: -396, height: -258), "the card follows the pointer exactly")
        model.endDrag()
        XCTAssertEqual(model.node("b")?.x, 4)
    }

    func testResizingFromAnyHandleAndKeepingTheRatio() throws {
        let harness = try harness(files: ["Boards/Free.canvas": freeBoard()])
        defer { harness.close() }
        let model = try model(harness, "Boards/Free.canvas")
        model.viewResized(CGSize(width: 1400, height: 900))
        model.camera.scale = 2
        model.camera.offset = .zero
        let card = try XCTUnwrap(model.node("b"))
        model.beginResize(card, handle: .topLeft)
        model.updateResize(CGSize(width: -40, height: -20))
        XCTAssertEqual(model.resizing?.frame, CanvasRect(x: 380, y: 290, width: 220, height: 110), "points are halved by the zoom")
        model.updateResize(CGSize(width: 2000, height: 2000))
        XCTAssertEqual(model.resizing?.frame.width, BoardStyle.minimumCard.width, "it stops at the smallest card")
        model.updateResize(CGSize(width: -100, height: 0), keepRatio: true)
        let kept = try XCTUnwrap(model.resizing).frame
        XCTAssertEqual(kept.width / kept.height, 2, accuracy: 0.05)
        model.endResize()
        XCTAssertEqual(model.node("b")?.frame.maxX, 600, "the opposite corner did not move")
        XCTAssertEqual(model.node("b")?.frame.maxY, 400)
    }

    func testTextSizeStepsFitsAndPersists() throws {
        let harness = try harness(files: ["Boards/Free.canvas": freeBoard()])
        defer { harness.close() }
        let model = try model(harness, "Boards/Free.canvas")
        model.selection = ["a", "c"]
        XCTAssertEqual(model.selectedFontSize, CanvasNode.defaultFontSize)
        model.stepFontSize(larger: true)
        XCTAssertEqual(model.node("a")?.fontSize, 20)
        XCTAssertEqual(model.selectedFontSize, 20)
        model.setFontSize(CanvasNode.defaultFontSize)
        XCTAssertNil(model.node("a")?.fontSize, "the default is not written")
        model.setFontSize(56)
        XCTAssertEqual(model.node("c")?.fontSize, 56)
        XCTAssertGreaterThan(model.node("c")?.height ?? 0, 100, "the card grows to hold the bigger text")
        model.flush()
        let saved = try CanvasDocument(text: try harness.vault.read("Boards/Free.canvas"))
        XCTAssertEqual(saved.node("c")?.fontSize, 56)
        model.fitToText()
        XCTAssertEqual(model.node("c")?.height, BoardText.height(of: "C", fontSize: 56, width: 200))
    }

    func testBiggerTextNeedsMoreRoom() {
        let small = BoardText.height(of: "One line", fontSize: 12, width: 300)
        let big = BoardText.height(of: "One line", fontSize: 40, width: 300)
        XCTAssertGreaterThan(big, small * 1.5)
        let long = String(repeating: "word ", count: 80)
        XCTAssertGreaterThan(BoardText.height(of: long, fontSize: 16, width: 200), BoardText.height(of: long, fontSize: 16, width: 600) * 2)
        XCTAssertGreaterThan(BoardText.height(of: "# Title\n\nBody", fontSize: 16, width: 300), BoardText.height(of: "Title\n\nBody", fontSize: 16, width: 300))
    }

    func testAligningAndStylingArrows() throws {
        let harness = try harness(files: ["Boards/Free.canvas": freeBoard()])
        defer { harness.close() }
        let model = try model(harness, "Boards/Free.canvas")
        model.selection = ["a", "b", "c"]
        model.align(.left)
        XCTAssertEqual(model.document.nodes.map(\.x), [0, 0, 0])
        model.distribute(.vertical)
        XCTAssertEqual(model.document.nodes.map(\.y), [0, 300, 150], "the middle card is spaced evenly")

        model.selection = []
        model.selectedEdge = "e"
        model.setEdgeShape(.straight)
        model.toggleEdgeDashed()
        model.setEdgeHeads(start: true, end: true)
        model.setColor("4")
        var edge = try XCTUnwrap(model.document.edge("e"))
        XCTAssertTrue(edge.isStraight)
        XCTAssertTrue(edge.isDashed)
        XCTAssertTrue(edge.startsWithArrow && edge.endsWithArrow)
        XCTAssertEqual(edge.color, "4")
        model.setEdgeShape(.curve)
        model.setEdgeHeads(start: false, end: false)
        edge = try XCTUnwrap(model.document.edge("e"))
        XCTAssertFalse(edge.isStraight)
        XCTAssertFalse(edge.startsWithArrow || edge.endsWithArrow)
        model.reverseEdge()
        XCTAssertEqual(model.document.edge("e")?.fromNode, "b")
    }

    func testMovingTheEndOfAnArrowToAnotherCard() throws {
        let harness = try harness(files: ["Boards/Free.canvas": freeBoard()])
        defer { harness.close() }
        let model = try model(harness, "Boards/Free.canvas")
        model.viewResized(CGSize(width: 1400, height: 900))
        model.camera.scale = 1
        model.camera.offset = .zero
        model.selectedEdge = "e"
        let edge = try XCTUnwrap(model.document.edge("e"))
        model.beginReconnect(edge, movesStart: false)
        model.updateLink(to: CGPoint(x: 900, y: 100))
        XCTAssertEqual(model.link?.target, "c")
        model.endLink()
        XCTAssertEqual(model.document.edge("e")?.toNode, "c")
        XCTAssertEqual(model.document.edge("e")?.fromNode, "a")
        // Dropped on nothing, an end stays where it was.
        model.beginReconnect(try XCTUnwrap(model.document.edge("e")), movesStart: true)
        model.updateLink(to: CGPoint(x: -900, y: -900))
        model.endLink()
        XCTAssertEqual(model.document.edge("e")?.fromNode, "a")
        XCTAssertEqual(model.document.edges.count, 1)
    }

    func testOptionDragMovesACopy() throws {
        let harness = try harness(files: ["Boards/Free.canvas": freeBoard()])
        defer { harness.close() }
        let model = try model(harness, "Boards/Free.canvas")
        model.camera.scale = 1
        model.beginDrag(try XCTUnwrap(model.node("a")), extend: false, duplicate: true)
        model.updateDrag(CGSize(width: 50, height: 0))
        model.endDrag()
        XCTAssertEqual(model.document.nodes.count, 4)
        XCTAssertEqual(model.node("a")?.x, 0, "the original stays")
        XCTAssertTrue(model.document.nodes.contains { $0.text == "A" && $0.x == 50 })
    }

    func testFilesFromTheVaultBecomeCardsOfTheRightSize() async throws {
        let harness = try harness(files: ["Boards/Free.canvas": freeBoard(), "Docs/Guide.pdf": "%PDF-1.4", "Docs/Clip.mp4": "x"])
        defer { harness.close() }
        let model = try model(harness, "Boards/Free.canvas")
        await model.addFiles([harness.vault.rootURL.appendingPathComponent("Docs/Guide.pdf"),
                              harness.vault.rootURL.appendingPathComponent("Docs/Clip.mp4")],
                             at: CanvasPoint(x: 0, y: 1000))
        let files = model.document.nodes.filter { $0.kind == .file }
        XCTAssertEqual(files.compactMap(\.file), ["Docs/Guide.pdf", "Docs/Clip.mp4"])
        XCTAssertEqual(files.first?.height, 520)
        XCTAssertEqual(files.last?.width, 480)
        XCTAssertEqual(model.selection.count, 2)
        XCTAssertEqual(CardFile.kind(of: "a.mov"), .video)
        XCTAssertEqual(CardFile.kind(of: "a.m4a"), .audio)
        XCTAssertTrue(CardFile.kind(of: "a.pdf").isLiveMediaKind)
    }

    func testADroppedFolderBringsItsFilesAndTextOrALinkBecomesACard() async throws {
        let harness = try harness(files: ["Boards/Free.canvas": freeBoard(), "Docs/Guide.pdf": "%PDF-1.4", "Docs/a.zip": "x",
                                          "Docs/Sub/deep.md": "# Deep"])
        defer { harness.close() }
        let model = try model(harness, "Boards/Free.canvas")
        await model.addFiles([harness.vault.rootURL.appendingPathComponent("Docs", isDirectory: true)], at: CanvasPoint(x: 0, y: 0))
        XCTAssertEqual(Set(model.document.nodes.compactMap(\.file)), ["Docs/Guide.pdf", "Docs/a.zip"], "any file, no subfolder")
        model.addFolder("Docs", at: CanvasPoint(x: 0, y: 2000))
        XCTAssertEqual(model.document.nodes.filter { $0.kind == .file }.count, 4)
        model.paste("https://jsoncanvas.org", at: CanvasPoint(x: 3000, y: 0))
        model.paste("Some text", at: CanvasPoint(x: 4000, y: 0))
        XCTAssertTrue(model.document.nodes.contains { $0.kind == .link && $0.url == "https://jsoncanvas.org" })
        XCTAssertTrue(model.document.nodes.contains { $0.kind == .text && $0.text == "Some text" })
    }

    func testAnEmptyGroupTakesTheCardsDraggedIntoIt() throws {
        let harness = try harness(files: ["Boards/Free.canvas": freeBoard()])
        defer { harness.close() }
        let model = try model(harness, "Boards/Free.canvas")
        model.selection = []
        model.groupSelection()
        let id = try XCTUnwrap(model.selection.first)
        let group = try XCTUnwrap(model.node(id))
        XCTAssertEqual(group.kind, .group)
        XCTAssertEqual(group.width, BoardModel.emptyGroupSize.width)
        let card = try XCTUnwrap(model.addText(at: CanvasPoint(x: group.frame.center.x, y: group.frame.center.y), text: "In", editNow: false))
        XCTAssertTrue(model.document.expandingGroups([id]).contains(card), "a card in its bounds moves with the group")
    }

    func testWebAddressesAreRecognised() {
        XCTAssertEqual(BoardActions.webAddress("jsoncanvas.org"), "https://jsoncanvas.org")
        XCTAssertEqual(BoardActions.webAddress(" http://localhost:3000/x "), "http://localhost:3000/x")
        XCTAssertNil(BoardActions.webAddress("not an address"))
        XCTAssertNil(BoardActions.webAddress("hello"))
        XCTAssertNil(BoardActions.webAddress("file:///etc/passwd"))
    }

    func testTheMinimapChoiceIsRemembered() throws {
        let harness = try harness()
        defer { harness.close() }
        let context = ViewContext(resource: .file("Boards/Trip.canvas"))
        let store = try XCTUnwrap(harness.kernel.services.service(CanvasUIPlugin.storeKey))
        let model = store.model(for: context)
        model.toggleMinimap()
        XCTAssertTrue(model.showsMinimap)
        let saved = try XCTUnwrap(context.state(BoardTabState.self))
        XCTAssertEqual(saved.minimap, true)
    }

    // MARK: Big boards

    private func bigModel(cards: Int = 1000) throws -> (UIPluginHarness, BoardModel) {
        let harness = try UIPluginHarness(logicPlugins: logicPlugins, uiPlugins: [CanvasUIPlugin.self],
                                          files: ["Boards/Big.canvas": CanvasPerformanceTests.bigBoard(cards: cards)])
        let model = try model(harness, "Boards/Big.canvas")
        model.viewResized(CGSize(width: 1500, height: 950))
        return (harness, model)
    }

    func testCardsShowTheirContentFromAboutAThirdOfTheZoom() {
        XCTAssertEqual(BoardModel.detailAlpha(0.1), 0)
        XCTAssertEqual(BoardModel.detailAlpha(BoardModel.farScale), 0)
        XCTAssertEqual(BoardModel.detailAlpha(0.35), 0.5, accuracy: 0.001, "half way between the two levels")
        XCTAssertEqual(BoardModel.detailAlpha(BoardModel.nearScale), 1)
        XCTAssertEqual(BoardModel.detailAlpha(2), 1)
        XCTAssertLessThanOrEqual(BoardModel.nearScale, 0.4, "real content from 40 % up")
        var previous = -1.0
        for scale in stride(from: 0.2, through: 0.5, by: 0.01) {
            let alpha = BoardModel.detailAlpha(CGFloat(scale))
            XCTAssertGreaterThanOrEqual(alpha, previous, "the cross-fade never goes back")
            previous = alpha
        }
    }

    func testAThousandCardsAreNotAThousandViews() throws {
        let (harness, model) = try bigModel()
        defer { harness.close() }
        model.fit(animated: false)
        XCTAssertLessThan(model.camera.scale, BoardModel.farScale, "the whole board is the far level")
        XCTAssertGreaterThan(model.visibleNodes().count, 900, "and it is all in view")

        model.camera.scale = 0.4
        model.camera.offset = CGSize(width: -1200, height: -400)
        let inView = model.visibleNodes().filter { $0.kind != .group }
        XCTAssertGreaterThan(inView.count, 100, "a dense board has far more cards in view than the budget")
        let views = model.viewCards(among: inView)
        XCTAssertEqual(views.count, BoardModel.viewBudget)
        let middle = CanvasPoint(model.camera.worldPoint(CGPoint(x: 750, y: 475)))
        let farthestView = views.map { ($0.frame.center - middle).length }.max() ?? 0
        let nearestOther = inView.filter { card in !views.contains { $0.id == card.id } }
            .map { ($0.frame.center - middle).length }.min() ?? .infinity
        XCTAssertLessThanOrEqual(farthestView, nearestOther, "the views are the cards nearest the middle")

        model.selection = [inView.last!.id]
        XCTAssertTrue(model.viewCards(among: inView).contains { $0.id == inView.last!.id }, "what is selected stays a view")
        XCTAssertEqual(model.viewCards(among: inView).count, BoardModel.viewBudget)
    }

    func testFarOutTheBoardAnswersClicksForTheCards() throws {
        let (harness, model) = try bigModel(cards: 200)
        defer { harness.close() }
        model.fit(animated: false)
        let card = try XCTUnwrap(model.node("n42"))
        let point = model.camera.screenPoint(CGPoint(x: card.frame.center.x, y: card.frame.center.y))
        XCTAssertEqual(model.card(atViewPoint: point)?.id, "n42")
        model.tapBackground(at: point, count: 1)
        XCTAssertEqual(model.selection, ["n42"])
        model.tapBackground(at: CGPoint(x: point.x + 1, y: point.y), count: 1, extend: true)
        XCTAssertEqual(model.selection, [], "extending a selection with the same card unselects it")
        model.tapBackground(at: CGPoint(x: -500, y: -500), count: 1)
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testACardPastTheViewBudgetAnswersClicksNearToo() throws {
        let (harness, model) = try bigModel()
        defer { harness.close() }
        model.camera.scale = 0.6
        model.camera.offset = CGSize(width: -1200, height: -400)
        let inView = model.visibleNodes().filter { $0.kind != .group }
        let views = Set(model.viewCards(among: inView).map(\.id))
        let drawn = try XCTUnwrap(inView.first { !views.contains($0.id) }, "a dense board draws some cards only")
        let point = model.camera.screenPoint(CGPoint(x: drawn.frame.center.x, y: drawn.frame.center.y))
        // Not a view, it gets no click of its own: the board answers for it rather than writing new text there.
        let count = model.document.nodes.count
        model.tapBackground(at: point, count: 2)
        XCTAssertEqual(model.selection, [drawn.id])
        XCTAssertEqual(model.document.nodes.count, count, "no new text")
        XCTAssertTrue(model.viewCards(among: inView).contains { $0.id == drawn.id }, "selected, it becomes a view")
    }

    func testArrowCurvesAreKeptUntilTheBoardChanges() throws {
        let (harness, model) = try bigModel(cards: 50)
        defer { harness.close() }
        let edge = try XCTUnwrap(model.document.edge("e1"))
        let first = try XCTUnwrap(model.curve(of: edge))
        model.camera.pan(by: CGSize(width: 300, height: 20))
        XCTAssertEqual(model.curve(of: edge), first, "panning does not move arrows")
        model.selection = ["n1"]
        model.nudge(50, 0)
        XCTAssertNotEqual(model.curve(of: edge), first, "an edit does")
        model.beginDrag(try XCTUnwrap(model.node("n0")), extend: false)
        model.updateDrag(CGSize(width: 40, height: 0))
        let during = try XCTUnwrap(model.curve(of: edge))
        XCTAssertNotEqual(during.start, try XCTUnwrap(model.curve(of: edge)).start - CanvasPoint(x: 1, y: 0), "a drag shows now")
        model.endDrag()
    }

    func testReloadsWhenTheFileChangesOutside() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        _ = try await harness.run("canvas.add-node", ["path": "Boards/Trip.canvas", "text": "From an agent"])
        XCTAssertTrue(model.document.nodes.contains { $0.text == "From an agent" })
    }

    func testABrokenBoardIsShownButNeverWritten() throws {
        let harness = try harness(files: ["Boards/Broken.canvas": "{ not json"])
        defer { harness.close() }
        let model = try model(harness, "Boards/Broken.canvas")
        XCTAssertFalse(model.isEditable)
        XCTAssertNil(model.addText(at: CanvasPoint(x: 0, y: 0), text: "x", editNow: false))
        model.flush()
        XCTAssertEqual(try harness.vault.read("Boards/Broken.canvas"), "{ not json")
    }

    func testTheBoardRendersAtEveryZoom() throws {
        let harness = try harness()
        defer { harness.close() }
        let type = try XCTUnwrap(harness.views.viewTypes(for: .file("Boards/Trip.canvas")).first)
        let context = ViewContext(resource: .file("Boards/Trip.canvas"))
        let view = harness.render(type.makeView(context), size: CGSize(width: 900, height: 600))
        XCTAssertGreaterThan(view.fittingSize.width, 0)
        let model = try model(harness)
        model.camera.scale = 0.2
        _ = harness.render(AnyView(BoardView(model: model)), size: CGSize(width: 900, height: 600))
    }

    func testAMindmapNoteIsALiveCardEnteredWithADoubleClick() throws {
        let map = "---\nmindmap-plugin: basic\n---\n\n# Ideas\n\n- One\n- Two\n"
        let board = CanvasDocument(nodes: [
            CanvasNode(id: "map", kind: .file, x: 0, y: 0, width: 500, height: 300, file: "Maps/Ideas.md"),
            CanvasNode(id: "note", kind: .file, x: 600, y: 0, width: 400, height: 400, file: "Projects/Trip.md"),
            CanvasNode(id: "inner", kind: .file, x: 0, y: 400, width: 300, height: 200, file: "Boards/Trip.canvas"),
        ]).text
        let harness = try UIPluginHarness(logicPlugins: logicPlugins, uiPlugins: [CanvasUIPlugin.self, MindmapPlugin.self],
                                          files: ["Maps/Ideas.md": map, "Projects/Trip.md": "# Trip\n",
                                                  "Boards/Outer.canvas": board, "Boards/Trip.canvas": self.board])
        defer { harness.close() }
        let model = try model(harness, "Boards/Outer.canvas")
        XCTAssertEqual(model.store.embeddedViewType(for: "Maps/Ideas.md")?.id, "mindmap.file")
        XCTAssertNil(model.store.embeddedViewType(for: "Projects/Trip.md"), "a plain note shows its preview")
        XCTAssertEqual(model.store.thumbnail("Boards/Trip.canvas")?.nodes.count, 3)

        let card = try XCTUnwrap(model.node("map"))
        let context = try XCTUnwrap(model.embedContext(for: card))
        XCTAssertEqual(context.presentation, .embedded)
        XCTAssertFalse(context.isActive)
        model.tap(card, count: 2, extend: false)
        XCTAssertEqual(model.activeEmbed, "map")
        XCTAssertTrue(context.isActive)
        XCTAssertTrue(harness.workspace.opened.isEmpty, "entered in place, not opened in a tab")
        model.tapBackground(at: CGPoint(x: -5000, y: -5000), count: 1)
        XCTAssertNil(model.activeEmbed)
        XCTAssertFalse(context.isActive)

        model.activate(try XCTUnwrap(model.node("inner")))
        XCTAssertEqual(harness.workspace.opened.last?.resource, .file("Boards/Trip.canvas"))
        XCTAssertEqual(harness.workspace.opened.last?.placement, .replace, "a board inside a board is entered")
        _ = harness.render(AnyView(BoardView(model: model)), size: CGSize(width: 1200, height: 800))
    }

    func testVisibleNodesAreCulled() throws {
        var nodes: [CanvasNode] = []
        for i in 0..<2000 {
            nodes.append(CanvasNode(id: "n\(i)", kind: .text, x: Double(i % 50) * 300, y: Double(i / 50) * 200,
                                    width: 260, height: 120, text: "Card \(i)"))
        }
        let harness = try harness(files: ["Boards/Big.canvas": CanvasDocument(nodes: nodes).text])
        defer { harness.close() }
        let model = try model(harness, "Boards/Big.canvas")
        model.viewResized(CGSize(width: 1000, height: 700))
        model.camera.scale = 1
        model.camera.offset = .zero
        let visible = model.visibleNodes()
        XCTAssertLessThan(visible.count, 60)
        XCTAssertTrue(visible.contains { $0.id == "n0" })
    }
}

/// Writes pictures of the demo board to `LOAM_SNAPSHOT_DIR` when it is set, to look at the board without the app.
@MainActor
final class CanvasSnapshotTests: XCTestCase {
    func testSnapshotsOfTheDemoBoard() throws {
        guard let folder = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] else { throw XCTSkip("no folder") }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../scripts/make-test-vault.sh").standardized
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/bin/bash")
        make.arguments = [script.path, vault.path]
        try make.run()
        make.waitUntilExit()
        var files: [String: String] = [:]
        for path in ["Boards/Demo.canvas", "Projects/Website redesign.md", "Areas/Health/Running.md",
                     "Projects/Reading list.md", "Maps/Trip ideas.md", "Boards/Big.canvas"] {
            files[path] = try String(contentsOf: vault.appendingPathComponent(path), encoding: .utf8)
        }
        let harness = try UIPluginHarness(logicPlugins: builtinPlugins.filter { $0.manifest.id == "canvas" },
                                          uiPlugins: [CanvasUIPlugin.self, MindmapPlugin.self], files: files)
        defer { harness.close() }
        let store = try XCTUnwrap(harness.kernel.services.service(CanvasUIPlugin.storeKey))
        let model = store.model(for: ViewContext(resource: .file("Boards/Demo.canvas")))
        let size = CGSize(width: 1400, height: 900)
        for (name, setup) in [
            ("fit", { (m: BoardModel) in m.fit(animated: false) }),
            ("selected", { (m: BoardModel) in m.fit(animated: false); m.selection = ["run"]; m.selectedEdge = nil }),
            ("far", { (m: BoardModel) in m.fit(animated: false); m.camera.zoom(by: 0.4) }),
        ] as [(String, (BoardModel) -> Void)] {
            model.viewResized(size)
            setup(model)
            let view = harness.render(AnyView(BoardView(model: model).environment(\.themeTokens, .standard)), size: size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("board-\(name).png"))
        }
    }

    /// A dense board at the levels of detail: all drawn in one pass far out, views near the middle at a middling zoom.
    func testSnapshotsOfABigBoardAtEveryLevelOfDetail() throws {
        guard let folder = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] else { throw XCTSkip("no folder") }
        let harness = try UIPluginHarness(logicPlugins: builtinPlugins.filter { $0.manifest.id == "canvas" },
                                          uiPlugins: [CanvasUIPlugin.self],
                                          files: ["Boards/Big.canvas": CanvasPerformanceTests.bigBoard(cards: 400)])
        defer { harness.close() }
        let store = try XCTUnwrap(harness.kernel.services.service(CanvasUIPlugin.storeKey))
        let model = store.model(for: ViewContext(resource: .file("Boards/Big.canvas")))
        let size = CGSize(width: 1500, height: 950)
        model.viewResized(size)
        for (name, scale) in [("fit", 0.0), ("20", 0.2), ("30", 0.3), ("35", 0.35), ("45", 0.45)] {
            model.fit(animated: false)
            if scale > 0 {
                model.camera.scale = scale
                model.camera.offset = CGSize(width: -1500 * scale, height: -400 * scale)
            }
            let view = harness.render(AnyView(BoardView(model: model).environment(\.themeTokens, .standard)), size: size)
            view.appearance = NSAppearance(named: .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("big-\(name).png"))
        }
    }

    /// The redesign board of ~/TestVault, in the states the redesign added: selection bar, arrows, minimap, hover.
    func testSnapshotsOfTheRedesignBoard() throws {
        guard let folder = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] else { throw XCTSkip("no folder") }
        let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("TestVault")
        guard let board = try? String(contentsOf: source.appendingPathComponent("Boards/Redesign.canvas"), encoding: .utf8)
        else { throw XCTSkip("no Redesign board") }
        var files = ["Boards/Redesign.canvas": board]
        for path in ["Projects/Refonte.md"] {
            files[path] = try String(contentsOf: source.appendingPathComponent(path), encoding: .utf8)
        }
        let harness = try UIPluginHarness(logicPlugins: builtinPlugins.filter { $0.manifest.id == "canvas" },
                                          uiPlugins: [CanvasUIPlugin.self], files: files)
        defer { harness.close() }
        for path in ["assets/chicken.webp", "assets/canvas-demo/Glass.aiff", "assets/canvas-demo/guide.pdf"] {
            let target = harness.vault.rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: source.appendingPathComponent(path), to: target)
        }
        let store = try XCTUnwrap(harness.kernel.services.service(CanvasUIPlugin.storeKey))
        let model = store.model(for: ViewContext(resource: .file("Boards/Redesign.canvas")))
        let size = CGSize(width: 1500, height: 950)
        model.viewResized(size)
        func shoot(_ name: String, _ setup: (BoardModel) -> Void) throws {
            model.selection = []
            model.selectedEdge = nil
            model.showsMinimap = false
            model.setHovered(nil)
            model.fit(animated: false)
            setup(model)
            let view = harness.render(AnyView(BoardView(model: model).environment(\.themeTokens, .standard)), size: size)
            view.appearance = NSAppearance(named: .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("redesign-\(name).png"))
        }
        try shoot("fit") { _ in }
        try shoot("text-selected") { $0.selection = ["t1"] }
        try shoot("two-selected") { $0.selection = ["t1", "t2", "n1"] }
        try shoot("edge-selected") { $0.selectedEdge = "e1" }
        try shoot("hover") { $0.setHovered("n1"); $0.hoverPoint = CGPoint(x: 80, y: 60) }
        try shoot("minimap") { $0.showsMinimap = true }
        try shoot("far") { $0.camera.zoom(by: 0.3) }
    }
}

/// How fluid a big board is: the time to draw a frame while panning and zooming a board of a thousand cards and as
/// many arrows, at three zoom levels. Each frame is a full software draw of the view (`cacheDisplay`), so the numbers
/// compare one build with another more than they predict the GPU.
@MainActor
final class CanvasPerformanceTests: XCTestCase {
    /// Progress lines, written at once to `LOAM_SNAPSHOT_DIR/perf-progress.txt` (a killed run loses buffered output).
    static func log(_ line: String) {
        guard let folder = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: folder + "/perf-progress.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? data.write(to: url) }
    }

    static func bigBoard(cards: Int) -> String {
        let columns = 40
        var nodes: [CanvasNode] = []
        for index in 0..<cards {
            nodes.append(CanvasNode(
                id: "n\(index)", kind: .text, x: Double(index % columns) * 320, y: Double(index / columns) * 220,
                width: 260, height: 120, color: index % 5 == 0 ? "\(index % 6 + 1)" : nil,
                text: "## Card \(index)\nSome text on card \(index)"
            ))
        }
        let edges = (1..<cards).map { CanvasEdge(id: "e\($0)", fromNode: "n\($0 - 1)", toNode: "n\($0)") }
        return CanvasDocument(nodes: nodes, edges: edges).text
    }

    /// Milliseconds per frame, sorted, for `frames` frames each preceded by `step`: the time SwiftUI needs to bring the
    /// view up to date (bodies, layout, layers: what blocks the main thread), and with `draws` the time of a full
    /// software draw on top, which only compares one build with another.
    private func measure(_ view: NSView, model: BoardModel, frames: Int, draws: Bool,
                         step: @MainActor (BoardModel, Int) -> Void) throws -> [Double] {
        var times: [Double] = []
        for frame in 0..<frames {
            Self.log("frame \(frame)")
            step(model, frame)
            let start = DispatchTime.now().uptimeNanoseconds
            CFRunLoopRunInMode(.defaultMode, 0, true)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            CATransaction.flush()
            if draws {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return times.sorted()
    }

    func testPanningAndZoomingABigBoard() throws {
        guard ProcessInfo.processInfo.environment["LOAM_PERF"] != nil else { throw XCTSkip("LOAM_PERF=1 runs the benchmark") }
        let cards = Int(ProcessInfo.processInfo.environment["LOAM_PERF_CARDS"] ?? "") ?? 1000
        let harness = try UIPluginHarness(logicPlugins: builtinPlugins.filter { $0.manifest.id == "canvas" },
                                          uiPlugins: [CanvasUIPlugin.self],
                                          files: ["Boards/Big.canvas": Self.bigBoard(cards: cards)])
        defer { harness.close() }
        let store = try XCTUnwrap(harness.kernel.services.service(CanvasUIPlugin.storeKey))
        let model = store.model(for: ViewContext(resource: .file("Boards/Big.canvas")))
        let size = CGSize(width: 1500, height: 950)
        model.viewResized(size)
        var report: [String] = []
        let view = harness.render(AnyView(BoardView(model: model).environment(\.themeTokens, .standard)), size: size)
        view.appearance = NSAppearance(named: .aqua)
        for (name, scale) in [("fit", 0.0), ("25%", 0.25), ("40%", 0.4), ("100%", 1.0)] {
            Self.log("level \(name)")
            model.fit(animated: false)
            if scale > 0 {
                model.camera.scale = scale
                model.camera.offset = CGSize(width: -3000 * scale, height: -1000 * scale)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            BoardProfile.isCounting = true
            BoardProfile.reset()
            let pan = try measure(view, model: model, frames: 24, draws: false) { m, _ in
                m.camera.pan(by: CGSize(width: -37, height: -11))
            }
            let panProfile = BoardProfile.summary
            BoardProfile.isCounting = false
            let zoom = try measure(view, model: model, frames: 24, draws: false) { m, frame in
                m.camera.zoom(by: frame % 2 == 0 ? 1.04 : 0.96)
            }
            let drawn = try measure(view, model: model, frames: 3, draws: true) { m, _ in
                m.camera.pan(by: CGSize(width: -37, height: -11))
            }
            let line = String(format: "PERF %@ cards=%d  update: pan %.1f ms (worst %.1f), zoom %.1f ms (worst %.1f)  software draw: %.0f ms",
                              name, cards, pan[pan.count / 2], pan.last!, zoom[zoom.count / 2], zoom.last!, drawn[drawn.count / 2])
            report.append(line)
            Self.log(line)
            Self.log("   pan profile: " + panProfile)
        }
        if let folder = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
            try report.joined(separator: "\n").write(toFile: folder + "/perf.txt", atomically: true, encoding: .utf8)
        }
    }
}
