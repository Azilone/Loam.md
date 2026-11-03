import CoreGraphics
import WorkspaceModel
import XCTest

final class DropGeometryTests: XCTestCase {
    private let size = CGSize(width: 400, height: 200)

    func testDropEdgeTable() {
        let cases: [(CGPoint, DropEdge, String)] = [
            (CGPoint(x: 200, y: 100), .center, "middle"),
            (CGPoint(x: 101, y: 51), .center, "just inside the center"),
            (CGPoint(x: 10, y: 100), .leading, "left"),
            (CGPoint(x: 99, y: 100), .leading, "just inside the left band"),
            (CGPoint(x: 390, y: 100), .trailing, "right"),
            (CGPoint(x: 200, y: 5), .top, "top"),
            (CGPoint(x: 200, y: 195), .bottom, "bottom"),
            // Corners: the nearer edge, as a fraction of the pane's size.
            (CGPoint(x: 4, y: 20), .leading, "top left, nearer the left"),
            (CGPoint(x: 80, y: 2), .top, "top left, nearer the top"),
            (CGPoint(x: 396, y: 190), .trailing, "bottom right, nearer the right"),
            (CGPoint(x: 360, y: 199), .bottom, "bottom right, nearer the bottom"),
            // Outside the pane (a drag leaving it): clamped.
            (CGPoint(x: -20, y: 100), .leading, "left of the pane"),
            (CGPoint(x: 200, y: 500), .bottom, "below the pane"),
        ]
        for (point, edge, label) in cases {
            XCTAssertEqual(dropEdge(at: point, in: size), edge, label)
        }
    }

    func testTheBandIsAFractionOfEachSide() {
        XCTAssertEqual(dropEdge(at: CGPoint(x: 150, y: 100), in: size, band: 0.4), .leading)
        XCTAssertEqual(dropEdge(at: CGPoint(x: 150, y: 100), in: size, band: 0.25), .center)
    }

    func testABandOfZeroOrAnEmptyPaneIsAlwaysTheCenter() {
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 400, y: 200), CGPoint(x: 200, y: 0)] {
            XCTAssertEqual(dropEdge(at: point, in: size, band: 0), .center)
        }
        XCTAssertEqual(dropEdge(at: .zero, in: .zero), .center)
    }

    func testTabInsertionIndex() {
        let midpoints: [CGFloat] = [50, 150, 250]
        XCTAssertEqual(tabInsertionIndex(at: 0, midpoints: midpoints), 0)
        XCTAssertEqual(tabInsertionIndex(at: 49, midpoints: midpoints), 0)
        XCTAssertEqual(tabInsertionIndex(at: 51, midpoints: midpoints), 1)
        XCTAssertEqual(tabInsertionIndex(at: 200, midpoints: midpoints), 2)
        XCTAssertEqual(tabInsertionIndex(at: 900, midpoints: midpoints), 3, "the empty area appends")
        XCTAssertEqual(tabInsertionIndex(at: 10, midpoints: []), 0)
    }
}
