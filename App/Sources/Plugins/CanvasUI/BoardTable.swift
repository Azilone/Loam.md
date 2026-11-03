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

/// A table drawn on the board: a coloured header (the card's colour, else the accent) over plain rows, hairlines
/// between the cells. A double-click writes in a cell; Tab goes to the next one (a new row after the last), Return
/// down, Escape stops.
struct BoardTableView: View {
    let model: BoardModel
    let node: CanvasNode
    let table: CanvasTable
    let layout: BoardTableLayout
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let size = CGFloat(node.effectiveFontSize)
        let header = BoardStyle.color(node.color) ?? theme.accent
        let editing: (row: Int, column: Int)? = {
            // A cell whose row or column was just deleted is no longer written.
            if case .cell(let id, let row, let column) = model.editing?.target, id == node.id,
               row < table.rowCount, column < table.columnCount { return (row, column) }
            return nil
        }()
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Corners.r(size * 0.4), style: .continuous).fill(theme.background)
            Rectangle().fill(header).frame(height: layout.rows.first ?? 0)
            ForEach(0..<table.rowCount, id: \.self) { row in
                ForEach(0..<table.columnCount, id: \.self) { column in
                    let rect = layout.rect(row: row, column: column)
                    if editing?.row != row || editing?.column != column {
                        Text(Self.inline(table[row, column]))
                            .font(.ui(size: size, weight: row == 0 ? .semibold : .regular))
                            .foregroundStyle(row == 0 ? Color.white : theme.text)
                            .multilineTextAlignment(Self.alignment(table.alignments[column]))
                            .frame(width: rect.width - size * BoardTableLayout.padding.horizontal * 2,
                                   alignment: Self.frameAlignment(table.alignments[column]))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
            grid
            if let editing { cellField(row: editing.row, column: editing.column) }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Corners.r(size * 0.4), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Corners.r(size * 0.4), style: .continuous)
            .strokeBorder(theme.text.opacity(0.18), lineWidth: 1))
    }

    private var grid: some View {
        Canvas { context, size in
            var lines = Path()
            var x: CGFloat = 0
            for width in layout.columns.dropLast() {
                x += width
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
            }
            var y: CGFloat = 0
            for height in layout.rows.dropLast() {
                y += height
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(lines, with: .color(theme.text.opacity(0.14)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func cellField(row: Int, column: Int) -> some View {
        let rect = layout.rect(row: row, column: column)
        let size = CGFloat(node.effectiveFontSize)
        return BoardCellField(model: model, size: size, bold: row == 0, alignment: Self.alignment(table.alignments[column]))
            .padding(.horizontal, size * BoardTableLayout.padding.horizontal - 5)
            .frame(width: rect.width, height: rect.height)
            .background(theme.accent.opacity(0.08))
            .overlay(Rectangle().strokeBorder(theme.accent, lineWidth: 2))
            .offset(x: rect.minX, y: rect.minY)
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func alignment(_ alignment: CanvasTable.Alignment) -> TextAlignment {
        switch alignment {
        case .center: return .center
        case .right: return .trailing
        case .left, .none: return .leading
        }
    }

    static func frameAlignment(_ alignment: CanvasTable.Alignment) -> Alignment {
        switch alignment {
        case .center: return .center
        case .right: return .trailing
        case .left, .none: return .leading
        }
    }
}

/// The text field of a table cell being written: Tab and Shift-Tab go across, Return goes down, Escape cancels.
struct BoardCellField: View {
    let model: BoardModel
    let size: CGFloat
    let bold: Bool
    let alignment: TextAlignment
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: Binding(get: { model.editing?.draft ?? "" }, set: { model.editing?.draft = $0 }))
            .textFieldStyle(.plain)
            .font(.ui(size: size, weight: bold ? .semibold : .regular))
            .multilineTextAlignment(alignment)
            .focused($focused)
            // A frame later: on its first appearance the field is not in the window yet, and the keys went to the board.
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onKeyPress(.tab, phases: .down) { press in
                model.moveCell(by: press.modifiers.contains(.shift) ? -1 : 1)
                return .handled
            }
            .onSubmit { model.moveCellDown() }
            .onExitCommand { model.cancelEditing() }
            .onChange(of: focused) { if !focused { model.commitEditing() } }
    }
}
