import PluginKit
import PluginKitTesting
import XCTest
@testable import TasksPlugin

final class TaskIndexTests: XCTestCase {
    private var vault: TemporaryVault!
    private var written: [String] = []

    override func setUpWithError() throws {
        vault = try TemporaryVault()
        written = []
    }

    private func index(today: String = "2026-10-18") -> TaskIndex {
        TaskIndex(vault: vault, today: { today }, didWrite: { [unowned self] in self.written.append($0) })
    }

    private func seed() throws {
        try vault.write("Work/Launch.md", "---\nproject: Launch\n---\n# Launch\n- [ ] Ship 📅 2026-10-20 #work\n- [x] Plan 📅 2026-10-10 ✅ 2026-10-09\n- [ ] Review !high #work/review\n")
        try vault.write("Home/Chores.md", "- [ ] Rent 📅 2026-10-15 #home\n- [ ] Dishes !low\n- [ ] Taxes ⏫ 📅 2026-10-20\n")
        try vault.write("Inbox.md", "- [ ] Idea\n")
    }

    // MARK: Filters and sort

    func testSortsByDueThenPriorityThenPathAndLine() throws {
        try seed()
        let tasks = try index().tasks()
        XCTAssertEqual(tasks.map(\.text), ["Plan", "Rent #home", "Taxes", "Ship #work", "Review #work/review", "Idea", "Dishes"])
        XCTAssertEqual(tasks.map(\.project), ["Launch", "Home", "Home", "Launch", "Launch", "", "Home"])
    }

    func testOnlyNotesHoldTasks() throws {
        try seed()
        try vault.write("todo.txt", "- [ ] Not a task\n")
        try vault.write("Boards/Plan.canvas", "{\"text\": \"- [ ] Neither\"}")
        XCTAssertFalse(try index().tasks().contains { $0.path == "todo.txt" || $0.path == "Boards/Plan.canvas" })
    }

    func testFilters() throws {
        try seed()
        let index = index()
        func texts(_ filter: TaskFilter) throws -> [String] { try index.tasks(filter: filter).map(\.text) }
        XCTAssertEqual(try texts(TaskFilter(done: true)), ["Plan"])
        XCTAssertEqual(try texts(TaskFilter(done: false, dueBefore: "2026-10-20")), ["Rent #home"])
        XCTAssertEqual(try texts(TaskFilter(dueOn: "2026-10-20")), ["Taxes", "Ship #work"])
        XCTAssertEqual(try texts(TaskFilter(project: "launch")), ["Plan", "Ship #work", "Review #work/review"])
        XCTAssertEqual(try texts(TaskFilter(project: "")), ["Idea"])
        XCTAssertEqual(try texts(TaskFilter(tag: "#Work")), ["Ship #work", "Review #work/review"])
        XCTAssertEqual(try texts(TaskFilter(tag: "work/review")), ["Review #work/review"])
        XCTAssertEqual(try texts(TaskFilter(path: "Home")), ["Rent #home", "Taxes", "Dishes"])
        XCTAssertEqual(try texts(TaskFilter(path: "Inbox.md")), ["Idea"])
        XCTAssertEqual(try texts(TaskFilter(path: "Hom")), [])
        XCTAssertEqual(try texts(TaskFilter(text: "RE")), ["Rent #home", "Review #work/review"])
    }

    func testLiveTextWinsOverTheFileAndChangesAreSeen() throws {
        try seed()
        let index = index()
        XCTAssertEqual(try index.tasks(TaskFilter(path: "Inbox.md"), liveText: { $0 == "Inbox.md" ? "- [ ] Typed\n" : nil }).map(\.text), ["Typed"])
        try vault.write("Inbox.md", "- [ ] Idea\n- [ ] Second idea\n")
        XCTAssertEqual(try index.tasks(filter: TaskFilter(path: "Inbox.md")).map(\.text), ["Idea", "Second idea"])
        try vault.move("Inbox.md", to: "Old/Inbox.md")
        XCTAssertEqual(try index.tasks(filter: TaskFilter(text: "idea")).map(\.path), ["Old/Inbox.md", "Old/Inbox.md"])
    }

    // MARK: Toggle

    func testToggleChecksWithACompletionDateAndUnchecksWithoutIt() throws {
        try vault.write("Note.md", "# Note\n\n- [ ] Ship 📅 2026-10-20  \nEnd\n")
        let index = index()
        let checked = try index.toggle(path: "Note.md", line: 3, expectedText: "Ship")
        XCTAssertEqual(try vault.read("Note.md"), "# Note\n\n- [x] Ship 📅 2026-10-20 ✅ 2026-10-18\nEnd\n")
        XCTAssertTrue(checked.done)
        XCTAssertEqual(checked.completed, "2026-10-18")
        XCTAssertEqual(written, ["Note.md"])

        let unchecked = try index.toggle(path: "Note.md", line: 3, expectedText: "Ship")
        XCTAssertEqual(try vault.read("Note.md"), "# Note\n\n- [ ] Ship 📅 2026-10-20\nEnd\n")
        XCTAssertFalse(unchecked.done)
        XCTAssertNil(unchecked.completed)
    }

    func testToggleUppercaseXAndNestedNumberedLines() throws {
        try vault.write("Note.md", "1. [X] Done ✅ 2026-01-01\n   - [ ] Child\n")
        let index = index()
        try index.toggle(path: "Note.md", line: 1, expectedText: "Done")
        try index.toggle(path: "Note.md", line: 2, expectedText: "Child")
        XCTAssertEqual(try vault.read("Note.md"), "1. [ ] Done\n   - [x] Child ✅ 2026-10-18\n")
    }

    func testToggleRefusesAStaleLineAndWritesNothing() throws {
        let text = "- [ ] One\n- [ ] Two\n```\n- [ ] Code\n```\nPlain\n"
        try vault.write("Note.md", text)
        let index = index()
        let cases: [(Int, String)] = [(1, "Two"), (2, "One"), (4, "Code"), (6, "Plain"), (9, "One"), (0, "One")]
        for (line, expected) in cases {
            XCTAssertThrowsError(try index.toggle(path: "Note.md", line: line, expectedText: expected)) { error in
                XCTAssertEqual(error as? TasksError, .lineChanged(path: "Note.md", line: line))
            }
        }
        XCTAssertThrowsError(try index.toggle(path: "Missing.md", line: 1, expectedText: "One"))
        XCTAssertThrowsError(try index.toggle(path: "../Out.md", line: 1, expectedText: "One"))
        XCTAssertEqual(try vault.read("Note.md"), text)
        XCTAssertEqual(written, [])
    }

    func testToggleKeepsCRLFLineEndings() throws {
        try vault.write("Note.md", "---\r\nproject: X\r\n---\r\n- [ ] One\r\n- [ ] Two\r\n")
        try index().toggle(path: "Note.md", line: 5, expectedText: "Two")
        XCTAssertEqual(try vault.read("Note.md"), "---\r\nproject: X\r\n---\r\n- [ ] One\r\n- [x] Two ✅ 2026-10-18\r\n")
    }

    // MARK: Add

    func testAddGoesAtTheEndOfTheTasksSection() throws {
        try vault.write("Day.md", "# Day\n\n## Tasks\n- [ ] First\n\n## Notes\nText\n")
        let index = index()
        let task = try index.add("Second 📅 2026-10-19", to: "Day.md")
        XCTAssertEqual(try vault.read("Day.md"), "# Day\n\n## Tasks\n- [ ] First\n- [ ] Second 📅 2026-10-19\n\n## Notes\nText\n")
        XCTAssertEqual(task.line, 5)
        XCTAssertEqual(task.due, "2026-10-19")
        XCTAssertEqual(written, ["Day.md"])

        // An empty section, a section running to the end, CRLF.
        try vault.write("Empty.md", "# Day\n## Tasks\n\n## Log\n")
        XCTAssertEqual(try index.add("A", to: "Empty.md").line, 3)
        XCTAssertEqual(try vault.read("Empty.md"), "# Day\n## Tasks\n- [ ] A\n\n## Log\n")
        try vault.write("End.md", "### tasks\r\n- [ ] A\r\n")
        try index.add("B", to: "End.md")
        XCTAssertEqual(try vault.read("End.md"), "### tasks\r\n- [ ] A\r\n- [ ] B\r\n")
        // A deeper heading stays in the section; a heading in a code block is not one.
        try vault.write("Deep.md", "```\n## Tasks\n```\n## Tasks\n### Sub\n- [ ] A\n## Next\n")
        try index.add("B", to: "Deep.md")
        XCTAssertEqual(try vault.read("Deep.md"), "```\n## Tasks\n```\n## Tasks\n### Sub\n- [ ] A\n- [ ] B\n## Next\n")
    }

    func testAddWithoutAHeadingAppendsOrCreatesTheNote() throws {
        let index = index()
        let created = try index.add("  First\nline  ", to: "Inbox.md")
        XCTAssertEqual(try vault.read("Inbox.md"), "- [ ] First line\n")
        XCTAssertEqual(created, TaskItem(path: "Inbox.md", line: 1, text: "First line", done: false))
        try index.add("Second", to: "Inbox.md")
        XCTAssertEqual(try vault.read("Inbox.md"), "- [ ] First line\n- [ ] Second\n")

        try vault.write("Prose.md", "# Prose\n\nA paragraph.")
        XCTAssertEqual(try index.add("Task", to: "Prose.md").line, 5)
        XCTAssertEqual(try vault.read("Prose.md"), "# Prose\n\nA paragraph.\n\n- [ ] Task\n")

        XCTAssertThrowsError(try index.add("   ", to: "Inbox.md")) { XCTAssertEqual($0 as? TasksError, .emptyText) }
        XCTAssertThrowsError(try index.add("x", to: "image.png")) { XCTAssertEqual($0 as? TasksError, .notANote("image.png")) }
    }
}
