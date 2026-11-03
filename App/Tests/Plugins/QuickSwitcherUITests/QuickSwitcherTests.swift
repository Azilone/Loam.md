import BuiltinPlugins
import Foundation
import PluginKitUI
import PluginKitUITesting
import QuickSwitcherUI
import SwiftUI
import XCTest

/// The switcher end to end: the command shows the popup, typing ranks notes, picking opens or creates one.
@MainActor
final class QuickSwitcherTests: XCTestCase {
    private let files = [
        "Daily/2026-10-18.md": "Today.\n",
        "Daily notes.md": "# Daily notes\n",
        "Projects/Plan.md": "# Plan\n",
        "Welcome.md": "# Welcome\n",
    ]

    /// A harness with the note graph (from the logic plugins) unless `withGraph` is false.
    private func harness(withGraph: Bool = true, files: [String: String]? = nil) throws -> UIPluginHarness {
        try UIPluginHarness(
            logicPlugins: withGraph ? builtinPlugins : [],
            uiPlugins: [QuickSwitcherPlugin.self],
            files: files ?? self.files
        )
    }

    private func open(_ harness: UIPluginHarness) async throws {
        _ = try await harness.run("switcher.open")
    }

    private func setModified(_ harness: UIPluginHarness, _ dates: [String: TimeInterval]) throws {
        for (path, seconds) in dates {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: seconds)],
                ofItemAtPath: harness.vault.url(path).path
            )
        }
    }

    func testCommandHasCmdOAndShowsThePopup() async throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertEqual(harness.kernel.commands.command(id: "switcher.open")?.shortcut, KeyShortcut("o", [.command]))
        try await open(harness)
        XCTAssertEqual(harness.quickPick.shownCount, 1)
        XCTAssertEqual(harness.quickPick.placeholder, "Open a note…")
    }

    func testFuzzyQueryRanksMatchingTitlesAndPathsFirst() async throws {
        let harness = try harness()
        defer { harness.close() }
        try await open(harness)
        let ids = harness.quickPick.query("dly").map(\.id)
        XCTAssertEqual(Set(ids.prefix(2)), ["note:Daily/2026-10-18.md", "note:Daily notes.md"])
        XCTAssertFalse(ids.contains("note:Projects/Plan.md"))
        XCTAssertFalse(ids.contains("note:Welcome.md"))
    }

    func testTitleMatchBeatsPathMatch() async throws {
        let harness = try harness(files: ["Plan/Notes.md": "", "Plan.md": "# Plan\n"])
        defer { harness.close() }
        try await open(harness)
        XCTAssertEqual(harness.quickPick.query("plan").first?.id, "note:Plan.md")
    }

    func testEmptyQueryListsMostRecentlyModifiedFirst() async throws {
        let harness = try harness()
        defer { harness.close() }
        try setModified(harness, [
            "Welcome.md": 1_000, "Projects/Plan.md": 4_000, "Daily notes.md": 2_000, "Daily/2026-10-18.md": 3_000,
        ])
        try await open(harness)
        XCTAssertEqual(harness.quickPick.query("").map(\.id), [
            "note:Projects/Plan.md", "note:Daily/2026-10-18.md", "note:Daily notes.md", "note:Welcome.md",
        ])
    }

    func testResultsAreLimitedToFifty() async throws {
        var many: [String: String] = [:]
        for index in 0..<70 { many["Note \(index).md"] = "" }
        let harness = try harness(files: many)
        defer { harness.close() }
        try await open(harness)
        XCTAssertEqual(harness.quickPick.query("").count, 50)
        XCTAssertEqual(harness.quickPick.query("note").filter { $0.id.hasPrefix("note:") }.count, 50)
    }

    func testChoosingANoteOpensItInPlace() async throws {
        let harness = try harness()
        defer { harness.close() }
        try await open(harness)
        let row = try XCTUnwrap(harness.quickPick.query("welc").first)
        XCTAssertEqual(row.title, "Welcome")
        XCTAssertEqual(row.subtitle, "Welcome.md")
        XCTAssertTrue(harness.quickPick.choose(id: row.id))
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Welcome.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace])
    }

    func testCreateRowOnlyWithoutAnExactTitle() async throws {
        let harness = try harness()
        defer { harness.close() }
        try await open(harness)
        XCTAssertFalse(harness.quickPick.query("").contains { $0.id.hasPrefix("create:") })
        XCTAssertFalse(harness.quickPick.query("daily NOTES").contains { $0.id.hasPrefix("create:") })
        let rows = harness.quickPick.query("Ideas")
        XCTAssertEqual(rows.last?.id, "create:Ideas")
        XCTAssertEqual(rows.last?.title, "Create “Ideas”")
        XCTAssertEqual(rows.last?.symbol, "plus")
    }

    func testEachNoteShowsTheIconOfTheViewItOpensWith() async throws {
        let harness = try harness()
        defer { harness.close() }
        let remove = harness.views.register(ViewType(
            id: "test.board", title: "Board", symbol: "rectangle.on.rectangle.angled",
            canOpen: { $0.path == "Projects/Plan.md" }, prefers: { $0.path == "Projects/Plan.md" },
            makeView: { _ in AnyView(EmptyView()) }
        ))
        defer { remove() }
        try await open(harness)
        let rows = harness.quickPick.query("")
        XCTAssertEqual(rows.first { $0.id == "note:Projects/Plan.md" }?.symbol, "rectangle.on.rectangle.angled")
        XCTAssertEqual(rows.first { $0.id == "note:Welcome.md" }?.symbol, "doc.text")
    }

    func testCreatingWithoutAnEditorWritesTheNoteInTheInboxAndOpensIt() async throws {
        let harness = try harness()
        defer { harness.close() }
        try await open(harness)
        _ = harness.quickPick.query("Big/Idea")
        XCTAssertTrue(harness.quickPick.choose(id: "create:Big/Idea"))
        XCTAssertEqual(try harness.vault.read("Inbox/Big-Idea.md"), "")
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Inbox/Big-Idea.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace])
    }

    func testCreatingWithAnEditorOpensADraftAndWritesNothing() async throws {
        let editor = RecordingEditor()
        let harness = try UIPluginHarness(
            logicPlugins: builtinPlugins, uiPlugins: [QuickSwitcherPlugin.self], files: files, editor: editor
        )
        defer { harness.close() }
        try await open(harness)
        _ = harness.quickPick.query("Ideas")
        XCTAssertTrue(harness.quickPick.choose(id: "create:Ideas"))
        XCTAssertFalse(harness.vault.exists("Inbox/Ideas.md"), "the file appears once text is typed")
        XCTAssertEqual(editor.drafts.map(\.path), ["Inbox/Ideas.md"])
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Inbox/Ideas.md")])
    }

    func testCreatingAnExistingFileOpensItWithoutOverwriting() async throws {
        // The note graph titles this note "Heading", so typing its file name still offers to create it.
        let harness = try harness(files: ["Draft.md": "---\ntitle: Heading\n---\n"])
        defer { harness.close() }
        try await open(harness)
        _ = harness.quickPick.query("Draft")
        XCTAssertTrue(harness.quickPick.choose(id: "create:Draft"))
        XCTAssertEqual(try harness.vault.read("Draft.md"), "---\ntitle: Heading\n---\n")
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Draft.md")])
    }

    func testWorksWithoutTheNoteGraphUsingFileNames() async throws {
        let harness = try harness(withGraph: false, files: ["Folder/Some note.md": "# Other title\n"])
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("quick-switcher"), "\(harness.report)")
        try await open(harness)
        let rows = harness.quickPick.query("")
        XCTAssertEqual(rows.map(\.title), ["Some note"])
        XCTAssertEqual(rows.map(\.subtitle), ["Folder/Some note.md"])
        XCTAssertFalse(harness.quickPick.query("some note").contains { $0.id.hasPrefix("create:") })
    }
}
