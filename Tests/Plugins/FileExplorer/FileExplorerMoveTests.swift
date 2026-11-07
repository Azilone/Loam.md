import XCTest
import NoteGraphPlugin
import PluginKit
import PluginKitTesting
@testable import FileExplorerPlugin

/// Moves go through the note graph when it is there, and are plain moves otherwise.
final class FileExplorerMoveTests: XCTestCase {
    private let notes = [
        "a.md": "# A\n\nSee [B](Folder/b.md).\n",
        "Folder/b.md": "# B\n\nBack to [A](../a.md).\n",
    ]

    private func files(_ harness: PluginTestHarness) throws -> FilesService {
        try XCTUnwrap(harness.kernel.services.service(.files))
    }

    func testMovingAFileWithTheNoteGraphRewritesLinks() throws {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, FileExplorerPlugin.self], files: notes)
        let result = try files(harness).move("Folder/b.md", to: "Other/b.md")
        XCTAssertEqual(result, MoveResult(moves: ["Folder/b.md": "Other/b.md"], updated: ["a.md"]))
        XCTAssertEqual(try harness.vault.read("a.md"), "# A\n\nSee [B](Other/b.md).\n")
        XCTAssertEqual(try harness.vault.read("Other/b.md"), "# B\n\nBack to [A](../a.md).\n")
    }

    func testMovingAFolderWithTheNoteGraphRewritesLinks() throws {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, FileExplorerPlugin.self], files: notes)
        let result = try files(harness).move("Folder", to: "Renamed")
        XCTAssertEqual(result.moves, ["Folder/b.md": "Renamed/b.md"])
        XCTAssertEqual(result.updated, ["a.md"])
        XCTAssertEqual(try harness.vault.read("a.md"), "# A\n\nSee [B](Renamed/b.md).\n")
    }

    func testWithoutTheNoteGraphAMoveIsPlainAndStillAnnounced() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self], files: notes)
        var events: [String] = []
        _ = harness.kernel.events.on(NotesWillMove.self) { events.append("will \($0.moves)") }
        _ = harness.kernel.events.on(NotesMoved.self) { events.append("did \($0.moves)") }

        let files = try files(harness)
        XCTAssertEqual(try files.move("Folder/b.md", to: "b.md"), MoveResult(moves: ["Folder/b.md": "b.md"], updated: []))
        XCTAssertEqual(try harness.vault.read("a.md"), notes["a.md"], "links are left as they are")
        XCTAssertEqual(try files.move("Folder", to: "Empty"), MoveResult(moves: [:], updated: []))
        try harness.vault.write("F/x.md", "")
        XCTAssertEqual(try files.move("F", to: "G/F"), MoveResult(moves: ["F/x.md": "G/F/x.md"], updated: []))
        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(events.first, "will \(["Folder/b.md": "b.md"])")
    }

    func testInvalidMovesAreRefusedAndChangeNothing() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self], files: notes)
        let files = try files(harness)
        XCTAssertThrowsError(try files.move("a.md", to: ".trash/a.md")) { XCTAssertEqual($0 as? FilesError, .hiddenPath(".trash/a.md")) }
        XCTAssertThrowsError(try files.move("a.md", to: ".loam/a.md")) { XCTAssertEqual($0 as? FilesError, .hiddenPath(".loam/a.md")) }
        XCTAssertThrowsError(try files.move("a.md", to: "Folder/.a.md"))
        XCTAssertThrowsError(try files.move("Folder", to: "Folder/Inner")) { XCTAssertEqual($0 as? FilesError, .moveIntoItself("Folder/Inner")) }
        XCTAssertThrowsError(try files.move("a.md", to: "Folder/b.md")) { XCTAssertEqual($0 as? VaultError, .alreadyExists(path: "Folder/b.md")) }
        XCTAssertThrowsError(try files.move("missing.md", to: "x.md")) { XCTAssertEqual($0 as? VaultError, .notFound(path: "missing.md")) }
        XCTAssertThrowsError(try files.move("a.md", to: ""))
        XCTAssertEqual(try harness.vault.markdownPaths(), ["Folder/b.md", "a.md"])
    }
}
