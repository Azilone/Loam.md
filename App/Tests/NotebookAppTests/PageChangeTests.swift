@testable import NotebookApp
import PluginKitUI
import SwiftUI
import WorkspaceModel
import XCTest

/// Why a pane's page changed, which decides how it moves (`docs/design/MOTION.md`).
@MainActor
final class PageChangeTests: XCTestCase {
    private let card = OpenOrigin.frame(CGRect(x: 300, y: 200, width: 200, height: 120))
    private let pane = CGRect(x: 0, y: 0, width: 800, height: 600)

    private func key(_ workspace: WorkspaceController) throws -> PageKey {
        PageKey(try XCTUnwrap(workspace.layout.activeTab))
    }

    private func change(_ workspace: WorkspaceController) throws -> PageChange {
        workspace.pageChange(for: workspace.layout.focusedPane, showing: try key(workspace))
    }

    func testAResourceOpenedFromACardGrowsFromIt() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .replace, from: card)
        XCTAssertEqual(try change(workspace), .opened(card))
    }

    func testAResourceOpenedWithoutAnOriginReplacesThePageAtOnce() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .replace)
        XCTAssertEqual(try change(workspace), .replaced)
    }

    func testAReplacedPageDoesNotAnimate() {
        XCTAssertEqual(PageChange.replaced.arriving(in: pane), .instant)
        XCTAssertEqual(PageChange.replaced.leaving(in: pane), .instant)
    }

    func testBackShrinksToWhereThePageCameFrom() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .replace, from: card)
        let tab = try XCTUnwrap(workspace.layout.activeTab).id
        workspace.goBack(in: tab)
        XCTAssertEqual(workspace.activeResource, .file("a.md"))
        XCTAssertEqual(try change(workspace), .back(card))
    }

    func testBackWithoutAKnownOriginSwapsAtOnce() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .replace)
        workspace.goBack(in: try XCTUnwrap(workspace.layout.activeTab).id)
        XCTAssertEqual(try change(workspace), .replaced)
    }

    func testSelectingATabToTheRightComesFromTheRight() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .newTab)
        XCTAssertEqual(try change(workspace), .tab(direction: 1), "a new tab opens to the right of the selected one")
        let first = try XCTUnwrap(workspace.layout.panes[0].tabs.first).id
        workspace.select(first)
        XCTAssertEqual(try change(workspace), .tab(direction: -1))
        let second = try XCTUnwrap(workspace.layout.panes[0].tabs.last).id
        workspace.select(second)
        XCTAssertEqual(try change(workspace), .tab(direction: 1))
    }

    func testClosingTheSelectedTabHasNoDirection() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .newTab)
        workspace.close(try XCTUnwrap(workspace.layout.activeTab).id)
        XCTAssertEqual(try change(workspace), .closed)
    }

    func testAnOriginDoesNotMakeANewTabGrowFromTheCard() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .newTab, from: card)
        XCTAssertEqual(try change(workspace), .tab(direction: 1))
    }

    func testAnotherViewOfTheSameResourceSwapsInPlace() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        let tab = try XCTUnwrap(workspace.layout.activeTab).id
        workspace.setViewType("test.table", for: tab)
        XCTAssertEqual(try change(workspace), .swap)
    }

    func testAChangeIsOnlyKnownForThePageItWasMadeFor() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .replace, from: card)
        let pane = workspace.layout.focusedPane
        let other = PageKey(try XCTUnwrap(workspace.layout.activeTab).id, .file("zzz.md"))
        XCTAssertEqual(workspace.pageChange(for: pane, showing: other), .crossfade)
        XCTAssertEqual(workspace.pageChange(for: pane, showing: nil), .crossfade)
    }

    func testBesideOpensAPaneWithoutAPageChangeForTheNewOne() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .beside)
        XCTAssertEqual(workspace.layout.panes.count, 2)
        // The first pane keeps its page: nothing to animate there.
        let first = workspace.layout.panes[0]
        XCTAssertEqual(workspace.pageChange(for: first.id, showing: first.tabs.first.map(PageKey.init)), .crossfade)
    }

    // MARK: Poses

    func testAPageFromACardStartsALittleSmallerFromItsCentre() {
        let effect = PageChange.opened(card).arriving(in: pane)
        XCTAssertEqual(effect.scale, Motion.Metrics.pageOpenScale)
        XCTAssertEqual(effect.anchor, .center, "from the page's centre, not the card")
        XCTAssertEqual(PageChange.opened(card).leaving(in: pane), .identity, "the page under it stays still")
    }

    func testAPageFromASidebarComesFromItsEdge() {
        XCTAssertEqual(PageChange.opened(.sidebar(.leading)).arriving(in: pane).offset.width, -Motion.Metrics.sidebarShift)
        XCTAssertEqual(PageChange.opened(.sidebar(.trailing)).arriving(in: pane).offset.width, Motion.Metrics.sidebarShift)
    }

    func testATabPageComesFromTheSideOfTheNewTab() {
        XCTAssertEqual(PageChange.tab(direction: 1).arriving(in: pane).offset.width, Motion.Metrics.tabShift)
        XCTAssertEqual(PageChange.tab(direction: -1).arriving(in: pane).offset.width, -Motion.Metrics.tabShift)
        XCTAssertEqual(PageChange.tab(direction: 1).leaving(in: pane), .identity, "the old page only fades")
    }

    func testBackShrinksTheLeavingPageALittleAtItsCentre() {
        let leaving = PageChange.back(card).leaving(in: pane)
        XCTAssertEqual(leaving.scale, Motion.Metrics.pageOpenScale)
        XCTAssertEqual(leaving.anchor, .center)
        XCTAssertEqual(PageChange.back(card).arriving(in: pane), .identity)
    }

    func testCrossFadesDoNotMove() {
        for change in [PageChange.crossfade, .closed] {
            XCTAssertEqual(change.arriving(in: pane), .identity)
            XCTAssertEqual(change.leaving(in: pane), .identity)
        }
    }
}

private extension PageKey {
    init(_ tab: TabID, _ resource: Resource) {
        self.init(WorkspaceModel.Tab(id: tab, resource: resource))
    }
}
