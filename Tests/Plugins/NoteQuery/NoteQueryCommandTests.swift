import XCTest
import NoteGraphPlugin
import PluginKit
import PluginKitTesting
@testable import NoteQueryPlugin

/// The `query.*` commands, as the CLI and agents call them.
final class NoteQueryCommandTests: XCTestCase {
    private func harness() throws -> PluginTestHarness {
        try PluginTestHarness([NoteGraphPlugin.self, NoteQueryPlugin.self], files: [
            "A/one.md": "---\nstatus: todo\npriority: 2\n---\n# One\n\n#work\n",
            "A/two.md": "---\nstatus: done\npriority: 1\n---\n# Two\n\n#work\n",
            "three.md": "---\nstatus: todo\n---\n# Three\n",
        ])
    }

    private func records(_ json: String) throws -> [NoteRecord] {
        try JSONDecoder().decode([NoteRecord].self, from: Data(json.utf8))
    }

    func testRunWithAJSONQuery() async throws {
        let harness = try harness()
        let query = NoteQuery(filters: [PropertyFilter(key: "status", op: .equals, value: .string("todo"))],
                              sort: [SortKey(key: "title", descending: true)])
        let output = try await harness.run("query.run", ["query": try JSON.string(query)])
        XCTAssertEqual(try records(output).map(\.title), ["three", "one"])
        XCTAssertEqual(try records(output).first?.properties["status"], .string("todo"))
    }

    func testRunWithSimpleArguments() async throws {
        let harness = try harness()
        let output = try await harness.run("query.run", [
            "folder": "A", "tag": "work", "where": #"[{"key":"priority","op":"greaterThan","value":0}]"#,
            "sort": "-priority", "limit": "1",
        ])
        XCTAssertEqual(try records(output).map(\.path), ["A/one.md"])
        let all = try await harness.run("query.run")
        XCTAssertEqual(try records(all).count, 3)
    }

    func testBadArgumentsThrow() async throws {
        let harness = try harness()
        for (name, value) in [("query", "{"), ("where", #"[{"key":"a","op":"near"}]"#), ("limit", "many")] {
            do {
                _ = try await harness.run("query.run", [name: value])
                XCTFail("\(name) should throw")
            } catch {
                XCTAssertEqual(error as? NoteQueryError, .invalidArgument(name: name))
            }
        }
    }

    func testValues() async throws {
        let harness = try harness()
        let output = try await harness.run("query.values", ["key": "status"])
        XCTAssertEqual(try JSONDecoder().decode([PropertyValue].self, from: Data(output.utf8)), [.string("done"), .string("todo")])
        let scoped = try await harness.run("query.values", ["key": "status", "folder": "A", "tag": "work"])
        XCTAssertEqual(scoped, try JSON.string([PropertyValue.string("done"), .string("todo")]))
    }

    func testSetPropertyWritesAndReturnsTheRecord() async throws {
        let harness = try harness()
        let output = try await harness.run("query.set-property", ["path": "three.md", "key": "status", "value": "doing"])
        let record = try JSONDecoder().decode(NoteRecord.self, from: Data(output.utf8))
        XCTAssertEqual(record.properties["status"], .string("doing"))
        XCTAssertEqual(try harness.vault.read("three.md"), "---\nstatus: doing\n---\n# Three\n")

        _ = try await harness.run("query.set-property", ["path": "three.md", "key": "priority", "value": "3"])
        _ = try await harness.run("query.set-property", ["path": "three.md", "key": "labels", "value": #"["a","b"]"#])
        XCTAssertEqual(try harness.vault.read("three.md"), "---\nstatus: doing\npriority: 3\nlabels:\n  - a\n  - b\n---\n# Three\n")

        _ = try await harness.run("query.set-property", ["path": "three.md", "key": "labels", "value": ""])
        _ = try await harness.run("query.set-property", ["path": "three.md", "key": "priority"])
        XCTAssertEqual(try harness.vault.read("three.md"), "---\nstatus: doing\n---\n# Three\n")

        let found = try await harness.run("query.run", ["where": #"[{"key":"status","op":"equals","value":"doing"}]"#])
        XCTAssertEqual(try records(found).map(\.path), ["three.md"])
    }

    func testSetPropertySummarySaysItWrites() throws {
        let harness = try harness()
        XCTAssertTrue(try XCTUnwrap(harness.kernel.commands.command(id: "query.set-property")).summary.contains("Writes to the vault"))
    }

    func testUnloadingRemovesTheServiceAndCommands() throws {
        let harness = try harness()
        harness.host.deactivateAll()
        XCTAssertNil(harness.kernel.services.service(.noteQuery))
        XCTAssertNil(harness.kernel.commands.command(id: "query.run"))
    }
}
