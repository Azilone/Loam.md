import Foundation

/// A table on the board: a text card whose Markdown is one GFM table and nothing else, so any Markdown reader shows
/// it as a table. The first row is the header. Cells are inline Markdown; a `|` in one is written `\|`.
public struct CanvasTable: Equatable, Sendable {
    public enum Alignment: String, Sendable {
        case none, left, center, right
    }

    /// The rows, the header first; every row has `columnCount` cells.
    public var rows: [[String]]
    public var alignments: [Alignment]

    public init(rows: [[String]], alignments: [Alignment]? = nil) {
        let width = max(1, rows.map(\.count).max() ?? 1)
        self.rows = (rows.isEmpty ? [[""]] : rows).map { $0 + Array(repeating: "", count: width - $0.count) }
        self.alignments = (alignments ?? []).prefix(width) + Array(repeating: .none, count: max(0, width - (alignments?.count ?? 0)))
    }

    /// An empty table with a header of "Column 1"… and `rows` empty rows under it.
    public static func empty(columns: Int = 3, rows: Int = 2) -> CanvasTable {
        CanvasTable(rows: [(1...columns).map { "Column \($0)" }]
            + Array(repeating: Array(repeating: "", count: columns), count: rows))
    }

    public var columnCount: Int { rows.first?.count ?? 0 }
    public var rowCount: Int { rows.count }

    // MARK: Reading and writing

    /// Whether a text card's text is a table and only that, without parsing it all.
    public static func isTable(_ text: String?) -> Bool {
        guard let text, text.hasPrefix("|") else { return false }
        return CanvasTable(markdown: text) != nil
    }

    /// The table a text is; nil unless the text is one GFM table (a header, a delimiter row, rows) and nothing else.
    public init?(markdown: String) {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var trimmed = lines[...]
        while trimmed.last?.isEmpty == true { trimmed.removeLast() }
        guard trimmed.count >= 2, trimmed.allSatisfy({ $0.hasPrefix("|") }) else { return nil }
        let delimiter = Self.cells(trimmed[trimmed.startIndex + 1])
        guard !delimiter.isEmpty,
              delimiter.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ":-".contains($0) } && $0.contains("-") }) else {
            return nil
        }
        let alignments: [Alignment] = delimiter.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            case (false, false): return .none
            }
        }
        let rows = [Self.cells(trimmed[trimmed.startIndex])] + trimmed.dropFirst(2).map(Self.cells)
        self.init(rows: rows.map { Array($0.prefix(alignments.count)) }, alignments: alignments)
    }

    /// The cells of one table line, unescaped.
    static func cells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The table as GFM, its columns padded to line up, as people write tables by hand.
    public var markdown: String {
        let escaped = rows.map { $0.map { Self.escape($0) } }
        let widths = (0..<columnCount).map { column in max(3, escaped.map { $0[column].count }.max() ?? 3) }
        func line(_ cells: [String]) -> String {
            "| " + cells.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                .joined(separator: " | ") + " |"
        }
        let delimiter = "| " + alignments.enumerated().map { column, alignment -> String in
            let dashes = String(repeating: "-", count: max(1, widths[column] - (alignment == .center ? 2 : alignment == .none ? 0 : 1)))
            switch alignment {
            case .none: return dashes
            case .left: return ":" + dashes
            case .right: return dashes + ":"
            case .center: return ":" + dashes + ":"
            }
        }.joined(separator: " | ") + " |"
        return ([line(escaped[0]), delimiter] + escaped.dropFirst().map(line)).joined(separator: "\n")
    }

    private static func escape(_ cell: String) -> String {
        cell.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
    }

    // MARK: Editing

    public subscript(row: Int, column: Int) -> String {
        get { rows.indices.contains(row) && (0..<columnCount).contains(column) ? rows[row][column] : "" }
        set {
            guard rows.indices.contains(row), (0..<columnCount).contains(column) else { return }
            rows[row][column] = newValue
        }
    }

    /// Adds an empty row at `index` (the end when nil), never above the header.
    public mutating func insertRow(at index: Int? = nil) {
        rows.insert(Array(repeating: "", count: columnCount), at: min(max(index ?? rows.count, 1), rows.count))
    }

    public mutating func insertColumn(at index: Int? = nil) {
        let at = min(max(index ?? columnCount, 0), columnCount)
        for row in rows.indices { rows[row].insert(row == 0 ? "Column \(columnCount + 1)" : "", at: at) }
        alignments.insert(.none, at: at)
    }

    /// Removes a row; the header and the last row stay.
    public mutating func removeRow(_ index: Int) {
        guard index > 0, rows.indices.contains(index), rows.count > 2 else { return }
        rows.remove(at: index)
    }

    /// Removes a column; the last one stays.
    public mutating func removeColumn(_ index: Int) {
        guard (0..<columnCount).contains(index), columnCount > 1 else { return }
        for row in rows.indices { rows[row].remove(at: index) }
        alignments.remove(at: index)
    }
}

extension CanvasNode {
    /// A text card holding a table and nothing else.
    public var isTable: Bool { kind == .text && CanvasTable.isTable(text) }

    public var table: CanvasTable? { kind == .text ? text.flatMap(CanvasTable.init(markdown:)) : nil }
}
