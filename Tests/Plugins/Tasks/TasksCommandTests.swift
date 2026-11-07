import PluginKit
import PluginKitTesting
import LoamCore
import XCTest
@testable import TasksPlugin

/// The `tasks.*` commands, as the CLI and agents call them.
final class TasksCommandTests: XCTestCase {
    private func harness() throws -> PluginTestHarness {
        try PluginTestHarness([TasksPlugin.self], files: [
            "Work/Launch.md": "---\nproject: Launch\n---\n- [ ] Ship 📅 2026-10-20 #work\n- [x] Plan\n",
            "Inbox.md": "- [ ] Idea\n",
        ])
    }

    private func tasks(_ json: String) throws -> [TaskItem] {
        try JSONDecoder().decode([TaskItem].self, from: Data(json.utf8))
    }

    func testListWithArgumentsAndAJSONFilter() async throws {
        let harness = try harness()
        func list(_ arguments: [String: String] = [:]) async throws -> [TaskItem] {
            try tasks(try await harness.run("tasks.list", arguments))
        }
        var found = try await list()
        XCTAssertEqual(found.map(\.text), ["Ship #work", "Idea", "Plan"])
        found = try await list(["done": "false", "project": "launch"])
        XCTAssertEqual(found.map(\.text), ["Ship #work"])
        found = try await list(["tag": "work", "dueOn": "2026-10-20"])
        XCTAssertEqual(found.map(\.line), [4])
        found = try await list(["filter": try JSON.string(TaskFilter(done: true))])
        XCTAssertEqual(found.map(\.text), ["Plan"])
        found = try await list(["path": "Inbox.md", "text": "ide"])
        XCTAssertEqual(found.count, 1)
        // `today` is accepted for dates.
        _ = try await list(["dueBefore": "today"])
    }

    func testBadArgumentsThrow() async throws {
        let harness = try harness()
        let cases: [(String, [String: String], TasksError)] = [
            ("tasks.list", ["filter": "{"], .invalidArgument(name: "filter")),
            ("tasks.list", ["done": "maybe"], .invalidArgument(name: "done")),
            ("tasks.list", ["dueOn": "tomorrow"], .invalidDate("tomorrow")),
            ("tasks.toggle", ["path": "Inbox.md", "line": "one", "text": "Idea"], .invalidArgument(name: "line")),
            ("tasks.toggle", ["path": "Inbox.md", "line": "1", "text": "Other"], .lineChanged(path: "Inbox.md", line: 1)),
        ]
        for (command, arguments, expected) in cases {
            do {
                _ = try await harness.run(command, arguments)
                XCTFail("\(command) \(arguments) should throw")
            } catch {
                XCTAssertEqual(error as? TasksError, expected)
            }
        }
        do {
            _ = try await harness.run("tasks.add", ["path": "Inbox.md"])
            XCTFail("text is required")
        } catch {
            XCTAssertEqual(error as? CommandError, .missingArgument(name: "text"))
        }
    }

    func testToggleAndAddWriteAndAnnounceTheChange() async throws {
        let harness = try harness()
        var changed: [String] = []
        _ = harness.kernel.events.on(VaultChanged.self) { changed += $0.changes.map(\.path) }

        let toggled = try JSONDecoder().decode(TaskItem.self, from: Data(try await harness.run(
            "tasks.toggle", ["path": "Inbox.md", "line": "1", "text": "Idea"]
        ).utf8))
        XCTAssertTrue(toggled.done)
        XCTAssertTrue(try harness.vault.read("Inbox.md").hasPrefix("- [x] Idea ✅ "))

        let added = try JSONDecoder().decode(TaskItem.self, from: Data(try await harness.run(
            "tasks.add", ["path": "Inbox.md", "text": "Next !high"]
        ).utf8))
        XCTAssertEqual(added.line, 2)
        XCTAssertEqual(added.priority, .high)
        XCTAssertEqual(changed, ["Inbox.md", "Inbox.md"])
    }

    func testProvidesTheServiceAndUnloadsCleanly() throws {
        let harness = try harness()
        XCTAssertNotNil(harness.kernel.services.service(.tasks))
        XCTAssertEqual(Set(harness.kernel.commands.all.map(\.id)), ["tasks.list", "tasks.toggle", "tasks.add"])
        harness.host.deactivateAll()
        XCTAssertNil(harness.kernel.services.service(.tasks))
        XCTAssertEqual(harness.kernel.commands.all.map(\.id), [])
    }
}
