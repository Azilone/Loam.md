import BuiltinPlugins
import CollectionCardsUI
import CollectionTableUI
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import CollectionKanbanUI
@testable import CollectionsUI

/// The board's order and drag numbers: which index a card lands at, how the order is kept in the view, and that the
/// notes of the other cards stay as they were.
@MainActor
final class BoardTests: XCTestCase {
    private let logicPlugins = builtinPlugins.filter { ["note-graph", "note-query", "collections", "files"].contains($0.manifest.id) }

    private let base = """
    filters:
      and:
        - file.inFolder("Board")
        - file.ext == "md"
    properties:
      status:
        type: select
        options: [To do, Doing, Done]
    views:
      - type: kanban
        name: Board
        groupBy: {property: status, direction: ASC}
        order: [file.name, status]

    """

    private var files: [String: String] {
        [
            "Board/Board.base": base,
            "Board/Alpha.md": "---\nstatus: To do\n---\nalpha\n",
            "Board/Bravo.md": "---\nstatus: To do\n---\nbravo\n",
            "Board/Charlie.md": "---\nstatus: To do\n---\ncharlie\n",
            "Board/Delta.md": "---\nstatus: Doing\n---\ndelta\n",
        ]
    }

    private func model() throws -> (UIPluginHarness, CollectionViewModel) {
        let harness = try UIPluginHarness(
            logicPlugins: logicPlugins,
            uiPlugins: [CollectionsUIPlugin.self, CollectionTableUIPlugin.self, CollectionKanbanUIPlugin.self, CollectionCardsUIPlugin.self],
            files: files)
        let store = try XCTUnwrap(harness.kernel.services.service(CollectionsUIPlugin.storeKey))
        let model = store.model(for: ViewContext(resource: .folder("Board")))
        model.viewName = "Board"
        return (harness, model)
    }

    private func titles(_ model: CollectionViewModel) -> [[String]] {
        model.groups?.map { $0.entries.map(\.title) } ?? []
    }

    // MARK: Order

    func testWithoutAManualOrderTheCardsKeepTheViewsOrder() throws {
        let (harness, model) = try model()
        defer { harness.close() }
        XCTAssertEqual(titles(model), [["Alpha", "Bravo", "Charlie"], ["Delta"], []])
        XCTAssertEqual(model.manualOrder, [])
    }

    func testMovingACardInsideItsColumnOrdersItWithoutTouchingTheNotes() throws {
        let (harness, model) = try model()
        defer { harness.close() }
        model.moveEntry("Board/Charlie.md", to: .string("To do"), in: PropertyRef("status"), at: 0)
        XCTAssertEqual(titles(model), [["Charlie", "Alpha", "Bravo"], ["Delta"], []])
        for (path, text) in files where path.hasSuffix(".md") {
            XCTAssertEqual(try harness.vault.read(path), text, "\(path) is as it was")
        }
        XCTAssertTrue(try harness.vault.read("Board/Board.base").contains(CollectionViewModel.manualOrderKey))

        model.moveEntry("Board/Charlie.md", to: .string("To do"), in: PropertyRef("status"), at: 2)
        XCTAssertEqual(titles(model), [["Alpha", "Bravo", "Charlie"], ["Delta"], []])
    }

    func testTheOrderSurvivesAReload() throws {
        let (harness, model) = try model()
        defer { harness.close() }
        model.moveEntry("Board/Bravo.md", to: .string("To do"), in: PropertyRef("status"), at: 2)
        model.reload()
        XCTAssertEqual(titles(model), [["Alpha", "Charlie", "Bravo"], ["Delta"], []])
        let services = harness.kernel.services
        let reopened = CollectionViewModel(
            source: .file("Board/Board.base"), collections: { services.service(.collections) },
            noteQuery: { services.service(.noteQuery) }, workspace: { nil })
        reopened.viewName = "Board"
        XCTAssertEqual(titles(reopened), [["Alpha", "Charlie", "Bravo"], ["Delta"], []])
    }

    func testDroppingOnAnotherColumnWritesTheFieldAndTheIndex() throws {
        let (harness, model) = try model()
        defer { harness.close() }
        model.moveEntry("Board/Bravo.md", to: .string("Doing"), in: PropertyRef("status"), at: 0)
        XCTAssertEqual(titles(model), [["Alpha", "Charlie"], ["Bravo", "Delta"], []])
        XCTAssertEqual(try harness.vault.read("Board/Bravo.md"), "---\nstatus: Doing\n---\nbravo\n")
        XCTAssertEqual(try harness.vault.read("Board/Alpha.md"), files["Board/Alpha.md"])

        model.moveEntry("Board/Alpha.md", to: .string("Done"), in: PropertyRef("status"), at: 5)
        XCTAssertEqual(titles(model), [["Charlie"], ["Bravo", "Delta"], ["Alpha"]])
    }

    func testMovingAColumnReordersTheFieldsOptionsWithoutTouchingTheNotes() throws {
        let (harness, model) = try model()
        defer { harness.close() }
        model.reorderColumns(["Done", "To do", "Doing"], of: PropertyRef("status"))
        XCTAssertEqual(model.groups?.map(\.value), [.string("Done"), .string("To do"), .string("Doing")])
        XCTAssertEqual(titles(model), [[], ["Alpha", "Bravo", "Charlie"], ["Delta"]])
        XCTAssertEqual(model.property(PropertyRef("status")).options, ["Done", "To do", "Doing"])
        for (path, text) in files where path.hasSuffix(".md") {
            XCTAssertEqual(try harness.vault.read(path), text, "\(path) is as it was")
        }
    }

    func testDroppingOnTheColumnWithoutAValueRemovesTheField() throws {
        let (harness, model) = try model()
        defer { harness.close() }
        model.moveEntry("Board/Delta.md", to: nil, in: PropertyRef("status"), at: 0)
        XCTAssertEqual(model.groups?.last?.entries.map(\.title), ["Delta"])
        XCTAssertFalse(try harness.vault.read("Board/Delta.md").contains("status"))
    }

    func testANewCardGoesAfterTheOthersOnceTheOrderIsManual() throws {
        let (harness, model) = try model()
        defer { harness.close() }
        model.moveEntry("Board/Charlie.md", to: .string("To do"), in: PropertyRef("status"), at: 0)
        let path = try XCTUnwrap(model.newEntry(title: "Aaron", values: ["status": .string("To do")]))
        XCTAssertEqual(titles(model)[0], ["Charlie", "Alpha", "Bravo", "Aaron"], "unlisted cards come after the placed ones")
        model.moveEntry(path, to: .string("To do"), in: PropertyRef("status"), at: .max)
        XCTAssertEqual(titles(model)[0], ["Charlie", "Alpha", "Bravo", "Aaron"])
    }

    func testTheSearchDoesNotChangeWhereACardLands() throws {
        let (harness, model) = try model()
        defer { harness.close() }
        model.searchText = "charlie"
        model.moveEntry("Board/Charlie.md", to: .string("To do"), in: PropertyRef("status"), at: 0)
        model.searchText = ""
        XCTAssertEqual(titles(model)[0], ["Charlie", "Alpha", "Bravo"])
    }

    func testManualOrderListsEveryCardAndForgetsTheOnesThatLeft() {
        let order = ManualOrder.inserting(
            "c", at: 0, into: ["a", "b"], of: ["a", "b", "gone", "c", "d"], known: ["a", "b", "c", "d"])
        XCTAssertEqual(order, ["c", "a", "b", "d"])
        XCTAssertEqual(
            ManualOrder.inserting("c", at: 9, into: ["d"], of: ["c", "d", "e"], known: ["c", "d", "e"]), ["d", "c", "e"],
            "after the column's last card, before the next column's")
        XCTAssertEqual(ManualOrder.inserting("c", at: 0, into: [], of: ["a", "c"], known: ["a", "c"]), ["a", "c"])
    }

    // MARK: Reading off the main thread

    func testAMoveShowsAtOnceAndTheReadAfterItAgrees() async throws {
        let (harness, model) = try model()
        defer { harness.close() }
        model.moveEntry("Board/Bravo.md", to: .string("Doing"), in: PropertyRef("status"), at: 1)
        let shown = titles(model)
        XCTAssertEqual(shown, [["Alpha", "Charlie"], ["Delta", "Bravo"], []])
        XCTAssertEqual(model.value(PropertyRef("status"), of: try XCTUnwrap(model.entries.first { $0.title == "Bravo" })), .string("Doing"))
        await model.settled()
        XCTAssertEqual(titles(model), shown, "the collection read again gives what the move showed")
    }

    func testAChangeOnDiskIsReadInTheBackground() async throws {
        let harness = try UIPluginHarness(
            logicPlugins: logicPlugins,
            uiPlugins: [CollectionsUIPlugin.self, CollectionTableUIPlugin.self, CollectionKanbanUIPlugin.self, CollectionCardsUIPlugin.self],
            files: files)
        defer { harness.close() }
        let store = try XCTUnwrap(harness.kernel.services.service(CollectionsUIPlugin.storeKey))
        // The store follows the models of the pages alive: the page's context is held here.
        let context = ViewContext(resource: .folder("Board"))
        let model = store.model(for: context)
        model.viewName = "Board"
        try harness.vault.write("Board/Delta.md", "---\nstatus: Done\n---\ndelta\n")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .modified, path: "Board/Delta.md")]))
        await Task.yield()
        await model.settled()
        XCTAssertEqual(titles(model), [["Alpha", "Bravo", "Charlie"], [], ["Delta"]])
        withExtendedLifetime(context) {}
    }

    func testOnlyTheChangesUnderItsFolderReloadACollection() throws {
        let (harness, model) = try model()
        defer { harness.close() }
        XCTAssertTrue(model.isAffected(by: [VaultChange(kind: .modified, path: "Board/Alpha.md")]))
        XCTAssertTrue(model.isAffected(by: [VaultChange(kind: .added, path: "Board/New.md")]))
        XCTAssertTrue(model.isAffected(by: [VaultChange(kind: .modified, path: "Board/Board.base")]))
        XCTAssertFalse(model.isAffected(by: [VaultChange(kind: .modified, path: "Elsewhere/Note.md")]))
        XCTAssertFalse(model.isAffected(by: [VaultChange(kind: .modified, path: "Board/picture.png")]))
        XCTAssertFalse(model.isAffected(by: [VaultChange(kind: .modified, path: "Other.base")]))
    }

    // MARK: The AppKit board

    private func board(_ model: CollectionViewModel) -> BoardScrollView {
        let board = BoardScrollView(model: model, services: BoardServices(trash: { $0 }, restore: { $0 }, report: { _ in }))
        board.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        board.hostEnvironmentChanged(NativeViewEnvironment(theme: .standard))
        board.layoutSubtreeIfNeeded()
        board.document.viewportChanged()
        return board
    }

    func testTheBoardIsAppKitWithAColumnPerValueAndItsCards() throws {
        let (harness, model) = try model()
        defer { harness.close() }
        let views = try XCTUnwrap(harness.kernel.services.service(.collectionViews))
        XCTAssertNotNil(views.type("kanban")?.makeNSView, "AppKit, no SwiftUI twin")
        let board = board(model)
        XCTAssertEqual(board.document.columns.map(\.name), ["To do", "Doing", "Done"])
        XCTAssertEqual(board.document.lists, [["Board/Alpha.md", "Board/Bravo.md", "Board/Charlie.md"], ["Board/Delta.md"], []])
        XCTAssertEqual(Set(board.document.live.keys), ["Board/Alpha.md", "Board/Bravo.md", "Board/Charlie.md", "Board/Delta.md"])
        XCTAssertTrue(board.document.live.values.allSatisfy { $0.superview === board.document })
        let alpha = try XCTUnwrap(board.document.placement.frame(of: "Board/Alpha.md"))
        let bravo = try XCTUnwrap(board.document.placement.frame(of: "Board/Bravo.md"))
        XCTAssertEqual(bravo.minY, alpha.maxY + BoardMetrics.itemSpacing, "stacked in their column")
        XCTAssertEqual(board.document.placement.frame(of: "Board/Delta.md")?.minX, BoardMetrics.columnX(1) + BoardMetrics.padding)
    }

    func testTheBoardFollowsAMove() async throws {
        let (harness, model) = try model()
        defer { harness.close() }
        let board = board(model)
        model.moveEntry("Board/Alpha.md", to: .string("Done"), in: PropertyRef("status"), at: 0)
        board.refresh()
        XCTAssertEqual(board.document.lists, [["Board/Bravo.md", "Board/Charlie.md"], ["Board/Delta.md"], ["Board/Alpha.md"]])
        XCTAssertEqual(board.document.placement.frame(of: "Board/Alpha.md")?.minX, BoardMetrics.columnX(2) + BoardMetrics.padding)
    }

    func testABoardInANoteIsAsTallAsItsColumns() throws {
        let (harness, model) = try model()
        defer { harness.close() }
        let board = board(model)
        // Not embedded: it fills its page.
        XCTAssertNil(board.fittingSize(width: 700, maxHeight: nil))
        XCTAssertEqual(board.document.contentHeight, BoardMetrics.minColumnHeight + BoardMetrics.bottom, "a short board takes a column's least height")
    }

    func testTheColumnsAndTheirCardsArePlacedSideBySide() {
        let placement = BoardPlacement.place(lists: [["a", "b"], []], height: { $0 == "a" ? 100 : 60 }, fieldColumn: 1)
        XCTAssertEqual(placement.columns.count, 2)
        let top = BoardMetrics.padding + BoardMetrics.headerHeight + BoardMetrics.itemSpacing
        XCTAssertEqual(placement.frame(of: "a"), CGRect(x: BoardMetrics.padding, y: top, width: BoardMetrics.cardWidth, height: 100))
        XCTAssertEqual(placement.frame(of: "b")?.minY, top + 100 + BoardMetrics.itemSpacing)
        XCTAssertEqual(placement.columns[1].field?.minY, top, "the inline field where the first card would go")
        XCTAssertEqual(placement.columns[1].plus.minY, top + BoardMetrics.fieldHeight + BoardMetrics.itemSpacing)
        XCTAssertNil(placement.columns[0].field)
        XCTAssertEqual(placement.addColumn.minX, BoardMetrics.columnX(2))
    }

    // MARK: Drag numbers

    func testTheInsertionIndexFollowsTheMiddlesOfTheOtherCards() {
        let heights: [CGFloat] = [100, 60, 100]
        let top: CGFloat = 40
        // Middles of the packed cards: 90, 178, 266.
        func index(_ y: CGFloat) -> Int { BoardDragMath.insertionIndex(y: y, top: top, heights: heights) }
        XCTAssertEqual(index(-50), 0)
        XCTAssertEqual(index(89), 0)
        XCTAssertEqual(index(91), 1)
        XCTAssertEqual(index(177), 1)
        XCTAssertEqual(index(179), 2)
        XCTAssertEqual(index(265), 2)
        XCTAssertEqual(index(267), 3)
        XCTAssertEqual(index(900), 3)
        XCTAssertEqual(BoardDragMath.insertionIndex(y: 500, top: top, heights: []), 0, "an empty column")
    }

    func testTheColumnUnderTheCardIsClamped() {
        let width = BoardMetrics.column + BoardMetrics.spacing
        XCTAssertEqual(BoardDragMath.column(at: -300, count: 3), 0)
        XCTAssertEqual(BoardDragMath.column(at: 10, count: 3), 0)
        XCTAssertEqual(BoardDragMath.column(at: width + 1, count: 3), 1)
        XCTAssertEqual(BoardDragMath.column(at: 2 * width + 100, count: 3), 2)
        XCTAssertEqual(BoardDragMath.column(at: 99 * width, count: 3), 2)
        XCTAssertEqual(BoardDragMath.column(at: 10, count: 0), 0)
    }

    func testTheBoardScrollsOnlyNearItsEdgesAndFasterTheCloserToThem() {
        func speed(_ x: CGFloat) -> CGFloat { BoardDragMath.autoScrollSpeed(pointerX: x, viewport: 800) }
        XCTAssertEqual(speed(400), 0)
        XCTAssertEqual(speed(120), 0)
        XCTAssertLessThan(speed(60), 0)
        XCTAssertLessThan(speed(10), speed(60), "faster to the left")
        XCTAssertEqual(speed(-200), speed(0), "no faster past the edge")
        XCTAssertGreaterThan(speed(760), 0)
        XCTAssertGreaterThan(speed(790), speed(760))
        XCTAssertEqual(BoardDragMath.autoScrollSpeed(pointerX: 5, viewport: 100), 0, "a viewport too narrow for two bands")
    }

    func testTheCardLeansIntoTheHandsMovementUpToAPoint() {
        XCTAssertEqual(BoardDragMath.tilt(velocity: 0), 0)
        XCTAssertGreaterThan(BoardDragMath.tilt(velocity: 300), 0)
        XCTAssertLessThan(BoardDragMath.tilt(velocity: -300), 0)
        XCTAssertEqual(BoardDragMath.tilt(velocity: 9000), 4)
        XCTAssertEqual(BoardDragMath.tilt(velocity: -9000), -4)
    }

    /// A theme change: the board gives its cards the new theme before it asks them to show, and the title must still
    /// take the new colour (it stayed in the old one: dark text on a dark card).
    func testACardsTitleTakesTheNewThemesColourWhenTheBoardSetsTheThemeFirst() {
        var light = ThemeTokens.standard
        light.text = Color(red: 0.1, green: 0.1, blue: 0.1)
        var dark = light
        dark.text = Color(red: 0.9, green: 0.9, blue: 0.9)
        let content = BoardCardContent(title: "Alpha", lines: [], checklist: nil)
        let card = BoardCardView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        card.show(path: "Board/Alpha.md", content: content, theme: light)
        card.theme = dark
        card.show(path: "Board/Alpha.md", content: content, theme: dark)
        let colour = card.title.attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(colour?.usingColorSpace(.sRGB)?.redComponent ?? 0, 0.9, accuracy: 0.02)
    }
}

/// A card's checklist: the task lines of its note, outside the frontmatter and fenced code.
final class BoardChecklistTests: XCTestCase {
    func testCountsTheTaskLinesOfTheNote() {
        let text = "---\na: - [ ] no\n---\n- [x] Done\n- [ ] Open\n  * [X] Nested\n```\n- [ ] code\n```\n- [ ]\n"
        XCTAssertEqual(BoardChecklists.count(text), BoardChecklist(done: 2, total: 3))
        XCTAssertNil(BoardChecklists.count("Just text.\n"))
    }
}
