import Foundation
import PluginKitTesting
import PluginKitUI
import XCTest
@testable import MarkdownEditorUI

/// The shared documents, without views: saving, reloading, moves, deletions and reference counting.
@MainActor
final class DocumentStoreTests: XCTestCase {
    private var vault: TemporaryVault!
    private var store: DocumentStore!

    override func setUp() async throws {
        vault = try TemporaryVault()
        try vault.write("First.md", "# First\n")
        try vault.write("Projects/Second.md", "no heading")
        store = DocumentStore(vault: vault, saveDelay: .milliseconds(10))
    }

    func testTypingIsSavedShortlyAfterAndOurOwnSaveDoesNotReload() async throws {
        let document = try XCTUnwrap(store.acquire("First.md"))
        let editor = UUID()
        document.edit("# First\n\nedited", from: editor)
        XCTAssertEqual(document.revision, 1)
        XCTAssertTrue(document.hasUnsavedChanges)
        try await waitUntil { !document.hasUnsavedChanges }
        XCTAssertEqual(try vault.read("First.md"), "# First\n\nedited")

        store.vaultChanged([VaultChange(kind: .modified, path: "First.md")])
        XCTAssertEqual(document.revision, 1, "saving our own edit must not reload the editor")
        XCTAssertEqual(document.lastEditor, editor)
    }

    func testAnOutsideChangeReloads() throws {
        let document = try XCTUnwrap(store.acquire("First.md"))
        try vault.write("First.md", "# From outside\n")
        store.vaultChanged([VaultChange(kind: .modified, path: "First.md")])
        XCTAssertEqual(document.text, "# From outside\n")
        XCTAssertEqual(document.revision, 1)
        XCTAssertNil(document.lastEditor, "a reload is nobody's edit, so every editor shows it")
    }

    func testUnsavedEditsWinOverAnOutsideChange() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        let document = try XCTUnwrap(store.acquire("First.md"))
        document.edit("mine", from: UUID())
        try vault.write("First.md", "# Theirs\n")
        store.vaultChanged([VaultChange(kind: .modified, path: "First.md")])
        XCTAssertEqual(document.text, "mine")
        store.saveAll()
        XCTAssertEqual(try vault.read("First.md"), "mine")
        XCTAssertEqual(try vault.read("First (changed on disk).md"), "# Theirs\n", "the outside version is kept")
        XCTAssertNotNil(document.errorMessage)
    }

    func testOurOwnSaveSeenLateKeepsNoCopy() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        let document = try XCTUnwrap(store.acquire("First.md"))
        document.edit("one", from: UUID())
        store.saveAll()
        document.edit("two", from: UUID())
        store.vaultChanged([VaultChange(kind: .modified, path: "First.md")])
        XCTAssertFalse(vault.exists("First (changed on disk).md"))
        XCTAssertNil(document.errorMessage)
    }

    func testOneDocumentPerPathCountedAndSavedWhenTheLastViewGoes() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        let first = try XCTUnwrap(store.acquire("First.md"))
        let second = try XCTUnwrap(store.acquire("First.md"))
        XCTAssertTrue(first === second)
        XCTAssertEqual(store.viewCount(at: "First.md"), 2)

        first.edit("pending", from: UUID())
        store.release(first)
        XCTAssertEqual(store.openPaths, ["First.md"])
        XCTAssertEqual(try vault.read("First.md"), "# First\n", "still open in another view: not flushed yet")
        store.release(second)
        XCTAssertEqual(store.openPaths, [])
        XCTAssertEqual(try vault.read("First.md"), "pending", "the last view going saves")
    }

    func testAMissingFileHasNoDocument() {
        XCTAssertNil(store.acquire("Missing.md"))
        XCTAssertEqual(store.openPaths, [])
    }

    func testAMissingNoteOpensBlankAndIsOnlyCreatedOnceItHoldsText() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        let document = try XCTUnwrap(store.acquire("Daily/2026-01-01.md", allowMissing: true))
        XCTAssertEqual(document.text, "")
        XCTAssertFalse(document.existsOnDisk)
        document.edit("  \n", from: UUID())
        document.saveNow()
        XCTAssertFalse(vault.exists("Daily/2026-01-01.md"), "blank text leaves no file")
        document.edit("Hello\n", from: UUID())
        store.release(document)
        XCTAssertEqual(try vault.read("Daily/2026-01-01.md"), "Hello\n")
        XCTAssertTrue(document.existsOnDisk)
    }

    func testLookingAtAMissingNoteWritesNothing() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        let document = try XCTUnwrap(store.acquire("Daily/2026-01-02.md", allowMissing: true))
        store.release(document)
        XCTAssertFalse(vault.exists("Daily/2026-01-02.md"))
        XCTAssertFalse(vault.exists("Daily"), "not even its folder")
    }

    func testADraftOpensBlankAndLeavesNoFileWhileUntouched() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        XCTAssertNil(store.acquire("Inbox/Untitled.md"), "a path nobody announced is not a note")
        store.beginDraft("Inbox/Untitled.md")
        XCTAssertTrue(store.isDraft("Inbox/Untitled.md"))
        let document = try XCTUnwrap(store.acquire("Inbox/Untitled.md"))
        XCTAssertFalse(document.existsOnDisk)
        store.saveAll()
        store.release(document)
        XCTAssertFalse(vault.exists("Inbox/Untitled.md"))
        XCTAssertFalse(vault.exists("Inbox"), "not even its folder")
        XCTAssertFalse(store.isDraft("Inbox/Untitled.md"), "its name is free again")
        XCTAssertNotNil(store.acquire("Inbox/Untitled.md"), "Back to a dropped draft opens it blank")
    }

    func testADraftKeepsItsTemplateUntouchedAndWritesOnceChanged() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        store.beginDraft("Daily/2026-02-01.md", text: "## Log\n")
        let document = try XCTUnwrap(store.acquire("Daily/2026-02-01.md"))
        XCTAssertEqual(document.text, "## Log\n")
        document.edit("## Log\n", from: UUID())
        document.saveNow()
        XCTAssertFalse(vault.exists("Daily/2026-02-01.md"), "an untouched template is not a note")
        document.edit("## Log\n- did a thing\n", from: UUID())
        store.release(document)
        XCTAssertEqual(try vault.read("Daily/2026-02-01.md"), "## Log\n- did a thing\n")
    }

    func testANoteTypedThenEmptiedStaysOffTheDiskWhenItsLastViewCloses() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        store.beginDraft("Inbox/Untitled.md")
        let first = try XCTUnwrap(store.acquire("Inbox/Untitled.md"))
        let second = try XCTUnwrap(store.acquire("Inbox/Untitled.md"))
        first.edit("hello", from: UUID())
        first.saveNow()
        XCTAssertTrue(vault.exists("Inbox/Untitled.md"))
        first.edit("  \n", from: UUID())
        first.saveNow()
        XCTAssertFalse(vault.exists("Inbox/Untitled.md"), "an emptied new note leaves the disk at once")
        store.release(second)
        store.release(first)
        XCTAssertFalse(vault.exists("Inbox/Untitled.md"), "and stays off it when the last view closes")
    }

    func testAnEmptiedNewNoteLeavesTheDiskAtOnceAndStaysAnOpenDraft() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        store.beginDraft("Inbox/Untitled.md")
        let document = try XCTUnwrap(store.acquire("Inbox/Untitled.md"))
        document.edit("x", from: UUID())
        document.saveNow()
        XCTAssertTrue(vault.exists("Inbox/Untitled.md"))
        document.edit("", from: UUID())
        document.saveNow()
        XCTAssertFalse(vault.exists("Inbox/Untitled.md"))
        XCTAssertTrue(store.isDraft("Inbox/Untitled.md"), "its name is taken while the tab shows it")
        store.vaultChanged([VaultChange(kind: .removed, path: "Inbox/Untitled.md")])
        XCTAssertFalse(document.isClosed, "the removal is our own")
        document.edit("again", from: UUID())
        document.saveNow()
        XCTAssertEqual(try vault.read("Inbox/Untitled.md"), "again")
    }

    func testPropertiesTypedInANewNoteAreSavedAndKept() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        store.beginDraft("Inbox/Untitled.md")
        let document = try XCTUnwrap(store.acquire("Inbox/Untitled.md"))
        document.edit("---\ntags: a\n---\n", from: UUID())
        document.saveNow()
        XCTAssertEqual(try vault.read("Inbox/Untitled.md"), "---\ntags: a\n---\n")
        store.release(document)
        XCTAssertTrue(vault.exists("Inbox/Untitled.md"), "properties are content")
    }

    func testAWrittenThenVanishedNoteDoesNotReopenBlank() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        store.beginDraft("Inbox/Untitled.md")
        let document = try XCTUnwrap(store.acquire("Inbox/Untitled.md"))
        document.edit("x", from: UUID())
        document.saveNow()
        document.edit("", from: UUID())
        store.release(document)
        XCTAssertNil(store.acquire("Inbox/Untitled.md"))
    }

    func testClosingTheAppRemovesEmptiedNewNotesButNeverOlderOnes() throws {
        try vault.write("Old blank.md", "")
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        store.beginDraft("Inbox/Untitled.md")
        let draft = try XCTUnwrap(store.acquire("Inbox/Untitled.md"))
        draft.edit("x", from: UUID())
        draft.saveNow()
        draft.edit("", from: UUID())
        _ = try XCTUnwrap(store.acquire("Old blank.md"))
        store.discardEmptyNotes()
        XCTAssertFalse(vault.exists("Inbox/Untitled.md"))
        XCTAssertTrue(vault.exists("Old blank.md"), "a file that existed before is never removed")
    }

    func testAnOlderEmptyNoteStaysWhenItsTabCloses() throws {
        try vault.write("Old blank.md", "")
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        store.release(try XCTUnwrap(store.acquire("Old blank.md")))
        XCTAssertTrue(vault.exists("Old blank.md"))
    }

    func testRenamingADraftMovesItWithoutAFile() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        store.beginDraft("Inbox/Untitled.md")
        let document = try XCTUnwrap(store.acquire("Inbox/Untitled.md"))
        store.didMove(["Inbox/Untitled.md": "Inbox/Plan.md"])
        XCTAssertEqual(document.path, "Inbox/Plan.md")
        XCTAssertTrue(store.isDraft("Inbox/Plan.md"))
        XCTAssertFalse(store.isDraft("Inbox/Untitled.md"))
        document.edit("text", from: UUID())
        store.release(document)
        XCTAssertEqual(try vault.read("Inbox/Plan.md"), "text")
        XCTAssertFalse(vault.exists("Inbox/Untitled.md"))
    }

    func testARemovalEventForAFileThatCameBackReloadsInsteadOfClosing() throws {
        let document = try XCTUnwrap(store.acquire("First.md"))
        try vault.write("First.md", "# Rewritten\n")
        store.vaultChanged([VaultChange(kind: .removed, path: "First.md")])
        XCTAssertFalse(document.isClosed)
        XCTAssertEqual(document.text, "# Rewritten\n")
    }

    func testAMissingNoteTakesTheFileWhenAnotherPluginCreatesIt() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        let document = try XCTUnwrap(store.acquire("Daily/2026-01-03.md", allowMissing: true))
        try vault.write("Daily/2026-01-03.md", "From a command\n")
        store.didChange("Daily/2026-01-03.md")
        XCTAssertEqual(document.text, "From a command\n")
        XCTAssertTrue(document.existsOnDisk)
    }

    func testDocumentsAreSavedBeforeAMoveAndFollowIt() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        let document = try XCTUnwrap(store.acquire("First.md"))
        document.edit("pending", from: UUID())
        store.willMove(["First.md": "Moved.md"])
        XCTAssertEqual(try vault.read("First.md"), "pending", "flushed before the files move")
        try vault.move("First.md", to: "Moved.md")
        store.didMove(["First.md": "Moved.md"])
        XCTAssertTrue(store.document(at: "Moved.md") === document)
        XCTAssertNil(store.document(at: "First.md"))
        XCTAssertEqual(document.path, "Moved.md")
        store.release(document)
        XCTAssertEqual(store.openPaths, [], "released under its new path")
    }

    func testAChainOfMovesKeepsEveryDocument() throws {
        let a = try XCTUnwrap(store.acquire("First.md"))
        let b = try XCTUnwrap(store.acquire("Projects/Second.md"))
        store.didMove(["First.md": "Projects/Second.md", "Projects/Second.md": "Third.md"])
        XCTAssertTrue(store.document(at: "Projects/Second.md") === a)
        XCTAssertTrue(store.document(at: "Third.md") === b)
    }

    func testARemovedNoteIsClosedAndNotWrittenBack() async throws {
        let document = try XCTUnwrap(store.acquire("First.md"))
        document.edit("pending", from: UUID())
        try FileManager.default.removeItem(at: vault.url("First.md"))
        store.vaultChanged([VaultChange(kind: .removed, path: "First.md")])
        XCTAssertTrue(document.isClosed)
        XCTAssertEqual(store.openPaths, [])
        try await Task.sleep(for: .milliseconds(50))
        document.edit("typed after", from: UUID())
        store.release(document)
        XCTAssertFalse(vault.exists("First.md"))
    }

    func testSaveAllWritesEveryPendingEdit() throws {
        let store = DocumentStore(vault: vault, saveDelay: .seconds(60))
        store.acquire("First.md")?.edit("one", from: UUID())
        store.acquire("Projects/Second.md")?.edit("two", from: UUID())
        store.saveAll()
        XCTAssertEqual(try vault.read("First.md"), "one")
        XCTAssertEqual(try vault.read("Projects/Second.md"), "two")
    }

    func testLinksResolveToNotesFilesAndURLs() throws {
        try vault.writeData("Projects/photo.png", Data())
        XCTAssertEqual(NoteLinks.resolve("Projects/Second.md", from: "First.md", vault: vault), .note("Projects/Second.md"))
        XCTAssertEqual(NoteLinks.resolve("../First.md#top", from: "Projects/Second.md", vault: vault), .note("First.md"))
        XCTAssertEqual(
            NoteLinks.resolve("photo.png", from: "Projects/Second.md", vault: vault),
            .file("Projects/photo.png")
        )
        XCTAssertEqual(
            NoteLinks.resolve("https://example.com", from: "First.md", vault: vault),
            .external(URL(string: "https://example.com")!)
        )
        try vault.write("My note.md", "")
        XCTAssertEqual(NoteLinks.resolve("My%20note.md", from: "First.md", vault: vault), .note("My note.md"))
        XCTAssertNil(NoteLinks.resolve("Missing.md", from: "First.md", vault: vault))
        XCTAssertNil(NoteLinks.resolve("../../outside.md", from: "First.md", vault: vault))
    }
}
