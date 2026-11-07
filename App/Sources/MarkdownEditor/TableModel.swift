import Foundation

public enum TableAlignment: Equatable, Sendable {
    case none, left, center, right

    var delimiter: String {
        switch self {
        case .none: "---"
        case .left: ":--"
        case .center: ":-:"
        case .right: "--:"
        }
    }

    init(delimiter cell: String) {
        let cell = cell.trimmingCharacters(in: .whitespaces)
        switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
        case (true, true): self = .center
        case (true, false): self = .left
        case (false, true): self = .right
        default: self = .none
        }
    }
}

/// A GFM table row: its line and where its cells start and end.
struct TableRow: Equatable {
    /// The line, without its break.
    let line: NSRange
    /// The offsets of the `|` that bound the cells, plus the line's ends when the row has no outer pipes. Cell `i`
    /// lies between `bounds[i]` and `bounds[i + 1]`, both excluded.
    let bounds: [Int]

    var cellCount: Int { max(0, bounds.count - 1) }

    func cell(_ index: Int) -> NSRange {
        NSRange(location: bounds[index] + 1, length: bounds[index + 1] - bounds[index] - 1)
    }

    /// The row at `location`, when that line is a table row: it starts with `|` (after spaces) and has another.
    static func at(_ location: Int, in ns: NSString) -> TableRow? {
        let line = ns.lineWithoutBreak(at: location)
        return parse(line, in: ns)
    }

    static func parse(_ line: NSRange, in ns: NSString) -> TableRow? {
        let text = ns.substring(with: line)
        guard text.trimmingCharacters(in: .whitespaces).hasPrefix("|") else { return nil }
        var pipes: [Int] = []
        for offset in line.location..<NSMaxRange(line) where ns.character(at: offset) == 124 {
            if offset > line.location, ns.character(at: offset - 1) == 92 { continue }  // `\|` is text
            pipes.append(offset)
        }
        guard pipes.count >= 2 else { return nil }
        let trailing = text.trimmingCharacters(in: .whitespaces).hasSuffix("|")
        return TableRow(line: line, bounds: trailing ? pipes : pipes + [NSMaxRange(line)])
    }

    /// The `| --- | :-: |` line under the header.
    func isDelimiter(in ns: NSString) -> Bool {
        (0..<cellCount).allSatisfy { index in
            let cell = ns.substring(with: cell(index)).trimmingCharacters(in: .whitespaces)
            return !cell.isEmpty && cell.allSatisfy { "-:".contains($0) }
        }
    }
}

/// A GFM table as the editor's table component edits it: the cells' text (what the user sees and types, with `\|`
/// and `<br>` already decoded), the column alignments, and nothing of the Markdown syntax. `markdown()` writes it
/// back as `| a | b |` plus a `| --- | --- |` line, which any Markdown tool reads.
struct TableData: Equatable {
    /// The rows of cells; row 0 is the header. Every row has `columnCount` cells.
    var rows: [[String]]
    var alignments: [TableAlignment]
    /// The spaces before the table's first pipe, kept so a table in a list item stays there.
    var indent = ""

    var rowCount: Int { rows.count }
    var columnCount: Int { alignments.count }

    init(rows: [[String]], alignments: [TableAlignment]? = nil, indent: String = "") {
        let width = max(1, rows.map(\.count).max() ?? 1, alignments?.count ?? 0)
        var rows = rows.isEmpty ? [[]] : rows
        for index in rows.indices {
            rows[index] = Array((rows[index] + Array(repeating: "", count: max(0, width - rows[index].count))).prefix(width))
        }
        self.rows = rows
        let given = alignments ?? []
        self.alignments = Array((given + Array(repeating: .none, count: max(0, width - given.count))).prefix(width))
        self.indent = indent
    }

    /// An empty table of `rows` rows (the header included) by `columns` columns.
    static func empty(rows: Int, columns: Int) -> TableData {
        TableData(rows: Array(repeating: Array(repeating: "", count: columns), count: max(1, rows)))
    }

    // MARK: Reading

    /// The table whose lines hold `location`, with the range of those lines (without the last line break); nil when
    /// `location` is not in a table that has a delimiter line under its header.
    static func at(_ location: Int, in ns: NSString) -> (table: TableData, range: NSRange)? {
        guard location >= 0, location <= ns.length, TableRow.at(location, in: ns) != nil else { return nil }
        var first = ns.lineWithoutBreak(at: location)
        while first.location > 0, TableRow.at(first.location - 1, in: ns) != nil {
            first = ns.lineWithoutBreak(at: first.location - 1)
        }
        var last = ns.lineWithoutBreak(at: location)
        while NSMaxRange(last) < ns.length, TableRow.at(NSMaxRange(last) + 1, in: ns) != nil {
            last = ns.lineWithoutBreak(at: NSMaxRange(last) + 1)
        }
        return parse(NSRange(location: first.location, length: NSMaxRange(last) - first.location), in: ns)
    }

    /// The table written in `range` (whole lines).
    static func parse(_ range: NSRange, in ns: NSString) -> (table: TableData, range: NSRange)? {
        var rows: [TableRow] = []
        var line = ns.lineWithoutBreak(at: range.location)
        while true {
            guard let row = TableRow.parse(line, in: ns) else { return nil }
            rows.append(row)
            if NSMaxRange(line) >= NSMaxRange(range) { break }
            line = ns.lineWithoutBreak(at: NSMaxRange(line) + 1)
        }
        guard rows.count >= 2, rows[1].isDelimiter(in: ns) else { return nil }
        func cells(_ row: TableRow) -> [String] {
            (0..<row.cellCount).map { decode(ns.substring(with: row.cell($0)).trimmingCharacters(in: .whitespaces)) }
        }
        let width = rows[0].cellCount
        let alignments = (0..<rows[1].cellCount).map {
            TableAlignment(delimiter: ns.substring(with: rows[1].cell($0)))
        }
        let indent = ns.substring(with: NSRange(location: rows[0].line.location, length: rows[0].bounds[0] - rows[0].line.location))
        // Every row as wide as the header, as GFM reads it.
        let body = ([cells(rows[0])] + rows.dropFirst(2).map(cells)).map {
            Array(($0 + Array(repeating: "", count: max(0, width - $0.count))).prefix(width))
        }
        let table = TableData(rows: body, alignments: Array(alignments.prefix(width)), indent: indent)
        return (table, NSRange(location: rows[0].line.location, length: NSMaxRange(rows[rows.count - 1].line) - rows[0].line.location))
    }

    /// A cell as typed: `\|` is a pipe, `<br>` a line break.
    static func decode(_ cell: String) -> String {
        cell.replacingOccurrences(of: "\\|", with: "|")
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
    }

    /// A cell as written in a Markdown row.
    static func encode(_ cell: String) -> String {
        var text = ""
        var previous: Character?
        for character in cell {
            if character == "|", previous != "\\" { text += "\\|" } else { text.append(character) }
            previous = character
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Writing

    /// The table as Markdown: one space inside each pipe, no padding, `---` for the delimiter cells.
    func markdown() -> String {
        func line(_ cells: [String]) -> String {
            indent + "|" + cells.map { $0.isEmpty ? "  |" : " \($0) |" }.joined()
        }
        var lines = [line(rows[0].map(Self.encode))]
        lines.append(line(alignments.map(\.delimiter)))
        for row in rows.dropFirst() { lines.append(line(row.map(Self.encode))) }
        return lines.joined(separator: "\n")
    }

    // MARK: Editing

    /// Inserts an empty row so it ends up at `index` (1 or more: the header stays first).
    mutating func insertRow(at index: Int) {
        rows.insert(Array(repeating: "", count: columnCount), at: min(max(1, index), rows.count))
    }

    mutating func insertColumn(at index: Int) {
        let index = min(max(0, index), columnCount)
        for row in rows.indices { rows[row].insert("", at: index) }
        alignments.insert(.none, at: index)
    }

    /// Deletes body rows (the header cannot go); false when nothing was deleted.
    @discardableResult
    mutating func deleteRows(_ indexes: ClosedRange<Int>) -> Bool {
        guard indexes.lowerBound >= 1, indexes.upperBound < rows.count else { return false }
        rows.removeSubrange(indexes)
        return true
    }

    /// Deletes columns, never the last one.
    @discardableResult
    mutating func deleteColumns(_ indexes: ClosedRange<Int>) -> Bool {
        let doomed = indexes.clamped(to: 0...(columnCount - 1))
        guard doomed.count < columnCount else { return false }
        for row in rows.indices { rows[row].removeSubrange(doomed) }
        alignments.removeSubrange(doomed)
        return true
    }

    /// Copies a body row under itself.
    mutating func duplicateRow(_ index: Int) {
        guard index >= 1, index < rows.count else { return }
        rows.insert(rows[index], at: index + 1)
    }

    mutating func duplicateColumn(_ index: Int) {
        guard index >= 0, index < columnCount else { return }
        for row in rows.indices { rows[row].insert(rows[row][index], at: index + 1) }
        alignments.insert(alignments[index], at: index + 1)
    }

    /// Moves a body row so it ends up at `destination` (a body row index).
    mutating func moveRow(_ index: Int, to destination: Int) {
        guard index >= 1, index < rows.count else { return }
        let row = rows.remove(at: index)
        rows.insert(row, at: min(max(1, destination), rows.count))
    }

    mutating func moveColumn(_ index: Int, to destination: Int) {
        guard index >= 0, index < columnCount else { return }
        let target = min(max(0, destination), columnCount - 1)
        for row in rows.indices {
            let cell = rows[row].remove(at: index)
            rows[row].insert(cell, at: target)
        }
        alignments.insert(alignments.remove(at: index), at: target)
    }

    /// Empties the cells in a block of rows and columns.
    mutating func clear(rows range: ClosedRange<Int>, columns: ClosedRange<Int>) {
        for row in range where row < rows.count {
            for column in columns where column < columnCount { rows[row][column] = "" }
        }
    }

    /// Writes a block of text (what a spreadsheet copies: tab-separated columns, a line per row) with its top left
    /// cell at `row`, `column`, adding the rows and columns it needs. Returns the cells it filled.
    @discardableResult
    mutating func paste(_ grid: [[String]], row: Int, column: Int) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        guard let width = grid.map(\.count).max(), width > 0, row >= 0, column >= 0 else { return nil }
        while rows.count < row + grid.count { insertRow(at: rows.count) }
        while columnCount < column + width { insertColumn(at: columnCount) }
        for (r, cells) in grid.enumerated() {
            for (c, cell) in cells.enumerated() { rows[row + r][column + c] = cell }
        }
        return (row...(row + grid.count - 1), column...(column + width - 1))
    }

    // MARK: Clipboard

    /// The cells as a spreadsheet takes them: tab between cells, a line break between rows. A cell with a tab,
    /// a line break or a quote is quoted, as spreadsheets do.
    static func tabSeparated(_ grid: [[String]]) -> String {
        grid.map { row in
            row.map { cell in
                guard cell.contains(where: { "\t\n\"".contains($0) }) else { return cell }
                return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// Cells from tab-separated text (quotes undone), or from a GFM table; nil for plain text with neither.
    static func grid(from text: String) -> [[String]]? {
        let trimmed = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }
        let ns = trimmed as NSString
        if let (table, range) = parse(NSRange(location: 0, length: ns.length), in: ns), range.length == ns.length {
            return table.rows
        }
        guard trimmed.contains("\t") || trimmed.contains("\n") else { return nil }
        var grid: [[String]] = [[]]
        var cell = ""
        var quoted = false
        var iterator = trimmed.makeIterator()
        var pending = iterator.next()
        var atCellStart = true
        while let character = pending {
            pending = iterator.next()
            if quoted {
                if character == "\"" {
                    if pending == "\"" { cell.append("\""); pending = iterator.next() } else { quoted = false }
                } else {
                    cell.append(character)
                }
                continue
            }
            switch character {
            case "\"" where atCellStart:
                quoted = true
            case "\t":
                grid[grid.count - 1].append(cell)
                cell = ""
                atCellStart = true
                continue
            case "\n":
                grid[grid.count - 1].append(cell)
                grid.append([])
                cell = ""
                atCellStart = true
                continue
            default:
                cell.append(character)
            }
            atCellStart = false
        }
        grid[grid.count - 1].append(cell)
        return grid
    }
}
