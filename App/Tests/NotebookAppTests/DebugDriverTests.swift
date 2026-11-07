#if DEBUG
import DebugProtocol
import Foundation
import PluginKitUI
import XCTest
@testable import NotebookApp

/// The agent debug channel's commands, run against a real session without a window (the window commands have none
/// to act on and say so). The protocol itself is tested in DebugProtocolTests.
@MainActor
final class DebugDriverTests: ShellTestCase {
    private func driver(_ session: ShellSession?) throws -> DebugDriver {
        let instance = try XCTUnwrap(DebugInstance(name: "unit", base: root))
        return DebugDriver(instance: instance, settings: SettingsNavigation()) { session }
    }

    func testTheChannelIsCompiledIntoDebugBuilds() {
        XCTAssertTrue(AgentInstance.isCompiledIn)
    }

    func testPingAndHelpNeedNothing() async throws {
        let driver = try driver(nil)
        let ping = await driver.handle(DebugRequest(cmd: "ping", id: 9))
        XCTAssertTrue(ping.ok)
        XCTAssertEqual(ping.id, 9)
        XCTAssertEqual(ping.result?["pong"], true)
        let help = await driver.handle(DebugRequest(cmd: "help"))
        XCTAssertEqual(help.result?.array?.count, DebugCommand.names.count)
    }

    func testOpenShowsANoteAFolderAndAVirtualPage() async throws {
        try write("Inbox/A.md", "# A\n")
        let session = try openSession()
        let driver = try driver(session)
        let note = await driver.handle(DebugRequest(cmd: "open", params: ["path": "Inbox/A.md"]))
        XCTAssertTrue(note.ok, note.error ?? "")
        XCTAssertEqual(session.workspace.activeResource, .file("Inbox/A.md"))
        let page = await driver.handle(DebugRequest(cmd: "open", params: ["path": "test:page", "placement": "newTab"]))
        XCTAssertTrue(page.ok, page.error ?? "")
        XCTAssertEqual(session.workspace.activeResource, .virtual("test:page"))
    }

    func testOpenRefusesAMissingFileAndNoVault() async throws {
        let withVault = try driver(try openSession())
        let missing = await withVault.handle(DebugRequest(cmd: "open", params: ["path": "Nope.md"]))
        XCTAssertFalse(missing.ok)
        XCTAssertTrue(missing.error?.contains("No such file") == true)
        let noVault = await (try driver(nil)).handle(DebugRequest(cmd: "open", params: ["path": "A.md"]))
        XCTAssertEqual(noVault.error, "No vault is open.")
    }

    func testRunCallsARegisteredCommandAndReportsAnUnknownOne() async throws {
        let driver = try driver(try openSession())
        let hello = await driver.handle(DebugRequest(cmd: "run", params: ["command": "test.hello"]))
        XCTAssertEqual(hello.result?["output"], "hello")
        let unknown = await driver.handle(DebugRequest(cmd: "run", params: ["command": "nope.nothing"]))
        XCTAssertFalse(unknown.ok)
    }

    func testThemeWritesTheAppearanceToTheVaultConfig() async throws {
        let session = try openSession()
        let driver = try driver(session)
        let dark = await driver.handle(DebugRequest(cmd: "theme", params: ["value": "dark"]))
        XCTAssertTrue(dark.ok, dark.error ?? "")
        XCTAssertEqual(session.themes.appearance, .dark)
        _ = await driver.handle(DebugRequest(cmd: "theme", params: ["value": "auto"]))
        XCTAssertNil(session.themes.appearance)
    }

    func testReduceMotionOverridesTheSystem() async throws {
        let driver = try driver(nil)
        defer { Motion.reduceMotionOverride = nil }
        _ = await driver.handle(DebugRequest(cmd: "reduce-motion", params: ["value": true]))
        XCTAssertTrue(Motion.reduceMotion)
        _ = await driver.handle(DebugRequest(cmd: "reduce-motion", params: ["value": false]))
        XCTAssertFalse(Motion.reduceMotion)
    }

    func testBadRequestsAreAnswersNotCrashes() async throws {
        let driver = try driver(nil)
        let unknown = await driver.handle(DebugRequest(cmd: "teleport"))
        XCTAssertEqual(unknown.error, DebugError.unknownCommand("teleport").description)
        let missing = await driver.handle(DebugRequest(cmd: "type"))
        XCTAssertFalse(missing.ok)
        // No window is up in a test: window commands say so instead of failing silently.
        let click = await driver.handle(DebugRequest(cmd: "click", params: ["x": 1, "y": 2]))
        XCTAssertEqual(click.error, "The window is not up yet.")
    }

    func testStateFileDescribesTheInstance() throws {
        let driver = try driver(nil)
        driver.writeState()
        let data = try Data(contentsOf: URL(fileURLWithPath: driver.instance.statePath))
        let state = try JSONDecoder().decode(DebugValue.self, from: data)
        XCTAssertEqual(state["instance"], "unit")
        XCTAssertEqual(state["socket"]?.string, driver.instance.socketPath)
    }
}
#endif
