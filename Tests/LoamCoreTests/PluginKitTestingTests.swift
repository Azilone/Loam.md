import XCTest
import PluginKit
import PluginKitTesting

final class PluginKitTestingTests: XCTestCase {
    func testTemporaryVaultIsRemovedWhenReleased() throws {
        var vault: TemporaryVault? = try TemporaryVault()
        try vault?.write("a/n.md", "# N\n")
        let root = try XCTUnwrap(vault?.rootURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(vault?.url("a/n.md")).path))
        vault = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testHarnessReportsAnUnknownCommand() async throws {
        let harness = try PluginTestHarness([], files: ["n.md": "N"])
        XCTAssertEqual(try harness.vault.read("n.md"), "N")
        do {
            _ = try await harness.run("missing.command")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? PluginTestHarnessError, .unknownCommand(id: "missing.command"))
        }
    }
}
