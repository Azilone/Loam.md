import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest

final class OpenOriginTests: XCTestCase {
    private let pane = CGRect(x: 200, y: 50, width: 800, height: 600)

    func testAFrameGrowsFromItsCentreInPaneCoordinates() {
        let origin = OpenOrigin.frame(CGRect(x: 300, y: 150, width: 200, height: 100))
        let anchor = origin.anchor(in: pane)
        XCTAssertEqual(anchor.x, (400 - 200) / 800, accuracy: 0.0001)
        XCTAssertEqual(anchor.y, (200 - 50) / 600, accuracy: 0.0001)
    }

    func testAFrameOutsideThePaneIsClampedToItsEdge() {
        let left = OpenOrigin.frame(CGRect(x: 0, y: 0, width: 100, height: 100)).anchor(in: pane)
        XCTAssertEqual(left, UnitPoint(x: 0, y: 0))
        let right = OpenOrigin.frame(CGRect(x: 2000, y: 2000, width: 100, height: 100)).anchor(in: pane)
        XCTAssertEqual(right, UnitPoint(x: 1, y: 1))
    }

    func testASidebarAndThePaletteHaveTheirOwnAnchors() {
        XCTAssertEqual(OpenOrigin.sidebar(.leading).anchor(in: pane), .leading)
        XCTAssertEqual(OpenOrigin.sidebar(.trailing).anchor(in: pane), .trailing)
        XCTAssertEqual(OpenOrigin.palette.anchor(in: pane), .top)
    }

    func testAnEmptyPaneFallsBackToTheCentre() {
        XCTAssertEqual(OpenOrigin.frame(CGRect(x: 1, y: 1, width: 5, height: 5)).anchor(in: .zero), .center)
    }

    @MainActor
    func testTheRecordingWorkspaceKeepsTheOrigin() {
        let workspace = RecordingWorkspace()
        let origin = OpenOrigin.frame(CGRect(x: 1, y: 2, width: 3, height: 4))
        workspace.open(.file("a.md"), placement: .replace, from: origin)
        workspace.open(.file("b.md"), placement: .newTab)
        XCTAssertEqual(workspace.opened.map(\.resource), [.file("a.md"), .file("b.md")])
        XCTAssertEqual(workspace.openedOrigins, [origin, nil])
    }
}
