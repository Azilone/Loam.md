import XCTest
@testable import CanvasPlugin

final class CanvasInkTests: XCTestCase {
    private let points = [CanvasPoint(x: 10, y: 10), CanvasPoint(x: 40, y: 30), CanvasPoint(x: 80, y: 20), CanvasPoint(x: 120, y: 60)]

    func testStrokesAreSVGPathsThatReadBackExactly() throws {
        let ink = CanvasInk(strokes: [
            CanvasInkStroke(points: points, color: "1", width: 4),
            CanvasInkStroke(points: [CanvasPoint(x: 5, y: 5), CanvasPoint(x: 6.25, y: 7)], width: 16, opacity: 0.35),
        ])
        let svg = ink.svg(width: 130, height: 70)
        XCTAssertTrue(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\" data-loam=\"ink\""))
        XCTAssertTrue(svg.contains("viewBox=\"0 0 130 70\""))
        XCTAssertTrue(svg.contains("d=\"M10 10Q40 30 60 25Q80 20 100 40L120 60\""), "smooth for any SVG reader")
        XCTAssertTrue(svg.contains("stroke=\"#E84A4A\" data-color=\"1\""))
        XCTAssertTrue(svg.contains("stroke=\"currentColor\""), "no colour follows the text colour")
        XCTAssertTrue(svg.contains("stroke-opacity=\"0.35\""))
        let read = try XCTUnwrap(CanvasInk(svg: svg))
        XCTAssertEqual(read.strokes[0].points, points)
        XCTAssertEqual(read.strokes[0].color, "1")
        XCTAssertEqual(read.strokes[1].points, [CanvasPoint(x: 5, y: 5), CanvasPoint(x: 6.3, y: 7)])
        XCTAssertEqual(read.strokes[1].opacity, 0.35, accuracy: 0.001)
        XCTAssertNil(read.strokes[1].color)
        XCTAssertNil(CanvasInk(svg: "<svg viewBox=\"0 0 1 1\"></svg>"), "only Loam's drawings")
    }

    func testALineKeepsItsEndsAndHeads() throws {
        let line = CanvasInk(kind: .line, strokes: [CanvasInkStroke(points: [CanvasPoint(x: 0, y: 0), CanvasPoint(x: 100, y: -50)],
                                                                   dashed: true)],
                             endArrow: true)
        let read = try XCTUnwrap(CanvasInk(svg: line.svg(width: 100, height: 50)))
        XCTAssertEqual(read.kind, .line)
        XCTAssertTrue(read.endArrow)
        XCTAssertFalse(read.startArrow)
        XCTAssertEqual(read.strokes.count, 1, "the head is drawn, not read")
        XCTAssertTrue(read.strokes[0].dashed)
        XCTAssertEqual(read.ends?.1, CanvasPoint(x: 100, y: -50))
    }

    func testANodeHoldsADrawingWhereItWasDrawn() throws {
        let ink = CanvasInk(strokes: [CanvasInkStroke(points: [CanvasPoint(x: 200, y: 300), CanvasPoint(x: 260, y: 340)], width: 4)])
        let node = try XCTUnwrap(CanvasNode.drawing(id: "d", ink))
        XCTAssertTrue(node.isDrawing)
        XCTAssertFalse(node.isFreeText, "a drawing is not text")
        XCTAssertEqual(node.border, .invisible)
        XCTAssertEqual(node.x, 197)
        XCTAssertEqual(node.y, 297)
        XCTAssertEqual(node.drawing?.strokes[0].points, ink.strokes[0].points, "back in board units")
        let written = try CanvasDocument(text: CanvasDocument(nodes: [node]).text)
        XCTAssertEqual(written.nodes[0].drawing, node.drawing)
    }

    func testErasingFindsTheStrokesNearAPoint() {
        let ink = CanvasInk(strokes: [CanvasInkStroke(points: points), CanvasInkStroke(points: [CanvasPoint(x: 500, y: 500)])])
        XCTAssertEqual(Array(ink.strokes(near: CanvasPoint(x: 25, y: 22), radius: 4)), [0])
        XCTAssertEqual(Array(ink.strokes(near: CanvasPoint(x: 300, y: 300), radius: 4)), [])
    }

    func testSimplifyingKeepsTheShape() {
        let straight = (0...50).map { CanvasPoint(x: Double($0), y: Double($0) * 0.5) }
        XCTAssertEqual(CanvasInkStroke.simplify(straight, tolerance: 0.5).count, 2)
        let corner = (0...10).map { CanvasPoint(x: Double($0), y: 0) } + (1...10).map { CanvasPoint(x: 10, y: Double($0)) }
        XCTAssertEqual(CanvasInkStroke.simplify(corner, tolerance: 0.5), [CanvasPoint(x: 0, y: 0), CanvasPoint(x: 10, y: 0), CanvasPoint(x: 10, y: 10)])
    }
}
