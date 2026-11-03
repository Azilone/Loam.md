import XCTest
import PluginKit
import PluginKitTesting
@testable import NoteGraphPlugin

final class NoteGraphIndexTests: XCTestCase {
    /// Saving notes one by one updates the backlinks in place; they must match a reindex from scratch.
    func testAppliedChangesGiveTheBacklinksOfAFullReindex() throws {
        let vault = try TemporaryVault()
        for name in ["A", "B", "C", "D"] { try vault.write("\(name).md", "# \(name)\n") }
        let index = NoteGraphIndex(vault: vault)
        try index.reindex()

        let edits: [(String, String)] = [
            ("C.md", "[A](A.md) and [B](B.md), [A](A.md) again"),
            ("A.md", "[B](B.md) [A](A.md)"),
            ("D.md", "[A](A.md)"),
            ("C.md", "only [B](B.md)"),
            ("B.md", "[C](C.md) #work"),
        ]
        for (path, text) in edits {
            try vault.write(path, text)
            index.apply([VaultChange(kind: .modified, path: path)])
        }
        try FileManager.default.removeItem(at: vault.url("D.md"))
        index.apply([VaultChange(kind: .removed, path: "D.md")])

        let fresh = NoteGraphIndex(vault: vault)
        try fresh.reindex()
        for path in ["A.md", "B.md", "C.md", "D.md"] {
            XCTAssertEqual(index.backlinks(to: path), fresh.backlinks(to: path), path)
        }
        XCTAssertEqual(index.backlinks(to: "B.md"), ["A.md", "C.md"])
        XCTAssertEqual(index.notes(tagged: "#WORK").map(\.path), ["B.md"])
    }
}
