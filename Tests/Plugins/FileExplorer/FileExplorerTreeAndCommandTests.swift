import XCTest
import PluginKit
import PluginKitTesting
@testable import FileExplorerPlugin

/// The tree's shape and order, and the commands' JSON as the CLI and agents see it.
final class FileExplorerTreeAndCommandTests: XCTestCase {
    func testTreeIsDepthFirstWithFoldersFirst() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self], files: [
            "z.md": "", "B/y.md": "", "B/A/x.md": "", "a/c.md": "", ".loam/config.json": "{}",
        ])
        try harness.vault.createFolder("Empty")
        let files = try XCTUnwrap(harness.kernel.services.service(.files))
        XCTAssertEqual(try files.tree(), [
            FileNode(path: "a", isFolder: true, children: [FileNode(path: "a/c.md", isFolder: false, children: nil)]),
            FileNode(path: "B", isFolder: true, children: [
                FileNode(path: "B/A", isFolder: true, children: [FileNode(path: "B/A/x.md", isFolder: false, children: nil)]),
                FileNode(path: "B/y.md", isFolder: false, children: nil),
            ]),
            FileNode(path: "Empty", isFolder: true, children: []),
            FileNode(path: "z.md", isFolder: false, children: nil),
        ])
    }

    func testCommandsReturnJSON() async throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self], files: ["a.md": ""])
        let note = try await harness.run("files.new-note", ["folder": "N"])
        XCTAssertEqual(note, try JSON.string(["path": "N/Untitled.md"]))
        let folder = try await harness.run("files.new-folder", ["name": "F"])
        XCTAssertEqual(folder, try JSON.string(["path": "F"]))
        let moved = try await harness.run("files.move", ["from": "a.md", "to": "F/a.md"])
        XCTAssertEqual(moved, try JSON.string(MoveResult(moves: ["a.md": "F/a.md"], updated: [])))
        let trashed = try await harness.run("files.trash", ["path": "F/a.md"])
        XCTAssertEqual(trashed, try JSON.string(["path": ".trash/F/a.md"]))
        let inbox = try await harness.run("files.new-note", ["name": "Idea"])
        XCTAssertEqual(inbox, try JSON.string(["path": "Inbox/Idea.md"]), "without a folder, a note goes to the inbox")
        let atRoot = try await harness.run("files.new-note", ["folder": "", "name": "Top"])
        XCTAssertEqual(atRoot, try JSON.string(["path": "Top.md"]), "the root only when asked")
        XCTAssertFalse(harness.vault.exists("Top.md"), "the command picks a path and writes nothing: no empty note")
        let listed = try await harness.run("files.list")
        XCTAssertEqual(listed, try JSON.string([VaultEntry(path: "F", isFolder: true)]))
        let tree = try await harness.run("files.tree")
        let decoded = try JSONDecoder().decode([FileNode].self, from: Data(tree.utf8))
        XCTAssertEqual(decoded.map(\.path), ["F"])
        do {
            _ = try await harness.run("files.move", ["from": "F"])
            XCTFail("a missing argument should throw")
        } catch {
            XCTAssertEqual(error as? CommandError, .missingArgument(name: "to"))
        }
    }

    func testUnloadingRemovesTheServiceAndCommands() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self])
        XCTAssertNotNil(harness.kernel.services.service(.files))
        harness.host.deactivateAll()
        XCTAssertNil(harness.kernel.services.service(.files))
        XCTAssertNil(harness.kernel.commands.command(id: "files.tree"))
    }
}
