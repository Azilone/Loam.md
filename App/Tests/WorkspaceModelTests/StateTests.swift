import Foundation
import PluginKitUI
import WorkspaceModel
import XCTest

final class StateTests: XCTestCase {
    func testSetFractionsNormalisesAndIgnoresBadInput() {
        var layout = makeLayout()
        layout.open(.file("a.md"), placement: .replace)
        layout.open(.file("b.md"), placement: .beside)
        let split = layout.rootSplit!.id
        layout.setFractions(split: split, [3, 1])
        assertFractions(layout.rootSplit?.fractions, [0.75, 0.25])
        layout.setFractions(split: split, [1, 1, 1])
        layout.setFractions(split: split, [1, 0])
        layout.setFractions(split: split, [1, -1])
        layout.setFractions(split: UUID(), [1, 1])
        assertFractions(layout.rootSplit?.fractions, [0.75, 0.25])
        assertValid(layout)
    }

    func testStateAndViewTypeArePerTab() {
        var layout = makeLayout()
        let a = layout.open(.file("a.md"), placement: .newTab)
        let b = layout.open(.file("b.md"), placement: .newTab)
        layout.setState(Data("caret:4".utf8), for: a)
        layout.setViewType("kanban.board", for: b)
        XCTAssertEqual(layout.panes[0].tabs[0].state, Data("caret:4".utf8))
        XCTAssertNil(layout.panes[0].tabs[0].viewType)
        XCTAssertEqual(layout.panes[0].tabs[1].viewType, "kanban.board")
        layout.setViewType(nil, for: b)
        XCTAssertNil(layout.panes[0].tabs[1].viewType)
    }

    func testRetargetFollowsMovedFilesAndFolders() {
        var layout = makeLayout()
        layout.open(.file("a.md"), placement: .newTab)
        layout.open(.file("Old/b.md"), placement: .newTab)
        layout.open(.folder("Old/Sub"), placement: .newTab)
        layout.open(.folder("Old"), placement: .newTab)
        layout.open(.virtual("a.md"), placement: .newTab)
        layout.open(.file("Older/c.md"), placement: .newTab)
        let state = Data([7])
        layout.setState(state, for: layout.panes[0].tabs[0].id)
        layout.retarget(["a.md": "Notes/a.md", "Old": "New"])
        XCTAssertEqual(layout.picture, [["Notes/a.md", "New/b.md", "New/Sub", "New", "a.md", "Older/c.md"]])
        XCTAssertEqual(layout.panes[0].tabs[0].state, state, "a move keeps the view's state")
        XCTAssertEqual(layout.panes[0].tabs[4].resource.kind, .virtual)
    }

    func testJSONRoundTripIsEqual() throws {
        var layout = makeLayout()
        let a = layout.open(.file("a.md"), placement: .newTab)
        layout.setState(Data([1, 2, 3]), for: a)
        layout.setViewType("text", for: a)
        layout.open(.virtual("calendar:2026-10"), placement: .beside)
        layout.drop(resource: .folder("Projects"), on: layout.focusedPane, edge: .bottom)
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        XCTAssertEqual(decoded, layout)
        assertValid(decoded)
        // A decoded layout still makes fresh ids.
        var copy = decoded
        copy.open(.file("z.md"), placement: .newTab)
        assertValid(copy)
    }

    func testValidateReportsABrokenLayout() throws {
        let pane = Pane(id: PaneID(raw: UUID()), tabs: [Tab(id: TabID(raw: UUID()), resource: .file("a.md"))])
        struct Raw: Encodable { let root: LayoutNode; let focusedPane: PaneID }
        let data = try JSONEncoder().encode(Raw(root: .pane(pane), focusedPane: pane.id))
        let layout = try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        XCTAssertThrowsError(try layout.validate()) { error in
            XCTAssertTrue("\(error)".contains("does not select"), "\(error)")
        }
    }
}
