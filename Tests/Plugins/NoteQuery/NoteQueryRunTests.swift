import XCTest
import NoteGraphPlugin
import PluginKit
import PluginKitTesting
@testable import NoteQueryPlugin

/// Finding notes: folder, tags, each filter operator, sorting, limit, and distinct values.
final class NoteQueryRunTests: XCTestCase {
    private let files = [
        "Projects/alpha.md": "---\nstatus: doing\npriority: 2\ndue: 2026-10-20\ntags: [work, project/home]\n---\n# Alpha\n",
        "Projects/beta.md": "---\nstatus: Done\npriority: 10\ndue: 2026-09-01\ntags: [work]\nowners: [ann, bob]\n---\n# Beta\n",
        "Projects/Sub/gamma.md": "---\nstatus: todo\npriority: 1\nflag: true\n---\n# Gamma\n\n#work\n",
        "Inbox/delta.md": "---\nstatus: todo\nnote: Call the plumber\n---\n# Delta\n",
        "epsilon.md": "# Epsilon\n",
        "Projects2/zeta.md": "# Zeta\n",
    ]

    /// Kept for the test's duration: the plugins unload when the harness goes away.
    private var harness: PluginTestHarness?

    private func service() throws -> (PluginTestHarness, NoteQueryService) {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, NoteQueryPlugin.self], files: files)
        self.harness = harness
        return (harness, try XCTUnwrap(harness.kernel.services.service(.noteQuery)))
    }

    private func paths(_ query: NoteQuery, _ service: NoteQueryService) -> [String] {
        service.run(query).map(\.path)
    }

    func testDefaultIsEveryNoteByTitle() throws {
        let (_, query) = try service()
        XCTAssertEqual(query.run(NoteQuery()).map(\.title), ["alpha", "beta", "delta", "epsilon", "gamma", "zeta"])
    }

    func testFolderIsRecursiveAndExact() throws {
        let (_, query) = try service()
        XCTAssertEqual(paths(NoteQuery(folder: "Projects"), query),
                       ["Projects/alpha.md", "Projects/beta.md", "Projects/Sub/gamma.md"])
        XCTAssertEqual(paths(NoteQuery(folder: "Projects/Sub/"), query), ["Projects/Sub/gamma.md"])
        XCTAssertEqual(paths(NoteQuery(folder: ""), query).count, 6)
    }

    func testTagsAllMatchIgnoringCaseHashAndNesting() throws {
        let (_, query) = try service()
        XCTAssertEqual(paths(NoteQuery(tags: ["#WORK"]), query),
                       ["Projects/alpha.md", "Projects/beta.md", "Projects/Sub/gamma.md"])
        XCTAssertEqual(paths(NoteQuery(tags: ["work", "project"]), query), ["Projects/alpha.md"])
        XCTAssertEqual(paths(NoteQuery(tags: ["proj"]), query), [])
    }

    func testEachOperator() throws {
        let (_, query) = try service()
        func run(_ key: String, _ op: PropertyFilter.Op, _ value: PropertyValue? = nil) -> [String] {
            // Strings sort ignoring case, paths included.
            paths(NoteQuery(filters: [PropertyFilter(key: key, op: op, value: value)], sort: [SortKey(key: "path")]), query)
        }
        XCTAssertEqual(run("owners", .exists), ["Projects/beta.md"])
        XCTAssertEqual(run("priority", .missing), ["epsilon.md", "Inbox/delta.md", "Projects2/zeta.md"])
        XCTAssertEqual(run("status", .equals, .string("done")), ["Projects/beta.md"])
        XCTAssertEqual(run("Status", .equals, .string("TODO")), ["Inbox/delta.md", "Projects/Sub/gamma.md"])
        XCTAssertEqual(run("priority", .equals, .number(2)), ["Projects/alpha.md"])
        XCTAssertEqual(run("priority", .equals, .string("2")), ["Projects/alpha.md"])
        XCTAssertEqual(run("flag", .equals, .bool(true)), ["Projects/Sub/gamma.md"])
        XCTAssertEqual(run("status", .notEquals, .string("todo")),
                       ["epsilon.md", "Projects/alpha.md", "Projects/beta.md", "Projects2/zeta.md"])
        XCTAssertEqual(run("owners", .contains, .string("BOB")), ["Projects/beta.md"])
        XCTAssertEqual(run("note", .contains, .string("plumb")), ["Inbox/delta.md"])
        XCTAssertEqual(run("priority", .lessThan, .number(3)), ["Projects/alpha.md", "Projects/Sub/gamma.md"])
        XCTAssertEqual(run("priority", .greaterThan, .number(2)), ["Projects/beta.md"])
        XCTAssertEqual(run("due", .lessThan, .string("2026-10-01")), ["Projects/beta.md"])
        XCTAssertEqual(run("due", .greaterThan, .string("2026-10-01")), ["Projects/alpha.md"])
    }

    func testFiltersAllMatch() throws {
        let (_, query) = try service()
        let found = paths(NoteQuery(filters: [
            PropertyFilter(key: "status", op: .equals, value: .string("todo")),
            PropertyFilter(key: "priority", op: .exists),
        ]), query)
        XCTAssertEqual(found, ["Projects/Sub/gamma.md"])
    }

    func testSortKeysInOrderWithMissingLastAndStableTies() throws {
        let (_, query) = try service()
        // status: Done, doing, todo, todo; ties on status by priority descending; no status last, by path.
        let found = paths(NoteQuery(sort: [SortKey(key: "status"), SortKey(key: "priority", descending: true)]), query)
        XCTAssertEqual(found, [
            "Projects/alpha.md", "Projects/beta.md", "Projects/Sub/gamma.md", "Inbox/delta.md",
            "Projects2/zeta.md", "epsilon.md",
        ])
        let descending = paths(NoteQuery(sort: [SortKey(key: "priority", descending: true)]), query)
        XCTAssertEqual(descending, [
            "Projects/beta.md", "Projects/alpha.md", "Projects/Sub/gamma.md",
            "Inbox/delta.md", "Projects2/zeta.md", "epsilon.md",
        ])
    }

    func testModifiedAndLimit() throws {
        let (harness, query) = try service()
        let old = Date(timeIntervalSince1970: 1_000_000)
        for path in files.keys where path != "epsilon.md" {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: harness.vault.url(path).path)
        }
        let newest = query.run(NoteQuery(sort: [SortKey(key: "modified", descending: true)], limit: 1))
        XCTAssertEqual(newest.map(\.path), ["epsilon.md"])
        XCTAssertGreaterThan(newest[0].modified, 1_000_000)
        XCTAssertEqual(query.run(NoteQuery(limit: 2)).map(\.title), ["alpha", "beta"])
        XCTAssertEqual(query.run(NoteQuery(limit: 0)), [])
    }

    func testValuesAreDistinctSortedAndFlattened() throws {
        let (_, query) = try service()
        XCTAssertEqual(query.values(of: "status", in: NoteQuery()), [.string("doing"), .string("Done"), .string("todo")])
        XCTAssertEqual(query.values(of: "priority", in: NoteQuery()), [.number(1), .number(2), .number(10)])
        XCTAssertEqual(query.values(of: "owners", in: NoteQuery()), [.string("ann"), .string("bob")])
        XCTAssertEqual(query.values(of: "status", in: NoteQuery(folder: "Inbox")), [.string("todo")])
        XCTAssertEqual(query.values(of: "nothing", in: NoteQuery()), [])
    }

    func testQueryDecodesFromPartialJSON() throws {
        let json = #"{"tags":["work"],"filters":[{"key":"status","op":"exists"}],"sort":[{"key":"title"}]}"#
        let query = try JSONDecoder().decode(NoteQuery.self, from: Data(json.utf8))
        XCTAssertEqual(query, NoteQuery(
            tags: ["work"], filters: [PropertyFilter(key: "status", op: .exists)], sort: [SortKey(key: "title")]
        ))
        XCTAssertEqual(try JSONDecoder().decode(NoteQuery.self, from: Data("{}".utf8)), NoteQuery())
    }

    func testModifiedTimesAreReadOncePerChange() throws {
        let (harness, query) = try service()
        try harness.kernel.refreshVault()
        let before = try XCTUnwrap(query.run(NoteQuery()).first { $0.path == "epsilon.md" }).modified
        let url = harness.vault.rootURL.appendingPathComponent("epsilon.md")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: before + 100)], ofItemAtPath: url.path)
        XCTAssertEqual(query.run(NoteQuery()).first { $0.path == "epsilon.md" }?.modified, before, "cached until a change")
        try harness.kernel.refreshVault()
        let after = try XCTUnwrap(query.run(NoteQuery()).first { $0.path == "epsilon.md" }).modified
        XCTAssertEqual(after, before + 100, accuracy: 0.01)
    }
}
