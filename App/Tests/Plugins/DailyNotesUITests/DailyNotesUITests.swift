import BuiltinPlugins
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import DailyNotesUI

@MainActor
final class DailyNotesUITests: XCTestCase {
    private func harness(files: [String: String] = [:]) throws -> UIPluginHarness {
        let logic = builtinPlugins.filter { $0.manifest.id == "daily-notes" }
        return try UIPluginHarness(logicPlugins: logic, uiPlugins: [DailyNotesUIPlugin.self],
            files: files.merging(UIPluginHarness.flatDailyNotes) { mine, _ in mine }
        )
    }

    private func model(_ harness: UIPluginHarness) throws -> DailyCalendar {
        try XCTUnwrap(harness.kernel.services.service(DailyNotesUIPlugin.modelKey))
    }

    /// Today as the logic plugin sees it (the current calendar and clock).
    private var today: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    func testRegistersTheViewTypePanelAndCommands() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("daily-notes-ui"), "\(harness.report)")
        let day = Resource.file("Daily/2026-10-02.md")
        let page = try XCTUnwrap(harness.inspector.pages(for: day, viewType: nil).first)
        XCTAssertEqual(page.page.title, "Day")
        XCTAssertLessThan(page.page.order, 0, "before the note's other tabs")
        XCTAssertEqual(page.sections.map(\.id), ["daily.calendar"])
        XCTAssertTrue(harness.inspector.pages(for: .file("Notes/Plan.md"), viewType: nil).isEmpty)
        let ids = Set(harness.kernel.commands.all.map(\.id))
        for id in ["daily.open-today", "daily.open-previous", "daily.open-next", "calendar.open"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        XCTAssertEqual(
            harness.kernel.commands.command(id: "daily.open-today")?.shortcut,
            KeyShortcut("d", [.command])
        )
        harness.host.deactivateAll()
        XCTAssertEqual(harness.views.all.map(\.id), [])
        XCTAssertEqual(harness.inspector.all.map(\.id), [])
    }

    func testDoesNotStartWithoutTheDailyNotesService() throws {
        let harness = try UIPluginHarness(uiPlugins: [DailyNotesUIPlugin.self])
        defer { harness.close() }
        XCTAssertFalse(harness.host.isActive("daily-notes-ui"))
    }

    func testOpenTodayOpensTheNoteInTheFocusedTabWithoutCreatingIt() async throws {
        let harness = try harness()
        defer { harness.close() }
        let path = try await harness.run("daily.open-today")
        XCTAssertEqual(path, "Daily/\(today).md")
        XCTAssertFalse(harness.vault.exists(path), "the editor creates it when text is typed")
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file(path)])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace])
    }

    func testPreviousAndNextJumpBetweenExistingNotes() async throws {
        let harness = try harness(files: [
            "Daily/2026-01-05.md": "a", "Daily/2026-01-09.md": "b", "Daily/2026-02-01.md": "c", "Other.md": "x",
        ])
        defer { harness.close() }
        harness.workspace.activeResource = .file("Daily/2026-01-09.md")

        let previous = try await harness.run("daily.open-previous")
        XCTAssertEqual(previous, "Daily/2026-01-05.md")
        let none = try await harness.run("daily.open-previous")
        XCTAssertEqual(none, "No daily note before 2026-01-05.")
        let next = try await harness.run("daily.open-next")
        XCTAssertEqual(next, "Daily/2026-01-09.md")
        let next2 = try await harness.run("daily.open-next")
        XCTAssertEqual(next2, "Daily/2026-02-01.md")
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace, .replace, .replace])
        XCTAssertFalse(harness.vault.exists("Daily/2026-01-06.md"), "previous and next never create a note")

        // Not on a daily note: relative to today, so the latest note before it.
        harness.workspace.activeResource = .file("Other.md")
        let fromToday = try await harness.run("daily.open-previous")
        XCTAssertEqual(fromToday, "Daily/2026-02-01.md")
    }

    func testTheAgendaReadsADaysNoteAndTicksItsTasks() throws {
        let note = "---\ntags: [day]\n---\n# Monday\nWrote the plan.\n- [ ] Call Bob\n- [x] Run\n"
        let harness = try harness(files: ["Daily/2026-01-05.md": note])
        defer { harness.close() }
        let model = try model(harness)
        let content = try XCTUnwrap(model.content(of: "2026-01-05"))
        XCTAssertEqual(content.title, "Monday")
        XCTAssertEqual(content.preview, ["Wrote the plan."])
        XCTAssertEqual(content.tasks.map(\.text), ["Call Bob", "Run"])
        XCTAssertEqual(content.tasks.map(\.done), [false, true])
        XCTAssertNil(model.content(of: "2026-01-06"), "a day without a note")

        try model.toggleTask(date: "2026-01-05", line: content.tasks[0].id)
        XCTAssertEqual(try harness.vault.read("Daily/2026-01-05.md"), note.replacingOccurrences(of: "- [ ] Call", with: "- [x] Call"))
        try model.addTask("Ship it", date: "2026-01-06")
        XCTAssertTrue(try harness.vault.read("Daily/2026-01-06.md").contains("- [ ] Ship it"))
        XCTAssertEqual(DailyCalendar.day("2026-01-31", adding: 1), "2026-02-01")
        XCTAssertEqual(model.content(of: "2026-01-06")?.tasks.map(\.text), ["Ship it"], "adding reads the day again")
    }

    func testTheCalendarFollowsTheFolderSetting() async throws {
        let harness = try harness(files: ["Daily/2026-01-05.md": "# Old\n", "Journal/2026-01-07.md": "# New\n"])
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertEqual(model.content(of: "2026-01-05")?.title, "Old")

        try harness.setSettings(.map(["folder": .string("Journal")]), for: "daily-notes")
        // The calendar reads the new folder on the next turn of the main queue, once the service has it.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertNil(model.content(of: "2026-01-05"), "the old folder's note is gone")
        XCTAssertEqual(model.content(of: "2026-01-07")?.title, "New")
        XCTAssertEqual(model.date(of: .file("Journal/2026-01-07.md")), "2026-01-07")
    }

    func testTheAgendaReadsANoteAgainOnlyAfterAChange() throws {
        let harness = try harness(files: ["Daily/2026-01-05.md": "# One\n"])
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertEqual(model.content(of: "2026-01-05")?.title, "One")
        try harness.vault.write("Daily/2026-01-05.md", "# Two\n")
        XCTAssertEqual(model.content(of: "2026-01-05")?.title, "One", "kept until the vault reports a change")
        model.refresh()
        XCTAssertEqual(model.content(of: "2026-01-05")?.title, "Two")
    }

    func testAnEmptyNoteOrOneWithOnlyItsDateIsNoNote() throws {
        let harness = try harness(files: [
            "Daily/2026-01-05.md": "", "Daily/2026-01-06.md": "# 2026-01-06\n\n", "Daily/2026-01-07.md": "---\na: 1\n---\n",
            "Daily/2026-01-08.md": "# 2026-01-08\nHello\n",
        ])
        defer { harness.close() }
        let model = try model(harness)
        for day in ["2026-01-05", "2026-01-06", "2026-01-07"] { XCTAssertNil(model.content(of: day), day) }
        let filled = try XCTUnwrap(model.content(of: "2026-01-08"))
        XCTAssertNil(filled.title, "the date is the page's title already")
        XCTAssertEqual(filled.preview, ["Hello"])
        let grid = model.grid(Month("2026-01")!)
        let dots = grid.weeks.flatMap { $0 }.filter(\.hasNote).compactMap(\.date)
        XCTAssertEqual(dots, ["2026-01-08"])
    }

    func testThePreviewReadsAsTextNotMarkdown() throws {
        let note = "Some **bold** and *soft* with [a link](https://x.y) and [[Note|alias]] `code`\n\n"
            + "| a | b |\n| - | - |\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n![pic](a.png)\n- [ ] only task\n"
        let content = try XCTUnwrap(DailyCalendar.parse(note, date: "2026-01-05"))
        XCTAssertEqual(content.preview, ["Some bold and soft with a link and alias code", "Table", "Code"])
        XCTAssertEqual(content.tasks.map(\.text), ["only task"])
        XCTAssertNil(DailyCalendar.parse("![pic](a.png)\n", date: "2026-01-05"))
    }

    func testDateOfAResourceOnlyMatchesDailyNotes() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertEqual(model.date(of: .file("Daily/2026-03-04.md")), "2026-03-04")
        XCTAssertNil(model.date(of: .file("Notes/2026-03-04.md")))
        XCTAssertNil(model.date(of: .file("Daily/2026-02-30.md")))
        XCTAssertNil(model.date(of: .virtual("calendar:2026-03")))
        XCTAssertNil(model.date(of: nil))
    }

    func testMonthGridStartsOnTheCalendarsFirstWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        // October 2026 starts on a Thursday: three blanks before day 1 with Monday first.
        let grid = CalendarMonth.make(
            Month(year: 2026, month: 10)!,
            calendar: calendar,
            dates: ["2026-10-02", "2026-10-18", "2026-09-30"],
            today: "2026-10-18",
            selected: "2026-10-02"
        )
        XCTAssertEqual(grid.title, "October 2026")
        XCTAssertEqual(grid.weekdays, ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        XCTAssertEqual(grid.weeks.count, 5)
        XCTAssertTrue(grid.weeks.allSatisfy { $0.count == 7 })
        let cells = grid.weeks.flatMap { $0 }
        XCTAssertEqual(cells.prefix(4).map(\.date), [nil, nil, nil, "2026-10-01"])
        XCTAssertEqual(cells.compactMap(\.date).count, 31)
        XCTAssertEqual(Set(cells.map(\.id)).count, cells.count, "cell ids are unique")
        XCTAssertEqual(cells.filter(\.hasNote).map(\.date), ["2026-10-02", "2026-10-18"])
        XCTAssertEqual(cells.filter(\.isToday).map(\.date), ["2026-10-18"])
        XCTAssertEqual(cells.filter(\.isSelected).map(\.date), ["2026-10-02"])

        calendar.firstWeekday = 1
        let sundayFirst = CalendarMonth.make(
            Month(year: 2026, month: 10)!, calendar: calendar, dates: [], today: "", selected: nil
        )
        XCTAssertEqual(sundayFirst.weekdays.first, "Sun")
        XCTAssertEqual(sundayFirst.weeks[0].prefix(5).map(\.date), [nil, nil, nil, nil, "2026-10-01"])
    }

    func testMonthArithmeticAndParsing() {
        let january = Month(year: 2026, month: 1)!
        XCTAssertEqual(january.adding(-1).string, "2025-12")
        XCTAssertEqual(january.adding(13).string, "2027-02")
        XCTAssertEqual(Month("2026-10-18")?.string, "2026-10")
        XCTAssertNil(Month("2026-13"))
        XCTAssertNil(Month("26-10"))
        XCTAssertEqual(january.day(5), "2026-01-05")
    }

    func testClickingADayOpensItWithoutCreatingAFile() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        let path = try model.openDay("2026-05-06", placement: DailyCalendar.tabPlacement)
        XCTAssertEqual(path, "Daily/2026-05-06.md")
        XCTAssertFalse(harness.vault.exists(path))
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file(path)])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.beside])
        XCTAssertFalse(model.dates.contains("2026-05-06"))
        XCTAssertEqual(model.activeDate, "2026-05-06")
        XCTAssertEqual(DailyCalendar.panelPlacement, .replace)
    }

    func testAnEmptyDayOpensAsADraftWithItsTemplateAndNothingIsWritten() throws {
        let editor = RecordingEditor()
        let logic = builtinPlugins.filter { $0.manifest.id == "daily-notes" }
        let harness = try UIPluginHarness(
            logicPlugins: logic, uiPlugins: [DailyNotesUIPlugin.self],
            files: [".loam/templates/daily.md": "## Log\n"], editor: editor
        )
        defer { harness.close() }
        let model = try model(harness)
        let path = try model.openDay("2026-05-06", placement: .replace)
        XCTAssertFalse(harness.vault.exists(path), "even the template is only written once the user adds text")
        XCTAssertEqual(editor.drafts.map(\.path), [path])
        XCTAssertEqual(editor.drafts.map(\.text), ["## Log\n"])
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file(path)])
    }

    func testADayWithANoteIsNotADraft() throws {
        let editor = RecordingEditor()
        let logic = builtinPlugins.filter { $0.manifest.id == "daily-notes" }
        let harness = try UIPluginHarness(
            logicPlugins: logic, uiPlugins: [DailyNotesUIPlugin.self], files: ["Daily/2026-05-06.md": "Hi\n"],
            editor: editor
        )
        defer { harness.close() }
        _ = try model(harness).openDay("2026-05-06", placement: .replace)
        XCTAssertEqual(editor.drafts.count, 0)
    }

    func testDotsFollowVaultChanges() throws {
        let harness = try harness(files: ["Daily/2026-04-01.md": "x"])
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertEqual(model.dates, ["2026-04-01"])
        try harness.vault.write("Daily/2026-04-02.md", "y")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .added, path: "Daily/2026-04-02.md")]))
        XCTAssertEqual(model.dates, ["2026-04-01", "2026-04-02"])
    }

    func testActiveDailyNoteIsSelected() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("Daily/2026-07-14.md")))
        XCTAssertEqual(model.activeDate, "2026-07-14")
        XCTAssertEqual(model.currentMonth.string, "2026-07")
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("Other.md")))
        XCTAssertNil(model.activeDate)
    }

    func testTheViewTypeOpensCalendarResourcesOnly() throws {
        let harness = try harness()
        defer { harness.close() }
        for resource in [Resource.virtual("calendar:"), .virtual("calendar:2026-10")] {
            XCTAssertEqual(harness.views.viewTypes(for: resource).map(\.id), ["daily.calendar"], resource.path)
        }
        for resource in [
            Resource.virtual("calendar:2026-13"), .virtual("calendar:x"), .virtual("tips:"),
            .file("calendar:"), .file("Daily/2026-10-18.md"), .folder("Daily"),
        ] {
            XCTAssertEqual(harness.views.viewTypes(for: resource).map(\.id), [], resource.path)
        }
        XCTAssertEqual(DailyNotesUIPlugin.month(of: .virtual("calendar:2026-03"))?.string, "2026-03")
        XCTAssertNil(DailyNotesUIPlugin.month(of: .virtual("calendar:")))
    }

    func testCalendarOpenCommandOpensTheCalendarBeside() async throws {
        let harness = try harness()
        defer { harness.close() }
        _ = try await harness.run("calendar.open")
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.virtual("calendar:")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.beside])
    }

    func testViewAndPanelRenderOffscreen() throws {
        let harness = try harness(files: ["Daily/2026-10-02.md": "x"])
        defer { harness.close() }
        let size = CGSize(width: 320, height: 360)
        let type = try XCTUnwrap(harness.views.viewTypes(for: .virtual("calendar:2026-10")).first)
        for resource in [Resource.virtual("calendar:"), .virtual("calendar:2026-10")] {
            XCTAssertEqual(harness.render(type.makeView(ViewContext(resource: resource)), size: size).frame.size, size)
        }
        let saved = ViewContext(resource: .virtual("calendar:"))
        saved.setState(CalendarState(month: "2025-02"))
        XCTAssertEqual(harness.render(type.makeView(saved), size: size).frame.size, size)
        let day = Resource.file("Daily/2026-10-02.md")
        let section = try XCTUnwrap(harness.inspector.pages(for: day, viewType: nil).first?.sections.first)
        XCTAssertEqual(harness.render(section.makeView(day), size: size).frame.size, size)
    }

    func testTheHeaderAppliesToDailyNotesOnlyAndLeavesWithThePlugin() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertEqual(harness.noteHeaders.headers(for: .file("Daily/2025-12-05.md")).map(\.id), ["daily.header"])
        XCTAssertEqual(harness.noteHeaders.headers(for: .file("Notes/2025-12-05.md")).map(\.id), [])
        XCTAssertEqual(harness.noteHeaders.headers(for: .file("Daily/draft.md")).map(\.id), [])
        harness.host.deactivateAll()
        XCTAssertEqual(harness.noteHeaders.headers(for: .file("Daily/2025-12-05.md")).map(\.id), [])
    }

    func testTheWeekRunsFromMondayToSundayAndTurnsByWeeks() {
        // Friday 2025-12-05.
        XCTAssertEqual(DailyHeader.week(of: "2025-12-05", shift: 0), [
            "2025-12-01", "2025-12-02", "2025-12-03", "2025-12-04", "2025-12-05", "2025-12-06", "2025-12-07",
        ])
        XCTAssertEqual(DailyHeader.week(of: "2025-12-07", shift: 0).first, "2025-12-01")
        XCTAssertEqual(DailyHeader.week(of: "2025-12-05", shift: -1).first, "2025-11-24")
        XCTAssertEqual(DailyHeader.week(of: "2025-12-31", shift: 1).last, "2026-01-11")
        XCTAssertEqual(DailyHeader.format("2025-12-05", "EEEE"), "Friday")
        XCTAssertEqual(DailyHeader.format("2025-12-05", "MMM d, yyyy"), "Dec 5, 2025")
    }

    func testTheHeaderRendersOnADailyNote() throws {
        let harness = try harness(files: ["Daily/2025-12-05.md": "# 2025-12-05\n"])
        defer { harness.close() }
        let header = try XCTUnwrap(harness.noteHeaders.headers(for: .file("Daily/2025-12-05.md")).first)
        let view = header.makeView(ViewContext(resource: .file("Daily/2025-12-05.md")))
        let hosting = harness.render(view, size: CGSize(width: 900, height: 200))
        XCTAssertGreaterThan(hosting.fittingSize.height, 100)
    }

    func testTheSelectionFadesFromThePreviousDayOfTheSameWeek() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("Daily/2025-12-03.md")))
        XCTAssertNil(model.previousDate)
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("Daily/2025-12-05.md")))
        XCTAssertEqual(model.previousDate, "2025-12-03")
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("Other.md")))
        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("Daily/2025-12-06.md")))
        XCTAssertNil(model.previousDate, "coming from a note that is not a daily note")
    }

    func testDayContentIsReadOnceUntilTheNotesChange() throws {
        let harness = try harness(files: ["Daily/2026-01-05.md": "Hello\n"])
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertEqual(model.content(of: "2026-01-05")?.preview, ["Hello"])
        try harness.vault.write("Daily/2026-01-05.md", "Changed\n")
        XCTAssertEqual(model.content(of: "2026-01-05")?.preview, ["Hello"], "cached until a change is reported")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .modified, path: "Daily/2026-01-05.md")]))
        XCTAssertEqual(model.content(of: "2026-01-05")?.preview, ["Changed"])
    }

    func testCommandClickOnADateOpensANewTab() {
        XCTAssertEqual(DailyCalendar.clickPlacement(.replace, modifiers: []), .replace)
        XCTAssertEqual(DailyCalendar.clickPlacement(.beside, modifiers: [.shift]), .beside)
        XCTAssertEqual(DailyCalendar.clickPlacement(.replace, modifiers: [.command]), .newTab)
        XCTAssertEqual(DailyCalendar.clickPlacement(.beside, modifiers: [.command]), .newTab)
    }
}
