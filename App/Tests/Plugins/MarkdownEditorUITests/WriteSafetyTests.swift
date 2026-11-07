import AppKit
import BuiltinPlugins
import Foundation
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import TasksPlugin
import XCTest
@testable import MarkdownEditorUI
@testable import TasksUI

/// A plugin that reads a note, edits it and writes it back through `context.vault`, as most plugins that write do.
private final class AppenderPlugin: Plugin {
    static let manifest = PluginManifest(id: "test.appender", name: "Appender", version: "1.0")

    init() {}

    func activate(context: PluginContext) throws {
        nonisolated(unsafe) let vault = context.vault
        try context.registerCommand(Command(id: "test.append", title: "Append", summary: "Appends a line. Writes.") { arguments in
            let path = try arguments.require("path")
            try vault.write(path, try vault.read(path) + (try arguments.require("text")) + "\n")
            return ""
        })
        try context.registerCommand(Command(id: "test.read", title: "Read", summary: "Reads a note.") { arguments in
            try vault.read(try arguments.require("path"))
        })
    }
}

/// The vault events, recorded from whichever thread the plugin read or wrote on.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func append(_ line: String) {
        lock.withLock { stored.append(line) }
    }
}

/// Plugins writing a note the editor has open with unsaved typing: neither the typing nor the plugin's change is lost.
@MainActor
final class WriteSafetyTests: XCTestCase {
    private let files = [
        "First.md": "# First\n",
        "Todo.md": "# Todo\n\nNotes\n\n- [ ] Ship it\n",
        "Card.md": "---\nstatus: todo\n---\n# Card\n",
    ]
    private var harness: UIPluginHarness!
    private let recorder = EventLog()
    private var log: [String] {
        get { recorder.lines }
        set { recorder.lines = newValue }
    }
    private var stops: [() -> Void] = []

    override func setUp() async throws {
        harness = try UIPluginHarness(
            logicPlugins: builtinPlugins + [AppenderPlugin.self],
            uiPlugins: [MarkdownEditorPlugin.self, TasksUIPlugin.self],
            files: files
        )
        XCTAssertEqual(harness.report.failed, [:])
        let events = harness.kernel.events
        let recorder = recorder
        // `@Sendable`: plugins read and write from any thread, and a closure made here would otherwise be main-actor.
        stops = [
            events.on(NoteWillRead.self) { @Sendable in recorder.append("read \($0.path) \($0.pluginID)") },
            events.on(NoteWillChange.self) { @Sendable in recorder.append("will \($0.path) \($0.pluginID)") },
            events.on(NoteDidChange.self) { @Sendable in recorder.append("did \($0.path) \($0.pluginID)") },
        ]
    }

    override func tearDown() async throws {
        for stop in stops { stop() }
        harness.close()
    }

    private var documents: DocumentStore {
        get throws { try XCTUnwrap(harness.kernel.services.service(.editor) as? MarkdownEditorService).documents }
    }

    /// Opens `path` in an editor tab and types `text` at `location` (the end when nil), leaving it unsaved.
    private func type(_ text: String, in path: String, at location: Int? = nil) throws -> (view: NSView, document: MarkdownEditorUI.Document) {
        let type = try XCTUnwrap(harness.views.viewTypes(for: .file(path)).first)
        let view = harness.render(type.makeView(ViewContext(resource: .file(path), state: nil, isActive: true)))
        let editor = try XCTUnwrap(textView(in: view))
        if let location {
            // An edit at a place the caret cannot rest (the start of a task's line, before its hidden `- [ ] `).
            let range = NSRange(location: location, length: 0)
            XCTAssertTrue(editor.shouldChangeText(in: range, replacementString: text))
            editor.textStorage?.replaceCharacters(in: range, with: text)
            editor.didChangeText()
        } else {
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        let document = try XCTUnwrap(try documents.document(at: path))
        XCTAssertTrue(document.hasUnsavedChanges, "the save is still 500 ms away")
        return (view, document)
    }

    func testAPluginThatReadsThenWritesKeepsTheTypingAndTheEditorShowsItsChange() async throws {
        let (view, document) = try type("Typed.\n", in: "First.md")
        _ = try await harness.run("test.append", ["path": "First.md", "text": "Appended"])

        let expected = "# First\n\nTyped.\nAppended\n"
        XCTAssertEqual(try harness.vault.read("First.md"), expected)
        XCTAssertEqual(document.text, expected, "reloaded at once, without waiting for the file system")
        XCTAssertFalse(document.hasUnsavedChanges)
        // The page: the typed paragraph with the plugin's line under it (one paragraph, two lines).
        try await waitUntil { textView(in: view)?.string == "Typed.\u{2028}Appended\n" }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(try harness.vault.read("First.md"), expected, "no later save undoes the plugin's line")
    }

    func testATaskToggledFromTheTasksListKeepsTheTypingAboveIt() async throws {
        // Typing above the task moves it: the list (live text) and the file must agree on its line.
        let (view, document) = try type(" more", in: "Todo.md", at: 5)
        let board = try XCTUnwrap(harness.kernel.services.service(TasksUIPlugin.modelKey))
        board.refresh()
        let task = try XCTUnwrap(board.tasks.first { $0.path == "Todo.md" })
        XCTAssertEqual(task.line, 5)
        board.toggle(task)
        XCTAssertNil(board.error)

        let today = try XCTUnwrap(harness.kernel.services.service(.tasks)).today
        let expected = "# Todo\n\nNotes more\n\n- [x] Ship it ✅ \(today)\n"
        XCTAssertEqual(try harness.vault.read("Todo.md"), expected)
        XCTAssertEqual(document.text, expected)
        // The page: the date is a pill, one character.
        try await waitUntil { textView(in: view)?.string == "Notes more\nShip it \u{FFFC}\n" }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(try harness.vault.read("Todo.md"), expected)
    }

    func testSetPropertyThroughNoteQueryKeepsTheTyping() async throws {
        let (_, document) = try type("Body text\n", in: "Card.md")
        let query = try XCTUnwrap(harness.kernel.services.service(.noteQuery))
        try query.setProperty("status", to: .string("doing"), in: "Card.md")

        let expected = "---\nstatus: doing\n---\n# Card\n\nBody text\n"
        XCTAssertEqual(try harness.vault.read("Card.md"), expected)
        XCTAssertEqual(document.text, expected)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(try harness.vault.read("Card.md"), expected)
    }

    func testTheEditorsOwnSavesAndReadsCauseNoFlushOrReload() async throws {
        let (_, document) = try type("x", in: "First.md")
        let revision = document.revision
        log = []
        try await waitUntil { !document.hasUnsavedChanges }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log, ["will First.md markdown-editor", "did First.md markdown-editor"], "one save, nothing else")
        XCTAssertEqual(document.revision, revision, "its own save does not reload it")

        // Another plugin reading a saved note: nothing to flush.
        log = []
        _ = try await harness.run("test.read", ["path": "First.md"])
        XCTAssertEqual(log, ["read First.md test.appender"])

        // Reading a note with unsaved typing: exactly one save first, no loop.
        document.edit("# First\nxy", from: UUID())
        log = []
        let read = try await harness.run("test.read", ["path": "First.md"])
        XCTAssertEqual(read, "# First\nxy", "the reader gets the unsaved text")
        // The editor listened first, so its save is logged inside the read's dispatch, before this test's listener.
        XCTAssertEqual(log, [
            "will First.md markdown-editor", "did First.md markdown-editor", "read First.md test.appender",
        ])
        XCTAssertFalse(document.hasUnsavedChanges)
    }

    func testAPluginReadingAClosedNoteDoesNotTouchTheEditor() async throws {
        let (_, document) = try type("Typed", in: "First.md")
        log = []
        _ = try await harness.run("test.append", ["path": "Card.md", "text": "Other"])
        XCTAssertEqual(log, ["read Card.md test.appender", "will Card.md test.appender", "did Card.md test.appender"])
        XCTAssertTrue(document.hasUnsavedChanges, "another note's write leaves this one's pending save alone")
    }
}
