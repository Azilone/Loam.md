import XCTest
import NoteGraphPlugin
import PluginKit
import PluginKitTesting
@testable import FileExplorerPlugin

/// Trash is a move into `.trash/`, recoverable, and invisible to the explorer.
final class FileExplorerTrashTests: XCTestCase {
    private func files(_ harness: PluginTestHarness) throws -> FilesService {
        try XCTUnwrap(harness.kernel.services.service(.files))
    }

    func testTrashingANoteKeepsItsFolderPathAndRewritesNoLink() throws {
        let harness = try PluginTestHarness(
            [NoteGraphPlugin.self, FileExplorerPlugin.self],
            files: ["a.md": "[B](Folder/b.md)\n", "Folder/b.md": "# B\n"]
        )
        XCTAssertEqual(try files(harness).trash("Folder/b.md"), ".trash/Folder/b.md")
        XCTAssertEqual(try String(contentsOf: harness.vault.url(".trash/Folder/b.md"), encoding: .utf8), "# B\n")
        XCTAssertEqual(try harness.vault.read("a.md"), "[B](Folder/b.md)\n", "the link now points to a missing file")
    }

    func testTrashCollisionsGetASuffixBeforeTheExtension() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self], files: ["n.md": "1", "Folder/x.png": ""])
        let files = try files(harness)
        XCTAssertEqual(try files.trash("n.md"), ".trash/n.md")
        try harness.vault.write("n.md", "2")
        XCTAssertEqual(try files.trash("n.md"), ".trash/n 2.md")
        XCTAssertEqual(try files.trash("Folder"), ".trash/Folder")
        try harness.vault.createFolder("Folder")
        XCTAssertEqual(try files.trash("Folder"), ".trash/Folder 2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.vault.url(".trash/Folder/x.png").path))
    }

    func testListAndTreeNeverShowTheTrash() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self], files: ["a.md": "", "b.md": ""])
        let files = try files(harness)
        _ = try files.trash("a.md")
        XCTAssertEqual(try files.list(""), [VaultEntry(path: "b.md", isFolder: false)])
        XCTAssertEqual(try files.tree(), [FileNode(path: "b.md", isFolder: false, children: nil)])
    }

    func testTrashRefusesTheRootMissingFilesAndTheTrashItself() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self], files: ["a.md": ""])
        let files = try files(harness)
        _ = try files.trash("a.md")
        XCTAssertThrowsError(try files.trash(""))
        XCTAssertThrowsError(try files.trash("missing.md")) { XCTAssertEqual($0 as? VaultError, .notFound(path: "missing.md")) }
        XCTAssertThrowsError(try files.trash(".trash/a.md")) { XCTAssertEqual($0 as? FilesError, .alreadyInTrash(".trash/a.md")) }
        XCTAssertThrowsError(try files.trash(".trash")) { XCTAssertEqual($0 as? FilesError, .alreadyInTrash(".trash")) }
    }
}
