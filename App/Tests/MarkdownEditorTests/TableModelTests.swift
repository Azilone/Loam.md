import XCTest
@testable import MarkdownEditor

/// The table as data: read from GFM, written back as GFM, and changed by the operations the component offers.
final class TableModelTests: XCTestCase {
    private let source = "| Name | Price |\n| --- | :-: |\n| Bread | 2 |\n| Milk | 1 |"

    private func parse(_ text: String) throws -> TableData {
        try XCTUnwrap(TableData.parse(NSRange(location: 0, length: (text as NSString).length), in: text as NSString)).table
    }

    func testReadingAndWritingAGFMTable() throws {
        let table = try parse(source)
        XCTAssertEqual(table.rows, [["Name", "Price"], ["Bread", "2"], ["Milk", "1"]])
        XCTAssertEqual(table.alignments, [.none, .center])
        XCTAssertEqual(table.markdown(), "| Name | Price |\n| --- | :-: |\n| Bread | 2 |\n| Milk | 1 |")
    }

    func testAnyOtherToolReadsWhatIsWritten() throws {
        var table = try parse(source)
        table.paste([["a|b", "multi\nline"]], row: 1, column: 0)
        let markdown = table.markdown()
        XCTAssertEqual(markdown, "| Name | Price |\n| --- | :-: |\n| a\\|b | multi<br>line |\n| Milk | 1 |")
        XCTAssertEqual(try parse(markdown), table, "a pipe and a line break survive the round trip")
    }

    func testRowsAreAsWideAsTheHeaderAndTheSpacingIsNormalised() throws {
        let table = try parse("|a|b|c|\n|-|-|-|\n|1|\n| x | y | z | extra |")
        XCTAssertEqual(table.rows, [["a", "b", "c"], ["1", "", ""], ["x", "y", "z"]])
        XCTAssertEqual(table.markdown(), "| a | b | c |\n| --- | --- | --- |\n| 1 |  |  |\n| x | y | z |")
    }

    func testATableInsideAListKeepsItsIndent() throws {
        let table = try parse("  | a |\n  | - |\n  | 1 |")
        XCTAssertEqual(table.indent, "  ")
        XCTAssertEqual(table.markdown(), "  | a |\n  | --- |\n  | 1 |")
    }

    func testFindingTheTableAroundAnOffset() throws {
        let text = "Intro\n\n\(source)\n\nEnd"
        let ns = text as NSString
        let inside = ns.range(of: "Bread").location
        let (table, range) = try XCTUnwrap(TableData.at(inside, in: ns))
        XCTAssertEqual(table.rowCount, 3)
        XCTAssertEqual(ns.substring(with: range), source)
        XCTAssertNil(TableData.at(0, in: ns))
        XCTAssertNil(TableData.at(ns.range(of: "End").location, in: ns))
        XCTAssertNil(TableData.at(0, in: "| a | b |\nplain" as NSString), "no delimiter line, no table")
    }

    func testInsertingRowsAndColumns() throws {
        var table = try parse(source)
        table.insertRow(at: 2)
        XCTAssertEqual(table.rows[2], ["", ""])
        table.insertRow(at: 0)
        XCTAssertEqual(table.rows[1], ["", ""], "never above the header")
        table.insertColumn(at: 1)
        XCTAssertEqual(table.rows[0], ["Name", "", "Price"])
        XCTAssertEqual(table.alignments, [.none, .none, .center])
    }

    func testDeletingNeverLeavesNoHeaderOrNoColumn() throws {
        var table = try parse(source)
        XCTAssertFalse(table.deleteRows(0...0))
        XCTAssertTrue(table.deleteRows(1...2))
        XCTAssertEqual(table.rows, [["Name", "Price"]])
        XCTAssertTrue(table.deleteColumns(0...0))
        XCTAssertEqual(table.rows, [["Price"]])
        XCTAssertEqual(table.alignments, [.center])
        XCTAssertFalse(table.deleteColumns(0...0), "the last column stays")
    }

    func testDuplicatingAndMoving() throws {
        var table = try parse(source)
        table.duplicateRow(1)
        XCTAssertEqual(table.rows.map { $0[0] }, ["Name", "Bread", "Bread", "Milk"])
        table.moveRow(3, to: 1)
        XCTAssertEqual(table.rows.map { $0[0] }, ["Name", "Milk", "Bread", "Bread"])
        table.moveRow(0, to: 2)
        XCTAssertEqual(table.rows[0][0], "Name", "the header stays first")
        table.duplicateColumn(1)
        XCTAssertEqual(table.alignments, [.none, .center, .center])
        table.moveColumn(2, to: 0)
        XCTAssertEqual(table.rows[0], ["Price", "Name", "Price"])
        XCTAssertEqual(table.alignments, [.center, .none, .center])
    }

    func testClearingACell() throws {
        var table = try parse(source)
        table.clear(rows: 1...2, columns: 1...1)
        XCTAssertEqual(table.rows, [["Name", "Price"], ["Bread", ""], ["Milk", ""]])
    }

    func testPastingGrowsTheTable() throws {
        var table = try parse(source)
        let filled = table.paste([["a", "b", "c"], ["d", "e", "f"]], row: 2, column: 1)
        XCTAssertEqual(filled?.rows, 2...3)
        XCTAssertEqual(filled?.columns, 1...3)
        XCTAssertEqual(table.columnCount, 4)
        XCTAssertEqual(table.rows[3], ["", "d", "e", "f"])
        XCTAssertEqual(table.rows[2], ["Milk", "a", "b", "c"])
    }

    func testSpreadsheetTextBecomesCells() {
        XCTAssertEqual(TableData.grid(from: "a\tb\nc\td\n"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(TableData.grid(from: "\"x\ty\"\t\"say \"\"hi\"\"\"\n1\t2"), [["x\ty", "say \"hi\""], ["1", "2"]])
        XCTAssertNil(TableData.grid(from: "just text"))
        XCTAssertEqual(TableData.grid(from: "| a | b |\n| - | - |\n| 1 | 2 |"), [["a", "b"], ["1", "2"]], "a GFM table too")
    }

    func testCellsGoToASpreadsheetAsTabs() {
        XCTAssertEqual(TableData.tabSeparated([["a", "b"], ["c", "d"]]), "a\tb\nc\td")
        XCTAssertEqual(TableData.tabSeparated([["x\ty", "say \"hi\""]]), "\"x\ty\"\t\"say \"\"hi\"\"\"")
    }
}
