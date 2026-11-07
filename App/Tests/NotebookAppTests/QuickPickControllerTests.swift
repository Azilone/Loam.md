import PluginKitUI
import XCTest
@testable import NotebookApp

@MainActor
final class QuickPickControllerTests: XCTestCase {
    private let fruits = ["Apple", "Banana", "Cherry", "Date"].map { QuickPickItem(id: $0.lowercased(), title: $0) }
    private var chosen: [String] = []

    private func show(_ controller: QuickPickController) {
        let fruits = fruits
        controller.show(
            placeholder: "Pick a fruit",
            items: { query in Fuzzy.rank(fruits, query: query, key: \.title) },
            choose: { [weak self] item in self?.chosen.append(item.id) }
        )
    }

    func testASlowProviderIsAskedOffTheMainThreadAndOnlyTheLastQueryLands() async {
        let controller = QuickPickController()
        let fruits = fruits
        controller.showSearching(
            placeholder: "Search",
            items: { query in
                XCTAssertFalse(Thread.isMainThread)
                return Fuzzy.rank(fruits, query: query, key: \.title)
            },
            choose: { _ in }
        )
        await controller.settle()
        XCTAssertEqual(controller.results.count, 4)
        controller.query = "ch"
        controller.query = "an"
        XCTAssertEqual(controller.results.count, 4, "typing never waits for the rows")
        await controller.settle()
        XCTAssertEqual(controller.results.map(\.id), ["banana"])
    }

    func testShowListsEverythingAndFiltersOnQuery() {
        let controller = QuickPickController()
        XCTAssertFalse(controller.isPresented)
        show(controller)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.placeholder, "Pick a fruit")
        XCTAssertEqual(controller.results.map(\.id), ["apple", "banana", "cherry", "date"])
        controller.move(2)
        controller.query = "an"
        XCTAssertEqual(controller.results.map(\.id), ["banana"])
        XCTAssertEqual(controller.selectedIndex, 0, "a new query selects the first row")
        controller.query = "zzz"
        XCTAssertTrue(controller.results.isEmpty)
        controller.move(1)
        controller.chooseSelected()
        XCTAssertTrue(chosen.isEmpty)
        XCTAssertTrue(controller.isPresented)
    }

    func testResultsAreCapped() {
        let controller = QuickPickController()
        let many = (0..<500).map { QuickPickItem(id: "\($0)", title: "Item \($0)") }
        controller.show(placeholder: "", items: { _ in many }, choose: { _ in })
        XCTAssertEqual(controller.results.count, QuickPickController.maxResults)
    }

    func testMoveWrapsAround() {
        let controller = QuickPickController()
        show(controller)
        controller.move(-1)
        XCTAssertEqual(controller.selectedIndex, 3)
        controller.move(1)
        XCTAssertEqual(controller.selectedIndex, 0)
        controller.move(6)
        XCTAssertEqual(controller.selectedIndex, 2)
    }

    func testChooseCallsBackOnceAndDismisses() {
        let controller = QuickPickController()
        show(controller)
        controller.move(1)
        controller.chooseSelected()
        XCTAssertEqual(chosen, ["banana"])
        XCTAssertFalse(controller.isPresented)
        // The rows stay for the popup's exit; nothing can be chosen from them any more.
        controller.chooseSelected()
        controller.choose(at: 0)
        XCTAssertEqual(chosen, ["banana"], "nothing more once dismissed")

        show(controller)
        controller.choose(at: 2)
        XCTAssertEqual(chosen, ["banana", "cherry"])
    }

    func testDismissNeverChooses() {
        let controller = QuickPickController()
        show(controller)
        controller.query = "ch"
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(controller.query, "")
        XCTAssertTrue(chosen.isEmpty)
    }

    func testShowAgainReplacesTheRequestAndClearsTheQuery() {
        let controller = QuickPickController()
        show(controller)
        controller.query = "dat"
        let first = controller.presentation
        var other: [String] = []
        controller.show(
            placeholder: "Other",
            items: { _ in [QuickPickItem(id: "x", title: "X")] },
            choose: { other.append($0.id) }
        )
        XCTAssertNotEqual(controller.presentation, first)
        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(controller.results.map(\.id), ["x"])
        controller.chooseSelected()
        XCTAssertEqual(other, ["x"])
        XCTAssertTrue(chosen.isEmpty)
    }
}
