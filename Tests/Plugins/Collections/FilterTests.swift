import XCTest
import PluginKit
@testable import CollectionsPlugin

/// The subset of Obsidian's filter language Loam reads, and what it does with the rest.
final class FilterTests: XCTestCase {
    private let entry = FileFacts(
        path: "Projects/Sub/Alpha.md",
        tags: ["work", "project/home"],
        properties: ["status": .string("Doing"), "priority": .number(2), "owners": .list([.string("ann")]), "done": .bool(false)],
        modified: 10
    )
    private let host = FileFacts(path: "Projects/Board.md", tags: [], properties: ["kind": .string("board")], modified: 0)

    private func check(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Bool? {
        var evaluator = FilterEvaluator(entry: entry, host: host)
        return evaluator.matches(.expression(text))
    }

    func testParsesPrecedenceAndStrings() throws {
        XCTAssertEqual(try FilterExpression.parse("a || b && !c"),
                       .binary("||", .identifier("a"), .binary("&&", .identifier("b"), .unary("!", .identifier("c")))))
        XCTAssertEqual(try FilterExpression.parse(#"note["due date"] == 'it\'s'"#),
                       .binary("==", .index(.identifier("note"), .literal(.string("due date"))), .literal(.string("it's"))))
        XCTAssertEqual(try FilterExpression.parse("1 + 2 * 3 > 6"),
                       .binary(">", .binary("+", .literal(.number(1)), .binary("*", .literal(.number(2)), .literal(.number(3)))),
                               .literal(.number(6))))
        XCTAssertThrowsError(try FilterExpression.parse(#"file.inFolder("A"#))
        XCTAssertThrowsError(try FilterExpression.parse("a ==="))
    }

    func testFileFunctions() {
        XCTAssertEqual(check(#"file.inFolder("Projects")"#), true, "subfolders count")
        XCTAssertEqual(check(#"file.inFolder("Projects/")"#), true)
        XCTAssertEqual(check(#"file.inFolder("Proj")"#), false)
        XCTAssertEqual(check(#"file.hasTag("project")"#), true, "a nested tag counts for its parent")
        XCTAssertEqual(check(##"file.hasTag("#WORK")"##), true)
        XCTAssertEqual(check(#"file.hasTag("x", "work")"#), true, "any of the tags")
        XCTAssertEqual(check(#"file.hasProperty("priority")"#), true)
        XCTAssertEqual(check(#"file.hasProperty("nope")"#), false)
        XCTAssertEqual(check(#"file.ext == "md" && file.name == "Alpha.md" && file.basename == "Alpha""#), true)
        XCTAssertEqual(check(#"file.folder == "Projects/Sub""#), true)
        XCTAssertEqual(check(#"file.inFolder(this.file.folder)"#), true)
        XCTAssertEqual(check(#"file.path != this.file.path"#), true)
        XCTAssertEqual(check(#"this.kind == "board""#), true)
    }

    func testComparisons() {
        XCTAssertEqual(check(#"status == "doing""#), true, "strings ignore case")
        XCTAssertEqual(check(#"note.status != "done""#), true)
        XCTAssertEqual(check(#"missing != "done""#), true, "a missing value differs")
        XCTAssertEqual(check(#"missing == null"#), true)
        XCTAssertEqual(check("priority > 1 && priority <= 2"), true)
        XCTAssertEqual(check("priority >= 3 || done"), false)
        XCTAssertEqual(check("!done"), true)
        XCTAssertEqual(check(#"owners.contains("ANN")"#), true)
        XCTAssertEqual(check(#"status.contains("oin")"#), true)
        XCTAssertEqual(check(#"missing.contains("x")"#), false)
        XCTAssertEqual(check("missing.isEmpty()"), true)
        XCTAssertEqual(check("owners.length == 1"), true)
    }

    func testUnknownsShowTheEntry() {
        var evaluator = FilterEvaluator(entry: entry, host: host)
        XCTAssertNil(evaluator.matches(.expression(#"file.hasLink("Plan")"#)))
        XCTAssertNil(evaluator.matches(.expression("formula.cost > 2")))
        XCTAssertEqual(evaluator.matches(.expression(#"formula.cost > 2 && status == "nope""#)), false, "false wins in and")
        XCTAssertEqual(evaluator.matches(.expression(#"formula.cost > 2 || status == "doing""#)), true, "true wins in or")
        XCTAssertNil(evaluator.matches(.expression("now() > 3")))
        XCTAssertNil(evaluator.matches(.expression("((")))
        XCTAssertEqual(evaluator.unknowns.sorted(), ["cannot read the filter ((", "file.hasLink()", "formulas", "the function now()"])
    }

    func testTrees() {
        var evaluator = FilterEvaluator(entry: entry, host: host)
        XCTAssertEqual(evaluator.matches(.and([.expression("priority == 2"), .not([.expression("done")])])), true)
        XCTAssertEqual(evaluator.matches(.not([.expression("done"), .expression("priority == 2")])), false, "none may be true")
        XCTAssertEqual(evaluator.matches(.or([.expression("done"), .expression(#"file.hasLink("x")"#)])), nil)
        XCTAssertEqual(evaluator.matches(.and([])), true)
    }
}
