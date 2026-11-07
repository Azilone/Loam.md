import XCTest
import NoteGraphPlugin
import PluginKit
import PluginKitTesting
@testable import NoteQueryPlugin

/// The query's notes carry their modification time, kept up to date file by file as the vault changes.
final class NoteQueryStampTests: XCTestCase {
    func testAChangedNoteIsStampedAgainAndARemovedOneForgotten() throws {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, NoteQueryPlugin.self], files: ["a.md": "a\n", "b.md": "b\n"])
        let query = try XCTUnwrap(harness.kernel.services.service(.noteQuery))
        let engine = try XCTUnwrap(query as? NoteQueryEngine)
        XCTAssertEqual(query.run(NoteQuery()).map(\.path), ["a.md", "b.md"])
        let before = try XCTUnwrap(query.run(NoteQuery()).first { $0.path == "a.md" }).modified

        let url = harness.vault.rootURL.appendingPathComponent("a.md")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: before + 100)], ofItemAtPath: url.path)
        engine.update([VaultChange(kind: .modified, path: "a.md")])
        XCTAssertEqual(try XCTUnwrap(query.run(NoteQuery()).first { $0.path == "a.md" }?.modified), before + 100, accuracy: 0.01)

        try FileManager.default.removeItem(at: harness.vault.rootURL.appendingPathComponent("b.md"))
        engine.update([VaultChange(kind: .removed, path: "b.md")])
        engine.update([VaultChange(kind: .removed, path: "Gone folder")])
        XCTAssertEqual(try XCTUnwrap(query.run(NoteQuery()).first { $0.path == "a.md" }?.modified), before + 100, accuracy: 0.01, "stamped again after a walk")
    }
}
