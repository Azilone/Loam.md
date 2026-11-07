import HabitTrackerPlugin
import PluginKitUI
import PluginKitUITesting
import XCTest
@testable import HabitsUI

/// The sound of a habit checked: `done`, `allDone` for the day's last habit, `undone`.
@MainActor
final class HabitSoundsTests: XCTestCase {
    func testTheDaysLastHabitPlaysAllDone() throws {
        let harness = try UIPluginHarness(
            logicPlugins: [HabitTrackerPlugin.self], uiPlugins: [HabitsUIPlugin.self],
            files: ["Habits/Run.md": "# Run\n", "Habits/Read.md": "# Read\n"]
        )
        defer { harness.close() }
        let board = try XCTUnwrap(harness.kernel.services.service(HabitsUIPlugin.modelKey))
        let sounds = RecordingSounds()
        Sounds.player = sounds
        defer { Sounds.player = nil }
        let today = board.today

        board.toggle(board.rows[0], day: today)
        Thread.sleep(forTimeInterval: 0.1)
        board.toggle(board.rows[1], day: today)
        Thread.sleep(forTimeInterval: 0.1)
        board.toggle(board.rows[1], day: today)
        XCTAssertEqual(sounds.played, [.done, .allDone, .undone])
    }
}

@MainActor
final class RecordingSounds: SoundPlayer {
    private(set) var played: [SoundCue] = []
    func play(_ cue: SoundCue) { played.append(cue) }
}
