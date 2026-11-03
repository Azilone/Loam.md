import XCTest
import LoamCore
import PluginKit
import PluginKitTesting
@testable import CanvasPlugin

final class CanvasPluginTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testAnAgentBuildsABoardWithCommands() async throws {
        let harness = try PluginTestHarness([CanvasPlugin.self], files: ["Projects/Trip.md": "# Trip\n"])
        let created = try await harness.run("canvas.new", ["title": "Plans"])
        let path = try XCTUnwrap(try json(created)["path"] as? String)
        XCTAssertEqual(path, "Inbox/Plans.canvas")
        let second = try await harness.run("canvas.new", ["title": "Plans"])
        XCTAssertEqual(try json(second)["path"] as? String, "Inbox/Plans 2.canvas")

        let note = try json(await harness.run("canvas.add-node", ["path": path, "file": "Projects/Trip.md"]))
        let noteID = try XCTUnwrap(note["id"] as? String)
        let text = try json(await harness.run("canvas.add-node", [
            "path": path, "text": "**Dates**", "near": noteID, "color": "3",
        ]))
        let textID = try XCTUnwrap(text["id"] as? String)
        _ = try await harness.run("canvas.connect", ["path": path, "from": noteID, "to": textID, "label": "when"])
        _ = try await harness.run("canvas.update-node", ["path": path, "id": textID, "text": "**Dates**: May"])

        let read = try await harness.run("canvas.read", ["path": path])
        let board = try CanvasDocument(text: read)
        XCTAssertEqual(board.nodes.count, 2)
        let card = try XCTUnwrap(board.node(noteID)), label = try XCTUnwrap(board.node(textID))
        XCTAssertEqual(card.file, "Projects/Trip.md")
        XCTAssertEqual(card.frame, CanvasRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(label.x, 480, "placed beside the card it is near")
        XCTAssertEqual(label.text, "**Dates**: May")
        XCTAssertEqual(label.color, "3")
        XCTAssertEqual(board.edges.first?.label, "when")
        XCTAssertEqual(try harness.vault.read(path), board.text)

        let showing = try await harness.run("canvas.list", ["path": "Projects/Trip.md"])
        XCTAssertTrue(showing.contains("Inbox/Plans.canvas"))
        XCTAssertFalse(showing.contains("Plans 2"))

        let removed = try await harness.run("canvas.remove", ["path": path, "ids": noteID])
        XCTAssertEqual(try json(removed)["removed"] as? Int, 2, "the card and its edge")
        XCTAssertTrue(harness.vault.exists("Projects/Trip.md"), "the note stays")
    }

    func testCommandsRefuseBadInput() async throws {
        let harness = try PluginTestHarness([CanvasPlugin.self], files: ["Board.canvas": "", "Note.md": ""])
        await XCTAssertThrowsAsync(try await harness.run("canvas.add-node", ["path": "Board.canvas", "file": "Missing.md"]))
        await XCTAssertThrowsAsync(try await harness.run("canvas.add-node", ["path": "Board.canvas", "type": "text"]))
        await XCTAssertThrowsAsync(try await harness.run("canvas.add-node", ["path": "Note.md", "text": "x"]))
        await XCTAssertThrowsAsync(try await harness.run("canvas.connect", ["path": "Board.canvas", "from": "a", "to": "b"]))
        await XCTAssertThrowsAsync(try await harness.run("canvas.new", ["title": "../escape"]))
        XCTAssertEqual(try harness.vault.read("Board.canvas"), "", "a refused edit writes nothing")
    }

    func testBoardsFollowMovedNotes() throws {
        let board = CanvasDocument(nodes: [
            CanvasNode(id: "a", kind: .file, x: 0, y: 0, width: 400, height: 400, file: "Old.md"),
        ])
        let harness = try PluginTestHarness([CanvasPlugin.self], files: [
            "Old.md": "# Old\n", "Boards/One.canvas": board.text, "Boards/Broken.canvas": "{",
        ])
        try harness.vault.move("Old.md", to: "Folder/New.md")
        harness.kernel.events.emit(NotesMoved(moves: ["Old.md": "Folder/New.md"]))
        XCTAssertEqual(try CanvasDocument(text: try harness.vault.read("Boards/One.canvas")).nodes.first?.file,
                       "Folder/New.md")
        XCTAssertEqual(try harness.vault.read("Boards/Broken.canvas"), "{", "a board that does not parse is left alone")
    }

    func testAnAgentSetsTheFontSizeStylesArrowsAndAlignsCards() async throws {
        let harness = try PluginTestHarness([CanvasPlugin.self])
        func id(_ output: String) throws -> String { try XCTUnwrap(try json(output)["id"] as? String) }
        let created = try await harness.run("canvas.new", [:])
        let path = try XCTUnwrap(try json(created)["path"] as? String)
        let a = try id(await harness.run("canvas.add-node", [
            "path": path, "text": "A", "x": "0", "y": "0", "fontSize": "32",
        ]))
        let b = try id(await harness.run("canvas.add-node", [
            "path": path, "text": "B", "x": "300", "y": "100",
        ]))
        _ = try await harness.run("canvas.connect", [
            "path": path, "from": a, "to": b, "color": "4", "shape": "straight", "dashed": "true",
        ])
        _ = try await harness.run("canvas.align", ["path": path, "ids": "\(a),\(b)", "align": "left"])
        var board = try CanvasDocument(text: try await harness.run("canvas.read", ["path": path]))
        XCTAssertEqual(board.node(a)?.fontSize, 32)
        XCTAssertEqual(board.node(b)?.x, 0)
        XCTAssertEqual(board.edges.first?.shape, .straight)
        XCTAssertEqual(board.edges.first?.dashed, true)
        XCTAssertEqual(board.edges.first?.color, "4")

        _ = try await harness.run("canvas.update-node", ["path": path, "id": a, "fontSize": ""])
        board = try CanvasDocument(text: try await harness.run("canvas.read", ["path": path]))
        XCTAssertNil(board.node(a)?.fontSize)
        await XCTAssertThrowsAsync(try await harness.run("canvas.connect", [
            "path": path, "from": a, "to": b, "shape": "wavy",
        ]))
        await XCTAssertThrowsAsync(try await harness.run("canvas.align", ["path": path, "ids": a]))
    }
}

func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath,
                             line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}

final class NoteBoardsTests: XCTestCase {
    func testTheCanvasPluginSaysWhichBoardsShowANote() throws {
        let card = CanvasDocument(nodes: [
            CanvasNode(id: "a", kind: .file, x: 0, y: 0, width: 400, height: 400, file: "Note.md"),
        ]).text
        let harness = try PluginTestHarness([CanvasPlugin.self], files: [
            "Note.md": "# Note\n", "A.canvas": card, "Folder/B.canvas": card, "C.canvas": CanvasDocument().text,
        ])
        let service = try XCTUnwrap(harness.kernel.services.service(.noteBoards))
        XCTAssertEqual(try service.boards(showing: "Note.md"), ["A.canvas", "Folder/B.canvas"])
        try harness.kernel.refreshVault()
        try harness.vault.write("C.canvas", card)
        // The app hears of it from the file watcher (`VaultChanged`).
        try harness.kernel.refreshVault()
        XCTAssertEqual(try service.boards(showing: "Note.md"), ["A.canvas", "C.canvas", "Folder/B.canvas"],
                       "a board that changed is read again")
    }
}
