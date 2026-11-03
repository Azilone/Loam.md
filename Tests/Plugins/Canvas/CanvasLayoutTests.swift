import XCTest
@testable import CanvasPlugin

final class CanvasLayoutTests: XCTestCase {
    private let frame = CanvasRect(x: 100, y: 100, width: 200, height: 100)

    func testEachHandleMovesItsEdges() {
        XCTAssertEqual(frame.resized(.right, by: 30, 99), CanvasRect(x: 100, y: 100, width: 230, height: 100))
        XCTAssertEqual(frame.resized(.left, by: 30, 99), CanvasRect(x: 130, y: 100, width: 170, height: 100))
        XCTAssertEqual(frame.resized(.top, by: 99, -20), CanvasRect(x: 100, y: 80, width: 200, height: 120))
        XCTAssertEqual(frame.resized(.bottom, by: 99, 20), CanvasRect(x: 100, y: 100, width: 200, height: 120))
        XCTAssertEqual(frame.resized(.topLeft, by: -10, -10), CanvasRect(x: 90, y: 90, width: 210, height: 110))
        XCTAssertEqual(frame.resized(.bottomRight, by: 10, 10), CanvasRect(x: 100, y: 100, width: 210, height: 110))
    }

    func testAResizeStopsAgainstTheOppositeEdge() {
        let small = frame.resized(.left, by: 500, 0, minimum: (60, 40))
        XCTAssertEqual(small, CanvasRect(x: 240, y: 100, width: 60, height: 100), "the right edge stays at 300")
        let flat = frame.resized(.top, by: 0, 500, minimum: (60, 40))
        XCTAssertEqual(flat, CanvasRect(x: 100, y: 160, width: 200, height: 40))
    }

    func testAResizeCanKeepTheRatio() {
        let corner = frame.resized(.bottomRight, by: 100, 0, keepRatio: true)
        XCTAssertEqual(corner, CanvasRect(x: 100, y: 100, width: 300, height: 150))
        let topLeft = frame.resized(.topLeft, by: -100, 0, keepRatio: true)
        XCTAssertEqual(topLeft.maxX, 300)
        XCTAssertEqual(topLeft.maxY, 200, "the opposite corner stays")
        XCTAssertEqual(topLeft.width / topLeft.height, 2, accuracy: 0.001)
        let side = frame.resized(.right, by: 100, 0, keepRatio: true)
        XCTAssertEqual(side.width, 300)
        XCTAssertEqual(side.height, 150)
        XCTAssertEqual(side.center.y, frame.center.y, accuracy: 0.001, "a side grows the other way about the middle")
    }

    private func board() -> CanvasDocument {
        CanvasDocument(nodes: [
            CanvasNode(id: "a", kind: .text, x: 0, y: 10, width: 100, height: 50),
            CanvasNode(id: "b", kind: .text, x: 130, y: 70, width: 60, height: 20),
            CanvasNode(id: "c", kind: .text, x: 400, y: 0, width: 100, height: 80),
        ])
    }

    func testAlignmentUsesWhatTheSelectionCovers() {
        var document = board()
        document.align(["a", "b", "c"], to: .left)
        XCTAssertEqual(document.nodes.map(\.x), [0, 0, 0])
        document = board()
        document.align(["a", "b", "c"], to: .right)
        XCTAssertEqual(document.nodes.map { $0.x + $0.width }, [500, 500, 500])
        document = board()
        document.align(["a", "b", "c"], to: .centerY)
        XCTAssertEqual(document.nodes.map { $0.y + $0.height / 2 }, [45, 45, 45])
        document = board()
        document.align(["a"], to: .left)
        XCTAssertEqual(document, board(), "one card has nothing to align with")
    }

    func testAGroupAlignsWithItsCards() throws {
        var document = CanvasDocument(nodes: [
            CanvasNode(id: "g", kind: .group, x: 0, y: 0, width: 300, height: 300),
            CanvasNode(id: "in", kind: .text, x: 50, y: 50, width: 100, height: 100),
            CanvasNode(id: "out", kind: .text, x: 600, y: 0, width: 100, height: 100),
        ])
        document.align(["g", "in", "out"], to: .bottom)
        XCTAssertEqual(try XCTUnwrap(document.node("g")).y, 0, "the tallest keeps its place")
        XCTAssertEqual(try XCTUnwrap(document.node("in")).y, 50, "what lies in a selected group follows the group")
        XCTAssertEqual(try XCTUnwrap(document.node("out")).y, 200)
    }

    func testDistributeSpacesTheMiddleCardsEvenly() {
        var document = board()
        document.distribute(["a", "b", "c"], along: .horizontal)
        // widths 100 + 60 + 100 in 500: two gaps of 120.
        XCTAssertEqual(document.nodes.map(\.x), [0, 220, 400])
        document.distribute(["a", "c"], along: .horizontal)
        XCTAssertEqual(document.nodes.map(\.x), [0, 220, 400], "two cards have nothing to spread")
    }

    func testFontSizeStepsStayInRange() {
        var node = CanvasNode(id: "t", kind: .text, x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(node.effectiveFontSize, 16)
        XCTAssertEqual(node.steppedFontSize(larger: true), 20)
        XCTAssertEqual(node.steppedFontSize(larger: false), 14)
        node.fontSize = 17
        XCTAssertEqual(node.steppedFontSize(larger: true), 20)
        XCTAssertEqual(node.steppedFontSize(larger: false), 16)
        node.fontSize = 72
        XCTAssertEqual(node.steppedFontSize(larger: true), 72)
        node.fontSize = 12
        XCTAssertEqual(node.steppedFontSize(larger: false), 12)
    }

    func testTheExtensionsRoundTripAndOtherAppsKeepTheirs() throws {
        let text = """
        {"nodes":[{"id":"a","type":"text","text":"Big","x":0,"y":0,"width":100,"height":50,"fontSize":32,"zIndex":2},\
        {"id":"b","type":"text","text":"B","x":200,"y":0,"width":100,"height":50}],\
        "edges":[{"id":"e","fromNode":"a","toNode":"b","shape":"straight","dashed":true,"label":"x"}]}
        """
        let document = try CanvasDocument(text: text)
        XCTAssertEqual(document.nodes[0].fontSize, 32)
        XCTAssertEqual(document.edges[0].shape, .straight)
        XCTAssertTrue(document.edges[0].isDashed)
        XCTAssertTrue(document.text.contains(#""fontSize":32,"zIndex":2"#), "ours before the unknown ones")
        XCTAssertTrue(document.text.contains(#""label":"x","shape":"straight","dashed":true"#))
        XCTAssertEqual(try CanvasDocument(text: document.text), document)
    }

    func testStraightEdgesAreLines() throws {
        let from = CanvasRect(x: 0, y: 0, width: 100, height: 100), to = CanvasRect(x: 300, y: 200, width: 100, height: 100)
        let curve = CanvasGeometry.curve(from: from, side: .right, to: to, side: .left, straight: true)
        XCTAssertEqual(curve.control1, curve.start)
        XCTAssertEqual(curve.control2, curve.end)
        XCTAssertEqual(curve.middle, CanvasPoint(x: 200, y: 150))
        XCTAssertEqual(curve.distance(to: CanvasPoint(x: 200, y: 150)), 0, accuracy: 0.001)
        let document = CanvasDocument(
            nodes: [CanvasNode(id: "a", kind: .text, x: 0, y: 0, width: 100, height: 100),
                    CanvasNode(id: "b", kind: .text, x: 300, y: 200, width: 100, height: 100)],
            edges: [CanvasEdge(id: "e", fromNode: "a", toNode: "b", shape: .straight)]
        )
        XCTAssertEqual(CanvasGeometry.curve(of: document.edges[0], in: document)?.control1,
                       CanvasGeometry.curve(of: document.edges[0], in: document)?.start)
    }
}
