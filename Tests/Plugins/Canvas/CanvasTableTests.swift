import XCTest
@testable import CanvasPlugin

final class CanvasTableTests: XCTestCase {
    func testReadsAndWritesGFMTables() throws {
        let text = "| Idiom | Meaning |\n|:--|--:|\n| Break the ice | Start \\| talk |\n| Hit the road |\n"
        let table = try XCTUnwrap(CanvasTable(markdown: text))
        XCTAssertEqual(table.rows, [["Idiom", "Meaning"], ["Break the ice", "Start | talk"], ["Hit the road", ""]])
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.markdown, """
        | Idiom         | Meaning       |
        | :------------ | ------------: |
        | Break the ice | Start \\| talk |
        | Hit the road  |               |
        """)
        XCTAssertEqual(CanvasTable(markdown: table.markdown), table)
        XCTAssertTrue(CanvasTable.isTable(text))
        XCTAssertFalse(CanvasTable.isTable("| not a table"))
        XCTAssertFalse(CanvasTable.isTable("| A |\n|---|\n| 1 |\n\nAnd text after"), "a table and nothing else")
        XCTAssertFalse(CanvasTable.isTable("# Title"))
    }

    func testEditsKeepTheTableWhole() {
        var table = CanvasTable.empty(columns: 2, rows: 1)
        XCTAssertEqual(table.rows, [["Column 1", "Column 2"], ["", ""]])
        table[1, 1] = "x"
        table.insertRow()
        table.insertColumn(at: 1)
        XCTAssertEqual(table.rows, [["Column 1", "Column 3", "Column 2"], ["", "", "x"], ["", "", ""]])
        table.removeRow(0)
        XCTAssertEqual(table.rowCount, 3, "the header stays")
        table.removeRow(2)
        table.removeRow(1)
        XCTAssertEqual(table.rowCount, 2, "one row under the header stays")
        table.removeColumn(0)
        table.removeColumn(0)
        table.removeColumn(0)
        XCTAssertEqual(table.columnCount, 1)
        XCTAssertEqual(table.alignments.count, 1)
    }

    func testATableCardIsNotFreeText() {
        var node = CanvasNode(id: "t", kind: .text, x: 0, y: 0, width: 10, height: 10, text: CanvasTable.empty().markdown)
        node.border = .invisible
        XCTAssertTrue(node.isTable)
        XCTAssertFalse(node.isFreeText)
    }
}
