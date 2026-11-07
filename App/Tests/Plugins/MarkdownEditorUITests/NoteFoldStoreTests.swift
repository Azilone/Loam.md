import Foundation
import PluginKitTesting
import XCTest
@testable import MarkdownEditorUI

/// The folded headings kept per note, so they outlive the tab that showed it.
@MainActor
final class NoteFoldStoreTests: XCTestCase {
    func testFoldsComeBackForTheirNoteAfterARestart() throws {
        let vault = try TemporaryVault()
        let store = NoteFoldStore(vault: vault)
        store.set([6, 40], in: "A.md")
        store.set([12], in: "Projects/B.md")

        let restarted = NoteFoldStore(vault: vault)
        XCTAssertEqual(restarted.folded(in: "A.md"), [6, 40])
        XCTAssertEqual(restarted.folded(in: "Projects/B.md"), [12])
        XCTAssertEqual(restarted.folded(in: "C.md"), [])
    }

    func testUnfoldingEverythingForgetsTheNote() throws {
        let vault = try TemporaryVault()
        let store = NoteFoldStore(vault: vault)
        store.set([6], in: "A.md")
        store.set([], in: "A.md")

        XCTAssertEqual(NoteFoldStore(vault: vault).folded(in: "A.md"), [])
        XCTAssertFalse(try vault.read(NoteFoldStore.path).contains("A.md"))
    }

    func testAnUnreadableFileIsAnEmptyStore() throws {
        let vault = try TemporaryVault()
        try vault.write(NoteFoldStore.path, "not json")
        XCTAssertEqual(NoteFoldStore(vault: vault).folded(in: "A.md"), [])
    }
}
