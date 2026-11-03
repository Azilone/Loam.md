import XCTest
@testable import LoamCLI

/// `loam guide`, `loam skill` and `loam app`: what outside agents use.
final class AgentToolsTests: XCTestCase {
    func testGuideHasAnOverviewAndEveryTopic() throws {
        let overview = try XCTUnwrap(Guide.text(nil))
        XCTAssertTrue(overview.contains("loam guide <topic>"))
        for topic in Guide.topics {
            XCTAssertTrue(overview.contains(topic.name), topic.name)
            XCTAssertNotNil(Guide.text(topic.name))
        }
        XCTAssertTrue(try XCTUnwrap(Guide.text("plugins")).contains("loam plugin build"))
        XCTAssertTrue(try XCTUnwrap(Guide.text("migrate")).contains("Migration log.md"))
        XCTAssertNil(Guide.text("nope"))
    }

    func testParsingTheAgentVerbs() throws {
        XCTAssertEqual(try CLI.parse(["guide", "plugins"]).operands, ["plugins"])
        let skill = try CLI.parse(["skill", "install", "--claude"])
        XCTAssertEqual(skill.operands, ["install", "--claude"])
        let run = try CLI.parse(["app", "run", "tasks.add", "text=Buy milk"])
        XCTAssertEqual(run.operands, ["run", "tasks.add"])
        XCTAssertEqual(run.arguments, ["text": "Buy milk"])
        let test = try CLI.parse(["plugin", "test", "word-count"])
        XCTAssertEqual(test.command, "plugins.test")
        XCTAssertEqual(test.arguments, ["id": "word-count"])
    }

    func testGuideAndSkillRunWithoutAVault() throws {
        let guide = try XCTUnwrap(CLI.executeLocal(try CLI.parse(["guide", "app"])))
        XCTAssertEqual(guide.exitCode, 0)
        XCTAssertTrue(guide.stdout.contains("loam app relaunch"))
        let printed = try XCTUnwrap(CLI.executeLocal(try CLI.parse(["skill", "print"])))
        XCTAssertTrue(printed.stdout.hasPrefix("---\nname: loam\n"))
        XCTAssertNil(CLI.executeLocal(try CLI.parse(["list"])))
    }

    func testSkillInstallsWhereTheAgentsLook() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(AgentSkill.status(home: home).allSatisfy { !$0.installed })
        let written = try AgentSkill.install(["claude"], home: home)
        XCTAssertEqual(written, [home.appendingPathComponent(".claude/skills/loam/SKILL.md").path])
        let status = AgentSkill.status(home: home)
        XCTAssertEqual(status.first { $0.target == "claude" }?.current, true)
        XCTAssertEqual(status.first { $0.target == "codex" }?.installed, false)
        try AgentSkill.install([], home: home)
        XCTAssertTrue(AgentSkill.status(home: home).allSatisfy(\.current))
        AgentSkill.uninstall([], home: home)
        XCTAssertTrue(AgentSkill.status(home: home).allSatisfy { !$0.installed })
        XCTAssertThrowsError(try AgentSkill.install(["nope"], home: home))
    }

    func testCommandLineLink() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(CommandLineInstall.installed(home: home))
        try CommandLineInstall.install(executable: URL(fileURLWithPath: "/bin/echo"), home: home)
        XCTAssertEqual(CommandLineInstall.installed(home: home), "/bin/echo")
        try CommandLineInstall.install(executable: URL(fileURLWithPath: "/bin/cat"), home: home)
        XCTAssertEqual(CommandLineInstall.installed(home: home), "/bin/cat")
        let instance = URL(fileURLWithPath: "/tmp/loam-instances/x/Loam.app/Contents/Helpers/loam")
        XCTAssertThrowsError(try CommandLineInstall.install(executable: instance, home: home), "a test instance never takes the link")
        XCTAssertEqual(CommandLineInstall.installed(home: home), "/bin/cat")
        CommandLineInstall.uninstall(home: home)
        XCTAssertNil(CommandLineInstall.installed(home: home))
    }

    func testAppChannelRoundTrip() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let server = AppChannelServer(vault: vault) { request in
            AppChannel.Response(ok: true, output: "\(request.action) \(request.target ?? "") \(request.arguments["k"] ?? "")")
        }
        try server.start()
        defer { server.stop() }
        let response = try AppChannel.send(AppChannel.Request(action: "run", target: "x.y", arguments: ["k": "v"]), vault: vault)
        XCTAssertEqual(response, AppChannel.Response(ok: true, output: "run x.y v"))

        let result = CLI.executeApp(try CLI.parse(["app", "open", "Note.md"]), vault: vault)
        XCTAssertEqual(result.stdout, "open Note.md \n")
        let switched = CLI.executeApp(try CLI.parse(["app", "switch", vault.path + "/"]), vault: vault)
        XCTAssertEqual(switched.stdout, "switch \(vault.standardizedFileURL.path) \n")
        XCTAssertEqual(CLI.executeApp(try CLI.parse(["app", "switch", vault.path + "/nope"]), vault: vault).exitCode, 2)
        server.stop()
        XCTAssertThrowsError(try AppChannel.send(AppChannel.Request(action: "info"), vault: vault)) { error in
            XCTAssertTrue("\(error)".contains("not running"))
        }
    }
}
