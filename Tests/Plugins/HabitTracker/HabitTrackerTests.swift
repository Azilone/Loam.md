import XCTest
import PluginKit
import LoamCore
@testable import HabitTrackerPlugin

final class HabitTrackerTests: XCTestCase {
    private var root: URL!
    private var vault: Vault!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("habits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tracker(today: String = "2026-10-18") -> HabitTracker {
        HabitTracker(vault: vault, today: { today })
    }

    func testFirstCheckInCreatesTheNote() throws {
        let status = try tracker().check(name: "Meditate", date: nil)
        XCTAssertEqual(try vault.read("Habits/Meditate.md"), "# Meditate\n\n## Check-ins\n- [x] 2026-10-18\n")
        XCTAssertEqual(status, HabitStatus(name: "Meditate", checkIns: 1, currentStreak: 1, longestStreak: 1, lastCheckIn: "2026-10-18"))
    }

    func testCheckingTheSameDayTwiceChangesNothing() throws {
        let tracker = tracker()
        try tracker.check(name: "Run", date: "2026-10-18")
        let before = try vault.read("Habits/Run.md")
        try tracker.check(name: "Run", date: "2026-10-18")
        XCTAssertEqual(try vault.read("Habits/Run.md"), before)
    }

    func testStreaksAcrossGapsAndMonthBoundaries() throws {
        let tracker = tracker()
        for day in ["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-10", "2026-10-17", "2026-10-18"] {
            try tracker.check(name: "Read", date: day)
        }
        let status = try tracker.status(name: "Read")
        XCTAssertEqual(status.checkIns, 6)
        XCTAssertEqual(status.longestStreak, 3)
        XCTAssertEqual(status.currentStreak, 2)
    }

    func testStreakSurvivesUntilTheEndOfTheNextDayButNotLonger() throws {
        try tracker(today: "2026-10-17").check(name: "Read", date: "2026-10-17")
        XCTAssertEqual(try tracker(today: "2026-10-18").status(name: "Read").currentStreak, 1)
        XCTAssertEqual(try tracker(today: "2026-10-19").status(name: "Read").currentStreak, 0)
    }

    func testUserTextInTheNoteIsKept() throws {
        try vault.write("Habits/Yoga.md", "# Yoga\n\nWhy: back pain.\n\n## Check-ins\n- [x] 2026-10-01\n\n## Notes\nStretch.")
        try tracker().check(name: "Yoga", date: "2026-10-02")
        let text = try vault.read("Habits/Yoga.md")
        XCTAssertTrue(text.hasPrefix("# Yoga\n\nWhy: back pain.\n"))
        XCTAssertTrue(text.contains("Stretch.\n- [x] 2026-10-02\n"))
        XCTAssertEqual(try tracker().status(name: "Yoga").checkIns, 2)
    }

    func testInvalidInputIsRejected() {
        let tracker = tracker()
        XCTAssertThrowsError(try tracker.check(name: "../evil", date: nil))
        XCTAssertThrowsError(try tracker.check(name: ".hidden", date: nil))
        XCTAssertThrowsError(try tracker.check(name: "Ok", date: "2026-02-30"))
    }

    func testCommandsListHabitsSortedByName() async throws {
        let kernel = Kernel(vault: vault)
        let host = PluginHost(kernel: kernel)
        try host.register(HabitTrackerPlugin.self)
        try host.activateAll()

        let check = try XCTUnwrap(kernel.commands.command(id: "habits.check"))
        _ = try await check.handler(["name": "Walk", "date": "2026-10-01"])
        _ = try await check.handler(["name": "Read", "date": "2026-10-01"])
        let list = try XCTUnwrap(kernel.commands.command(id: "habits.list"))
        let statuses = try JSONDecoder().decode([HabitStatus].self, from: Data(try await list.handler([:]).utf8))
        XCTAssertEqual(statuses.map(\.name), ["Read", "Walk"])
    }

    func testTheFolderComesFromTheSettingsAndFollowsThem() async throws {
        let config = try ConfigStore(vault: vault)
        try config.mutate { $0.setSettings(.map(["folder": .string(" /Life/Habits/")]), for: "habit-tracker") }
        let kernel = Kernel(vault: vault, config: config)
        let host = PluginHost(kernel: kernel)
        try host.register(HabitTrackerPlugin.self)
        try host.activateAll()
        defer { host.deactivateAll() }
        XCTAssertEqual(kernel.settingsDefault(for: "habit-tracker"), .map(["folder": .string("Habits")]))

        let create = try XCTUnwrap(kernel.commands.command(id: "habits.create"))
        let created = try await create.handler(["name": "Walk"])
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(created.utf8)), ["path": "Life/Habits/Walk.md"])
        let list = try XCTUnwrap(kernel.commands.command(id: "habits.list"))
        func names() async throws -> [String] {
            try JSONDecoder().decode([HabitStatus].self, from: Data(try await list.handler([:]).utf8)).map(\.name)
        }
        let listed = try await names()
        XCTAssertEqual(listed, ["Walk"])

        // Emptied, it goes back to the default, so the notes at the root never count as habits.
        try vault.write("Loose.md", "# Loose\n")
        try config.mutate { $0.setSettings(.map(["folder": .string("")]), for: "habit-tracker") }
        kernel.events.emit(PluginSettingsChanged(pluginID: "habit-tracker"))
        let none = try await names()
        XCTAssertEqual(none, [])
        let service = try XCTUnwrap(kernel.services.service(.habits))
        XCTAssertEqual(service.folder, "Habits")
    }
}
