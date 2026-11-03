import XCTest
import PluginKit
import PluginKitTesting
@testable import CanvasPlugin

final class CanvasStyleTests: XCTestCase {
    func testShapesAreAdvancedCanvasStyleAttributesKeptWithOthers() throws {
        let text = """
        {"nodes":[{"id":"a","type":"text","text":"Go?","x":0,"y":0,"width":240,"height":180,\
        "styleAttributes":{"shape":"diamond","glow":true}}],"edges":[]}
        """
        var document = try CanvasDocument(text: text)
        XCTAssertEqual(document.nodes[0].shape, .diamond)
        XCTAssertNil(document.nodes[0].border)
        document.nodes[0].border = .dashed
        document.nodes[0].textAlign = .center
        document.nodes[0].shape = .circle
        let written = try CanvasDocument(text: document.text)
        XCTAssertEqual(written.nodes[0].styleAttribute("glow"), .bool(true), "another app's attribute stays")
        XCTAssertEqual(written.nodes[0].shape, .circle)
        XCTAssertEqual(written.nodes[0].border, .dashed)
        XCTAssertEqual(written.nodes[0].textAlign, .center)
        XCTAssertTrue(written.nodes[0].centresText)
        XCTAssertTrue(document.text.contains(#""styleAttributes":{"shape":"circle","glow":true,"border":"dashed","textAlign":"center"}"#))

        document.nodes[0].shape = .rectangle
        document.nodes[0].border = .solid
        document.nodes[0].textAlign = nil
        document.nodes[0].setStyleAttribute("glow", nil)
        XCTAssertNil(document.nodes[0].extraValue("styleAttributes"), "an empty styleAttributes goes away")
        XCTAssertFalse(document.text.contains("styleAttributes"))
    }

    func testTextSitsInTheMiddleOfADiamond() {
        let rect = CanvasNodeShape.diamond.textRect(in: CanvasRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(rect, CanvasRect(x: 50, y: 25, width: 100, height: 50))
        XCTAssertEqual(CanvasNodeShape.rectangle.textRect(in: CanvasRect(x: 1, y: 2, width: 3, height: 4)),
                       CanvasRect(x: 1, y: 2, width: 3, height: 4))
    }

    func testMetadataAndRatio() throws {
        var document = CanvasDocument(nodes: [CanvasNode(id: "s", kind: .group, x: 0, y: 0, width: 1600, height: 900)])
        document.startNode = "s"
        document.nodes[0].ratio = 16.0 / 9
        var read = try CanvasDocument(text: document.text)
        XCTAssertEqual(read.startNode, "s")
        XCTAssertEqual(read.nodes[0].ratio ?? 0, 16.0 / 9, accuracy: 1e-9)
        read.startNode = nil
        XCTAssertFalse(read.text.contains("metadata"))
    }

    func testCommandsMakeAndChangeShapes() async throws {
        let harness = try PluginTestHarness([CanvasPlugin.self])
        let path = "Inbox/Flow.canvas"
        _ = try await harness.run("canvas.new", ["title": "Flow"])
        let made = try await harness.run("canvas.add-node", ["path": path, "shape": "diamond"])
        let id = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(made.utf8)) as? [String: Any])?["id"] as? String)
        var board = try CanvasDocument(text: try harness.vault.read(path))
        XCTAssertEqual(board.node(id)?.shape, .diamond)
        XCTAssertEqual(board.node(id)?.text, "", "a shape needs no text")
        XCTAssertEqual(board.node(id)?.width, 240)
        _ = try await harness.run("canvas.update-node", ["path": path, "id": id, "shape": "", "border": "dotted"])
        board = try CanvasDocument(text: try harness.vault.read(path))
        XCTAssertNil(board.node(id)?.shape)
        XCTAssertEqual(board.node(id)?.border, .dotted)
        do {
            _ = try await harness.run("canvas.add-node", ["path": path, "shape": "star"])
            XCTFail("an unknown shape is refused")
        } catch {}
    }
}

final class CanvasSlidesTests: XCTestCase {
    private func frame(_ id: String, _ x: Double, _ y: Double) -> CanvasNode {
        var node = CanvasNode(id: id, kind: .group, x: x, y: y, width: 1280, height: 720, label: id)
        node.ratio = 16.0 / 9
        return node
    }

    func testSlidesAreReadInRowsWithoutArrows() {
        let document = CanvasDocument(nodes: [
            frame("c", 0, 1000), frame("b", 1500, 30), frame("a", 0, 0),
            CanvasNode(id: "g", kind: .group, x: 0, y: -900, width: 100, height: 100),
        ])
        XCTAssertEqual(document.slides(), ["a", "b", "c"], "a group without a ratio is not a slide")
        XCTAssertEqual(CanvasDocument(nodes: [CanvasNode(id: "g", kind: .group, x: 0, y: 0, width: 9, height: 9)]).slides(),
                       ["g"], "groups are the slides of a board without frames")
    }

    func testSlidesFollowArrowsFromTheStart() {
        var document = CanvasDocument(nodes: [frame("a", 0, 0), frame("b", 1500, 0), frame("c", 3000, 0), frame("d", 0, 1000)])
        document.startNode = "c"
        document.edges = [
            CanvasEdge(id: "1", fromNode: "c", toNode: "a", label: "2"),
            CanvasEdge(id: "2", fromNode: "c", toNode: "d", label: "1"),
            CanvasEdge(id: "3", fromNode: "d", toNode: "c"),
        ]
        XCTAssertEqual(document.slides(), ["c", "d", "a", "b"], "by label, no loop, then the rest in reading order")
    }

    func testAFrameAroundCardsIsSixteenByNine() {
        var document = CanvasDocument(nodes: [CanvasNode(id: "t", kind: .text, x: 0, y: 0, width: 100, height: 100)])
        let rect = CanvasDocument.frame(around: CanvasRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9, accuracy: 0.01)
        XCTAssertEqual(rect.center.x, 50, accuracy: 1)
        let id = document.addFrame(rect)
        XCTAssertEqual(document.nodes.first?.id, id, "under the cards it holds")
        XCTAssertEqual(document.startNode, id, "the first frame starts the presentation")
        XCTAssertEqual(document.node(id)?.label, "Slide 1")
        XCTAssertEqual(document.nextFrameLabel, "Slide 2")
    }

    func testCommandsAddFramesAndListSlides() async throws {
        let harness = try PluginTestHarness([CanvasPlugin.self])
        _ = try await harness.run("canvas.new", ["title": "Deck"])
        let path = "Inbox/Deck.canvas"
        let card = try await harness.run("canvas.add-node", ["path": path, "text": "Hello"])
        let cardID = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(card.utf8)) as? [String: Any])?["id"] as? String)
        _ = try await harness.run("canvas.add-frame", ["path": path, "ids": cardID])
        _ = try await harness.run("canvas.add-frame", ["path": path, "label": "End"])
        let slides = try await harness.run("canvas.slides", ["path": path])
        let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(slides.utf8)) as? [[String: String]])
        XCTAssertEqual(list.map { $0["label"] }, ["Slide 1", "End"])
    }
}
