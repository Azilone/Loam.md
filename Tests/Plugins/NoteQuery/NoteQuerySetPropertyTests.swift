import XCTest
import NoteGraphPlugin
import PluginKit
import PluginKitTesting
@testable import NoteQueryPlugin

/// Setting one property rewrites only its line; everything else in the file stays byte-for-byte.
final class NoteQuerySetPropertyTests: XCTestCase {
    private func set(
        _ key: String, _ value: PropertyValue?, in text: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (String, NoteRecord?) {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, NoteQueryPlugin.self], files: ["n.md": text])
        let query = try XCTUnwrap(harness.kernel.services.service(.noteQuery), file: file, line: line)
        try query.setProperty(key, to: value, in: "n.md")
        return (try harness.vault.read("n.md"), query.run(NoteQuery()).first)
    }

    private let note = """
        ---
        # planning
        title: Plan
        status: todo   # was doing
        tags:
          - work
          - home
        due: 2026-10-20
        ---
        # Plan

        status: not frontmatter
        """

    func testReplacesAnExistingKeyKeepingItsComment() throws {
        let (text, record) = try set("status", .string("done"), in: note)
        XCTAssertEqual(text, note.replacingOccurrences(of: "status: todo   # was doing", with: "status: done   # was doing"))
        XCTAssertEqual(record?.properties["status"], .string("done"))
    }

    func testAppendsANewKeyBeforeTheClosingLine() throws {
        let (text, record) = try set("priority", .number(3), in: note)
        XCTAssertEqual(text, note.replacingOccurrences(of: "due: 2026-10-20\n", with: "due: 2026-10-20\npriority: 3\n"))
        XCTAssertEqual(record?.properties["priority"], .number(3))
    }

    func testCreatesFrontmatterWhenMissing() throws {
        let (text, record) = try set("status", .string("todo"), in: "# Hello\n\nBody.\n")
        XCTAssertEqual(text, "---\nstatus: todo\n---\n# Hello\n\nBody.\n")
        XCTAssertEqual(record?.properties["status"], .string("todo"))
        XCTAssertEqual(record?.title, "n")
    }

    func testRemovesAKey() throws {
        let (text, record) = try set("due", nil, in: note)
        XCTAssertEqual(text, note.replacingOccurrences(of: "due: 2026-10-20\n", with: ""))
        XCTAssertNil(record?.properties["due"])
    }

    func testRemovesABlockListWithItsItems() throws {
        let (text, record) = try set("tags", nil, in: note)
        XCTAssertEqual(text, note.replacingOccurrences(of: "tags:\n  - work\n  - home\n", with: ""))
        XCTAssertEqual(record?.tags, [])
        let unindented = "---\ntags:\n- a\n- b\nx: 1\n---\nBody\n"
        XCTAssertEqual(try set("tags", nil, in: unindented).0, "---\nx: 1\n---\nBody\n")
    }

    func testReplacesABlockListWithABlockList() throws {
        let (text, record) = try set("tags", .list([.string("a"), .string("b c")]), in: note)
        XCTAssertEqual(text, note.replacingOccurrences(of: "tags:\n  - work\n  - home\n", with: "tags:\n  - a\n  - b c\n"))
        XCTAssertEqual(record?.tags, ["a", "b c"])
    }

    func testAFlowListStaysAFlowList() throws {
        let (text, record) = try set("tags", .list([.string("a"), .string("b")]), in: "---\ntags: [x]\n---\nBody\n")
        XCTAssertEqual(text, "---\ntags: [a, b]\n---\nBody\n")
        XCTAssertEqual(record?.tags, ["a", "b"])
    }

    func testANewListIsABlockList() throws {
        let (text, record) = try set("labels", .list([.string("a"), .number(2)]), in: "---\nx: 1\n---\nBody\n")
        XCTAssertEqual(text, "---\nx: 1\nlabels:\n  - a\n  - 2\n---\nBody\n")
        XCTAssertEqual(record?.properties["labels"], .list([.string("a"), .number(2)]))
        XCTAssertEqual(try set("labels", .list([.string("a")]), in: "Body\n").0, "---\nlabels:\n  - a\n---\nBody\n")
    }

    func testFindsAKeyIgnoringCase() throws {
        let (text, record) = try set("status", .string("done"), in: "---\nStatus: todo # was\n---\nBody\n")
        XCTAssertEqual(text, "---\nStatus: done # was\n---\nBody\n")
        XCTAssertEqual(record?.properties["Status"], .string("done"))
        XCTAssertEqual(try set("status", .string("x"), in: "---\nStatus: a\nstatus: b\n---\n").0, "---\nStatus: a\nstatus: x\n---\n")
    }

    func testRemovingTheLastKeyRemovesTheFrontmatter() throws {
        XCTAssertEqual(try set("x", nil, in: "---\nx: 1\n---\n# Body\n").0, "# Body\n")
    }

    func testRemovingAMissingKeyChangesNothing() throws {
        XCTAssertEqual(try set("nothing", nil, in: note).0, note)
        XCTAssertEqual(try set("nothing", nil, in: "Body\n").0, "Body\n")
    }

    func testQuotesValuesThatWouldReadAsSomethingElse() throws {
        let cases: [(PropertyValue, String)] = [
            (.string("yes"), #""yes""#),
            (.string("42"), #""42""#),
            (.string("null"), #""null""#),
            (.string(" padded "), #"" padded ""#),
            (.string("a: b"), #""a: b""#),
            (.string("#hash"), "\"#hash\""),
            (.string("say \"hi\"\nnow"), #""say \"hi\"\nnow""#),
            (.string("2026-10-18 10:00:00"), #""2026-10-18 10:00:00""#),
            (.string(""), #""""#),
            (.string("2026-10-18"), "2026-10-18"),
            (.string("Plain words, fine"), "Plain words, fine"),
            (.number(2.5), "2.5"),
            (.bool(false), "false"),
            (.list([.string("x, y"), .list([.number(1)])]), #"["x, y", [1]]"#),
            (.map(["b": .string("two"), "a": .number(1)]), "{a: 1, b: two}"),
            (.list([]), "[]"),
        ]
        for (value, yaml) in cases {
            let (text, record) = try set("v", value, in: "---\nv: old\n---\n")
            XCTAssertEqual(text, "---\nv: \(yaml)\n---\n", "\(value)")
            XCTAssertEqual(record?.properties["v"], value, "read back \(value)")
        }
    }

    func testKeepsCRLFLineEndings() throws {
        let text = "---\r\na: 1\r\nb: 2\r\n---\r\nBody\r\n"
        let (edited, record) = try set("a", .number(5), in: text)
        XCTAssertEqual(edited, "---\r\na: 5\r\nb: 2\r\n---\r\nBody\r\n")
        XCTAssertEqual(record?.properties, ["a": .number(5), "b": .number(2)])
        XCTAssertEqual(try set("c", .number(3), in: text).0, "---\r\na: 1\r\nb: 2\r\nc: 3\r\n---\r\nBody\r\n")
        XCTAssertEqual(try set("a", nil, in: text).0, "---\r\nb: 2\r\n---\r\nBody\r\n")
    }

    func testMatchesQuotedKeysAndLeavesNestedKeysAlone() throws {
        let text = "---\nmeta:\n  status: inner\n\"status\": outer\n---\n"
        XCTAssertEqual(try set("status", .string("new"), in: text).0, "---\nmeta:\n  status: inner\n\"status\": new\n---\n")
    }

    func testRemovesAMultiLineBlockScalar() throws {
        let text = "---\nsummary: |\n  line one\n\n  line two\nnext: 1\n---\n"
        XCTAssertEqual(try set("summary", nil, in: text).0, "---\nnext: 1\n---\n")
    }

    func testInvalidPathsAndKeysThrow() throws {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, NoteQueryPlugin.self], files: ["n.md": "x"])
        let query = try XCTUnwrap(harness.kernel.services.service(.noteQuery))
        XCTAssertThrowsError(try query.setProperty("a", to: .number(1), in: "missing.md")) {
            XCTAssertEqual($0 as? VaultError, .notFound(path: "missing.md"))
        }
        XCTAssertThrowsError(try query.setProperty("a", to: .number(1), in: "../n.md")) {
            XCTAssertEqual($0 as? VaultError, .outsideVault(path: "../n.md"))
        }
        XCTAssertThrowsError(try query.setProperty("", to: .number(1), in: "n.md")) {
            XCTAssertEqual($0 as? NoteQueryError, .invalidKey(""))
        }
        XCTAssertEqual(try harness.vault.read("n.md"), "x")
    }
}
