import BuiltinPlugins
import PluginKitUI
import PluginKitUITesting
import ProjectsPlugin
import SwiftUI
import XCTest
@testable import ProjectsUI

/// The Projects link, New Project, the progress row and the day's project tasks, on the `projects` service.
@MainActor
final class ProjectsUITests: XCTestCase {
    private let files = [
        "Projects/Website/Website.md": "---\nstatus: Active\ndue: 2026-10-01\n---\n",
        "Projects/Website/Copy.md": "---\nstatus: To do\ndue: 2026-01-02\n---\n",
        "Projects/Website/Brief.md": "---\nstatus: Done\n---\n",
        "Projects/Someday/Someday.md": "---\nstatus: Idea\n---\n",
        "Projects/Loose.md": "Old.\n",
        "Notes/Plain.md": "- [ ] Not a project\n",
    ]

    private func harness(editor: RecordingEditor? = nil) throws -> UIPluginHarness {
        let logic = builtinPlugins.filter { ["note-graph", "note-query", "projects"].contains($0.manifest.id) }
        return try UIPluginHarness(logicPlugins: logic, uiPlugins: [ProjectsUIPlugin.self], files: files, editor: editor)
    }

    func testRegistersTheLinkTheNewItemAndTheBand() throws {
        let harness = try harness()
        defer { harness.close() }
        let link = try XCTUnwrap(harness.panels.links.first { $0.id == "projects.link" })
        XCTAssertEqual(link.resource, .folder("Projects"))
        XCTAssertNil(link.count, "the sidebar counts only what is overdue")
        XCTAssertTrue(harness.panels.newItems.contains { $0.id == "projects.new" })
        XCTAssertEqual(harness.noteHeaders.headers(for: .file("Projects/Website/Website.md")).map(\.id), ["projects.progress"])
        XCTAssertTrue(harness.noteHeaders.headers(for: .file("Projects/Website/Copy.md")).isEmpty, "a task has no progress row")
        XCTAssertTrue(harness.noteHeaders.headers(for: .file("Notes/Plain.md")).isEmpty)
    }

    func testTheLinkWritesTheCollectionAndOpensTheFolder() throws {
        let harness = try harness()
        defer { harness.close() }
        let link = try XCTUnwrap(harness.panels.links.first { $0.id == "projects.link" })
        link.action?()
        XCTAssertTrue(harness.vault.exists("Projects/Projects.base"))
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.folder("Projects")])
    }

    func testNewProjectWritesItsKanbanAndOpensIt() async throws {
        let harness = try harness()
        defer { harness.close() }
        let path = try await harness.run("projects.new-project", ["title": "Launch"])
        XCTAssertEqual(path, "Projects/Launch/Launch.md")
        let text = try harness.vault.read(path)
        XCTAssertTrue(text.hasPrefix("---\nstatus: Active\n---\n"))
        XCTAssertTrue(text.contains("```base") && text.contains("file.inFolder(this.file.folder)"))
        XCTAssertEqual(harness.workspace.opened.last?.resource, .file(path))
    }

    func testTheModelCountsTaskNotesAndListsTheDaysTasks() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try XCTUnwrap(harness.kernel.services.service(ProjectsUIPlugin.modelKey))
        model.refresh()
        XCTAssertEqual(model.project("Projects/Website/Website.md")?.tasks, TaskCount(done: 1, total: 2, inProgress: 0, late: 1))
        XCTAssertEqual(model.tasks(dueOn: "2026-01-02").map(\.title), ["Copy"])
        XCTAssertEqual(model.looseNotes, ["Projects/Loose.md"])
        model.tidy()
        XCTAssertTrue(harness.vault.exists("Projects/Loose/Loose.md"))
        XCTAssertTrue(model.looseNotes.isEmpty)
        XCTAssertEqual(TaskStateLine.text(TaskCount(done: 1, total: 4, inProgress: 1)), "1 in progress · 2 to do")
        XCTAssertEqual(TaskStateLine.text(TaskCount(done: 3, total: 3)), "All 3 tasks done")
        XCTAssertEqual(TaskStateLine.text(TaskCount()), "No tasks yet")
    }

    func testViewsRender() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try XCTUnwrap(harness.kernel.services.service(ProjectsUIPlugin.modelKey))
        _ = harness.render(AnyView(ProgressBand(model: model, path: "Projects/Website/Website.md")))
        _ = harness.render(AnyView(DayProjectTasks(model: model, date: "2026-01-02")), size: CGSize(width: 700, height: 200))
    }
}
