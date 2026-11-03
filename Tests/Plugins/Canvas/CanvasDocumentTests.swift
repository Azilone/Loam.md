import XCTest
@testable import CanvasPlugin

final class CanvasDocumentTests: XCTestCase {
    /// The sample board of jsoncanvas.org, as Obsidian writes it.
    private let sample = """
    {
    \t"nodes":[
    \t\t{"id":"8132d4d894c80022","type":"file","file":"readme.md","x":-280,"y":-200,"width":570,"height":560,"color":"6"},
    \t\t{"id":"7efdbbe0c4742315","type":"file","file":"_site/logo.svg","x":-280,"y":-440,"width":217,"height":80},
    \t\t{"id":"59e896bc8da20699","type":"text","text":"Learn more:\\n\\n- [Apps](/docs/apps)\\n- [Spec](spec/1.0.md)","x":315,"y":-200,"width":280,"height":200,"color":"5"},
    \t\t{"id":"0ba565e7f30e0652","type":"link","url":"https://github.com/obsidianmd/jsoncanvas","x":315,"y":30,"width":280,"height":100},
    \t\t{"id":"g1","type":"group","label":"Group","background":"bg.png","backgroundStyle":"cover","x":-300,"y":-460,"width":920,"height":840}
    \t],
    \t"edges":[
    \t\t{"id":"6fa11ab87f90b8af","fromNode":"7efdbbe0c4742315","fromSide":"right","toNode":"59e896bc8da20699","toSide":"left","toEnd":"arrow","color":"1","label":"see"}
    \t]
    }

    """

    func testTheSampleBoardRoundTripsByteForByte() throws {
        let document = try CanvasDocument(text: sample)
        XCTAssertEqual(document.nodes.count, 5)
        XCTAssertEqual(document.edges.count, 1)
        XCTAssertEqual(document.nodes[2].text, "Learn more:\n\n- [Apps](/docs/apps)\n- [Spec](spec/1.0.md)")
        XCTAssertEqual(document.nodes[3].kind, .link)
        XCTAssertEqual(document.edges[0].toSide, .left)
        XCTAssertEqual(document.text, sample)
    }

    func testUnknownFieldsAreKeptInTheirOrder() throws {
        let text = """
        {"edges":[{"id":"e","fromNode":"a","toNode":"b","styleAttributes":{"path":"dotted"}}],"nodes":[\
        {"id":"a","type":"text","text":"A","x":0,"y":0,"width":10,"height":10,"zIndex":3,"styleAttributes":{"shape":"diamond","border":null}},\
        {"id":"b","type":"drawing","x":1.5,"y":0,"width":10,"height":10,"path":"M0 0 L10 10"}],"metadata":{"version":"1.0-1.0"}}
        """
        let document = try CanvasDocument(text: text)
        XCTAssertEqual(document.nodes[1].kind, .other("drawing"))
        let again = try CanvasDocument(text: document.text)
        XCTAssertEqual(again, document)
        XCTAssertTrue(document.text.contains(#""zIndex":3,"styleAttributes":{"shape":"diamond","border":null}"#))
        XCTAssertTrue(document.text.contains(#""x":1.5"#))
        XCTAssertTrue(document.text.contains(#""path":"M0 0 L10 10""#))
        XCTAssertTrue(document.text.contains(#""metadata":{"version":"1.0-1.0"}"#))
        XCTAssertTrue(document.text.contains(#""styleAttributes":{"path":"dotted"}"#))
    }

    func testStringsWithEscapesAndUnicode() throws {
        let text = #"{"nodes":[{"id":"a","type":"text","text":"é \"q\" \\ \t é 😀 \u0001","x":0,"y":0,"width":1,"height":1}]}"#
        let node = try XCTUnwrap(try CanvasDocument(text: text).nodes.first)
        XCTAssertEqual(node.text, "é \"q\" \\ \t é 😀 \u{01}")
        XCTAssertEqual(try CanvasDocument(text: CanvasDocument(nodes: [node]).text).nodes.first?.text, node.text)
    }

    func testEmptyAndBrokenFiles() throws {
        XCTAssertEqual(try CanvasDocument(text: ""), CanvasDocument())
        XCTAssertEqual(try CanvasDocument(text: "{}"), CanvasDocument())
        XCTAssertEqual(CanvasDocument().text, "{\n\t\"nodes\":[],\n\t\"edges\":[]\n}\n")
        XCTAssertThrowsError(try CanvasDocument(text: "{\"nodes\":["))
        XCTAssertThrowsError(try CanvasDocument(text: "[]"))
        XCTAssertThrowsError(try CanvasDocument(text: #"{"nodes":[{"id":"a","type":"text","x":0}]}"#))
        XCTAssertThrowsError(try CanvasDocument(text: #"{"edges":[{"id":"e","fromNode":"a"}]}"#))
    }
}

final class CanvasEditingTests: XCTestCase {
    private func card(_ id: String, _ x: Double, _ y: Double, _ width: Double = 100, _ height: Double = 50) -> CanvasNode {
        CanvasNode(id: id, kind: .text, x: x, y: y, width: width, height: height, text: id)
    }

    func testRemovingANodeRemovesItsEdges() throws {
        var document = CanvasDocument(nodes: [card("a", 0, 0), card("b", 200, 0), card("c", 400, 0)])
        let ab = try document.connect("a", to: "b")
        try document.connect("b", to: "c")
        XCTAssertThrowsError(try document.connect("a", to: "missing"))
        XCTAssertThrowsError(try document.connect("a", to: "a"))
        document.remove(["c"])
        XCTAssertEqual(document.nodes.map(\.id), ["a", "b"])
        XCTAssertEqual(document.edges.map(\.id), [ab])
    }

    func testMovingAGroupCarriesWhatItHolds() throws {
        var document = CanvasDocument(nodes: [card("a", 0, 0), card("b", 200, 0), card("outside", 1000, 0)])
        let group = try document.group(["a", "b"], label: "Ideas")
        XCTAssertEqual(document.nodes.first?.id, group, "a group goes under its cards")
        XCTAssertEqual(document.node(group)?.frame, CanvasRect(x: -40, y: -40, width: 380, height: 130))
        document.move([group], by: 10, 20)
        XCTAssertEqual(document.node("a")?.x, 10)
        XCTAssertEqual(document.node("b")?.y, 20)
        XCTAssertEqual(document.node("outside")?.x, 1000)
    }

    func testCopyAndPasteMakesNewIDsAndKeepsInnerEdges() throws {
        var document = CanvasDocument(nodes: [card("a", 0, 0), card("b", 200, 0), card("c", 400, 0)])
        try document.connect("a", to: "b", label: "inner")
        try document.connect("b", to: "c")
        let fragment = document.fragment(["a", "b"])
        XCTAssertEqual(fragment.edges.count, 1)
        let added = document.paste(try CanvasDocument(text: fragment.text), offsetBy: 0, 100)
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(Set(document.nodes.map(\.id)).count, 5)
        let pasted = try XCTUnwrap(document.edges.last)
        XCTAssertEqual(pasted.label, "inner")
        XCTAssertEqual([pasted.fromNode, pasted.toNode], added)
        XCTAssertEqual(document.node(added[0])?.y, 100)
    }

    func testFollowingMovedFiles() {
        var document = CanvasDocument(nodes: [
            CanvasNode(id: "a", kind: .file, x: 0, y: 0, width: 1, height: 1, file: "Old/Note.md"),
            CanvasNode(id: "b", kind: .group, x: 0, y: 0, width: 1, height: 1, background: "Old/bg.png"),
        ])
        XCTAssertTrue(document.follow(moves: ["Old/Note.md": "New/Note.md", "Old/bg.png": "New/bg.png"]))
        XCTAssertEqual(document.node("a")?.file, "New/Note.md")
        XCTAssertEqual(document.node("b")?.background, "New/bg.png")
        XCTAssertFalse(document.follow(moves: ["Other.md": "Else.md"]))
    }

    func testZOrder() {
        var document = CanvasDocument(nodes: [card("a", 0, 0), card("b", 0, 0), card("c", 0, 0)])
        document.bringToFront(["a"])
        XCTAssertEqual(document.nodes.map(\.id), ["b", "c", "a"])
        document.sendToBack(["c"])
        XCTAssertEqual(document.nodes.map(\.id), ["c", "b", "a"])
    }
}

final class CanvasGeometryTests: XCTestCase {
    func testEdgesUseTheFacingSides() {
        let a = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(CanvasGeometry.sides(from: a, to: a.offsetBy(300, 50)) == (.right, .left))
        XCTAssertTrue(CanvasGeometry.sides(from: a, to: a.offsetBy(-300, 0)) == (.left, .right))
        XCTAssertTrue(CanvasGeometry.sides(from: a, to: a.offsetBy(20, 300)) == (.bottom, .top))
        let curve = CanvasGeometry.curve(from: a, side: nil, to: a.offsetBy(300, 0), side: nil)
        XCTAssertEqual(curve.start, CanvasPoint(x: 100, y: 50))
        XCTAssertEqual(curve.end, CanvasPoint(x: 300, y: 50))
        XCTAssertEqual(curve.middle, CanvasPoint(x: 200, y: 50))
        XCTAssertLessThan(curve.distance(to: CanvasPoint(x: 200, y: 52)), 3)
        let (left, right) = curve.arrowHead()
        XCTAssertLessThan(left.x, 300)
        XCTAssertEqual(left.x, right.x, accuracy: 0.001)
    }

    func testFreeSpotAvoidsCards() {
        let document = CanvasDocument(nodes: [
            CanvasNode(id: "a", kind: .text, x: 0, y: 0, width: 100, height: 100),
            CanvasNode(id: "g", kind: .group, x: -500, y: -500, width: 2000, height: 2000),
        ])
        let spot = CanvasGeometry.freeSpot(for: (100, 100), near: CanvasPoint(x: 0, y: 0), in: document)
        XCTAssertEqual(spot, CanvasPoint(x: 140, y: 0))
        XCTAssertEqual(CanvasGeometry.freeSpot(for: (10, 10), near: CanvasPoint(x: 500, y: 500), in: document),
                       CanvasPoint(x: 500, y: 500))
    }

    func testSpatialIndexFindsVisibleNodesAndTheTopMost() {
        var nodes = (0..<1000).map { i in
            CanvasNode(id: "n\(i)", kind: .text, x: Double(i % 40) * 300, y: Double(i / 40) * 200,
                       width: 250, height: 150)
        }
        nodes.append(CanvasNode(id: "top", kind: .text, x: 10, y: 10, width: 50, height: 50))
        let index = CanvasSpatialIndex(nodes: nodes)
        XCTAssertEqual(index.nodes(in: CanvasRect(x: 0, y: 0, width: 260, height: 160)), ["n0", "top"])
        XCTAssertEqual(index.node(at: CanvasPoint(x: 20, y: 20)), "top")
        XCTAssertEqual(index.node(at: CanvasPoint(x: 120, y: 120)), "n0")
        XCTAssertNil(index.node(at: CanvasPoint(x: 270, y: 20)))
        XCTAssertEqual(index.nodes(in: CanvasRect(x: -1e9, y: -1e9, width: 2e9, height: 2e9)).count, 1001)
    }
}
