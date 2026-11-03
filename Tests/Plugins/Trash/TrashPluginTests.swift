import XCTest
import FileExplorerPlugin
import PluginKit
import PluginKitTesting
@testable import TrashPlugin

/// The `trash.*` commands, and `files.trash` recording its date through the service.
final class TrashPluginTests: XCTestCase {
    func testTrashingThroughFilesRecordsAndCommandsWork() async throws {
        let harness = try PluginTestHarness([FileExplorerPlugin.self, TrashPlugin.self], files: ["Notes/a.md": "hi"])
        var changes = 0
        _ = harness.kernel.events.on(TrashChanged.self) { _ in changes += 1 }
        let moved = try await harness.run("files.trash", ["path": "Notes/a.md"])
        XCTAssertTrue(moved.contains(".trash/Notes/a.md"))
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(try harness.vault.read(".trash/.trashed.json").contains("Notes/a.md"))

        let list = try await harness.run("trash.list")
        XCTAssertTrue(list.contains("\"originalPath\" : \"Notes/a.md\""))
        XCTAssertTrue(list.contains("\"daysLeft\" : 30"))

        _ = try await harness.run("trash.restore", ["path": ".trash/Notes/a.md"])
        XCTAssertEqual(try harness.vault.read("Notes/a.md"), "hi")

        _ = try await harness.run("files.trash", ["path": "Notes/a.md"])
        _ = try await harness.run("trash.delete", ["path": ".trash/Notes/a.md"])
        XCTAssertFalse(harness.vault.exists(".trash/Notes/a.md"))

        try harness.vault.write("b.md", "")
        _ = try await harness.run("files.trash", ["path": "b.md"])
        let emptied = try await harness.run("trash.empty")
        XCTAssertTrue(emptied.contains("1"))
        let purged = try await harness.run("trash.purge")
        XCTAssertTrue(purged.contains("deleted"))
    }

    func testRetentionSettingIsRead() throws {
        XCTAssertEqual(TrashPlugin.Settings().retentionDays, 30)
    }
}
