import PluginKit
import PluginKitUI
import PluginKitUITesting
import XCTest
@testable import SoundsUI

/// The player behind `Sounds.play`: installed while the plugin is active, silent when turned off (by its setting or
/// by the Mac), and a sound shipped for every cue.
@MainActor
final class SoundsUITests: XCTestCase {
    func testThePluginInstallsThePlayerAndRemovesItWhenDeactivated() throws {
        let harness = try UIPluginHarness(uiPlugins: [SoundsUIPlugin.self])
        let player = try XCTUnwrap(Sounds.player as? CuePlayer)
        player.systemAllows = { true }

        Sounds.play(.done)
        XCTAssertEqual(player.played, [.done])

        harness.close()
        XCTAssertNil(Sounds.player)
    }

    func testTheSettingsTurnTheSoundsOffAndSetTheVolume() throws {
        let harness = try UIPluginHarness(uiPlugins: [SoundsUIPlugin.self])
        defer { harness.close() }
        let player = try XCTUnwrap(Sounds.player as? CuePlayer)
        player.systemAllows = { true }

        try harness.setSettings(.map(["enabled": .bool(false)]), for: "sounds-ui")
        player.play(.trashed)
        XCTAssertEqual(player.played, [])

        try harness.setSettings(.map(["enabled": .bool(true), "volume": .number(3)]), for: "sounds-ui")
        XCTAssertEqual(player.volume, 1)
        player.play(.trashed)
        XCTAssertEqual(player.played, [.trashed])

        try harness.setSettings(.map(["volume": .number(0)]), for: "sounds-ui")
        player.play(.trashed)
        XCTAssertEqual(player.played, [.trashed])
    }

    func testTheMacsInterfaceSoundsSettingSilencesThem() {
        let player = CuePlayer()
        player.systemAllows = { false }
        player.play(.copied)
        XCTAssertEqual(player.played, [])
    }

    func testEveryCueHasASound() throws {
        XCTAssertNotNil(CuePlayer.bundle)
        for cue in SoundCue.allCases {
            XCTAssertNotNil(CuePlayer.url(of: cue), "\(cue)")
        }
    }
}
