import PluginKitUI
import PluginKitUITesting
import XCTest

@MainActor
final class FakesTests: XCTestCase {
    func testTheQuickPickFakeQueriesAndChooses() {
        let pick = RecordingQuickPick()
        let notes = ["Daily notes", "Random", "Recipes"]
        var chosen: [String] = []
        pick.show(
            placeholder: "Open a note",
            items: { query in Fuzzy.rank(notes, query: query) { $0 }.map { QuickPickItem(id: $0, title: $0) } },
            choose: { chosen.append($0.id) }
        )
        XCTAssertEqual(pick.placeholder, "Open a note")
        XCTAssertEqual(pick.query("rec").map(\.id), ["Recipes"])
        XCTAssertFalse(pick.choose(id: "Random"), "not listed for the last query")
        XCTAssertTrue(pick.choose(id: "Recipes"))
        XCTAssertEqual(chosen, ["Recipes"])
    }

    func testTheEditorFakeRecordsInsertions() {
        let editor = RecordingEditor()
        XCTAssertTrue(editor.insertAtCaret("hello"))
        editor.hasFocusedNote = false
        XCTAssertFalse(editor.insertAtCaret("lost"))
        XCTAssertEqual(editor.inserted, ["hello"])
    }
}
