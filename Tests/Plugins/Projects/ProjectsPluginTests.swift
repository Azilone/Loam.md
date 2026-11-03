import XCTest
import CollectionsPlugin
import LoamCore
import NoteGraphPlugin
import NoteQueryPlugin
import PluginKit
import PluginKitTesting
@testable import ProjectsPlugin

/// Projects as notes, their tasks as the notes of the folder named after them, by status.
final class ProjectsPluginTests: XCTestCase {
    private var files: [String: String] {
        [
            "Projects/Website/Website.md": "---\nstatus: Active\ndue: 2026-10-01\n---\nThe new site.\n",
            "Projects/Website/Write copy.md": "---\nstatus: To do\ndue: 2026-10-20\n---\nTone: friendly.\n",
            "Projects/Website/Navigation.md": "---\nstatus: In progress\ndue: 2099-01-01\n---\n",
            "Projects/Website/Brief.md": "---\nstatus: Done\ndue: 2026-10-01\n---\n",
            "Projects/Launch/Launch.md": "---\nstatus: Done\ndue: 2026-10-01\n---\n",
            "Projects/Idea/Idea.md": "---\nstatus: Idea\n---\n",
            "Projects/Loose.md": "---\nstatus: Active\n---\nAn older project.\n\n```base\nfilters:\n  and:\n    - file.inFolder(\"Projects/Loose\")\n```\n",
            "Projects/Website/Deep/Ignored.md": "---\nstatus: To do\n---\n",
            "Other/Note.md": "- [ ] Not a project\n",
        ]
    }

    private func harness() throws -> PluginTestHarness {
        try PluginTestHarness([NoteGraphPlugin.self, NoteQueryPlugin.self, CollectionsPlugin.self, ProjectsPlugin.self], files: files)
    }

    private func store(_ harness: PluginTestHarness) throws -> ProjectStore {
        try XCTUnwrap(harness.kernel.services.service(.projects) as? ProjectStore)
    }

    func testListCountsTaskNotesByStatus() async throws {
        let harness = try harness()
        let projects = try JSONDecoder().decode([ProjectItem].self, from: Data(try await harness.run("projects.list").utf8))
        XCTAssertEqual(projects.map(\.title), ["Idea", "Launch", "Website"], "tasks and loose notes are not projects")
        let website = try XCTUnwrap(projects.last)
        XCTAssertEqual(website.tasks, TaskCount(done: 1, total: 3, inProgress: 1, late: 1))
        XCTAssertTrue(website.overdue)
        XCTAssertFalse(projects[1].overdue, "a done project is never overdue")
        XCTAssertEqual(projects[0].tasks, TaskCount())
        let active = try await harness.run("projects.list", ["status": "active"])
        XCTAssertTrue(active.contains("Website") && !active.contains("Launch"))
    }

    func testTasksDueOnADay() throws {
        let harness = try harness()
        let store = try store(harness)
        XCTAssertEqual(store.tasks(dueOn: "2026-10-20").map(\.title), ["Write copy"])
        XCTAssertEqual(store.tasks(dueOn: "2026-10-20").first?.project, "Projects/Website/Website.md")
        XCTAssertEqual(store.tasks(dueOn: store.today).map(\.title), ["Write copy"], "today lists the late ones too")
        XCTAssertTrue(store.tasks(dueOn: "2026-10-01").isEmpty, "done tasks are not listed")
    }

    func testNewProjectIsAFolderWithItsNoteAndItsPlusWritesThere() async throws {
        let harness = try harness()
        let path = try JSONDecoder().decode([String: String].self, from: Data(
            try await harness.run("projects.new", ["title": "Mobile app", "due": "2026-12-17"]).utf8))["path"]
        XCTAssertEqual(path, "Projects/Mobile app/Mobile app.md")
        let text = try harness.vault.read("Projects/Mobile app/Mobile app.md")
        XCTAssertTrue(text.hasPrefix("---\nstatus: Active\ndue: 2026-12-17\n---\n\n\n```base\n"))
        XCTAssertTrue(text.contains("file.inFolder(this.file.folder)"))
        XCTAssertTrue(try harness.vault.read("Projects/Projects.base").contains("file.folder == \"Projects/\" + file.basename"))

        // The Kanban's "+" in To do: a task note beside the project's note, with that status; the note is no card.
        let yaml = try XCTUnwrap(text.components(separatedBy: "```base\n").last?.components(separatedBy: "```").first)
        let collections = try XCTUnwrap(harness.kernel.services.service(.collections))
        let source = CollectionSource.inline(yaml: yaml, host: "Projects/Mobile app/Mobile app.md")
        let task = try collections.newEntry(in: source, title: "Set up CI", values: ["status": .string("To do")])
        XCTAssertEqual(task, "Projects/Mobile app/Set up CI.md")
        XCTAssertTrue(try harness.vault.read(task).contains("status: To do"))
        XCTAssertEqual(try collections.entries(source, view: nil).entries.map(\.path), [task])
        XCTAssertEqual(try store(harness).create(title: "Mobile app", status: nil, due: nil), "Projects/Mobile app 2/Mobile app 2.md")

        XCTAssertThrowsError(try store(harness).create(title: "Bad", status: nil, due: "soon"))
    }

    func testAnAgentAddsCardsToAProjectsKanban() async throws {
        let harness = try harness()
        _ = try await harness.run("projects.new", ["title": "Launch"])
        let output = try await harness.run("projects.add-task", [
            "project": "Launch", "title": "Write copy", "status": "In progress", "due": "2026-11-02", "text": "Draft first.",
        ])
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(output.utf8))["path"], "Projects/Launch/Write copy.md")
        XCTAssertEqual(try harness.vault.read("Projects/Launch/Write copy.md"),
                       "---\nstatus: In progress\ndue: 2026-11-02\n---\n\nDraft first.\n")
        let second = try store(harness).addTask(project: "Projects/Launch/Launch.md", title: "Write copy", status: nil, due: nil, text: nil)
        XCTAssertEqual(second, "Projects/Launch/Write copy 2.md")
        XCTAssertTrue(try harness.vault.read(second).contains("status: To do"))
        XCTAssertThrowsError(try store(harness).addTask(project: "Nope", title: "x", status: nil, due: nil, text: nil))
        XCTAssertThrowsError(try store(harness).addTask(project: "Launch", title: "x", status: nil, due: "soon", text: nil))
    }

    func testTheProjectsCollectionListsProjectsNotTasks() throws {
        let harness = try harness()
        let path = try store(harness).ensureCollection()
        let collections = try XCTUnwrap(harness.kernel.services.service(.collections))
        let result = try collections.entries(.file(path), view: nil)
        XCTAssertEqual(result.view.type, "projects")
        XCTAssertEqual(Set(result.entries.map(\.path)),
                       ["Projects/Website/Website.md", "Projects/Launch/Launch.md", "Projects/Idea/Idea.md"])
    }

    func testAnOldProjectsCollectionFollowsTheFolderLayout() throws {
        let harness = try harness()
        try harness.vault.write("Projects/Projects.base", "filters:\n  and:\n  - file.folder == \"Projects\"\n  - file.ext == \"md\"\nviews:\n- type: projects\n  name: Projects\n")
        let path = try store(harness).ensureCollection()
        let collections = try XCTUnwrap(harness.kernel.services.service(.collections))
        XCTAssertEqual(Set(try collections.entries(.file(path), view: nil).entries.map(\.path)),
                       ["Projects/Website/Website.md", "Projects/Launch/Launch.md", "Projects/Idea/Idea.md"])
        // A folder made a collection before it held projects lists every note below it, tasks too.
        try harness.vault.write("Projects/Projects.base", "filters:\n  and:\n  - file.inFolder(\"Projects\")\n  - file.ext == \"md\"\nviews:\n- type: projects\n  name: Projects\n")
        _ = try store(harness).ensureCollection()
        XCTAssertEqual(Set(try collections.entries(.file(path), view: nil).entries.map(\.path)),
                       ["Projects/Website/Website.md", "Projects/Launch/Launch.md", "Projects/Idea/Idea.md"])
    }

    func testAFolderCollectionGetsADateDue() throws {
        var old = files
        old["Projects/Projects.base"] = "filters:\n  and:\n  - file.inFolder(\"Projects\")\n  - file.ext == \"md\"\nviews:\n- type: projects\n  name: Projects\n"
        let harness = try PluginTestHarness([NoteGraphPlugin.self, NoteQueryPlugin.self, CollectionsPlugin.self, ProjectsPlugin.self], files: old)
        let collections = try XCTUnwrap(harness.kernel.services.service(.collections))
        let due = try collections.definition(.file("Projects/Projects.base")).property(PropertyRef("due"))
        XCTAssertEqual(due.kind, .date)
        XCTAssertEqual(due.displayName, "Due")
    }

    func testABoardWithItsFiltersJoinedIsMended() throws {
        let harness = try harness()
        let path = "Projects/Website/Website.md"
        try harness.vault.write(path, "---\nstatus: Active\n---\n\n```base\nfilters:\n  and:\n  - file.inFolder(this.file.folder) - file.basename != this.file.basename\n  - file.ext == \"md\"\n```\n")
        XCTAssertEqual(try store(harness).mendBoards(), [path])
        let text = try harness.vault.read(path)
        XCTAssertTrue(text.contains("  - file.inFolder(this.file.folder)\n  - file.basename != this.file.basename\n  - file.ext"))
        XCTAssertEqual(try store(harness).mendBoards(), [])
    }

    func testANotesOwnCheckboxesCountInItsProgress() {
        let count = ProjectStore.checkboxes(in: "- [ ] a\n- [x] b\n  * [X] c\n```\n- [ ] code\n```\n- plain\n")
        XCTAssertEqual(count.total, 3)
        XCTAssertEqual(count.done, 2)
    }

    func testANoteAndItsFolderKeepOneName() throws {
        let harness = try harness()
        let store = try store(harness)
        let path = try store.create(title: "Untitled", status: nil, due: nil)
        try harness.vault.write("Projects/Untitled/First.md", "---\nstatus: To do\n---\n")
        // Renaming the note renames the folder.
        try harness.vault.move(path, to: "Projects/Untitled/Podcast.md")
        harness.kernel.events.emit(NotesMoved(moves: [path: "Projects/Untitled/Podcast.md"]))
        XCTAssertTrue(harness.vault.exists("Projects/Podcast/Podcast.md"))
        XCTAssertTrue(harness.vault.exists("Projects/Podcast/First.md"))
        XCTAssertFalse(harness.vault.exists("Projects/Untitled"))
        // Renaming the folder renames the note.
        try harness.vault.move("Projects/Podcast", to: "Projects/Show")
        harness.kernel.events.emit(NotesMoved(moves: ["Projects/Podcast/Podcast.md": "Projects/Show/Podcast.md",
                                                     "Projects/Podcast/First.md": "Projects/Show/First.md"]))
        XCTAssertTrue(harness.vault.exists("Projects/Show/Show.md"))
        XCTAssertTrue(store.follow(["Other/A.md": "Other/B.md"]).isEmpty, "only projects")
    }

    func testANewEmptyNoteInTheFolderBecomesAProject() throws {
        let harness = try harness()
        try harness.vault.write("Projects/Fresh.md", "")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .added, path: "Projects/Fresh.md")]))
        XCTAssertFalse(harness.vault.exists("Projects/Fresh.md"))
        let fresh = try harness.vault.read("Projects/Fresh/Fresh.md")
        XCTAssertTrue(fresh.hasPrefix("---\nstatus: Active\n---\n"))
        XCTAssertTrue(fresh.contains("file.inFolder(this.file.folder)"))
        try harness.vault.write("Projects/Website/New task.md", "")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .added, path: "Projects/Website/New task.md")]))
        XCTAssertEqual(try harness.vault.read("Projects/Website/New task.md"), "", "a task note is left alone")
        try harness.vault.write("Projects/Board.md", "---\nstatus: In progress\n---\n")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .added, path: "Projects/Board.md")]))
        let board = try harness.vault.read("Projects/Board/Board.md")
        XCTAssertTrue(board.hasPrefix("---\nstatus: In progress\n---\n"), "a board's \"+\" keeps its column")
        XCTAssertTrue(board.contains("file.inFolder(this.file.folder)"))
        try harness.vault.write("Projects/Typed.md", "Hello")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .added, path: "Projects/Typed.md")]))
        XCTAssertEqual(try harness.vault.read("Projects/Typed.md"), "Hello")
    }

    func testTidyMovesLooseNotesIntoTheirFolderAndTheirBoardFollows() throws {
        let harness = try harness()
        let store = try store(harness)
        XCTAssertEqual(store.looseNotes(), ["Projects/Loose.md"])
        XCTAssertEqual(try store.tidy(), ["Projects/Loose.md": "Projects/Loose/Loose.md"])
        let text = try harness.vault.read("Projects/Loose/Loose.md")
        XCTAssertTrue(text.contains("file.inFolder(this.file.folder)"))
        XCTAssertTrue(text.contains("file.basename != this.file.basename"))
        XCTAssertTrue(store.looseNotes().isEmpty)
        XCTAssertTrue(store.projects().contains { $0.path == "Projects/Loose/Loose.md" })
    }

    func testAnOlderProjectGetsItsBoardOnRequest() throws {
        let harness = try harness()
        let store = try store(harness)
        XCTAssertTrue(store.needsBoard("Projects/Website/Website.md"))
        try store.addBoard(to: "Projects/Website/Website.md")
        let text = try harness.vault.read("Projects/Website/Website.md")
        XCTAssertTrue(text.hasPrefix("---\nstatus: Active\ndue: 2026-10-01\n---\nThe new site.\n\n```base\nname: Tasks\n"))
        XCTAssertFalse(store.needsBoard("Projects/Website/Website.md"))
        try store.addBoard(to: "Projects/Website/Website.md")
        XCTAssertEqual(try harness.vault.read("Projects/Website/Website.md"), text, "added once")
        XCTAssertFalse(store.needsBoard("Projects/Website/Brief.md"), "a task needs none")
    }

    func testTheFolderSettingIsFollowed() throws {
        let harness = try harness()
        let store = try store(harness)
        XCTAssertTrue(store.isProject("Projects/Website/Website.md"))
        XCTAssertFalse(store.isProject("Projects/Website/Brief.md"))
        XCTAssertFalse(store.isProject("Projects/Loose.md"))
        XCTAssertFalse(store.isProject("Other/Note.md"))
        XCTAssertEqual(store.taskFolder(of: "Projects/Website/Website.md"), "Projects/Website")
        store.folder = "/Work/Clients/"
        XCTAssertEqual(store.folder, "Work/Clients")
        XCTAssertEqual(store.collectionPath, "Work/Clients/Clients.base")
    }

    func testUnloadingLeavesNothing() throws {
        let harness = try harness()
        harness.host.deactivateAll()
        XCTAssertNil(harness.kernel.commands.command(id: "projects.list"))
        XCTAssertNil(harness.kernel.services.service(.projects))
    }
}
