import XCTest
import PluginKit
@testable import LoamCore

final class VaultTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testWriteCreatesFoldersAndReadReturnsContents() throws {
        let vault = Vault(rootURL: root)
        try vault.write("a/b/note.md", "# Hi\n")
        XCTAssertEqual(try vault.read("a/b/note.md"), "# Hi\n")
        XCTAssertTrue(vault.exists("a/b/note.md"))
        XCTAssertFalse(vault.exists("a/b/missing.md"))
    }

    func testALinkInsideTheVaultNeverLeadsOut() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "secret".write(to: outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: root.appendingPathComponent("out"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("broken.md"),
                                  withDestinationURL: outside.appendingPathComponent("new.md"))
        let vault = Vault(rootURL: root)

        XCTAssertThrowsError(try vault.read("out/secret.md"))
        XCTAssertThrowsError(try vault.write("out/secret.md", "gone"))
        XCTAssertThrowsError(try vault.write("out/deep/new.md", "x"))
        XCTAssertThrowsError(try vault.write("broken.md", "x"))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("secret.md"), encoding: .utf8), "secret")
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("new.md").path))

        // A link that stays inside works.
        try vault.write("real/note.md", "hi")
        try fm.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("real"))
        XCTAssertEqual(try vault.read("alias/note.md"), "hi")
    }

    func testListingIsRelativeSortedAndSkipsHidden() throws {
        let vault = Vault(rootURL: root)
        try vault.write("b.md", "")
        try vault.write("a/z.md", "")
        try vault.write(".loam/config.md", "")
        try vault.write("a/image.png", "")
        XCTAssertEqual(try vault.markdownPaths(), ["a/z.md", "b.md"])
    }

    func testPathsCannotLeaveTheVault() {
        let vault = Vault(rootURL: root)
        XCTAssertThrowsError(try vault.read("../secret.md"))
        XCTAssertThrowsError(try vault.write("/etc/passwd", ""))
        XCTAssertThrowsError(try vault.write("a/../../x.md", ""))
        XCTAssertFalse(vault.exists("../secret.md"))
    }

    func testMoveRefusesToOverwrite() throws {
        let vault = Vault(rootURL: root)
        try vault.write("a.md", "A")
        try vault.write("b.md", "B")
        XCTAssertThrowsError(try vault.move("a.md", to: "b.md")) { error in
            XCTAssertEqual(error as? VaultError, .alreadyExists(path: "b.md"))
        }
        try vault.move("a.md", to: "sub/c.md")
        XCTAssertEqual(try vault.read("sub/c.md"), "A")
        XCTAssertFalse(vault.exists("a.md"))
    }

    func testMoveTakesAFolderWithItsContents() throws {
        let vault = Vault(rootURL: root)
        try vault.write("a/n.md", "N")
        try vault.write("a/sub/img.png", "")
        try vault.write("b/x.md", "")
        XCTAssertThrowsError(try vault.move("a", to: "b")) { error in
            XCTAssertEqual(error as? VaultError, .alreadyExists(path: "b"))
        }
        try vault.move("a", to: "deep/er/a2")
        XCTAssertEqual(try vault.read("deep/er/a2/n.md"), "N")
        XCTAssertTrue(vault.exists("deep/er/a2/sub/img.png"))
        XCTAssertFalse(vault.exists("a"))
    }

    func testListShowsOneLevelFoldersFirstAndHidesHiddenEntries() throws {
        let vault = Vault(rootURL: root)
        try vault.write("b.md", "")
        try vault.write("A.md", "")
        try vault.write("zeta/n.md", "")
        try vault.write("Alpha/deep/n.md", "")
        try vault.write(".loam/config.json", "{}")
        try vault.write(".trash/old.md", "")
        try vault.write(".hidden.md", "")
        XCTAssertEqual(try vault.list(""), [
            VaultEntry(path: "Alpha", isFolder: true),
            VaultEntry(path: "zeta", isFolder: true),
            VaultEntry(path: "A.md", isFolder: false),
            VaultEntry(path: "b.md", isFolder: false),
        ])
        XCTAssertEqual(try vault.list("Alpha"), [VaultEntry(path: "Alpha/deep", isFolder: true)])
        XCTAssertThrowsError(try vault.list("missing")) { error in
            XCTAssertEqual(error as? VaultError, .notFound(path: "missing"))
        }
        XCTAssertThrowsError(try vault.list("b.md"))
        XCTAssertThrowsError(try vault.list("../"))
    }

    func testCreateFolderMakesParentsIsIdempotentAndRefusesAFile() throws {
        let vault = Vault(rootURL: root)
        try vault.createFolder("x/y/z")
        try vault.createFolder("x/y/z")
        XCTAssertEqual(try vault.list("x/y"), [VaultEntry(path: "x/y/z", isFolder: true)])
        try vault.write("file.md", "")
        XCTAssertThrowsError(try vault.createFolder("file.md")) { error in
            XCTAssertEqual(error as? VaultError, .alreadyExists(path: "file.md"))
        }
    }

    func testVaultPathHelpers() throws {
        XCTAssertEqual(try VaultPath.normalize("a/./b//c/../d.md"), "a/b/d.md")
        XCTAssertEqual(VaultPath.directory(of: "a/b/c.md"), "a/b")
        XCTAssertEqual(VaultPath.directory(of: "c.md"), "")
        XCTAssertEqual(try VaultPath.resolve("../x.md", from: "a/b/c.md"), "a/x.md")
        XCTAssertEqual(try VaultPath.resolve("x.md", from: "c.md"), "x.md")
        XCTAssertThrowsError(try VaultPath.resolve("../../x.md", from: "a/c.md"))
    }
}

final class VaultWatchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRefreshReportsAddedModifiedAndRemovedNotes() throws {
        let vault = Vault(rootURL: root)
        try vault.write("keep.md", "same")
        try vault.write("edit.md", "one")
        try vault.write("gone.md", "bye")
        let kernel = Kernel(vault: vault)
        XCTAssertEqual(try kernel.refreshVault(), [], "the first call only records the starting point")

        var events: [[VaultChange]] = []
        _ = kernel.events.on(VaultChanged.self) { events.append($0.changes) }
        try vault.write("new.md", "hello")
        try vault.write("edit.md", "one and more")
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.md"))

        let changes = try kernel.refreshVault()
        XCTAssertEqual(changes, [
            VaultChange(kind: .removed, path: "gone.md"),
            VaultChange(kind: .modified, path: "edit.md"),
            VaultChange(kind: .added, path: "new.md"),
        ].sorted { $0.path < $1.path })
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(try kernel.refreshVault(), [])
        XCTAssertEqual(events.count, 1, "no event when nothing changed")
    }

    func testRefreshReportsEveryFileNotOnlyNotes() throws {
        let vault = Vault(rootURL: root)
        try vault.write("Boards/Plan.canvas", "{}")
        try vault.write("todo.txt", "one")
        try vault.write("Empty/.keep", "")
        try vault.write(".loam/state.json", "{}")
        let kernel = Kernel(vault: vault)
        XCTAssertEqual(try kernel.refreshVault(), [])
        XCTAssertEqual(try vault.markdownPaths(), [], "notes only")
        XCTAssertEqual(Set(try vault.stamps().keys), ["Boards/Plan.canvas", "todo.txt"], "files, not folders or hidden ones")

        var events: [VaultChanged] = []
        _ = kernel.events.on(VaultChanged.self) { events.append($0) }
        try vault.write("Boards/Plan.canvas", "{\"nodes\":[]}")
        try vault.write("Boards/Next.canvas", "{}")
        try vault.write("note.md", "")
        try FileManager.default.removeItem(at: root.appendingPathComponent("todo.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("New folder"), withIntermediateDirectories: true)
        try vault.write(".loam/state.json", "{\"changed\":true}")

        XCTAssertEqual(try kernel.refreshVault(), [
            VaultChange(kind: .added, path: "Boards/Next.canvas"),
            VaultChange(kind: .modified, path: "Boards/Plan.canvas"),
            VaultChange(kind: .added, path: "note.md"),
            VaultChange(kind: .removed, path: "todo.txt"),
        ])
        XCTAssertEqual(events.first?.noteChanges, [VaultChange(kind: .added, path: "note.md")])
    }

    func testWriteDataStoresBinaryFiles() throws {
        let vault = Vault(rootURL: root)
        try vault.writeData("img/a.bin", Data([0, 1, 2, 255]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("img/a.bin")), Data([0, 1, 2, 255]))
        XCTAssertThrowsError(try vault.writeData("../x.bin", Data()))
    }

    func testRemoveIfEmptyOnlyRemovesNotesHoldingNothing() throws {
        let vault = Vault(rootURL: root)
        try vault.write("blank.md", "")
        try vault.write("spaces.md", " \n\n")
        try vault.write("properties.md", "---\ntags: [a]\n---\n\n")
        try vault.write("text.md", "x\n")
        try vault.write("folder/inside.md", "")
        XCTAssertTrue(try vault.removeIfEmpty("blank.md"))
        XCTAssertTrue(try vault.removeIfEmpty("spaces.md"))
        XCTAssertFalse(try vault.removeIfEmpty("properties.md"), "properties are content")
        XCTAssertFalse(try vault.removeIfEmpty("text.md"), "a note with text is never removed")
        XCTAssertFalse(try vault.removeIfEmpty("missing.md"))
        XCTAssertFalse(try vault.removeIfEmpty("folder"), "a folder is never removed")
        XCTAssertFalse(vault.exists("blank.md") || vault.exists("spaces.md"))
        XCTAssertTrue(vault.exists("properties.md"))
        XCTAssertEqual(try vault.read("text.md"), "x\n")
        XCTAssertTrue(vault.exists("folder/inside.md"))
    }

    func testNoteContentIsEmptyForWhitespaceAndPropertylessFrontmatterOnly() {
        XCTAssertTrue(NoteContent.isEmpty(""))
        XCTAssertTrue(NoteContent.isEmpty("  \n\t\n"))
        XCTAssertTrue(NoteContent.isEmpty("---\n---\n"))
        XCTAssertTrue(NoteContent.isEmpty("---\n# note\n\n---\n"))
        XCTAssertFalse(NoteContent.isEmpty("---\ntitle: x\n---\n"), "a typed property is content")
        XCTAssertFalse(NoteContent.isEmpty("---\ntitle: x\n---\nText"))
        XCTAssertFalse(NoteContent.isEmpty("# Title"))
        XCTAssertFalse(NoteContent.isEmpty("---\nnot closed\n"), "an unclosed block is text")
    }
}
