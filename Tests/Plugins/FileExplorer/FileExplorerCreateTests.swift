import XCTest
import PluginKit
import PluginKitTesting
@testable import FileExplorerPlugin

/// New notes and folders: default names, "Name 2" collisions, and refused names.
final class FileExplorerCreateTests: XCTestCase {
    private func files(_ harness: PluginTestHarness) throws -> FilesService {
        try XCTUnwrap(harness.kernel.services.service(.files))
    }

    func testNewNoteNamingAndCollisionsInRootAndSubfolder() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self], files: ["Projects/Untitled.md": "x"])
        let files = try files(harness)
        XCTAssertEqual(try files.newNote(in: "", name: nil), "Untitled.md")
        XCTAssertEqual(try files.newNote(in: "", name: nil), "Untitled 2.md")
        XCTAssertEqual(try files.newNote(in: "", name: nil), "Untitled 3.md")
        XCTAssertEqual(try files.newNote(in: "Projects", name: nil), "Projects/Untitled 2.md")
        XCTAssertEqual(try files.newNote(in: "Projects", name: " Plan "), "Projects/Plan.md")
        XCTAssertEqual(try files.newNote(in: "Projects", name: "Plan.md"), "Projects/Plan 2.md")
        XCTAssertEqual(try harness.vault.read("Untitled 2.md"), "")
        XCTAssertEqual(try harness.vault.read("Projects/Untitled.md"), "x", "an existing note is never overwritten")
    }

    func testNewNotePathWritesNothingAndSkipsTakenNames() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self], files: ["Inbox/Untitled.md": "x"])
        let files = try files(harness)
        XCTAssertEqual(try files.newNotePath(in: "Inbox", name: nil, isTaken: { _ in false }), "Inbox/Untitled 2.md")
        XCTAssertFalse(harness.vault.exists("Inbox/Untitled 2.md"), "only the path is chosen")
        let taken: Set<String> = ["Inbox/Untitled 2.md", "Inbox/Untitled 3.md"]
        XCTAssertEqual(try files.newNotePath(in: "Inbox", name: nil, isTaken: { taken.contains($0) }), "Inbox/Untitled 4.md")
    }

    func testNewNoteCreatesAMissingFolder() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self])
        XCTAssertEqual(try files(harness).newNote(in: "a/b", name: "c"), "a/b/c.md")
        XCTAssertTrue(harness.vault.exists("a/b/c.md"))
    }

    func testNewFolderNamingAndCollisions() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self], files: ["Notes/a.md": ""])
        let files = try files(harness)
        XCTAssertEqual(try files.newFolder(in: "", name: nil), "New folder")
        XCTAssertEqual(try files.newFolder(in: "", name: nil), "New folder 2")
        XCTAssertEqual(try files.newFolder(in: "", name: "Notes"), "Notes 2")
        XCTAssertEqual(try files.newFolder(in: "Notes", name: "Sub"), "Notes/Sub")
        XCTAssertEqual(try files.list("Notes"), [VaultEntry(path: "Notes/Sub", isFolder: true), VaultEntry(path: "Notes/a.md", isFolder: false)])
    }

    func testInvalidNamesAreRefused() throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self])
        let files = try files(harness)
        for name in ["", "   ", "a/b", ".hidden", ".md"] {
            XCTAssertThrowsError(try files.newNote(in: "", name: name), name)
            XCTAssertThrowsError(try files.newFolder(in: "", name: name), name)
        }
        XCTAssertThrowsError(try files.newNote(in: ".trash", name: "a")) {
            XCTAssertEqual($0 as? FilesError, .hiddenPath(".trash"))
        }
        XCTAssertThrowsError(try files.newFolder(in: "../outside", name: "a"))
        XCTAssertEqual(try files.tree(), [])
    }
}
