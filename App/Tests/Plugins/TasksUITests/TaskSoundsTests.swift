import BuiltinPlugins
import PluginKitUI
import PluginKitUITesting
import XCTest
@testable import TasksUI

/// The sound of a check in the Tasks list: `done`, `allDone` for the last open task of the vault, `undone`.
@MainActor
final class TaskSoundsTests: XCTestCase {
    func testOnlyTheVaultsLastOpenTaskPlaysAllDone() throws {
        let logic = builtinPlugins.filter { ["tasks", "daily-notes", "note-graph"].contains($0.manifest.id) }
        let harness = try UIPluginHarness(
            logicPlugins: logic, uiPlugins: [TasksUIPlugin.self], files: ["Chores.md": "- [ ] Rent\n", "Work.md": "- [ ] Ship\n"]
        )
        defer { harness.close() }
        let board = try XCTUnwrap(harness.kernel.services.service(TasksUIPlugin.modelKey))
        let sounds = RecordingSounds()
        Sounds.player = sounds
        defer { Sounds.player = nil }

        board.toggle(try XCTUnwrap(board.tasks.first { $0.text == "Rent" }))
        Thread.sleep(forTimeInterval: 0.1)
        board.toggle(try XCTUnwrap(board.tasks.first { $0.text == "Ship" }))
        Thread.sleep(forTimeInterval: 0.1)
        board.toggle(try XCTUnwrap(board.tasks.first { $0.text == "Ship" }))
        XCTAssertEqual(sounds.played, [.done, .allDone, .undone])
    }
}

@MainActor
final class RecordingSounds: SoundPlayer {
    private(set) var played: [SoundCue] = []
    func play(_ cue: SoundCue) { played.append(cue) }
}
