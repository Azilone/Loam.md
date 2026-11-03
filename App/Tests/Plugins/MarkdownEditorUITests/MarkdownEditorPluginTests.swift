import AppKit
import BuiltinPlugins
import Foundation
import MarkdownEditor
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import MarkdownEditorUI

/// Adds a `/` item when an editor is there, as any plugin would.
private final class SlashItemPlugin: UIPlugin {
    static let manifest = PluginManifest(id: "test.slash", name: "Slash", version: "1.0", optionalRequires: ["editor"])

    init() {}

    @MainActor func activateUI(context: PluginContext) throws {
        context.addSlashItem(SlashItem(id: "test.date", title: "Date", symbol: "calendar") { _, trigger in
            TextChange(range: trigger, replacement: "2026-10-18", selection: NSRange(location: trigger.location + 10, length: 0))
        })
    }
}

/// Shows ` ```demo ` blocks as a live view, as a collections plugin shows ` ```base `; keeps the contexts it got.
private final class LiveBlockPlugin: UIPlugin {
    static let manifest = PluginManifest(id: "test.live", name: "Live", version: "1.0", optionalRequires: ["editor"])
    @MainActor static var contexts: [CodeBlockContext] = []

    init() {}

    @MainActor func activateUI(context: PluginContext) throws {
        context.addCodeBlockView(CodeBlockView(id: "test.demo", languages: ["Demo"]) { block in
            LiveBlockPlugin.contexts.append(block)
            return AnyView(Text(block.code))
        })
    }
}

/// The plugin end to end in the UI harness, with the note graph: view type, `editor` service, documents shared by
/// views and following moves.
@MainActor
final class MarkdownEditorPluginTests: XCTestCase {
    private let files = [
        "First.md": "# First\n\nSee [second](Projects/Second.md).\n",
        "Projects/Second.md": "# Second\n",
        "Live.md": "Intro\n\n```demo\nhello\n```\n",
        "photo.png": "",
    ]
    private var harness: UIPluginHarness!

    override func setUp() async throws {
        harness = try UIPluginHarness(
            logicPlugins: builtinPlugins,
            uiPlugins: [MarkdownEditorPlugin.self, SlashItemPlugin.self, LiveBlockPlugin.self],
            files: files
        )
        XCTAssertEqual(harness.report.failed, [:])
    }

    override func tearDown() async throws {
        harness.close()
    }

    private var service: MarkdownEditorService? {
        harness.kernel.services.service(.editor) as? MarkdownEditorService
    }

    private func render(_ path: String, active: Bool = true, state: EditorTabState? = nil) throws -> NSView {
        let data = try state.map { try JSONEncoder().encode($0) }
        let context = ViewContext(resource: .file(path), state: data, isActive: active)
        let type = try XCTUnwrap(harness.views.viewTypes(for: .file(path)).first)
        return harness.render(type.makeView(context))
    }

    // MARK: Registration

    func testTheViewTypeOpensMarkdownFilesOnly() {
        XCTAssertEqual(harness.views.viewTypes(for: .file("First.md")).map(\.id), [MarkdownEditorPlugin.viewTypeID])
        XCTAssertEqual(harness.views.viewTypes(for: .file("Notes/UPPER.MD")).map(\.id), [MarkdownEditorPlugin.viewTypeID])
        XCTAssertEqual(harness.views.all.first?.title, "Markdown")
        XCTAssertTrue(harness.views.viewTypes(for: .file("photo.png")).isEmpty)
        XCTAssertTrue(harness.views.viewTypes(for: .folder("Projects")).isEmpty)
        XCTAssertTrue(harness.views.viewTypes(for: .virtual("calendar:2026-10")).isEmpty)
    }

    func testDisablingTheEditorRemovesItsServiceAndViewType() {
        XCTAssertNotNil(harness.kernel.services.service(.editor))
        harness.host.deactivate("markdown-editor")
        XCTAssertNil(harness.kernel.services.service(.editor))
        XCTAssertTrue(harness.views.all.isEmpty)
    }

    func testAnotherPluginsSlashItemComesAndGoesWithIt() throws {
        let service = try XCTUnwrap(service)
        XCTAssertEqual(service.slashItems.map(\.id), ["test.date"])
        let ids = service.menuItems.map(\.id)
        XCTAssertEqual(Array(ids.prefix(SlashMenu.standardItems.count)), SlashMenu.standardItems.map(\.id))
        XCTAssertEqual(ids.last, "test.date", "added after the standard items")

        let item = try XCTUnwrap(service.menuItems.last)
        let edit = item.makeEdit("Today /da", NSRange(location: 6, length: 3))
        XCTAssertEqual(edit.applied(to: "Today /da"), "Today 2026-10-18")

        harness.host.deactivate("test.slash")
        XCTAssertEqual(service.slashItems.map(\.id), [])
        XCTAssertEqual(service.menuItems.map(\.id), SlashMenu.standardItems.map(\.id))
    }

    func testALiveBlockViewEditsItsCodeAndGoesWithItsPlugin() async throws {
        LiveBlockPlugin.contexts = []
        let service = try XCTUnwrap(service)
        XCTAssertEqual(Set(service.liveBlocks(notePath: "Live.md", tokens: .standard).keys), ["demo"])
        let view = try render("Live.md")
        try await waitUntil { !LiveBlockPlugin.contexts.isEmpty }
        let context = try XCTUnwrap(LiveBlockPlugin.contexts.first)
        XCTAssertEqual(context.notePath, "Live.md")
        XCTAssertEqual(context.language, "demo")
        XCTAssertEqual(context.code, "hello")
        XCTAssertFalse(context.isEditingCode)

        // The view's edit is the note's: saved as typing is, followed by the context. The page holds the block as one
        // character; its code never shows in the text.
        context.replaceCode("bye")
        XCTAssertEqual(textView(in: view)?.string, "Intro\n\u{FFFC}\n")
        XCTAssertEqual(service.text(of: "Live.md"), "Intro\n\n```demo\nbye\n```\n")
        XCTAssertEqual(context.code, "bye")
        try await waitUntil { (try? self.harness.vault.read("Live.md")) == "Intro\n\n```demo\nbye\n```\n" }
        // Its code is edited on the code page, not in the text.
        context.editCode()
        XCTAssertFalse(context.isEditingCode)

        harness.host.deactivate("test.live")
        XCTAssertTrue(service.liveBlocks(notePath: "Live.md", tokens: .standard).isEmpty)
    }

    // MARK: Links to notes

    func testTheDoubleBracketMenuLinksANoteRelativeToTheEditedOne() throws {
        let service = try XCTUnwrap(service)
        let items = service.linkItems("sec", from: "First.md")
        XCTAssertEqual(items.map(\.title), ["Second"], "by the note's title")
        let text = "See [[sec"
        let edit = try XCTUnwrap(items.first).makeEdit(text, NSRange(location: 4, length: 5))
        XCTAssertEqual(edit.applied(to: text), "See [Second](Projects/Second.md) ")

        let back = try XCTUnwrap(service.linkItems("first", from: "Projects/Second.md").first)
        XCTAssertEqual(back.makeEdit("[[first]] next", NSRange(location: 0, length: 7)).applied(to: "[[first]] next"),
                       "[First](../First.md) next", "closing brackets typed go, the space after stays")
    }

    func testPagesSharingATitleShowTheirFileName() {
        typealias Page = NoteMentions.Candidate
        let pages = [
            Page(path: "Maps/Mindmap 3.md", title: "Mindmap", modified: 3),
            Page(path: "Mindmap.md", title: "Mindmap", modified: 2),
            Page(path: "Maps/Mindmap.md", title: "Mindmap", modified: 1),
            Page(path: "Plan.md", title: "Q4 plan", modified: 0),
        ]
        XCTAssertEqual(NoteMentions.displayNames(pages), [
            "Maps/Mindmap 3.md": "Mindmap 3", "Mindmap.md": "Mindmap", "Maps/Mindmap.md": "Mindmap — Maps",
            "Plan.md": "Q4 plan",
        ])
    }

    func testThePictureIsNotAPageToLink() throws {
        let service = try XCTUnwrap(service)
        XCTAssertFalse(service.linkItems("", from: "First.md").map(\.id).contains("notes/photo.png"))
    }

    func testTheNoteMenusNeverOfferTheEditedNote() throws {
        let service = try XCTUnwrap(service)
        XCTAssertFalse(service.linkItems("", from: "First.md").map(\.id).contains("notes/First.md"))
        XCTAssertTrue(service.linkItems("", from: "Live.md").map(\.id).contains("notes/First.md"))
    }

    func testTheMentionMenuListsNotesWhoseTitleContainsTheWords() throws {
        let service = try XCTUnwrap(service)
        let items = service.mentionItems("cond", from: "First.md")
        XCTAssertEqual(items.map(\.title), ["Second"])
        XCTAssertEqual(items.first?.section, "Notes")
        XCTAssertTrue(service.mentionItems("sd", from: "First.md").isEmpty, "letters in order are not enough after @")
    }

    func testANewNoteShowsUpInTheMenus() async throws {
        let service = try XCTUnwrap(service)
        XCTAssertTrue(service.linkItems("roadmap", from: "First.md").isEmpty)
        try harness.vault.write("Roadmap.md", "# Roadmap\n")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .added, path: "Roadmap.md")]))
        try await waitUntil { !service.linkItems("roadmap", from: "First.md").isEmpty }
    }

    // MARK: Views

    func testTheViewRendersTheNoteOffscreen() throws {
        let view = try render("First.md")
        XCTAssertEqual(view.frame.size, CGSize(width: 400, height: 300))
        // The page: the note's text without syntax, its `# First` the page's title.
        XCTAssertEqual(textView(in: view)?.string, "See second.\n")
    }

    func testAMissingNoteShowsAPlaceholder() throws {
        let view = try render("Missing.md")
        XCTAssertNil(textView(in: view))
        XCTAssertEqual(service?.documents.openPaths, [])
    }

    func testAMissingNoteWithAHeaderThatCreatesOnEditOpensBlankAndWritesNothing() throws {
        let remove = harness.noteHeaders.register(NoteHeader(
            id: "test.header", createsOnEdit: true, appliesTo: { $0.path.hasPrefix("Daily/") },
            makeView: { _ in AnyView(Text("Header")) }
        ))
        defer { remove() }
        let view = try render("Daily/2026-01-01.md")
        XCTAssertEqual(textView(in: view)?.string, "")
        XCTAssertEqual(service?.documents.openPaths, ["Daily/2026-01-01.md"])
        XCTAssertFalse(harness.vault.exists("Daily/2026-01-01.md"), "looking creates nothing")
        // A note that is not covered by the header keeps its placeholder.
        XCTAssertNil(textView(in: try render("Other/Missing.md")))
    }

    func testTheCaretIsRestoredFromTheTabState() throws {
        let view = try render("First.md", state: EditorTabState(caret: 5, scrollY: 0))
        XCTAssertEqual(textView(in: view)?.selectedRange().location, 5)
    }

    func testTwoViewsShareOneDocument() throws {
        let store = try XCTUnwrap(service?.documents)
        let first = try render("First.md")
        let second = try render("First.md", active: false)
        XCTAssertEqual(store.openPaths, ["First.md"])
        XCTAssertEqual(store.viewCount(at: "First.md"), 2)

        // Typing in one editor reaches the other through the shared document.
        let typing = try XCTUnwrap(textView(in: first))
        typing.setSelectedRange(NSRange(location: 0, length: 0))
        typing.insertText("Hello ", replacementRange: typing.selectedRange())
        let document = try XCTUnwrap(store.document(at: "First.md"))
        XCTAssertEqual(document.text, "# First\n\nHello See [second](Projects/Second.md).\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(textView(in: second)?.string, "Hello See second.\n")
    }

    func testTypingIsSavedAndInsertAtCaretTargetsTheActiveTab() async throws {
        let service = try XCTUnwrap(service)
        XCTAssertFalse(service.insertAtCaret("nothing"), "no editor yet")
        let view = try render("Projects/Second.md")
        XCTAssertTrue(service.hasActiveEditor)
        let editor = try XCTUnwrap(textView(in: view))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertTrue(service.insertAtCaret("inserted"))
        XCTAssertEqual(editor.string, "inserted")
        try await waitUntil { (try? self.harness.vault.read("Projects/Second.md")) == "# Second\n\ninserted\n" }
    }

    func testTextOfAnOpenNoteIsTheLiveTextAndTypingSendsDocumentTextChanged() async throws {
        let service = try XCTUnwrap(service)
        XCTAssertNil(service.text(of: "First.md"), "not open in an editor")
        var changed: [String] = []
        let stop = harness.kernel.events.on(DocumentTextChanged.self) { changed.append($0.path) }
        defer { stop() }

        let view = try render("First.md")
        XCTAssertEqual(service.text(of: "First.md"), files["First.md"])
        let editor = try XCTUnwrap(textView(in: view))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("A", replacementRange: editor.selectedRange())
        editor.insertText("B", replacementRange: editor.selectedRange())
        XCTAssertEqual(service.text(of: "First.md"), "# First\n\nABSee [second](Projects/Second.md).\n", "unsaved typing included")
        XCTAssertEqual(changed, [], "debounced")
        try await waitUntil { !changed.isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(changed, ["First.md"], "once for a burst of typing")
    }

    func testRevealPutsTheCaretOnALineOfTheActiveNote() throws {
        let service = try XCTUnwrap(service)
        XCTAssertFalse(service.reveal(line: 1, in: "First.md"), "no editor yet")
        let view = try render("First.md")
        let editor = try XCTUnwrap(textView(in: view))
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        // Line 3 is `See [second](...)`, the page's first block.
        XCTAssertTrue(service.reveal(line: 3, in: "First.md"))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertFalse(service.reveal(line: 1, in: "Projects/Second.md"), "the active editor shows another note")
        XCTAssertFalse(service.reveal(line: 40, in: "First.md"), "no such line")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testAnOutsideChangeReachesTheEditor() async throws {
        let view = try render("First.md")
        try harness.kernel.refreshVault()  // the first call records the starting point
        try harness.vault.write("First.md", "# Rewritten\n")
        try harness.kernel.refreshVault()
        XCTAssertEqual(service?.documents.document(at: "First.md")?.text, "# Rewritten\n")
        // Not the page's title any more: the heading shows.
        try await waitUntil { textView(in: view)?.string == "Rewritten\n" }
    }

    // MARK: Moves and links

    func testPendingEditsAreFlushedBeforeAMoveAndTheDocumentFollowsIt() async throws {
        let store = try XCTUnwrap(service?.documents)
        let document = try XCTUnwrap(store.acquire("Projects/Second.md"))
        defer { store.release(document) }
        document.edit("# Second\n\npending", from: UUID())
        _ = try await harness.run("notes.move", ["from": "Projects/Second.md", "to": "Archive/Second.md"])
        XCTAssertEqual(try harness.vault.read("Archive/Second.md"), "# Second\n\npending")
        XCTAssertEqual(document.path, "Archive/Second.md")
        XCTAssertTrue(store.document(at: "Archive/Second.md") === document)
        XCTAssertEqual(store.openPaths, ["Archive/Second.md"])
        XCTAssertFalse(document.hasUnsavedChanges)
    }

    func testANoteLinkOpensInPlaceOrBeside() throws {
        let service = try XCTUnwrap(service)
        service.openLink("Projects/Second.md", from: "First.md", beside: false)
        service.openLink("../First.md", from: "Projects/Second.md", beside: true)
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Projects/Second.md"), .file("First.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace, .beside])
    }

    func testADatePillOpensItsDaysNoteWithoutCreatingIt() throws {
        let service = try XCTUnwrap(service)
        XCTAssertTrue(service.canOpenDays)
        service.openDay("2026-10-22", newTab: false)
        service.openDay("2026-10-23", newTab: true)
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Daily/2026-10-22.md"), .file("Daily/2026-10-23.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace, .newTab])
        XCTAssertFalse(harness.vault.exists("Daily/2026-10-22.md"), "looking at a day writes nothing")
        let document = try XCTUnwrap(service.documents.acquire("Daily/2026-10-22.md"))
        XCTAssertFalse(document.existsOnDisk, "it opens blank, as a draft")
        service.documents.release(document)
        XCTAssertFalse(harness.vault.exists("Daily/2026-10-22.md"))
    }

    func testADayThatHasANoteOpensThatNote() throws {
        try harness.vault.write("Daily/2026-10-22.md", "Done things\n")
        let service = try XCTUnwrap(service)
        service.openDay("2026-10-22", newTab: false)
        let document = try XCTUnwrap(service.documents.acquire("Daily/2026-10-22.md"))
        XCTAssertEqual(document.text, "Done things\n")
    }

    func testRenamingADraftFollowsInMemoryAndWritesNothing() throws {
        let service = try XCTUnwrap(service)
        service.beginDraft(at: "Inbox/Untitled.md")
        let document = try XCTUnwrap(service.documents.acquire("Inbox/Untitled.md"))
        XCTAssertTrue(service.rename("Inbox/Untitled.md", to: "Plan"))
        XCTAssertEqual(document.path, "Inbox/Plan.md")
        XCTAssertFalse(harness.vault.exists("Inbox/Plan.md"))
        XCTAssertFalse(harness.vault.exists("Inbox/Untitled.md"))
        service.documents.release(document)
    }

    func testALinkToAFileAViewOpensStaysInTheApp() throws {
        try harness.vault.write("Boards/Board.canvas", "{}")
        let remove = harness.views.register(ViewType(
            id: "test.board",
            title: "Board",
            canOpen: { $0.pathExtension == "canvas" },
            makeView: { _ in AnyView(EmptyView()) }
        ))
        defer { remove() }
        var opened: [URL] = []
        let harness = try XCTUnwrap(harness)
        let service = MarkdownEditorService(
            documents: DocumentStore(vault: harness.vault),
            workspace: { harness.workspace },
            openURL: { opened.append($0) }
        )
        service.views = { harness.views }
        service.openLink("Boards/Board.canvas", from: "First.md", beside: false)
        service.openLink("Board.canvas", from: "Boards/Plan.md", beside: true)
        service.openLink("photo.png", from: "First.md", beside: false)
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Boards/Board.canvas"), .file("Boards/Board.canvas")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace, .beside])
        XCTAssertEqual(opened, [harness.vault.rootURL.appendingPathComponent("photo.png")], "no view opens a .png")
    }

    func testOtherLinksOpenInTheirOwnApp() {
        var opened: [URL] = []
        let service = MarkdownEditorService(
            documents: DocumentStore(vault: harness.vault),
            workspace: { nil },
            openURL: { opened.append($0) }
        )
        service.openLink("https://example.com", from: "First.md", beside: false)
        service.openLink("photo.png", from: "First.md", beside: false)
        XCTAssertEqual(opened, [URL(string: "https://example.com")!, harness.vault.rootURL.appendingPathComponent("photo.png")])
    }
}
