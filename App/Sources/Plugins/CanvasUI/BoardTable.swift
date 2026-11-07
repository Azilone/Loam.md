import AppKit
import CanvasPlugin
import PluginKitUI
import SwiftUI

/// Where a table's cells are, in board units: each column as wide as its widest cell (wrapping past a limit), each
/// row as tall as its tallest cell. The card is the table's size; clicks find their cell through it.
struct BoardTableLayout: Equatable {
    let columns: [CGFloat]
    let rows: [CGFloat]

    var size: CGSize { CGSize(width: columns.reduce(0, +), height: rows.reduce(0, +)) }

    /// Room inside a cell, in ems.
    static let padding = (horizontal: 0.7, vertical: 0.45)

    static func make(_ table: CanvasTable, fontSize: Double) -> BoardTableLayout {
        let size = CGFloat(fontSize)
        let horizontal = size * padding.horizontal, vertical = size * padding.vertical
        let regular = NSFont.systemFont(ofSize: size), bold = NSFont.systemFont(ofSize: size, weight: .semibold)
        func font(_ row: Int) -> NSFont { row == 0 ? bold : regular }
        let columns: [CGFloat] = (0..<table.columnCount).map { column in
            let widest = table.rows.enumerated().map { row, cells in
                (plain(cells[column]) as NSString).size(withAttributes: [.font: font(row)]).width
            }.max() ?? 0
            return (min(max(widest * 1.04, size * 4), size * 18) + horizontal * 2).rounded(.up)
        }
        let rows: [CGFloat] = table.rows.enumerated().map { row, cells in
            let line = font(row).ascender - font(row).descender + font(row).leading
            let tallest = cells.enumerated().map { column, cell in
                (plain(cell) as NSString).boundingRect(
                    with: CGSize(width: max(10, columns[column] - horizontal * 2), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font(row)]
                ).height
            }.max() ?? 0
            return (max(tallest, line) + vertical * 2).rounded(.up)
        }
        return BoardTableLayout(columns: columns, rows: rows)
    }

    /// A cell's text without its inline Markdown marks.
    static func plain(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let plain = (try? AttributedString(markdown: text, options: options)).map { String($0.characters) } ?? text
        return plain.isEmpty ? " " : plain
    }

    func rect(row: Int, column: Int) -> CGRect {
        CGRect(x: columns.prefix(column).reduce(0, +), y: rows.prefix(row).reduce(0, +),
               width: columns.indices.contains(column) ? columns[column] : 0, height: rows.indices.contains(row) ? rows[row] : 0)
    }

    /// The cell under a point of the card, in board units.
    func cell(at point: CGPoint) -> (row: Int, column: Int)? {
        var x: CGFloat = 0, y: CGFloat = 0
        guard let column = columns.firstIndex(where: { x += $0; return point.x < x }),
              let row = rows.firstIndex(where: { y += $0; return point.y < y }), point.x >= 0, point.y >= 0 else { return nil }
        return (row, column)
    }
}

extension BoardStore {
    /// A table's layout at a font size, made once per text.
    func tableLayout(_ text: String, fontSize: Double) -> BoardTableLayout? {
        let key = "\(fontSize)|" + text
        if let known = tables[key] { return known }
        if tables.count > 300 { tables.removeAll() }
        let layout = CanvasTable(markdown: text).map { BoardTableLayout.make($0, fontSize: fontSize) }
        tables[key] = .some(layout)
        return layout
    }

    /// The size of a card that is as big as its content (free text, a table) at a font size.
    func fittedSize(of node: CanvasNode, text: String? = nil, fontSize: Double? = nil) -> (width: Double, height: Double) {
        let text = text ?? node.text ?? "", fontSize = fontSize ?? node.effectiveFontSize
        if node.isTable, let layout = tableLayout(text, fontSize: fontSize) {
            return (Double(layout.size.width), Double(layout.size.height))
        }
        return freeTextSize(text, fontSize: fontSize)
    }
}

extension CanvasNode {
    /// A card as big as its content, which resizing scales: free text, a table.
    var sizesToText: Bool { isFreeText || isTable }
}

