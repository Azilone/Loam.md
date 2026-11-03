import BuiltinPlugins
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import TasksPlugin
import XCTest
@testable import TasksUI

@MainActor
final class TasksUITests: XCTestCase {
    /// The logic plugins the UI runs on: tasks, daily notes, and the note graph.
    private let logic = builtinPlugins.filter { ["tasks", "daily-notes", "note-graph"].contains($0.manifest.id) }

    private func harness(files: [String: String] = [:], editor: RecordingEditor? = nil, daily: Bool = true) throws -> UIPluginHarness {
        let logic = daily ? logic : logic.filter { $0.manifest.id != "daily-notes" }
        return try UIPluginHarness(logicPlugins: logic, uiPlugins: [TasksUIPlugin.self], files: files, editor: editor)
    }

    private func board(_ harness: UIPluginHarness) throws -> TaskBoard {
        try XCTUnwrap(harness.kernel.services.service(TasksUIPlugin.modelKey))
    }

    /// A day relative to today, as the logic plugin sees it (the current calendar and clock).
    private func day(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func seed() -> [String: String] {
        [
            "Work/Launch.md": "---\nproject: Launch\n---\n- [ ] Ship 📅 \(day(0)) #work\n- [ ] Late 📅 \(day(-2))\n- [x] Planned ✅ \(day(-1))\n",
            "Home/Chores.md": "- [ ] Rent 📅 \(day(3)) #home\n- [ ] Dishes\n",
        ]
    }

    func testRegistersViewPanelAndCommandsAndUnloadsCleanly() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("tasks-ui"), "\(harness.report)")
        XCTAssertEqual(harness.views.viewTypes(for: .virtual("tasks:")).map(\.id), ["tasks.list"])
        XCTAssertEqual(harness.views.viewTypes(for: .virtual("tasks:Launch")).map(\.id), ["tasks.list"])
        XCTAssertEqual(harness.views.viewTypes(for: .virtual("task:")).map(\.id), [])
        XCTAssertEqual(harness.views.viewTypes(for: .file("tasks:.md")).map(\.id), [])
        let today = try XCTUnwrap(harness.kernel.services.service(.dailyNotes)?.path(for: nil))
        let page = try XCTUnwrap(harness.inspector.pages(for: .file(today), viewType: nil).first)
        XCTAssertEqual(page.page.id, "daily.day", "with the calendar, in a daily note's Day tab")
        XCTAssertEqual(page.sections.map(\.id), ["tasks.due"])
        XCTAssertTrue(harness.inspector.pages(for: .file("Notes/Plan.md"), viewType: nil).isEmpty)
        XCTAssertTrue(Set(harness.kernel.commands.all.map(\.id)).isSuperset(of: ["tasks.open", "tasks.add-quick"]))
        harness.host.deactivateAll()
        XCTAssertEqual(harness.views.all.map(\.id), [])
        XCTAssertEqual(harness.inspector.all.map(\.id), [])
    }

    func testAddsTheDaysSectionToTheMentionMenu() throws {
        let editor = RecordingEditor()
        let harness = try harness(editor: editor)
        defer { harness.close() }
        let source = try XCTUnwrap(editor.mentionSources.first { $0.id == DateMentions.sourceID })
        XCTAssertEqual(source.section, "Days")
        let items = source.suggestions("tom")
        XCTAssertEqual(items.map(\.title).first?.hasPrefix("Tomorrow, "), true)
        let text = "- [ ] Call @tom"
        let change = items[0].makeChange(text, NSRange(location: 11, length: 4))
        XCTAssertEqual(change.applied(to: text), "- [ ] Call 📅 \(day(1)) ")
        harness.host.deactivateAll()
        XCTAssertEqual(editor.mentionSources.map(\.id), [])
    }

    func testChoosingADayReplacesTheLinesDueDate() {
        func apply(_ text: String, _ query: String) -> String {
            let at = (text as NSString).range(of: "@" + query)
            return DateMentions.change(in: text, trigger: at, date: "2026-10-21").applied(to: text)
        }
        XCTAssertEqual(apply("- [ ] A 📅 2026-10-19 @wed", "wed"), "- [ ] A 📅 2026-10-21 ")
        XCTAssertEqual(apply("- [ ] A @wed #work due:2026-10-19", "wed"), "- [ ] A 📅 2026-10-21 #work")
        XCTAssertEqual(apply("- [ ] A @wed next\n- [ ] B 📅 2026-10-19", "wed"), "- [ ] A 📅 2026-10-21 next\n- [ ] B 📅 2026-10-19")
        let text = "- [ ] A @wed"
        let change = DateMentions.change(in: text, trigger: NSRange(location: 8, length: 4), date: "2026-10-21")
        XCTAssertEqual(change.selection, NSRange(location: ("- [ ] A 📅 2026-10-21 " as NSString).length, length: 0))
    }

    func testDoesNotStartWithoutTheTasksService() throws {
        let harness = try UIPluginHarness(uiPlugins: [TasksUIPlugin.self])
        defer { harness.close() }
        XCTAssertFalse(harness.host.isActive("tasks-ui"))
    }

    func testModesGroupAsCraftDoes() throws {
        let harness = try harness(files: seed())
        defer { harness.close() }
        let board = try board(harness)
        func groups(_ mode: TaskBoard.Mode) -> [[String]] {
            board.groups(TaskBoard.Filter(mode: mode)).map { [$0.title] + $0.tasks.map(\.text) }
        }
        XCTAssertEqual(groups(.today), [["Overdue", "Late"], ["Today", "Ship #work"]])
        XCTAssertEqual(groups(.inbox), [["No date", "Dishes"]])
        XCTAssertEqual(groups(.upcoming).map { $0.dropFirst() }, [["Rent #home"]])
        XCTAssertEqual(Set(groups(.all).flatMap { $0.dropFirst() }), ["Late", "Ship #work", "Rent #home", "Dishes"])
        XCTAssertTrue(board.groups(TaskBoard.Filter()).allSatisfy { $0.notePath != nil }, "All is by note")
        XCTAssertEqual(board.doneTasks(TaskBoard.Filter()).map(\.text), ["Planned"])

        try harness.vault.write("Home/Chores.md", "- [ ] Rent 📅 \(day(3)) #home\n- [ ] Dishes\n- [ ] Laundry\n")
        board.refresh()
        XCTAssertEqual(groups(.inbox), [["No date", "Dishes", "Laundry"]], "new tasks group again")
    }

    func testUndatedTasksOfADailyNoteArePlannedOnItsDay() throws {
        let harness = try harness(files: [
            "Daily/\(day(0)).md": "- [ ] Call Bob\n- [x] Done already\n",
            "Daily/\(day(2)).md": "- [ ] Pack\n",
            "Daily/\(day(-3)).md": "- [ ] Forgotten\n",
            "Notes/2020-01-01.md": "- [ ] Not a daily note\n",
        ])
        defer { harness.close() }
        let board = try board(harness)
        func groups(_ mode: TaskBoard.Mode) -> [[String]] {
            board.groups(TaskBoard.Filter(mode: mode)).map { [$0.title] + $0.tasks.map(\.text) }
        }
        XCTAssertEqual(groups(.today), [["Today", "Call Bob"]])
        XCTAssertEqual(groups(.upcoming).map { $0.dropFirst() }, [["Pack"]])
        XCTAssertEqual(groups(.inbox), [["No date", "Forgotten", "Not a daily note"]], "older daily notes stay in Inbox")
        XCTAssertEqual(board.dueTasks.map(\.text), ["Call Bob"])
    }

    func testSectionsByDate() throws {
        let harness = try harness(files: seed())
        defer { harness.close() }
        let board = try board(harness)
        let sections = board.sections(TaskBoard.Filter())
        XCTAssertEqual(sections.map(\.kind), [.overdue, .today, .upcoming, .noDate, .done])
        XCTAssertEqual(sections.map { $0.tasks.map(\.text) }, [["Late"], ["Ship #work"], ["Rent #home"], ["Dishes"], ["Planned"]])
        XCTAssertEqual(Set(sections.flatMap(\.tasks).map(\.id)).count, 5, "row ids are unique")
        XCTAssertEqual(board.dueTasks.map(\.text), ["Late", "Ship #work"])
        XCTAssertEqual(TaskBoard.displayText(sections[1].tasks[0]), "Ship")
        XCTAssertEqual(String(TaskBoard.displayAttributed(sections[1].tasks[0]).characters), "Ship")
    }

    func testFilters() throws {
        let harness = try harness(files: seed())
        defer { harness.close() }
        let board = try board(harness)
        XCTAssertEqual(board.projects, ["Home", "Launch"])
        func texts(_ filter: TaskBoard.Filter, scope: String? = nil) -> [String] {
            board.sections(filter, scope: scope).flatMap(\.tasks).map(\.text)
        }
        XCTAssertEqual(texts(TaskBoard.Filter(project: "launch")), ["Late", "Ship #work", "Planned"])
        XCTAssertEqual(texts(TaskBoard.Filter(tag: "#HOME")), ["Rent #home"])
        XCTAssertEqual(texts(TaskBoard.Filter(project: "Launch", tag: "home")), [])
        XCTAssertEqual(texts(TaskBoard.Filter(project: "Launch"), scope: "Home"), ["Rent #home", "Dishes"], "a tasks:<project> tab wins")
        XCTAssertEqual(TasksUIPlugin.project(of: .virtual("tasks:Home")), "Home")
        XCTAssertNil(TasksUIPlugin.project(of: .virtual("tasks:")))
    }

    func testToggleWritesTheNoteAndMovesTheRow() throws {
        let harness = try harness(files: seed())
        defer { harness.close() }
        let board = try board(harness)
        let ship = try XCTUnwrap(board.tasks.first { $0.text == "Ship #work" })
        board.toggle(ship)
        XCTAssertNil(board.error)
        XCTAssertTrue(try harness.vault.read("Work/Launch.md").contains("- [x] Ship 📅 \(day(0)) #work ✅ \(day(0))"))
        let sections = board.sections(TaskBoard.Filter())
        XCTAssertEqual(sections.first { $0.kind == .done }?.tasks.map(\.text), ["Ship #work", "Planned"])
        XCTAssertNil(sections.first { $0.kind == .today })

        board.toggle(try XCTUnwrap(board.tasks.first { $0.text == "Ship #work" }))
        XCTAssertEqual(board.sections(TaskBoard.Filter()).first { $0.kind == .today }?.tasks.map(\.text), ["Ship #work"])
    }

    func testATaskCheckedInTheListStaysInItsGroupUntilTheListIsOpenedAgain() throws {
        let harness = try harness(files: seed())
        defer { harness.close() }
        let board = try board(harness)
        let ship = try XCTUnwrap(board.tasks.first { $0.text == "Ship #work" })
        let checked = try XCTUnwrap(board.toggle(ship))
        XCTAssertTrue(checked.done)
        let today = TaskBoard.Filter(mode: .today)
        let kept = board.groups(today, keeping: [checked.id])
        XCTAssertEqual(kept.first { $0.id == "today" }?.tasks.map(\.done), [true], "struck through, in place")
        XCTAssertEqual(board.doneTasks(today, keeping: [checked.id]).map(\.text), ["Planned"], "not twice")
        XCTAssertNil(board.groups(today).first { $0.id == "today" }, "gone once the list forgets it")

        let unchecked = try XCTUnwrap(board.toggle(checked), "the undo toggles it back")
        XCTAssertFalse(unchecked.done)
        XCTAssertTrue(try harness.vault.read("Work/Launch.md").contains("- [ ] Ship 📅 \(day(0)) #work\n"))
    }

    func testAStaleLineShowsAnErrorInsteadOfEditingTheWrongLine() throws {
        let harness = try harness(files: seed())
        defer { harness.close() }
        let board = try board(harness)
        let rent = try XCTUnwrap(board.tasks.first { $0.text == "Rent #home" })
        // Someone inserts a line above it, outside the app, and the list has not heard of it yet.
        let changed = "- [ ] New first\n- [ ] Rent 📅 \(day(3)) #home\n- [ ] Dishes\n"
        try harness.vault.write("Home/Chores.md", changed)
        board.toggle(rent)
        XCTAssertEqual(try harness.vault.read("Home/Chores.md"), changed)
        XCTAssertTrue(board.error?.contains("changed in Home/Chores.md") == true, board.error ?? "")
        XCTAssertEqual(board.tasks.first { $0.text == "Rent #home" }?.line, 2, "the list was read again")
    }

    func testQuickAddGoesToTodaysDailyNote() async throws {
        let harness = try harness()
        defer { harness.close() }
        let board = try board(harness)
        let path = try XCTUnwrap(board.quickAdd("  Call Bob  "))
        XCTAssertEqual(path, "Daily/\(day(0)).md")
        XCTAssertTrue(try harness.vault.read(path).contains("- [ ] Call Bob\n"))
        XCTAssertEqual(board.sections(TaskBoard.Filter()).first?.tasks.map(\.text), ["Call Bob"])
        XCTAssertNil(board.quickAdd("   "))

        let result = try await harness.run("tasks.add-quick", ["text": "Buy milk"])
        XCTAssertEqual(result, path)
        XCTAssertTrue(try harness.vault.read(path).contains("- [ ] Call Bob\n- [ ] Buy milk\n"))
    }

    func testQuickAddWithoutDailyNotesGoesToTheInbox() throws {
        let harness = try harness(daily: false)
        defer { harness.close() }
        let board = try board(harness)
        XCTAssertEqual(board.quickAdd("Idea"), "Inbox.md")
        XCTAssertEqual(try harness.vault.read("Inbox.md"), "- [ ] Idea\n")
    }

    func testOpeningATaskOpensItsNoteBesideAndRevealsTheLine() throws {
        let editor = RecordingEditor()
        let harness = try harness(files: seed(), editor: editor)
        defer { harness.close() }
        let board = try board(harness)
        board.open(try XCTUnwrap(board.tasks.first { $0.text == "Late" }))
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Work/Launch.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.beside])
        XCTAssertEqual(editor.revealed.map(\.line), [5])
        XCTAssertEqual(editor.revealed.map(\.path), ["Work/Launch.md"])
    }

    func testUnsavedEditorTextIsListed() async throws {
        let editor = RecordingEditor()
        let harness = try harness(files: seed(), editor: editor)
        defer { harness.close() }
        let board = try board(harness)
        editor.texts["Home/Chores.md"] = "- [ ] Typed just now\n"
        harness.kernel.events.emit(DocumentTextChanged(path: "Home/Chores.md"))
        try await waitUntil { board.tasks.contains { $0.text == "Typed just now" } }
        XCTAssertTrue(board.tasks.contains { $0.text == "Typed just now" })
        XCTAssertFalse(board.tasks.contains { $0.text == "Dishes" })
    }

    func testCommandsOpenTheList() async throws {
        let harness = try harness()
        defer { harness.close() }
        let board = try board(harness)
        let all = try await harness.run("tasks.open")
        XCTAssertEqual(all, "Opened the tasks.")
        let launch = try await harness.run("tasks.open", ["project": "Launch"])
        XCTAssertEqual(launch, "Opened the tasks of Launch.")
        XCTAssertEqual(board.focusRequest, 0)
        _ = try await harness.run("tasks.add-quick")
        XCTAssertEqual(board.focusRequest, 1)
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.virtual("tasks:"), .virtual("tasks:Launch"), .virtual("tasks:")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.newTab, .newTab, .newTab])
    }

    func testRefreshesWhenTheVaultChanges() async throws {
        let harness = try harness()
        defer { harness.close() }
        let board = try board(harness)
        XCTAssertEqual(board.tasks, [])
        try harness.vault.write("Note.md", "- [ ] Fresh\n")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .added, path: "Note.md")]))
        try await waitUntil { !board.tasks.isEmpty }
        XCTAssertEqual(board.tasks.map(\.text), ["Fresh"])
    }

    func testViewAndPanelRenderOffscreen() throws {
        let harness = try harness(files: seed())
        defer { harness.close() }
        let size = CGSize(width: 700, height: 500)
        for resource: Resource in [.virtual("tasks:"), .virtual("tasks:Launch"), .virtual("tasks:Nothing")] {
            let type = try XCTUnwrap(harness.views.viewTypes(for: resource).first)
            let view = harness.render(type.makeView(ViewContext(resource: resource)), size: size)
            XCTAssertGreaterThan(view.fittingSize.height, 0, resource.path)
        }
        let today = Resource.file(try XCTUnwrap(harness.kernel.services.service(.dailyNotes)?.path(for: nil)))
        let section = try XCTUnwrap(harness.inspector.pages(for: today, viewType: nil).first?.sections.first)
        XCTAssertGreaterThan(harness.render(section.makeView(today), size: CGSize(width: 260, height: 400)).fittingSize.height, 0)

        let empty = try self.harness()
        defer { empty.close() }
        let type = try XCTUnwrap(empty.views.viewTypes(for: .virtual("tasks:")).first)
        XCTAssertGreaterThan(empty.render(type.makeView(ViewContext(resource: .virtual("tasks:")))).fittingSize.height, 0)
        let emptyToday = Resource.file(try XCTUnwrap(empty.kernel.services.service(.dailyNotes)?.path(for: nil)))
        let emptySection = try XCTUnwrap(empty.inspector.pages(for: emptyToday, viewType: nil).first?.sections.first)
        XCTAssertGreaterThan(empty.render(emptySection.makeView(emptyToday)).fittingSize.height, 0)
    }

    func testTheDayHeaderListsTheTasksDueThatDayInOtherNotes() throws {
        let daily = "Daily/\(day(0)).md"
        let harness = try harness(files: seed().merging([daily: "# Day\n- [ ] Own task 📅 \(day(0))\n"]) { a, _ in a })
        defer { harness.close() }
        let model = try board(harness)
        XCTAssertEqual(harness.noteHeaders.headers(for: .file(daily)).map(\.id), ["tasks.day-header"])
        XCTAssertEqual(harness.noteHeaders.headers(for: .file("Work/Launch.md")).map(\.id), [])
        let groups = model.dayGroups(date: day(0), excluding: daily)
        XCTAssertEqual(groups.map(\.path), ["Work/Launch.md"])
        XCTAssertEqual(groups.first?.tasks.map(\.text), ["Ship #work"])
        XCTAssertEqual(model.dayGroups(date: day(1), excluding: daily), [])
        let header = try XCTUnwrap(harness.noteHeaders.headers(for: .file(daily)).first)
        _ = harness.render(header.makeView(ViewContext(resource: .file(daily))), size: CGSize(width: 900, height: 200))
        harness.host.deactivateAll()
        XCTAssertEqual(harness.noteHeaders.headers(for: .file(daily)).map(\.id), [])
    }

    func testNoDayHeaderWithoutDailyNotes() throws {
        let harness = try harness(daily: false)
        defer { harness.close() }
        XCTAssertEqual(harness.noteHeaders.headers(for: .file("Daily/\(day(0)).md")).map(\.id), [])
    }
}

/// Waits until `condition` holds, polling: the board refreshes once typing and saving pause.
@MainActor
private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return XCTFail("timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
