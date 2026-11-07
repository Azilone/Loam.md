import AppKit
import AttachmentsPlugin
import CapturePlugin
import NoteGraphPlugin
import NoteQueryPlugin
import PluginKit
import PluginKitUI
import PluginKitUITesting
import XCTest
@testable import CaptureUI

/// The clipboard read in order, the window's duplicate check, the flow after Enter with a fake agent, the shortcut.
@MainActor
final class CaptureUITests: XCTestCase {
    private func harness() throws -> UIPluginHarness {
        try UIPluginHarness(
            logicPlugins: [NoteGraphPlugin.self, NoteQueryPlugin.self, AttachmentsPlugin.self, CapturePlugin.self],
            uiPlugins: [CaptureUIPlugin.self]
        )
    }

    private func model(_ harness: UIPluginHarness) throws -> CaptureModel {
        try XCTUnwrap(harness.kernel.services.service(CaptureUIPlugin.modelKey))
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("loam-capture-test-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    func testTheCommandsAndTheStatusButtonComeAndGo() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertEqual(harness.panels.panels(in: .statusBar).map(\.id), ["capture.status"])
        harness.host.deactivateAll()
        XCTAssertTrue(harness.panels.panels(in: .statusBar).isEmpty)
    }

    // MARK: The clipboard

    func testTheClipboardIsReadRichestFirst() throws {
        let board = pasteboard()
        board.setString("https://example.com/post?utm_source=x", forType: .string)
        board.setString("A post", forType: NSPasteboard.PasteboardType("public.url-name"))
        guard case .items(let link) = PasteboardReader.read(board) else { return XCTFail("a link") }
        XCTAssertEqual(link.first?.content, .link(url: "https://example.com/post?utm_source=x", title: "A post"))

        board.clearContents()
        board.setString("read https://example.com later", forType: .string)
        guard case .items(let text) = PasteboardReader.read(board) else { return XCTFail("text") }
        XCTAssertEqual(text.first?.content.kind, .text)

        board.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        board.writeObjects([image])
        guard case .items(let picture) = PasteboardReader.read(board) else { return XCTFail("an image") }
        XCTAssertEqual(picture.first?.content.kind, .image)
        XCTAssertNotNil(picture.first?.preview)
    }

    func testAPasswordManagersCopyIsNeverRead() {
        let board = pasteboard()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("hunter2", forType: .string)
        XCTAssertEqual(PasteboardReader.read(board), .empty)
        XCTAssertEqual(PasteboardReader.read(pasteboard()), .empty)
    }

    func testFinderFilesBecomeOneItemEach() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("capture-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.txt")
        let b = folder.appendingPathComponent("b.zip")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let board = pasteboard()
        board.writeObjects([a as NSURL, b as NSURL])
        guard case .items(let files) = PasteboardReader.read(board) else { return XCTFail("files") }
        XCTAssertEqual(files.map(\.title), ["a", "b"])
        board.clearContents()
        board.writeObjects([folder as NSURL])
        XCTAssertEqual(PasteboardReader.read(board), .unsupported("folder"))
    }

    // MARK: The window

    func testOpeningShowsTheClipboardOnceAndAnExactDuplicate() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        var shown = 0
        model.showWindow = { shown += 1 }
        model.hideWindow = {}
        model.showLine = {}
        model.readVault = { try? harness.vault.read($0) }
        let board = pasteboard()
        board.setString("A thought worth keeping", forType: .string)
        model.open(pasteboard: board)
        XCTAssertEqual(model.drafts.count, 1)
        XCTAssertEqual(shown, 1)
        model.settings = { CaptureSettings(useAgent: false) }
        model.confirm(pasteboard: board)
        try await waitFor { model.line != nil && model.line != .saved("Saved for later") }
        XCTAssertTrue(harness.vault.exists("Saved for later/A thought worth keeping.md"))

        model.open(pasteboard: board)
        XCTAssertTrue(model.drafts.isEmpty, "the same copy is not offered twice")

        board.clearContents()
        board.setString("a thought   worth keeping", forType: .string)
        model.open(pasteboard: board)
        XCTAssertEqual(model.existing?.path, "Saved for later/A thought worth keeping.md")
    }

    // MARK: After Enter

    func testTheAgentsTurnRenamesAndTheLineSaysSo() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.showLine = {}
        var asked: [String: String] = [:]
        model.isAvailable = { _ in true }
        model.run = { id, arguments in
            switch id {
            case "assistant.default-agent": return #"{"kind":"claude","state":"ready","account":"Claude Max"}"#
            case "assistant.ask":
                asked = arguments
                try harness.vault.move("Saved for later/Buy oat milk.md", to: "Saved for later/Groceries.md")
                return #"{"chat":"c1","answer":"Done.\n{\"items\":[{\"n\":1,\"path\":\"Saved for later/Groceries.md\",\"title\":\"Groceries\",\"tags\":[\"shopping\"],\"merged_into\":null}]}","changes":[{"path":"Saved for later/Groceries.md","kind":"added"}],"error":null}"#
            default: return ""
            }
        }
        await model.save([.text("Buy oat milk")], note: "")
        XCTAssertEqual(asked["mode"], "auto")
        XCTAssertNil(asked["agent"], "auto leaves the choice to the Assistant")
        XCTAssertTrue(asked["prompt"]?.contains("note `Saved for later/Buy oat milk.md`") == true)
        XCTAssertEqual(model.line, .done(title: "Groceries", detail: "#shopping"))
        XCTAssertEqual(model.outcomes.first?.path, "Saved for later/Groceries.md")
    }

    func testChangesOutsideTheCaptureAreShown() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.showLine = {}
        model.isAvailable = { _ in true }
        model.run = { id, _ in
            switch id {
            case "assistant.default-agent": return #"{"kind":"codex","state":"ready"}"#
            case "assistant.ask": return #"{"chat":"c2","answer":"ok","changes":[{"path":"Notes/Other.md","kind":"modified"}],"error":null}"#
            default: return ""
            }
        }
        await model.save([.text("Hello there")], note: "")
        XCTAssertEqual(model.line, .done(title: "Hello there", detail: "also changed 1 other note"))
    }

    func testASignedOutAgentLeavesTheItemSaved() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.showLine = {}
        model.isAvailable = { _ in true }
        model.run = { id, _ in id == "assistant.default-agent" ? #"{"kind":"claude","state":"signedOut"}"# : "" }
        await model.save([.text("Keep me")], note: "")
        XCTAssertEqual(model.line, .notSorted("Saved for later", reason: "sign in to Claude Code to sort it", retry: false))
        XCTAssertTrue(harness.vault.exists("Saved for later/Keep me.md"))
    }

    func testUndoUndoesTheTurnThenTrashesTheNote() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.showLine = {}
        model.settings = { CaptureSettings(useAgent: false) }
        var ran: [String] = []
        model.run = { id, _ in ran.append(id); return "" }
        await model.save([.text("Oops")], note: "")
        XCTAssertTrue(model.canUndo)
        model.undo()
        try await waitFor { !harness.vault.exists("Saved for later/Oops.md") }
        XCTAssertTrue(harness.vault.exists(".trash/Saved for later/Oops.md"))
        XCTAssertFalse(ran.contains("assistant.undo-turn"), "no agent turn to undo")
    }

    // MARK: The shortcut

    func testTheShortcutIsReadAsMenusPrintIt() {
        XCTAssertEqual(GlobalHotkey.shortcut(display: "⌃⌥Space"), KeyShortcut("space", [.control, .option]))
        XCTAssertEqual(GlobalHotkey.shortcut(display: "⇧⌘K"), KeyShortcut("k", [.shift, .command]))
        XCTAssertNil(GlobalHotkey.shortcut(display: "⌘"))
        XCTAssertNotNil(GlobalHotkey.keyCode("space"))
        XCTAssertNil(GlobalHotkey.keyCode("f13"))
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool, timeout: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
