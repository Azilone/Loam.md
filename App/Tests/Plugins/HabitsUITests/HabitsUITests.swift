import HabitTrackerPlugin
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import HabitsUI

@MainActor
final class HabitsUITests: XCTestCase {
    private func harness(files: [String: String] = [:]) throws -> UIPluginHarness {
        try UIPluginHarness(logicPlugins: [HabitTrackerPlugin.self], uiPlugins: [HabitsUIPlugin.self], files: files)
    }

    private func board(_ harness: UIPluginHarness) throws -> HabitsBoard {
        try XCTUnwrap(harness.kernel.services.service(HabitsUIPlugin.modelKey))
    }

    /// Today and the days before it, as the logic plugin sees them (the current calendar and clock).
    private func day(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    func testTheBoardFollowsTheFolderSetting() async throws {
        let harness = try harness(files: ["Habits/Run.md": "# Run\n", "Life/Read.md": "# Read\n"])
        defer { harness.close() }
        let board = try board(harness)
        XCTAssertEqual(board.rows.map(\.name), ["Run"])

        try harness.setSettings(.map(["folder": .string("Life")]), for: "habit-tracker")
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertEqual(board.rows.map(\.name), ["Read"])
        XCTAssertEqual(board.folder, "Life")
    }

    func testRegistersTheViewTypeAndCommandsAndUnloadsCleanly() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("habits-ui"), "\(harness.report)")
        let ids = Set(harness.kernel.commands.all.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["habits.open", "habits.check-today"]))
        harness.host.deactivateAll()
        XCTAssertEqual(harness.views.all.map(\.id), [])
        XCTAssertNil(harness.kernel.commands.command(id: "habits.open"))
    }

    func testColourIconAndArchiveAreFrontmatterProperties() throws {
        let harness = try harness(files: ["Habits/Run.md": "# Run\n\nMy notes.\n"])
        defer { harness.close() }
        let board = try board(harness)
        let run = try XCTUnwrap(board.rows.first)
        XCTAssertEqual(run.color, HabitsBoard.defaultColor("Run"))
        board.setColor(run, "teal")
        board.setIcon(board.rows[0], "🏃")
        XCTAssertEqual(board.rows[0].color, "teal")
        XCTAssertEqual(board.rows[0].icon, "🏃")
        XCTAssertEqual(try harness.vault.read("Habits/Run.md"), "---\ncolor: teal\nicon: 🏃\n---\n# Run\n\nMy notes.\n")
        board.archive(board.rows[0])
        XCTAssertEqual(board.rows, [])
        XCTAssertTrue(try harness.vault.read("Habits/Run.md").contains("archived: true"))
        // The sidebar link counts what is left to do today.
        XCTAssertEqual(harness.panels.links.map(\.id).contains("habits.link"), true)
    }

    func testDoesNotStartWithoutTheHabitsService() throws {
        let harness = try UIPluginHarness(uiPlugins: [HabitsUIPlugin.self])
        defer { harness.close() }
        XCTAssertFalse(harness.host.isActive("habits-ui"))
    }

    func testTheViewTypeOpensOnlyTheHabitsPage() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertEqual(harness.views.viewTypes(for: .virtual("habits:")).map(\.id), ["habits.board"])
        for other: Resource in [.virtual("habits:x"), .virtual("calendar:"), .file("Habits/Run.md"), .folder("Habits")] {
            XCTAssertEqual(harness.views.viewTypes(for: other).map(\.id), [], "\(other)")
        }
    }

    func testWindowIsFourteenDaysEndingToday() {
        let days = HabitsBoard.window(endingAt: "2026-03-05", count: 14, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(days.count, 14)
        XCTAssertEqual(days.first?.id, "2026-02-20")
        XCTAssertEqual(days.last?.id, "2026-03-05")
        XCTAssertEqual(days.map(\.id).filter { $0.hasPrefix("2026-02-28") || $0.hasPrefix("2026-03-01") }, ["2026-02-28", "2026-03-01"])
        XCTAssertEqual(days.filter(\.isToday).map(\.id), ["2026-03-05"])
        XCTAssertEqual(days.last?.weekday, "Thu")
        XCTAssertEqual(days.last?.number, 5)
        XCTAssertEqual(Set(days.map(\.id)).count, 14, "column ids are unique")
        XCTAssertEqual(HabitsBoard.window(endingAt: "nope", count: 14), [])
    }

    func testRowsShowEachHabitOverTheWindow() throws {
        let harness = try harness(files: [
            "Habits/Run.md": "# Run\n\n## Check-ins\n- [x] \(day(20))\n- [x] \(day(1))\n- [x] \(day(0))\n",
            "Habits/Read.md": "# Read\n",
            "Notes/Other.md": "- [x] \(day(0))\n",
        ])
        defer { harness.close() }
        let board = try board(harness)
        XCTAssertEqual(board.days.count, 7)
        XCTAssertEqual(board.days.last?.id, day(0))
        XCTAssertEqual(board.days.first?.id, day(6))
        XCTAssertEqual(board.rows.map(\.name), ["Read", "Run"])
        XCTAssertEqual(board.rows.map(\.id), ["Habits/Read.md", "Habits/Run.md"])
        let run = board.rows[1]
        XCTAssertEqual(run.checked.count, 7)
        XCTAssertEqual(run.checked.enumerated().filter(\.element).map(\.offset), [5, 6], "the day 20 days ago is outside")
        XCTAssertTrue(run.doneToday)
        XCTAssertEqual(board.doneToday, 1)
        XCTAssertEqual(board.rate(run), 3.0 / 21.0, accuracy: 0.001, "3 days of the 21 since the first check-in")
        XCTAssertEqual(run.currentStreak, 2)
        XCTAssertEqual(run.longestStreak, 2)
        XCTAssertEqual(board.rows[0].checked, Array(repeating: false, count: 7))
        // The right sidebar shows the first habit until one is picked.
        XCTAssertEqual(board.selectedRow?.name, "Read")
        board.select(run)
        XCTAssertEqual(board.selectedRow?.name, "Run")
        XCTAssertEqual(board.checkIns(lastDays: 7), 2)
        // The history ends with this week and holds the day 20 days ago.
        XCTAssertTrue(board.history().joined().contains(day(20)))
        XCTAssertEqual(board.history().last?.compactMap { $0 }.last, day(0))
    }

    func testTogglingACellWritesTheNoteAndUpdatesTheStreak() throws {
        let harness = try harness(files: ["Habits/Run.md": "# Run\n\n## Check-ins\n- [x] \(day(1))\n"])
        defer { harness.close() }
        let board = try board(harness)
        XCTAssertEqual(board.rows[0].currentStreak, 1)

        board.toggle(board.rows[0], day: day(0))
        XCTAssertTrue(try harness.vault.read("Habits/Run.md").contains("- [x] \(day(0))"))
        XCTAssertEqual(board.rows[0].currentStreak, 2)
        XCTAssertEqual(board.rows[0].checked.last, true)

        board.toggle(board.rows[0], day: day(1))
        XCTAssertFalse(try harness.vault.read("Habits/Run.md").contains(day(1)))
        XCTAssertEqual(board.rows[0].currentStreak, 1)
        XCTAssertEqual(board.rows[0].longestStreak, 1)
        XCTAssertNil(board.error)
    }

    func testCreateAddsAHabitAndReportsADuplicate() throws {
        let harness = try harness()
        defer { harness.close() }
        let board = try board(harness)
        XCTAssertEqual(board.rows, [])
        XCTAssertEqual(board.create("  Meditate "), "Habits/Meditate.md")
        XCTAssertTrue(harness.vault.exists("Habits/Meditate.md"))
        XCTAssertEqual(board.rows.map(\.name), ["Meditate"])

        XCTAssertNil(board.create("Meditate"))
        XCTAssertEqual(board.error, "\"Meditate\" already exists.")
        XCTAssertNil(board.create("   "))
    }

    func testASuggestionCreatesTheHabitWithItsIcon() throws {
        let harness = try harness()
        defer { harness.close() }
        let board = try board(harness)
        board.create("Read", icon: "📚")
        XCTAssertEqual(board.rows.map(\.name), ["Read"])
        XCTAssertEqual(board.rows.first?.icon, "📚")
    }

    func testTheStripShowsWholeWeeksEndingToday() throws {
        let harness = try harness()
        defer { harness.close() }
        let board = try board(harness)
        XCTAssertEqual(board.days(weeks: 1), board.days)
        let three = board.days(weeks: 3)
        XCTAssertEqual(three.count, 21)
        XCTAssertEqual(three.last?.id, board.today)
        XCTAssertEqual(Array(three.suffix(7)), board.days)
    }

    func testClickingANameOpensTheNoteBeside() throws {
        let harness = try harness(files: ["Habits/Run.md": "# Run\n"])
        defer { harness.close() }
        let board = try board(harness)
        board.openNote(board.rows[0])
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Habits/Run.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.beside])
    }

    func testDoubleClickingAHabitSelectsItAndShowsTheInspector() throws {
        let harness = try harness(files: ["Habits/Run.md": "# Run\n", "Habits/Read.md": "# Read\n"])
        defer { harness.close() }
        let board = try board(harness)
        let row = try XCTUnwrap(board.rows.last)
        board.inspect(row)
        XCTAssertEqual(board.selectedRow?.path, row.path)
        XCTAssertEqual(harness.workspace.inspectorRequests, 1)
    }

    func testOpenCommandOpensTheBoardInANewTab() async throws {
        let harness = try harness()
        defer { harness.close() }
        let result = try await harness.run("habits.open")
        XCTAssertEqual(result, "Opened the habits page.")
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.virtual("habits:")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.newTab])
    }

    func testCheckTodayPicksAHabitInThePopup() async throws {
        let harness = try harness(files: ["Habits/Run.md": "# Run\n", "Habits/Read.md": "# Read\n"])
        defer { harness.close() }
        let result = try await harness.run("habits.check-today")
        XCTAssertEqual(result, "")
        XCTAssertEqual(harness.quickPick.shownCount, 1)
        XCTAssertEqual(harness.quickPick.query("").map(\.title), ["Read", "Run"])
        XCTAssertEqual(harness.quickPick.query("ru").map(\.id), ["Habits/Run.md"])
        XCTAssertTrue(harness.quickPick.choose(id: "Habits/Run.md"))
        XCTAssertTrue(try harness.vault.read("Habits/Run.md").contains("- [x] \(day(0))"))
        let board = try board(harness)
        XCTAssertEqual(board.rows.first { $0.name == "Run" }?.checked.last, true)
    }

    func testCheckTodayWithoutHabitsSaysSo() async throws {
        let harness = try harness()
        defer { harness.close() }
        let result = try await harness.run("habits.check-today")
        XCTAssertTrue(result.hasPrefix("No habit yet"))
        XCTAssertEqual(harness.quickPick.shownCount, 0)
    }

    func testRefreshesWhenTheVaultChanges() throws {
        let harness = try harness()
        defer { harness.close() }
        let board = try board(harness)
        try harness.vault.write("Habits/Swim.md", "# Swim\n")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .added, path: "Habits/Swim.md")]))
        XCTAssertEqual(board.rows.map(\.name), ["Swim"])
    }

    func testTheBoardRendersOffscreenEmptyAndFull() throws {
        let harness = try harness()
        defer { harness.close() }
        let type = try XCTUnwrap(harness.views.viewTypes(for: .virtual("habits:")).first)
        let context = ViewContext(resource: .virtual("habits:"))
        XCTAssertGreaterThan(harness.render(type.makeView(context)).fittingSize.height, 0)

        _ = try board(harness).create("Run")
        let full = harness.render(type.makeView(context), size: CGSize(width: 900, height: 400))
        XCTAssertGreaterThan(full.fittingSize.width, 0)
    }
}
