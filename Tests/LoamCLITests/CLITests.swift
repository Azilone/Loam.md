import XCTest
import DailyNotesPlugin
import PluginKit
import LoamCore
@testable import LoamCLI

final class CLITests: XCTestCase {
    private var root: URL!
    private var kernel: Kernel!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        kernel = Kernel(vault: Vault(rootURL: root))
        let host = PluginHost(kernel: kernel)
        try host.register(DailyNotesPlugin.self)
        try host.activateAll()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testParseReadsVaultCommandAndArguments() throws {
        let invocation = try CLI.parse(["--vault", "/v", "daily.append", "text=a=b c", "date=2026-01-02"])
        XCTAssertEqual(invocation.vault, "/v")
        XCTAssertEqual(invocation.command, "daily.append")
        XCTAssertEqual(invocation.arguments, ["text": "a=b c", "date": "2026-01-02"])
        XCTAssertEqual(try CLI.parse(["--vault=/w", "list"]).vault, "/w")
    }

    func testParseRejectsBadInput() {
        XCTAssertThrowsError(try CLI.parse(["cmd", "positional"]))
        XCTAssertThrowsError(try CLI.parse(["--vault"]))
        XCTAssertThrowsError(try CLI.parse(["--nope", "cmd"]))
        XCTAssertThrowsError(try CLI.parse(["cmd", "=x"]))
    }

    func testPluginAliasesMapToThePluginsCommands() throws {
        func parsed(_ arguments: [String]) throws -> (String?, [String: String]) {
            let invocation = try CLI.parse(arguments)
            return (invocation.command, invocation.arguments)
        }
        XCTAssertTrue(try parsed(["plugin", "new", "hello2"]) == ("plugins.new", ["id": "hello2"]))
        XCTAssertTrue(try parsed(["plugin", "new", "hello2", "--ui", "name=Hello Two"])
            == ("plugins.new", ["id": "hello2", "ui": "true", "name": "Hello Two"]))
        XCTAssertTrue(try parsed(["plugin", "build", "hello2"]) == ("plugins.build", ["id": "hello2"]))
        XCTAssertTrue(try parsed(["plugin", "build", "--all"]) == ("plugins.build", ["all": "true"]))
        XCTAssertTrue(try parsed(["plugin", "install", "https://example.com/p.git?ref=a=b"])
            == ("plugins.install", ["url": "https://example.com/p.git?ref=a=b"]))
        XCTAssertTrue(try parsed(["plugin", "install", "../my plugin"]) == ("plugins.install", ["url": "../my plugin"]))
        XCTAssertTrue(try parsed(["plugin", "list"]) == ("plugins.list", [:]))
        XCTAssertTrue(try parsed(["plugin", "remove", "hello2"]) == ("plugins.remove", ["id": "hello2"]))
        XCTAssertTrue(try parsed(["plugin", "enable", "hello2"]) == ("plugins.enable", ["id": "hello2"]))
        XCTAssertTrue(try parsed(["--vault", "/v", "plugin", "disable", "hello2"]) == ("plugins.disable", ["id": "hello2"]))
        // The key=value spelling keeps working.
        XCTAssertTrue(try parsed(["plugins.new", "id=hello2", "ui=true"]) == ("plugins.new", ["id": "hello2", "ui": "true"]))
        XCTAssertTrue(try CLI.parse(["plugin", "--help"]).wantsHelp)
    }

    func testPluginAliasesRejectBadInput() {
        XCTAssertThrowsError(try CLI.parse(["plugin"]))
        XCTAssertThrowsError(try CLI.parse(["plugin", "frobnicate", "x"]))
        XCTAssertThrowsError(try CLI.parse(["plugin", "build", "--ui", "x"]))
        XCTAssertThrowsError(try CLI.parse(["plugin", "new", "a", "b"]))
        XCTAssertThrowsError(try CLI.parse(["plugin", "list", "x"]))
        XCTAssertThrowsError(try CLI.parse(["daily.append", "--ui"]))
    }

    func testRunningACommandPrintsItsOutputAndWritesTheVault() async throws {
        let invocation = try CLI.parse(["daily.append", "text=Hello", "date=2026-05-06"])
        let result = await CLI.execute(invocation, kernel: kernel)
        XCTAssertEqual(result, CLIResult(exitCode: 0, stdout: "Daily/2026-05-06.md\n", stderr: ""))
        XCTAssertEqual(try kernel.vault.read("Daily/2026-05-06.md"), "Hello\n")
    }

    func testListShowsEveryRegisteredCommand() async throws {
        let result = await CLI.execute(try CLI.parse(["list"]), kernel: kernel)
        XCTAssertEqual(result.exitCode, 0)
        let ids = try JSONDecoder().decode([[String: String]].self, from: Data(result.stdout.utf8)).map { $0["id"] }
        XCTAssertEqual(ids, ["daily.append", "daily.ensure", "daily.list", "daily.path", "daily.prepend", "daily.read"])
    }

    func testListKeepsTheMatchingCommandsAndHasABriefForm() async throws {
        let matching = await CLI.execute(try CLI.parse(["list", "PREPEND"]), kernel: kernel)
        let ids = try JSONDecoder().decode([[String: String]].self, from: Data(matching.stdout.utf8)).map { $0["id"] }
        XCTAssertEqual(ids, ["daily.prepend"])
        let brief = await CLI.execute(try CLI.parse(["list", "--brief"]), kernel: kernel)
        XCTAssertEqual(brief.stdout.split(separator: "\n").count, 6)
        XCTAssertTrue(brief.stdout.hasPrefix("daily.append  "))
        XCTAssertThrowsError(try CLI.parse(["list", "--json"]))
    }

    func testPipedOutputIsCompactJSONAndTextStaysAsItIs() {
        let result = CLIResult(exitCode: 0, stdout: "{\n  \"a\" : [\n\n  ]\n}\n", stderr: "")
        XCTAssertEqual(CLI.compacted(result).stdout, "{\"a\":[]}\n")
        XCTAssertEqual(CLI.compactJSON("Daily/2026-05-06.md\n"), "Daily/2026-05-06.md\n")
        XCTAssertEqual(CLI.compactJSON("[not json\n"), "[not json\n")
    }

    func testErrorsGoToStderrAsJSONWithAnExitCode() async throws {
        let missing = await CLI.execute(try CLI.parse(["daily.append"]), kernel: kernel)
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertEqual(missing.stderr, "{\n  \"error\" : \"missing argument \\\"text\\\"\"\n}\n")
        XCTAssertEqual(missing.stdout, "")

        let unknown = await CLI.execute(try CLI.parse(["nope"]), kernel: kernel)
        XCTAssertEqual(unknown.exitCode, 2)
        XCTAssertTrue(unknown.stderr.contains("unknown command"))
    }

    func testHelpIsTheDefault() async throws {
        let result = await CLI.execute(try CLI.parse([]), kernel: kernel)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasPrefix("Usage: loam"))
    }

    func testARuntimeVaultRespectsItsConfig() async throws {
        try kernel.vault.write(ConfigStore.path, #"{ "plugins": { "daily-notes": { "enabled": false } } }"#)
        let runtime = try Runtime(rootURL: root, plugins: [DailyNotesPlugin.self])
        defer { runtime.close() }
        let result = await CLI.execute(try CLI.parse(["list"]), kernel: runtime.kernel)
        let ids = try JSONDecoder().decode([[String: String]].self, from: Data(result.stdout.utf8)).map { $0["id"] }
        XCTAssertEqual(ids, [
            "plugins.disable", "plugins.enable", "plugins.list", "plugins.set-setting", "plugins.settings",
            "tools.check", "tools.install", "tools.list",
        ])

        let enable = await CLI.execute(try CLI.parse(["plugins.enable", "id=daily-notes"]), kernel: runtime.kernel)
        XCTAssertEqual(enable.exitCode, 0, enable.stderr)
        XCTAssertNotNil(runtime.kernel.commands.command(id: "daily.append"))

        let unknown = await CLI.execute(try CLI.parse(["plugins.disable", "id=nope"]), kernel: runtime.kernel)
        XCTAssertEqual(unknown.exitCode, 1)
        XCTAssertTrue(unknown.stderr.contains("unknown plugin"), unknown.stderr)
    }

    func testActivationProblemsBecomeWarnings() {
        XCTAssertEqual(CLI.activationWarnings(ActivationReport(activated: ["a"])), "")
        let report = ActivationReport(skipped: ["b": "requires service 'x'"], failed: ["a": "Boom"])
        XCTAssertEqual(
            CLI.activationWarnings(report),
            "warning: plugin a did not start: Boom\nwarning: plugin b did not start: requires service 'x'\n"
        )
    }
}
