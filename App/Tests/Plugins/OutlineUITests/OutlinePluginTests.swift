import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import OutlineUI

/// The plugin in the UI harness, with a recording editor standing in for the Markdown editor.
@MainActor
final class OutlinePluginTests: XCTestCase {
    private let files = [
        "Plan.md": "# Plan\n\n## Goals\n\n## Risks\n",
        "Empty.md": "No headings here.\n",
        "photo.png": "",
    ]
    private var editor: RecordingEditor!
    private var harness: UIPluginHarness!

    override func setUp() async throws {
        editor = RecordingEditor()
        harness = try UIPluginHarness(uiPlugins: [OutlinePlugin.self], files: files, editor: editor)
        XCTAssertTrue(harness.host.isActive("outline"), "\(harness.report)")
    }

    override func tearDown() async throws {
        harness.close()
    }

    private var model: OutlineModel {
        get throws { try XCTUnwrap(harness.kernel.services.service(OutlinePlugin.modelKey)) }
    }

    private func activate(_ resource: Resource?) {
        harness.workspace.activeResource = resource
        harness.kernel.events.emit(ActiveResourceChanged(resource: resource))
    }

    func testTheOutlineHasNoTabInTheRightSidebar() {
        // The ticks beside the page show the headings already.
        XCTAssertTrue(harness.inspector.pages(for: .file("Plan.md"), viewType: "markdown.editor")
            .allSatisfy { $0.page.title != "Outline" })
    }

    func testFollowsTheActiveNote() async throws {
        let model = try model
        XCTAssertNil(model.path)
        XCTAssertEqual(model.headings, [])

        activate(.file("Plan.md"))
        XCTAssertEqual(model.path, "Plan.md")
        try await waitUntil { model.headings.count == 3 }
        XCTAssertEqual(model.headings.map(\.text), ["Plan", "Goals", "Risks"])
        XCTAssertEqual(model.headings.map(\.line), [1, 3, 5])

        activate(.file("Empty.md"))
        XCTAssertEqual(model.path, "Empty.md")
        XCTAssertEqual(model.headings, [], "the last note's headings go at once")

        activate(.file("photo.png"))
        XCTAssertNil(model.path, "not a note")
        activate(.virtual("calendar:2026-10"))
        XCTAssertNil(model.path)
        activate(nil)
        XCTAssertNil(model.path)
    }

    func testPrefersTheEditorsLiveTextAndRefreshesWhileTyping() async throws {
        let model = try model
        editor.texts["Plan.md"] = "# Plan\n\n## Goals\n"
        activate(.file("Plan.md"))
        try await waitUntil { model.headings.count == 2 }
        XCTAssertEqual(model.headings.map(\.text), ["Plan", "Goals"], "the unsaved text, not the file")

        editor.texts["Plan.md"] = "# Plan\n\n## Goals\n\n## Typed just now\n"
        harness.kernel.events.emit(DocumentTextChanged(path: "Other.md"))
        XCTAssertEqual(model.headings.count, 2, "another note's change is ignored")
        harness.kernel.events.emit(DocumentTextChanged(path: "Plan.md"))
        try await waitUntil { model.headings.count == 3 }
        XCTAssertEqual(model.headings.map(\.text), ["Plan", "Goals", "Typed just now"])
    }

    func testRefreshesWhenTheFileChangesOnDiskAndFollowsAMove() async throws {
        let model = try model
        activate(.file("Plan.md"))
        try await waitUntil { model.headings.count == 3 }
        try harness.vault.write("Plan.md", "# Rewritten\n")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .modified, path: "Plan.md")]))
        try await waitUntil { model.headings.count == 1 }
        XCTAssertEqual(model.headings.map(\.text), ["Rewritten"])

        try harness.vault.move("Plan.md", to: "Archive/Plan.md")
        harness.kernel.events.emit(NotesMoved(moves: ["Plan.md": "Archive/Plan.md"]))
        XCTAssertEqual(model.path, "Archive/Plan.md")
        XCTAssertEqual(model.headings.map(\.text), ["Rewritten"])
    }

    func testAClickRevealsTheHeadingInTheEditor() async throws {
        let model = try model
        activate(.file("Plan.md"))
        try await waitUntil { model.headings.count == 3 }
        model.select(model.headings[1])
        XCTAssertEqual(editor.revealed.map(\.line), [3])
        XCTAssertEqual(editor.revealed.map(\.path), ["Plan.md"])
        XCTAssertTrue(harness.workspace.opened.isEmpty)
    }

    func testAClickOpensTheNoteWhenNoEditorShowsIt() async throws {
        let model = try model
        activate(.file("Plan.md"))
        try await waitUntil { model.headings.count == 3 }
        editor.canReveal = false
        model.select(model.headings[2])
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Plan.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace])
    }

    func testWorksWithoutAnEditor() async throws {
        let harness = try UIPluginHarness(uiPlugins: [OutlinePlugin.self], files: files)
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("outline"), "\(harness.report)")
        let model = try XCTUnwrap(harness.kernel.services.service(OutlinePlugin.modelKey))
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("Plan.md")))
        try await waitUntil { model.headings.count == 3 }
        XCTAssertEqual(model.headings.map(\.text), ["Plan", "Goals", "Risks"])
        model.select(model.headings[0])
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Plan.md")])
    }

    func testTheHeadingsCommandForAgents() async throws {
        editor.texts["Plan.md"] = "# Plan\n\n## Live\n"
        let json = try await harness.run("outline.headings", ["path": "Plan.md"])
        let decoded = try JSONDecoder().decode([OutlineHeading].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, [OutlineHeading(level: 1, text: "Plan", line: 1), OutlineHeading(level: 2, text: "Live", line: 3)])

        do {
            _ = try await harness.run("outline.headings")
            XCTFail("no path and no active note")
        } catch let error as CommandError {
            XCTAssertEqual(error, .missingArgument(name: "path"))
        }

        activate(.file("Empty.md"))
        let empty = try await harness.run("outline.headings")
        XCTAssertEqual(try JSONDecoder().decode([OutlineHeading].self, from: Data(empty.utf8)), [])

        do {
            _ = try await harness.run("outline.headings", ["path": "Missing.md"])
            XCTFail("missing note")
        } catch let error as OutlineError {
            XCTAssertEqual(error, .noteNotFound(path: "Missing.md"))
        }
    }

    func testUnloadingRemovesTheSectionAndCommand() {
        harness.host.deactivate("outline")
        XCTAssertTrue(harness.inspector.all.isEmpty)
        XCTAssertNil(harness.kernel.commands.command(id: "outline.headings"))
    }
}

/// Waits until `condition` holds, polling: the headings are parsed off the main thread while typing.
@MainActor
private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return XCTFail("timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
