import PluginKitUI
import WorkspaceModel
import XCTest

final class DropTests: XCTestCase {
    /// Two panes side by side: [a, b] and [c].
    private func twoPanes() -> WorkspaceLayout {
        var layout = makeLayout()
        layout.open(.file("a.md"), placement: .newTab)
        layout.open(.file("b.md"), placement: .newTab)
        layout.open(.file("c.md"), placement: .beside)
        return layout
    }

    func testDropOnCenterMovesTheTabSelectsAndFocuses() {
        var layout = twoPanes()
        let a = layout.panes[0].tabs[0].id
        layout.drop(tab: a, on: layout.panes[1].id, edge: .center)
        XCTAssertEqual(layout.picture, [["b.md"], ["c.md", "a.md"]])
        XCTAssertEqual(layout.activeTab?.id, a)
        XCTAssertEqual(layout.focusedPane, layout.panes[1].id)
        assertValid(layout)
    }

    func testDropOnAnEdgeSplitsThePane() {
        var layout = twoPanes()
        let a = layout.panes[0].tabs[0].id
        layout.drop(tab: a, on: layout.panes[1].id, edge: .top)
        XCTAssertEqual(layout.picture, [["b.md"], ["a.md"], ["c.md"]])
        guard case .split(_, .vertical, let children, let fractions) = layout.rootSplit?.children[1] else {
            return XCTFail("expected a vertical split on the right")
        }
        XCTAssertEqual(children.count, 2)
        assertFractions(fractions, [0.5, 0.5])
        XCTAssertEqual(layout.activeTab?.id, a)
        assertValid(layout)
    }

    func testDropOnAnEdgeOfTheParentsAxisAddsASibling() {
        var layout = twoPanes()
        layout.setFractions(split: layout.rootSplit!.id, [0.6, 0.4])
        let a = layout.panes[0].tabs[0].id
        layout.drop(tab: a, on: layout.panes[1].id, edge: .leading)
        XCTAssertEqual(layout.picture, [["b.md"], ["a.md"], ["c.md"]])
        XCTAssertEqual(layout.rootSplit?.children.count, 3)
        assertFractions(layout.rootSplit?.fractions, [0.6, 0.2, 0.2])
        assertValid(layout)
    }

    func testDropOnAnEdgeOfTheSourcePaneWithOtherTabs() {
        var layout = twoPanes()
        let b = layout.panes[0].tabs[1].id
        layout.drop(tab: b, on: layout.panes[0].id, edge: .bottom)
        XCTAssertEqual(layout.picture, [["a.md"], ["b.md"], ["c.md"]])
        XCTAssertEqual(layout.panes[0].selected, layout.panes[0].tabs[0].id)
        assertValid(layout)
    }

    func testDroppingTheOnlyTabOnItsOwnPaneDoesNothing() {
        let layout = twoPanes()
        let c = layout.panes[1].tabs[0].id
        for edge in [DropEdge.leading, .trailing, .top, .bottom, .center] {
            var copy = layout
            copy.drop(tab: c, on: layout.panes[1].id, edge: edge)
            XCTAssertEqual(copy, layout, "\(edge)")
        }
    }

    func testDroppingTheLastTabOfAPaneElsewhereRemovesThePane() {
        var layout = twoPanes()
        let c = layout.panes[1].tabs[0].id
        layout.drop(tab: c, on: layout.panes[0].id, edge: .top)
        XCTAssertEqual(layout.picture, [["c.md"], ["a.md", "b.md"]])
        XCTAssertEqual(layout.rootSplit?.axis, .vertical)
        assertValid(layout)
    }

    func testDropResourceOnAnEdgeOpensANewTabInANewPane() {
        var layout = makeLayout()
        layout.open(.file("a.md"), placement: .replace)
        let tab = layout.drop(resource: .virtual("calendar:2026-10"), on: layout.focusedPane, edge: .leading)
        XCTAssertEqual(layout.picture, [["calendar:2026-10"], ["a.md"]])
        XCTAssertEqual(layout.activeTab?.id, tab)
        assertValid(layout)
    }

    func testDropResourceOnTheCenterAppendsATab() {
        var layout = twoPanes()
        let tab = layout.drop(resource: .file("d.md"), on: layout.panes[0].id, edge: .center)
        XCTAssertEqual(layout.picture, [["a.md", "b.md", "d.md"], ["c.md"]])
        XCTAssertEqual(layout.activeTab?.id, tab)
        XCTAssertEqual(layout.focusedPane, layout.panes[0].id)
    }

    func testMoveTabBetweenPanesRemovesTheEmptiedPane() {
        var layout = twoPanes()
        let c = layout.panes[1].tabs[0].id
        layout.moveTab(c, to: layout.panes[0].id, at: 1)
        XCTAssertEqual(layout.picture, [["a.md", "c.md", "b.md"]])
        XCTAssertEqual(layout.activeTab?.id, c)
        assertValid(layout)
    }

    func testMoveTabReordersWithinAPaneAndClampsTheIndex() {
        var layout = twoPanes()
        let pane = layout.panes[0].id
        let a = layout.panes[0].tabs[0].id
        layout.moveTab(a, to: pane, at: 99)
        XCTAssertEqual(layout.picture, [["b.md", "a.md"], ["c.md"]])
        layout.moveTab(a, to: pane, at: -3)
        XCTAssertEqual(layout.picture, [["a.md", "b.md"], ["c.md"]])
        assertValid(layout)
    }
}
