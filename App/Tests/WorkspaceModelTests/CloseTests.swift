import PluginKitUI
import WorkspaceModel
import XCTest

final class CloseTests: XCTestCase {
    func testClosingTheSelectedTabSelectsTheRightNeighbourElseTheLeft() {
        var layout = makeLayout()
        let a = layout.open(.file("a.md"), placement: .newTab)
        let b = layout.open(.file("b.md"), placement: .newTab)
        let c = layout.open(.file("c.md"), placement: .newTab)
        layout.select(b)
        layout.close(b)
        XCTAssertEqual(layout.activeTab?.id, c)
        layout.close(c)
        XCTAssertEqual(layout.activeTab?.id, a)
        assertValid(layout)
    }

    func testClosingAnUnselectedTabKeepsTheSelection() {
        var layout = makeLayout()
        let a = layout.open(.file("a.md"), placement: .newTab)
        let b = layout.open(.file("b.md"), placement: .newTab)
        layout.close(a)
        XCTAssertEqual(layout.activeTab?.id, b)
    }

    func testClosingTheLastTabLeavesOneEmptyPane() {
        var layout = makeLayout()
        let a = layout.open(.file("a.md"), placement: .newTab)
        layout.close(a)
        XCTAssertEqual(layout.picture, [[]])
        XCTAssertNil(layout.activeTab)
        assertValid(layout)
    }

    func testAnEmptiedPaneDisappearsAndTheSplitCollapses() {
        var layout = makeLayout()
        let a = layout.open(.file("a.md"), placement: .replace)
        layout.open(.file("b.md"), placement: .beside)
        layout.close(a)
        XCTAssertEqual(layout.picture, [["b.md"]])
        guard case .pane = layout.root else { return XCTFail("split did not collapse") }
        assertValid(layout)
    }

    func testFocusMovesToASiblingWhenTheFocusedPaneDisappears() {
        var layout = makeLayout()
        layout.open(.file("a.md"), placement: .replace)
        layout.open(.file("b.md"), placement: .beside)
        let c = layout.open(.file("c.md"), placement: .beside)
        layout.close(c)
        XCTAssertEqual(layout.selectedPath(layout.focused), "b.md")
        layout.focus(layout.panes[0].id)
        layout.close(layout.activeTab!.id)
        XCTAssertEqual(layout.selectedPath(layout.focused), "b.md")
        assertValid(layout)
    }

    func testCollapseFlattensASplitIntoItsParentOfTheSameAxis() {
        var layout = makeLayout()
        layout.open(.file("a.md"), placement: .replace)
        layout.open(.file("b.md"), placement: .beside)
        // H[a, V[b, H[c, d]]]
        let c = layout.drop(resource: .file("c.md"), on: layout.panes[1].id, edge: .bottom)
        layout.drop(resource: .file("d.md"), on: layout.pane(containing: c)!, edge: .trailing)
        XCTAssertEqual(layout.picture, [["a.md"], ["b.md"], ["c.md"], ["d.md"]])
        assertValid(layout)
        layout.close(layout.panes[1].tabs[0].id)
        // V collapses to H[c, d], which is flattened into the root: H[a, c, d].
        XCTAssertEqual(layout.picture, [["a.md"], ["c.md"], ["d.md"]])
        XCTAssertEqual(layout.rootSplit?.children.count, 3)
        assertFractions(layout.rootSplit?.fractions, [0.5, 0.25, 0.25])
        assertValid(layout)
    }

    func testCloseAllClosesMatchingTabsEverywhere() {
        var layout = makeLayout()
        layout.open(.file("Old/a.md"), placement: .newTab)
        layout.open(.file("b.md"), placement: .newTab)
        layout.open(.file("Old/c.md"), placement: .beside)
        layout.closeAll { $0.path.hasPrefix("Old/") }
        XCTAssertEqual(layout.picture, [["b.md"]])
        assertValid(layout)
    }

    func testSelectFocusesThePaneAndUnknownIdsAreIgnored() {
        var layout = makeLayout()
        let a = layout.open(.file("a.md"), placement: .replace)
        layout.open(.file("b.md"), placement: .beside)
        layout.select(a)
        XCTAssertEqual(layout.focusedPane, layout.panes[0].id)
        let before = layout
        layout.focus(PaneID(raw: UUID()))
        layout.select(TabID(raw: UUID()))
        layout.close(TabID(raw: UUID()))
        XCTAssertEqual(layout, before)
    }
}
