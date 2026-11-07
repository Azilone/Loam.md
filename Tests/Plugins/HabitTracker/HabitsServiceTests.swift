import PluginKit
import PluginKitTesting
import XCTest
@testable import HabitTrackerPlugin

final class HabitsServiceTests: XCTestCase {
    private var vault: TemporaryVault!

    override func setUpWithError() throws {
        vault = try TemporaryVault()
    }

    private func service(today: String = "2026-10-18") -> HabitsService {
        HabitTracker(vault: vault, today: { today })
    }

    func testCreateWritesAShortHeaderAndRefusesAnExistingHabit() throws {
        let service = service()
        XCTAssertEqual(try service.create(" Meditate "), "Habits/Meditate.md")
        XCTAssertEqual(try vault.read("Habits/Meditate.md"), "---\ncreated: 2026-10-18\n---\n# Meditate\n\n## Check-ins\n")
        XCTAssertThrowsError(try service.create("Meditate")) { error in
            XCTAssertEqual(error as? HabitError, .alreadyExists("Meditate"))
        }
        XCTAssertThrowsError(try service.create("a/b"))
        XCTAssertThrowsError(try service.create(""))

        // Checking a created habit appends under its section.
        try service.check("Meditate", date: "2026-10-17")
        XCTAssertEqual(
            try vault.read("Habits/Meditate.md"),
            "---\ncreated: 2026-10-18\n---\n# Meditate\n\n## Check-ins\n- [x] 2026-10-17\n"
        )
    }

    func testHabitsListsNotesWithDaysStreaksAndCreated() throws {
        try vault.write("Habits/Run.md", "# Run\n\n## Check-ins\n- [x] 2026-10-10\n- [X] 2026-10-17\n- [x] 2026-10-18\n")
        try vault.write("Habits/Read.md", "---\ncreated: '2026-09-01'\n---\n# Read\n")
        try vault.write("Habits/Old/Nested.md", "- [x] 2026-10-18\n")
        try vault.write("Other.md", "- [x] 2026-10-18\n")

        let habits = try service().habits()
        XCTAssertEqual(habits.map(\.name), ["Read", "Run"])
        XCTAssertEqual(habits[0], Habit(
            name: "Read", path: "Habits/Read.md", checkedDays: [], currentStreak: 0, longestStreak: 0, created: "2026-09-01"
        ))
        XCTAssertEqual(habits[1], Habit(
            name: "Run",
            path: "Habits/Run.md",
            checkedDays: ["2026-10-10", "2026-10-17", "2026-10-18"],
            currentStreak: 2,
            longestStreak: 2,
            created: "2026-10-10"
        ))
    }

    func testUncheckRemovesOnlyThatDayAndKeepsTheRest() throws {
        try vault.write("Habits/Yoga.md", "# Yoga\n\nWhy: back.\n\n## Check-ins\n- [x] 2026-10-16\n- [x] 2026-10-17\n- [x] 2026-10-18\n\nMine.")
        let service = service()
        try service.uncheck("Yoga", date: "2026-10-17")
        XCTAssertEqual(try vault.read("Habits/Yoga.md"), "# Yoga\n\nWhy: back.\n\n## Check-ins\n- [x] 2026-10-16\n- [x] 2026-10-18\n\nMine.")
        var yoga = try XCTUnwrap(service.habits().first)
        XCTAssertEqual(yoga.checkedDays, ["2026-10-16", "2026-10-18"])
        XCTAssertEqual(yoga.currentStreak, 1)

        try service.uncheck("Yoga", date: nil)
        yoga = try XCTUnwrap(service.habits().first)
        XCTAssertEqual(yoga.checkedDays, ["2026-10-16"])
        XCTAssertEqual(yoga.currentStreak, 0)

        // Unchecking a day that is not checked changes nothing; a bad date or a missing habit throws.
        let before = try vault.read("Habits/Yoga.md")
        try service.uncheck("Yoga", date: "2026-01-01")
        XCTAssertEqual(try vault.read("Habits/Yoga.md"), before)
        XCTAssertThrowsError(try service.uncheck("Yoga", date: "2026-13-01"))
        XCTAssertThrowsError(try service.uncheck("Missing", date: nil))
    }

    func testThePluginProvidesTheServiceAndTheNewCommands() async throws {
        let harness = try PluginTestHarness([HabitTrackerPlugin.self])
        XCTAssertNotNil(harness.kernel.services.service(.habits))

        let created = try await harness.run("habits.create", ["name": "Walk"])
        XCTAssertEqual(created, try JSON.string(["path": "Habits/Walk.md"]))
        _ = try await harness.run("habits.check", ["name": "Walk", "date": "2026-10-01"])
        let status = try JSONDecoder().decode(
            HabitStatus.self,
            from: Data(try await harness.run("habits.uncheck", ["name": "Walk", "date": "2026-10-01"]).utf8)
        )
        XCTAssertEqual(status.checkIns, 0)
        XCTAssertFalse(try harness.vault.read("Habits/Walk.md").contains("2026-10-01"))

        harness.host.deactivateAll()
        XCTAssertNil(harness.kernel.services.service(.habits))
        XCTAssertNil(harness.kernel.commands.command(id: "habits.uncheck"))
    }
}
