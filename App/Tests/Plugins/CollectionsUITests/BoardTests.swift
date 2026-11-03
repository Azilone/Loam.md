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
}

/// A card's checklist: the task lines of its note, outside the frontmatter and fenced code.
final class BoardChecklistTests: XCTestCase {
    func testCountsTheTaskLinesOfTheNote() {
        let text = "---\na: - [ ] no\n---\n- [x] Done\n- [ ] Open\n  * [X] Nested\n```\n- [ ] code\n```\n- [ ]\n"
        XCTAssertEqual(BoardChecklists.count(text), BoardChecklist(done: 2, total: 3))
        XCTAssertNil(BoardChecklists.count("Just text.\n"))
    }
}
