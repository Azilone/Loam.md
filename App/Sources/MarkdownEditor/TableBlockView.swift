import AppKit
import PluginKitUI

/// Where a table's keyboard focus goes when it leaves the table.
enum TableExit { case above, below }

/// What a table view asks of the editor that holds it.
@MainActor
protocol TableBlockViewDelegate: AnyObject {
    /// The editor's undo manager: edits of the cells are undone with the text's.
    var tableUndoManager: UndoManager? { get }
    /// The table's cells changed (typing, a shape change, a paste): the editor writes the Markdown back to the note.
    /// `coalescing` merges a run of typing in one cell into one undo step.
    func tableView(_ view: TableBlockView, edited data: TableData, action: String, coalescing: Bool)
    /// The table's height changed, so the room the text keeps for it must too.
    func tableViewDidChangeHeight(_ view: TableBlockView)
    func tableView(_ view: TableBlockView, leave exit: TableExit)
    /// Removes the whole table from the note.
    func tableViewDelete(_ view: TableBlockView)
    func tableView(_ view: TableBlockView, open link: String, modifiers: NSEvent.ModifierFlags)
}

/// A cell, by row (0 is the header) and column.
struct TableCell: Hashable {
    var row: Int
    var column: Int
}

/// What is selected in a table when the keyboard is not in a cell's text: a block of cells, whole rows, whole columns
/// or all of it.
struct TableSelection: Equatable {
    enum Kind { case cells, rows, columns, all }
    var kind: Kind
    var anchor: TableCell
    var head: TableCell

    func rows(of data: TableData) -> ClosedRange<Int> {
        kind == .columns || kind == .all ? 0...(data.rowCount - 1) : min(anchor.row, head.row)...max(anchor.row, head.row)
    }

    func columns(of data: TableData) -> ClosedRange<Int> {
        kind == .rows || kind == .all ? 0...(data.columnCount - 1) : min(anchor.column, head.column)...max(anchor.column, head.column)
    }

    /// Whether the selection is only the header's row.
    func contains(_ cell: TableCell, in data: TableData) -> Bool {
        rows(of: data).contains(cell.row) && columns(of: data).contains(cell.column)
    }
}

/// The table component: cells drawn and edited on a grid, whose text is the note's GFM table (`TableData`). The
/// source is never in the text view's reach: the note's text keeps the table's lines hidden, and this view, placed
/// in the room reserved for it, shows and edits them. One text view (the editor) moves over the cell being typed in;
/// every other cell is drawn, so a table of hundreds of cells costs no more views than one cell.
final class TableBlockView: NSView, NSTextViewDelegate {
    weak var delegate: TableBlockViewDelegate?

    var theme = MarkdownTheme() {
        didSet { if theme != oldValue { restyleAll() } }
    }

    private(set) var data = TableData.empty(rows: 2, columns: 2)
    /// Each column's share of the table's width; they add up to 1.
    var fractions: [CGFloat] = []
    /// The table's width: the text column's.
    private(set) var tableWidth: CGFloat = 600

    // MARK: Geometry

    static let sideRoom: CGFloat = 30
    static let topRoom: CGFloat = 26
    static let bottomRoom: CGFloat = 30
    static let minColumnWidth: CGFloat = 48
    private static let handleSize: CGFloat = 18
    private var padding: CGFloat { MarkdownTheme.tableCellPadding }
    private var rowPadding: CGFloat { MarkdownTheme.tableRowPadding }

    private(set) var columnWidths: [CGFloat] = []
    private(set) var rowHeights: [CGFloat] = []
    var tableHeight: CGFloat { rowHeights.reduce(0, +) }
    /// The table's rectangle in this view's coordinates.
    var tableRect: NSRect { NSRect(x: Self.sideRoom, y: Self.topRoom, width: tableWidth, height: tableHeight) }

    /// The frame this view takes in the text view when the table's top left corner is at `origin`.
    func frame(forTableOrigin origin: NSPoint) -> NSRect {
        NSRect(
            x: origin.x - Self.sideRoom, y: origin.y - Self.topRoom,
            width: tableWidth + 2 * Self.sideRoom, height: tableHeight + Self.topRoom + Self.bottomRoom
        )
    }

    override var isFlipped: Bool { true }

    // MARK: State

    private var styled: [[NSAttributedString]] = []
    private(set) var editing: TableCell?
    var selection: TableSelection? {
        didSet {
            if selection != oldValue { needsDisplay = true; NSAccessibility.post(element: self, notification: .selectedCellsChanged) }
        }
    }
    /// The text view's selection covers the whole table (Select All, a drag across it): drawn as one selected block.
    var isSelectedAsText = false {
        didSet { if isSelectedAsText != oldValue { needsDisplay = true } }
    }
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var isLoading = false
    private var isRestyling = false
    private(set) lazy var editor = TableCellEditor(table: self)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        addSubview(editor)
        editor.isHidden = true
        setAccessibilityRole(.table)
        setAccessibilityLabel("Table")
    }

    // MARK: Loading

    /// Shows `data` at `width`, as the note's text has it now. The cell being typed in keeps its caret, and the
    /// view only redraws when what is written changed.
    func update(_ new: TableData, width: CGFloat, theme: MarkdownTheme, fractions saved: [CGFloat]?) {
        let sameText = new.markdown() == data.markdown()
        let sameShape = new.rowCount == data.rowCount && new.columnCount == data.columnCount
        if !sameText || !sameShape {
            let old = data
            data = new
            if let saved, saved.count == new.columnCount { fractions = saved }
            else if fractions.count != new.columnCount { fractions = Array(repeating: 1 / CGFloat(new.columnCount), count: new.columnCount) }
            // A cell that was being typed in follows the text it now has.
            if let editing, editing.row < new.rowCount, editing.column < new.columnCount {
                if old.rows.indices.contains(editing.row), old.rows[editing.row].indices.contains(editing.column),
                   old.rows[editing.row][editing.column] != new.rows[editing.row][editing.column] || editor.isHidden {
                    loadEditor()
                }
            } else if editing != nil {
                endEditing()
            }
            if let selection, selection.anchor.row >= new.rowCount || selection.anchor.column >= new.columnCount
                || selection.head.row >= new.rowCount || selection.head.column >= new.columnCount {
                self.selection = nil
            }
        } else if fractions.count != new.columnCount {
            fractions = Array(repeating: 1 / CGFloat(new.columnCount), count: new.columnCount)
        }
        if let saved, saved.count == data.columnCount { fractions = saved }
        // The width first: a new theme lays the cells out again at once, at the width they will have.
        let resized = tableWidth != width
        tableWidth = width
        let themed = self.theme != theme
        self.theme = theme
        // Every cell is styled and measured again, so only when what it shows changed: the note is restyled on each
        // keystroke, whichever paragraph the caret is in.
        // A new width only lays the cells out again: their styled text does not depend on it, and restyling every
        // cell on each step of a resize was a large part of its frames.
        if !themed, !sameText || !sameShape || styled.isEmpty {
            restyleAll()
        } else if !themed, resized {
            relayout()
            if editing != nil { positionEditor() }
        }
        needsDisplay = true
        updateAccessibility()
    }

    /// The table's data from the note's text, after an edit this view made: it does not reload what it already shows.
    private func restyleAll() {
        styled = data.rows.enumerated().map { row, cells in
            cells.enumerated().map { column, text in attributed(text, row: row, column: column, selection: nil) }
        }
        relayout()
        if editing != nil { positionEditor() }
    }

    // MARK: Styling and layout

    /// A cell's text as it is drawn: the inline Markdown styled (the syntax hidden unless `selection` is inside it),
    /// bold in the header, and aligned as its column is. Block syntax at the start of a cell is plain text, as GFM
    /// has no blocks in cells.
    func attributed(_ text: String, row: Int, column: Int, selection: NSRange?) -> NSAttributedString {
        let storage = NSTextStorage(string: text)
        if !text.isEmpty {
            let guarded = "\u{200B}" + text
            let spans: [StyleSpan] = MarkdownStyler.spans(in: guarded).compactMap { span in
                switch span.style {
                case .strong, .emphasis, .strikethrough, .highlight, .inlineCode, .link, .marker, .concealable: break
                default: return nil
                }
                let start = span.range.location - 1
                guard start >= 0 else { return nil }
                return StyleSpan(span.style, NSRange(location: start, length: min(span.range.length, text.utf16.count - start)))
            }
            theme.apply(spans, to: storage, revealing: selection ?? NSRange(location: Int.max / 2, length: 0))
        } else {
            storage.setAttributes(theme.baseAttributes, range: NSRange(location: 0, length: 0))
        }
        let whole = NSRange(location: 0, length: storage.length)
        if row == 0 {
            storage.enumerateAttribute(.font, in: whole) { value, range, _ in
                // A weight rather than the bold trait: the trait leaves some families (SF at a variable weight) as they are.
                let font = (value as? NSFont) ?? theme.bodyFont
                let header = font.fontDescriptor.symbolicTraits.contains(.monoSpace)
                    ? font.adding(.bold) : theme.bodyFont(size: font.pointSize, weight: .semibold)
                storage.addAttribute(.font, value: header, range: range)
            }
        }
        storage.enumerateAttribute(.markdownInlineCode, in: whole) { value, range, _ in
            if value != nil { storage.addAttribute(.backgroundColor, value: theme.codeBackgroundColor, range: range) }
        }
        let style = ((storage.length > 0 ? storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil)
            ?? theme.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
        style.alignment = switch data.alignments[column] {
        case .none, .left: .left
        case .center: .center
        case .right: .right
        }
        style.lineBreakMode = .byWordWrapping
        storage.addAttribute(.paragraphStyle, value: style, range: whole)
        return storage
    }

    private var lineHeight: CGFloat {
        let font = theme.bodyFont
        return ceil((font.ascender - font.descender + font.leading) * max(theme.lineHeightMultiple, 1))
    }

    private func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return lineHeight }
        let box = text.boundingRect(
            with: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(lineHeight, ceil(box.height))
    }

    /// Sets the columns' widths from their shares, and the rows' heights from their tallest cell. Tells the editor
    /// when the table's height changed.
    func relayout() {
        guard data.columnCount > 0, styled.count == data.rowCount else { return }
        if fractions.count != data.columnCount { fractions = Array(repeating: 1 / CGFloat(data.columnCount), count: data.columnCount) }
        columnWidths = fractions.map { $0 * tableWidth }
        let before = tableHeight
        rowHeights = data.rows.indices.map { row in
            let tallest = data.rows[row].indices.map { column -> CGFloat in
                let text = editing == TableCell(row: row, column: column) ? editorAttributed() : styled[row][column]
                return textHeight(text, width: columnWidths[column] - 2 * padding)
            }.max() ?? lineHeight
            return tallest + 2 * rowPadding
        }
        if abs(tableHeight - before) > 0.5 { delegate?.tableViewDidChangeHeight(self) }
        needsDisplay = true
    }

    private func editorAttributed() -> NSAttributedString {
        guard let editing else { return NSAttributedString() }
        return attributed(editor.string, row: editing.row, column: editing.column, selection: nil)
    }

    private func columnX(_ column: Int) -> CGFloat { Self.sideRoom + columnWidths[..<column].reduce(0, +) }
    private func rowY(_ row: Int) -> CGFloat { Self.topRoom + rowHeights[..<row].reduce(0, +) }

    func rect(of cell: TableCell) -> NSRect {
        NSRect(x: columnX(cell.column), y: rowY(cell.row), width: columnWidths[cell.column], height: rowHeights[cell.row])
    }

    private func textRect(of cell: TableCell) -> NSRect {
        rect(of: cell).insetBy(dx: padding, dy: rowPadding)
    }

    /// The cell under `point` (clamped to the table when `clamping`), or nil outside the grid.
    func cell(at point: NSPoint, clamping: Bool = false) -> TableCell? {
        guard !columnWidths.isEmpty, !rowHeights.isEmpty else { return nil }
        var x = point.x - Self.sideRoom
        var y = point.y - Self.topRoom
        if !clamping, x < 0 || y < 0 || x >= tableWidth || y >= tableHeight { return nil }
        x = min(max(0, x), tableWidth - 0.01)
        y = min(max(0, y), tableHeight - 0.01)
        var column = 0
        var edge: CGFloat = 0
        while column < columnWidths.count - 1, x >= edge + columnWidths[column] { edge += columnWidths[column]; column += 1 }
        var row = 0
        edge = 0
        while row < rowHeights.count - 1, y >= edge + rowHeights[row] { edge += rowHeights[row]; row += 1 }
        return TableCell(row: row, column: column)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !columnWidths.isEmpty, styled.count == data.rowCount else { return }
        let box = tableRect
        let line = theme.textColor.withAlphaComponent(0.11)
        let frame = NSBezierPath(continuousRoundedRect: box.insetBy(dx: 0.5, dy: 0.5), radius: Corners.r(8))
        // The header's tint, rounded at the top.
        let header = NSRect(x: box.minX, y: box.minY, width: box.width, height: rowHeights[0])
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        theme.textColor.withAlphaComponent(0.04).setFill()
        header.fill()
        NSGraphicsContext.restoreGraphicsState()
        line.setFill()
        var y = box.minY
        for row in 0..<(data.rowCount - 1) {
            y += rowHeights[row]
            NSRect(x: box.minX, y: y - 0.5, width: box.width, height: 1).fill()
        }
        var x = box.minX
        for column in 0..<(data.columnCount - 1) {
            x += columnWidths[column]
            NSRect(x: x - 0.5, y: box.minY, width: 1, height: box.height).fill()
        }
        line.setStroke()
        frame.lineWidth = 1
        frame.stroke()

        drawHoverTint()
        for row in 0..<data.rowCount {
            for column in 0..<data.columnCount where editing != TableCell(row: row, column: column) {
                let cell = TableCell(row: row, column: column)
                let text = styled[row][column]
                guard text.length > 0 else { continue }
                var area = textRect(of: cell)
                // Short text sits at the top of a tall row, as the editor puts it.
                area.size.height = max(area.height, lineHeight)
                text.draw(with: area, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
        drawSelection()
        drawChrome()
    }

    /// Craft's selection: a ring in the accent round the cells (a faint tint too for whole rows, columns or the table).
    private func drawSelection() {
        if isSelectedAsText {
            drawRing(tableRect, radius: 8, tint: 0.1)
            return
        }
        if let selection {
            let rows = selection.rows(of: data)
            let columns = selection.columns(of: data)
            let top = rect(of: TableCell(row: rows.lowerBound, column: columns.lowerBound))
            let bottom = rect(of: TableCell(row: rows.upperBound, column: columns.upperBound))
            drawRing(top.union(bottom), radius: selection.kind == .all ? 8 : 4, tint: selection.kind == .cells ? 0 : 0.06)
        } else if let editing {
            drawRing(rect(of: editing), radius: 4, tint: 0)
        }
    }

    private func drawRing(_ area: NSRect, radius: CGFloat, tint: CGFloat) {
        let path = NSBezierPath(continuousRoundedRect: area.insetBy(dx: 1, dy: 1), radius: Corners.r(radius))
        if tint > 0 {
            theme.accentColor.withAlphaComponent(tint).setFill()
            path.fill()
        }
        theme.accentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    /// The row or column under the pointer's grip takes a faint tint.
    private func drawHoverTint() {
        theme.accentColor.withAlphaComponent(0.06).setFill()
        switch hoverHandle {
        case .columnGrip(let column)?:
            NSRect(x: columnX(column), y: tableRect.minY, width: columnWidths[column], height: tableRect.height).fill()
        case .rowGrip(let row)?:
            NSRect(x: tableRect.minX, y: rowY(row), width: tableRect.width, height: rowHeights[row]).fill()
        default: break
        }
    }

    // MARK: Handles

    private enum Handle: Equatable {
        /// The dots at the table's right and bottom edges, which add a column or a row at the end.
        case addColumn, addRow
        /// The `⋯` beside the table's top right corner.
        case tableMenu
        /// The `⋮` in the cell being edited.
        case cellMenu
        /// A column's pill on the table's top edge, a row's on its left edge: they select, open the menu, and drag.
        case rowGrip(Int), columnGrip(Int)
        /// The border between a column and the next, dragged to resize.
        case border(Int)
    }

    private var hoverHandle: Handle? {
        didSet { if hoverHandle != oldValue { needsDisplay = true } }
    }

    /// The cell the keyboard is in or the selection ends at.
    private var activeCell: TableCell? { editing ?? selection?.head }

    private func pillRect(column: Int) -> NSRect {
        let cell = rect(of: TableCell(row: 0, column: column))
        return NSRect(x: cell.midX - 15, y: tableRect.minY - 7, width: 30, height: 14)
    }

    private func pillRect(row: Int) -> NSRect {
        let cell = rect(of: TableCell(row: row, column: 0))
        return NSRect(x: tableRect.minX - 7, y: cell.midY - 15, width: 14, height: 30)
    }

    private var addColumnRect: NSRect {
        guard let active = activeCell else { return .zero }
        return NSRect(x: tableRect.maxX - 10, y: rect(of: active).midY - 10, width: 20, height: 20)
    }

    private var addRowRect: NSRect {
        guard let active = activeCell else { return .zero }
        return NSRect(x: rect(of: active).midX - 10, y: tableRect.maxY - 10, width: 20, height: 20)
    }

    private var tableMenuRect: NSRect {
        NSRect(x: tableRect.maxX + 6, y: tableRect.minY + 2, width: 20, height: 20)
    }

    private var cellMenuRect: NSRect {
        guard let editing else { return .zero }
        let cell = rect(of: editing)
        return NSRect(x: cell.maxX - 24, y: cell.minY + 4, width: 20, height: 20)
    }

    private func handle(at point: NSPoint) -> Handle? {
        if editing != nil, cellMenuRect.contains(point) { return .cellMenu }
        if addColumnRect.contains(point) { return .addColumn }
        if addRowRect.contains(point) { return .addRow }
        if (isHovered || selection != nil || editing != nil), tableMenuRect.contains(point) { return .tableMenu }
        if point.y >= tableRect.minY - 14, point.y <= tableRect.minY + 8, point.x >= tableRect.minX, point.x <= tableRect.maxX,
           let cell = cell(at: NSPoint(x: point.x, y: tableRect.minY + 1), clamping: true) {
            return .columnGrip(cell.column)
        }
        if point.x >= tableRect.minX - 16, point.x <= tableRect.minX + 8, point.y >= tableRect.minY, point.y <= tableRect.maxY,
           let cell = cell(at: NSPoint(x: tableRect.minX + 1, y: point.y), clamping: true) {
            return .rowGrip(cell.row)
        }
        if point.y >= tableRect.minY, point.y <= tableRect.maxY {
            var x = tableRect.minX
            for column in 0..<(data.columnCount - 1) {
                x += columnWidths[column]
                if abs(point.x - x) <= 3 { return .border(column) }
            }
        }
        return nil
    }

    /// What the table shows besides its cells: the marks round the active cell, a hovered or selected row's or
    /// column's pill, the dots that add a row or a column, and the buttons for the menus.
    private func drawChrome() {
        let accent = theme.accentColor
        if let active = activeCell, active.row < data.rowCount, active.column < data.columnCount {
            let cell = rect(of: active)
            accent.withAlphaComponent(0.45).setFill()
            NSBezierPath(continuousRoundedRect: NSRect(x: cell.midX - 13, y: tableRect.minY - 1.5, width: 26, height: 3), radius: Corners.r(1.5)).fill()
            NSBezierPath(continuousRoundedRect: NSRect(x: tableRect.minX - 1.5, y: cell.midY - 9, width: 3, height: 18), radius: Corners.r(1.5)).fill()
            for (dot, hovered, symbol) in [(addColumnRect, hoverHandle == .addColumn, "plus"), (addRowRect, hoverHandle == .addRow, "plus")] {
                if hovered {
                    accent.setFill()
                    NSBezierPath(ovalIn: dot).fill()
                    drawSymbol(symbol, in: dot, color: .white)
                } else {
                    accent.withAlphaComponent(0.45).setFill()
                    NSBezierPath(ovalIn: NSRect(x: dot.midX - 2.5, y: dot.midY - 2.5, width: 5, height: 5)).fill()
                }
            }
        }
        // A pill on the selected column or row, and on the hovered one.
        var pills: [(NSRect, Bool, Bool)] = []
        if let selection, selection.kind == .columns || selection.kind == .rows {
            if selection.kind == .columns { for column in selection.columns(of: data) { pills.append((pillRect(column: column), true, true)) } }
            else { for row in selection.rows(of: data) { pills.append((pillRect(row: row), false, true)) } }
        }
        switch hoverHandle {
        case .columnGrip(let column)?: pills.append((pillRect(column: column), true, false))
        case .rowGrip(let row)?: pills.append((pillRect(row: row), false, false))
        default: break
        }
        for (rect, horizontal, _) in pills {
            accent.setFill()
            NSBezierPath(continuousRoundedRect: rect, radius: Corners.r(4)).fill()
            NSColor.white.setFill()
            for index in -1...1 {
                let dot = horizontal
                    ? NSRect(x: rect.midX - 1.25 + CGFloat(index) * 5, y: rect.midY - 1.25, width: 2.5, height: 2.5)
                    : NSRect(x: rect.midX - 1.25, y: rect.midY - 1.25 + CGFloat(index) * 5, width: 2.5, height: 2.5)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
        if isHovered || selection != nil || editing != nil {
            let circle = tableMenuRect
            theme.textColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(ovalIn: circle).fill()
            drawSymbol("ellipsis", in: circle, color: theme.secondaryTextColor)
        }
        if editing != nil {
            drawSymbol("ellipsis", in: cellMenuRect, color: theme.secondaryTextColor, rotated: true)
        }
        if let target = dragTarget { drawInsertionLine(target) }
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor, rotated: Bool = false) {
        guard let image = NSImage.symbol(name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) else { return }
        let size = rotated ? NSSize(width: image.size.height, height: image.size.width) : image.size
        let tinted = NSImage(size: size, flipped: false) { bounds in
            if rotated {
                let transform = NSAffineTransform()
                transform.translateX(by: bounds.width / 2, yBy: bounds.height / 2)
                transform.rotate(byDegrees: 90)
                transform.translateX(by: -image.size.width / 2, yBy: -image.size.height / 2)
                transform.concat()
                image.draw(in: NSRect(origin: .zero, size: image.size))
                color.set()
                NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
            } else {
                image.draw(in: bounds)
                color.set()
                bounds.fill(using: .sourceAtop)
            }
            return true
        }
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    // MARK: Hover and hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !editor.isHidden, editor.frame.contains(local), handle(at: local) != .cellMenu { return editor }
        if tableRect.contains(local) || handle(at: local) != nil { return self }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoverHandle = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isHovered = true
        hoverHandle = handle(at: point)
        switch hoverHandle {
        case .border?: NSCursor.resizeLeftRight.set()
        case .addColumn?, .addRow?, .tableMenu?, .cellMenu?, .rowGrip?, .columnGrip?: NSCursor.pointingHand.set()
        case nil: NSCursor.iBeam.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        mouseMoved(with: event)
    }

    // MARK: Mouse

    private var dragTarget: DragTarget?

    private struct DragTarget {
        let isRow: Bool
        /// The line between two rows or columns the drag would drop at: 0 is before the first.
        let line: Int
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch handle(at: point) {
        case .addColumn?: addColumnAtEnd()
        case .addRow?: addRowAtEnd()
        case .tableMenu?: showMenu(tableMenu(), at: tableMenuRect)
        case .cellMenu?:
            if let editing { showMenu(menu(for: TableSelection(kind: .cells, anchor: editing, head: editing)), at: cellMenuRect) }
        case .border(let column)?: trackResize(column: column, event: event)
        case .rowGrip(let row)?: trackGrip(row: row, column: nil, event: event)
        case .columnGrip(let column)?: trackGrip(row: nil, column: column, event: event)
        case nil: trackCells(event, startingIn: nil)
        }
    }

    /// A click and drag from a cell: a caret in the cell it starts in; a drag into another cell selects the block of
    /// cells between them. Double and triple clicks select words and the cell's text, as in a text view.
    func trackCells(_ event: NSEvent, startingIn editorView: NSView?) {
        let point = convert(event.locationInWindow, from: nil)
        guard let start = cell(at: point) else { return }
        if event.clickCount >= 2 {
            if editing != start { beginEditing(start, at: point) }
            if event.clickCount == 2 {
                let index = min(editor.characterIndexForInsertion(at: convert(point, to: editor)), max(0, (editor.string as NSString).length))
                editor.setSelectedRange(editor.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord))
            } else {
                editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            }
            return
        }
        if event.modifierFlags.contains(.shift), let anchor = selection?.anchor ?? editing {
            endEditing()
            select(TableSelection(kind: .cells, anchor: anchor, head: start))
            return
        }
        if event.modifierFlags.contains(.command), let link = link(at: point, in: start) {
            delegate?.tableView(self, open: link, modifiers: event.modifierFlags)
            return
        }
        if editing != start { beginEditing(start, at: point) } else { placeCaret(at: point) }
        guard let window else { return }
        var selecting = false
        let anchorIndex = editor.selectedRange().location
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let current = convert(next.locationInWindow, from: nil)
            let over = cell(at: current, clamping: true) ?? start
            if over != start || selecting {
                selecting = true
                if selection == nil { endEditing() }
                select(TableSelection(kind: .cells, anchor: start, head: over))
            } else {
                let index = editor.characterIndexForInsertion(at: convert(current, to: editor))
                editor.setSelectedRange(NSRange(location: min(anchorIndex, index), length: abs(index - anchorIndex)))
            }
        }
        if selecting { window.makeFirstResponder(self) }
    }

    private func link(at point: NSPoint, in cell: TableCell) -> String? {
        guard editing != cell else { return nil }
        let text = styled[cell.row][cell.column]
        let area = textRect(of: cell)
        let layout = NSLayoutManager()
        let storage = NSTextStorage(attributedString: text)
        let container = NSTextContainer(size: NSSize(width: area.width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let index = layout.characterIndex(
            for: NSPoint(x: point.x - area.minX, y: point.y - area.minY), in: container, fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard index < storage.length else { return nil }
        return storage.attribute(.markdownLink, at: index, effectiveRange: nil) as? String
    }

    private func trackResize(column: Int, event: NSEvent) {
        guard let window else { return }
        var last = convert(event.locationInWindow, from: nil).x
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let x = convert(next.locationInWindow, from: nil).x
            let pair = columnWidths[column] + columnWidths[column + 1]
            let width = min(max(Self.minColumnWidth, columnWidths[column] + x - last), pair - Self.minColumnWidth)
            last += width - columnWidths[column]
            fractions[column] = width / tableWidth
            fractions[column + 1] = (pair - width) / tableWidth
            relayout()
            if editing != nil { positionEditor() }
            delegate?.tableViewDidChangeHeight(self)
        }
    }

    /// A click on a row or column grip selects it (Shift extends); a drag moves it.
    private func trackGrip(row: Int?, column: Int?, event: NSEvent) {
        guard let window else { return }
        endEditing()
        window.makeFirstResponder(self)
        let isRow = row != nil
        let index = row ?? column ?? 0
        let wasSelected = selection.map { ($0.kind == (isRow ? .rows : .columns)) && (isRow ? $0.rows(of: data) : $0.columns(of: data)).contains(index) } ?? false
        if event.modifierFlags.contains(.shift), let current = selection, (current.kind == .rows) == isRow, current.kind != .cells {
            select(isRow
                ? TableSelection(kind: .rows, anchor: current.anchor, head: TableCell(row: index, column: 0))
                : TableSelection(kind: .columns, anchor: current.anchor, head: TableCell(row: 0, column: index)))
        } else {
            select(isRow
                ? TableSelection(kind: .rows, anchor: TableCell(row: index, column: 0), head: TableCell(row: index, column: 0))
                : TableSelection(kind: .columns, anchor: TableCell(row: 0, column: index), head: TableCell(row: 0, column: index)))
        }
        let start = convert(event.locationInWindow, from: nil)
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let current = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp { break }
            guard hypot(current.x - start.x, current.y - start.y) > 4 else { continue }
            // The header never moves, and nothing moves above it.
            if isRow && index == 0 { continue }
            if !moved {
                Haptics.levelChange()
                Sounds.play(.pickedUp)
            }
            moved = true
            let line = dropLine(isRow: isRow, at: current)
            if line.line != dragTarget?.line { Haptics.alignment() }
            dragTarget = line
            needsDisplay = true
        }
        let target = dragTarget
        dragTarget = nil
        needsDisplay = true
        guard moved, let target else {
            // A second click on the pill of what is selected opens its menu, as Craft's does.
            if !moved, wasSelected, let selection {
                showMenu(menu(for: selection), at: isRow ? pillRect(row: index) : pillRect(column: index))
            }
            return
        }
        if isRow {
            var destination = target.line
            if destination > index { destination -= 1 }
            guard destination != index, destination >= 1 else { return }
            var new = data
            new.moveRow(index, to: destination)
            commit(new, action: "Move Row")
            Sounds.play(.dropped)
            select(TableSelection(kind: .rows, anchor: TableCell(row: destination, column: 0), head: TableCell(row: destination, column: 0)))
        } else {
            var destination = target.line
            if destination > index { destination -= 1 }
            guard destination != index else { return }
            var new = data
            new.moveColumn(index, to: destination)
            moveFraction(from: index, to: destination)
            commit(new, action: "Move Column")
            Sounds.play(.dropped)
            select(TableSelection(kind: .columns, anchor: TableCell(row: 0, column: destination), head: TableCell(row: 0, column: destination)))
        }
    }

    private func dropLine(isRow: Bool, at point: NSPoint) -> DragTarget {
        if isRow {
            var line = 1
            var y = rowY(1)
            while line < data.rowCount, point.y > y + rowHeights[line] / 2 { y += rowHeights[line]; line += 1 }
            return DragTarget(isRow: true, line: min(line, data.rowCount))
        }
        var line = 0
        var x = columnX(0)
        while line < data.columnCount, point.x > x + columnWidths[line] / 2 { x += columnWidths[line]; line += 1 }
        return DragTarget(isRow: false, line: min(line, data.columnCount))
    }

    private func drawInsertionLine(_ target: DragTarget) {
        theme.accentColor.setFill()
        if target.isRow {
            let y = target.line >= data.rowCount ? tableRect.maxY : rowY(target.line)
            NSRect(x: tableRect.minX, y: y - 1, width: tableRect.width, height: 2).fill()
        } else {
            let x = target.line >= data.columnCount ? tableRect.maxX : columnX(target.line)
            NSRect(x: x - 1, y: tableRect.minY, width: 2, height: tableRect.height).fill()
        }
    }

    // MARK: Focus and selection

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { true }

    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.releaseSelectionIfFocusLeft() }
        }
        return true
    }

    /// The keyboard left the table (a click elsewhere): nothing stays selected in it.
    func releaseSelectionIfFocusLeft() {
        guard let window else { return }
        let responder = window.firstResponder as? NSView
        if responder === self || responder === editor { return }
        selection = nil
        if editing != nil { endEditing() }
    }

    func select(_ new: TableSelection) {
        selection = new
        if editing != nil, new.kind != .cells || new.anchor != new.head || new.anchor != editing {
            endEditing()
        }
        if window?.firstResponder !== self, editing == nil { window?.makeFirstResponder(self) }
    }

    /// Puts the caret in `cell`; `edge` says where, `.all` selects its text.
    enum CaretPlacement { case start, end, all }

    func focus(_ cell: TableCell, caret: CaretPlacement = .start) {
        let cell = TableCell(row: min(max(0, cell.row), data.rowCount - 1), column: min(max(0, cell.column), data.columnCount - 1))
        selection = nil
        beginEditing(cell, at: nil)
        let length = (editor.string as NSString).length
        switch caret {
        case .start: editor.setSelectedRange(NSRange(location: 0, length: 0))
        case .end: editor.setSelectedRange(NSRange(location: length, length: 0))
        case .all: editor.setSelectedRange(NSRange(location: 0, length: length))
        }
    }

    // MARK: Editing a cell

    private func beginEditing(_ cell: TableCell, at point: NSPoint?) {
        if editing != cell {
            endEditing()
            editing = cell
            selection = nil
            loadEditor()
        }
        window?.makeFirstResponder(editor)
        if let point { placeCaret(at: point) }
        needsDisplay = true
    }

    private func placeCaret(at point: NSPoint) {
        let index = editor.characterIndexForInsertion(at: convert(point, to: editor))
        editor.setSelectedRange(NSRange(location: index, length: 0))
    }

    private func loadEditor() {
        guard let editing, editing.row < data.rowCount, editing.column < data.columnCount else { return }
        isLoading = true
        let text = data.rows[editing.row][editing.column]
        let range = editor.selectedRange()
        editor.string = text
        restyleEditor()
        editor.isHidden = false
        positionEditor()
        editor.setSelectedRange(NSRange(location: min(range.location, (text as NSString).length), length: 0))
        isLoading = false
    }

    private func positionEditor() {
        guard let editing, editing.row < data.rowCount, editing.column < data.columnCount else { return }
        var area = textRect(of: editing)
        area.size.height = max(area.height, lineHeight)
        if editor.frame != area { editor.frame = area }
        editor.textContainer?.size = NSSize(width: area.width, height: CGFloat.greatestFiniteMagnitude)
    }

    private func restyleEditor() {
        guard let editing, let storage = editor.textStorage, !isRestyling else { return }
        isRestyling = true
        defer { isRestyling = false }
        let styledText = attributed(editor.string, row: editing.row, column: editing.column, selection: editor.selectedRange())
        let saved = editor.selectedRange()
        storage.beginEditing()
        storage.setAttributes([:], range: NSRange(location: 0, length: storage.length))
        styledText.enumerateAttributes(in: NSRange(location: 0, length: styledText.length)) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
        editor.setSelectedRange(saved)
        var typing = theme.baseAttributes
        if editing.row == 0 { typing[.font] = theme.bodyFont(size: theme.fontSize, weight: .semibold) }
        if let style = (styledText.length > 0 ? styledText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) : nil) {
            typing[.paragraphStyle] = style
        } else {
            let paragraph = theme.paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            paragraph.alignment = switch data.alignments[editing.column] {
            case .none, .left: .left
            case .center: .center
            case .right: .right
            }
            typing[.paragraphStyle] = paragraph
        }
        editor.typingAttributes = typing
        editor.insertionPointColor = theme.accentColor
    }

    func endEditing() {
        guard editing != nil else { return }
        let cell = editing!
        editing = nil
        editor.isHidden = true
        if cell.row < styled.count, cell.column < styled[cell.row].count, cell.row < data.rowCount, cell.column < data.columnCount {
            styled[cell.row][cell.column] = attributed(data.rows[cell.row][cell.column], row: cell.row, column: cell.column, selection: nil)
        }
        relayout()
        needsDisplay = true
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isLoading, let editing else { return }
        var new = data
        new.rows[editing.row][editing.column] = editor.string
        restyleEditor()
        data = new
        styled[editing.row][editing.column] = attributed(editor.string, row: editing.row, column: editing.column, selection: nil)
        relayout()
        positionEditor()
        needsDisplay = true
        delegate?.tableView(self, edited: new, action: "Typing", coalescing: true)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isLoading, !isRestyling, editing != nil else { return }
        restyleEditor()
        relayout()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let editing else { return false }
        let text = editor.string as NSString
        let range = editor.selectedRange()
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            move(from: editing, by: .next)
        case #selector(NSResponder.insertBacktab(_:)):
            move(from: editing, by: .previous)
        case #selector(NSResponder.insertNewline(_:)):
            // Down one row; in the last row a new row (Craft).
            if editing.row == data.rowCount - 1 {
                var new = data
                new.insertRow(at: data.rowCount)
                commit(new, action: "Add Row")
                focus(TableCell(row: data.rowCount - 1, column: editing.column))
            } else {
                focus(TableCell(row: editing.row + 1, column: editing.column))
            }
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            editor.insertText("\n", replacementRange: range)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveUpAndModifySelection(_:)):
            guard range.length == 0, onFirstLine() else { return false }
            if editing.row == 0 { delegate?.tableView(self, leave: .above) } else { focus(TableCell(row: editing.row - 1, column: editing.column), caret: .end) }
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)):
            guard range.length == 0, onLastLine() else { return false }
            if editing.row == data.rowCount - 1 { delegate?.tableView(self, leave: .below) } else { focus(TableCell(row: editing.row + 1, column: editing.column), caret: .start) }
        case #selector(NSResponder.moveLeft(_:)):
            guard range.length == 0, range.location == 0 else { return false }
            move(from: editing, by: .previous, caret: .end)
        case #selector(NSResponder.moveRight(_:)):
            guard range.length == 0, range.location == text.length else { return false }
            move(from: editing, by: .next, caret: .start, addsRow: false)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.moveToBeginningOfParagraph(_:)):
            focus(TableCell(row: 0, column: editing.column))
        case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)):
            focus(TableCell(row: data.rowCount - 1, column: editing.column), caret: .end)
        case #selector(NSResponder.moveToLeftEndOfLine(_:)), #selector(NSResponder.moveToBeginningOfLine(_:)):
            focus(TableCell(row: editing.row, column: 0))
        case #selector(NSResponder.moveToRightEndOfLine(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
            focus(TableCell(row: editing.row, column: data.columnCount - 1), caret: .end)
        case #selector(NSResponder.cancelOperation(_:)):
            let cell = editing
            endEditing()
            window?.makeFirstResponder(self)
            select(TableSelection(kind: .cells, anchor: cell, head: cell))
        default:
            return false
        }
        return true
    }

    private func onFirstLine() -> Bool {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return true }
        let location = min(editor.selectedRange().location, max(0, layout.numberOfGlyphs - 1))
        guard layout.numberOfGlyphs > 0 else { return true }
        let glyph = layout.glyphIndexForCharacter(at: location)
        var line = NSRange()
        layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        _ = container
        return line.location == 0
    }

    private func onLastLine() -> Bool {
        guard let layout = editor.layoutManager else { return true }
        guard layout.numberOfGlyphs > 0 else { return true }
        let length = (editor.string as NSString).length
        let location = min(editor.selectedRange().location, length)
        let glyph = layout.glyphIndexForCharacter(at: min(location, length - 1))
        var line = NSRange()
        layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        return location >= length || NSMaxRange(line) >= layout.numberOfGlyphs
    }

    enum Step { case next, previous }

    /// Tab and Shift-Tab, the arrows at the edge of a cell: the next cell in reading order. Tab in the very last
    /// cell adds a row (`addsRow`).
    func move(from cell: TableCell, by step: Step, caret: CaretPlacement = .all, addsRow: Bool = true) {
        var next = cell
        switch step {
        case .next:
            if cell.column + 1 < data.columnCount { next.column += 1 }
            else if cell.row + 1 < data.rowCount { next = TableCell(row: cell.row + 1, column: 0) }
            else if addsRow {
                var new = data
                new.insertRow(at: data.rowCount)
                commit(new, action: "Add Row")
                next = TableCell(row: data.rowCount - 1, column: 0)
            } else { delegate?.tableView(self, leave: .below); return }
        case .previous:
            if cell.column > 0 { next.column -= 1 }
            else if cell.row > 0 { next = TableCell(row: cell.row - 1, column: data.columnCount - 1) }
            else { delegate?.tableView(self, leave: .above); return }
        }
        focus(next, caret: caret)
    }

    // MARK: Changing the table

    /// Writes a new shape or content to the note and shows it.
    func commit(_ new: TableData, action: String) {
        data = new
        restyleAll()
        delegate?.tableView(self, edited: new, action: action, coalescing: false)
    }

    private func moveFraction(from: Int, to: Int) {
        guard fractions.indices.contains(from) else { return }
        fractions.insert(fractions.remove(at: from), at: min(to, fractions.count))
    }

    func addRowAtEnd() {
        var new = data
        new.insertRow(at: data.rowCount)
        commit(new, action: "Add Row")
        focus(TableCell(row: data.rowCount - 1, column: 0))
    }

    func addColumnAtEnd() {
        insertColumn(at: data.columnCount)
        focus(TableCell(row: 0, column: data.columnCount - 1))
    }

    func insertRow(at index: Int) {
        var new = data
        new.insertRow(at: index)
        commit(new, action: "Insert Row")
        select(TableSelection(kind: .rows, anchor: TableCell(row: max(1, index), column: 0), head: TableCell(row: max(1, index), column: 0)))
    }

    func insertColumn(at index: Int) {
        var new = data
        let width = 1 / CGFloat(new.columnCount + 1)
        new.insertColumn(at: index)
        let scale = 1 - width
        fractions = fractions.map { $0 * scale }
        fractions.insert(width, at: min(max(0, index), fractions.count))
        commit(new, action: "Insert Column")
    }

    func deleteRows(_ range: ClosedRange<Int>) {
        var new = data
        guard new.deleteRows(range) else { return NSSound.beep() }
        endEditing()
        commit(new, action: range.count > 1 ? "Delete Rows" : "Delete Row")
        selection = nil
    }

    func deleteColumns(_ range: ClosedRange<Int>) {
        var new = data
        guard new.deleteColumns(range) else { return NSSound.beep() }
        endEditing()
        let kept = fractions.enumerated().filter { !range.contains($0.offset) }.map(\.element)
        let total = kept.reduce(0, +)
        fractions = kept.map { $0 / total }
        commit(new, action: range.count > 1 ? "Delete Columns" : "Delete Column")
        selection = nil
    }

    func duplicateRows(_ range: ClosedRange<Int>) {
        var new = data
        for row in range.reversed() { new.duplicateRow(row) }
        commit(new, action: "Duplicate Row")
    }

    func duplicateColumns(_ range: ClosedRange<Int>) {
        var new = data
        for column in range.reversed() { new.duplicateColumn(column) }
        let width = 1 / CGFloat(new.columnCount)
        fractions = Array(repeating: width, count: new.columnCount)
        commit(new, action: "Duplicate Column")
    }

    func moveRows(_ range: ClosedRange<Int>, by offset: Int) {
        guard range.lowerBound >= 1 else { return }
        let target = range.lowerBound + offset
        guard target >= 1, target + range.count - 1 < data.rowCount else { return NSSound.beep() }
        var new = data
        let moved = Array(new.rows[range])
        new.rows.removeSubrange(range)
        new.rows.insert(contentsOf: moved, at: target)
        commit(new, action: "Move Row")
        select(TableSelection(kind: .rows, anchor: TableCell(row: target, column: 0), head: TableCell(row: target + range.count - 1, column: 0)))
    }

    func moveColumns(_ range: ClosedRange<Int>, by offset: Int) {
        let target = range.lowerBound + offset
        guard target >= 0, target + range.count - 1 < data.columnCount else { return NSSound.beep() }
        var new = data
        for row in new.rows.indices {
            let moved = Array(new.rows[row][range])
            new.rows[row].removeSubrange(range)
            new.rows[row].insert(contentsOf: moved, at: target)
        }
        let movedAlignments = Array(new.alignments[range])
        new.alignments.removeSubrange(range)
        new.alignments.insert(contentsOf: movedAlignments, at: target)
        let movedFractions = Array(fractions[range])
        fractions.removeSubrange(range)
        fractions.insert(contentsOf: movedFractions, at: target)
        commit(new, action: "Move Column")
        select(TableSelection(kind: .columns, anchor: TableCell(row: 0, column: target), head: TableCell(row: 0, column: target + range.count - 1)))
    }

    func align(_ columns: ClosedRange<Int>, _ alignment: TableAlignment) {
        var new = data
        for column in columns { new.alignments[column] = alignment }
        commit(new, action: "Align Column")
    }

    func clear(_ selection: TableSelection) {
        var new = data
        new.clear(rows: selection.rows(of: data), columns: selection.columns(of: data))
        commit(new, action: "Clear Cells")
    }

    // MARK: Keyboard on a selection

    override func keyDown(with event: NSEvent) {
        guard let selection else {
            if let editing { focus(editing) }
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)
        if command { _ = performKeyEquivalent(with: event); return }
        func extend(_ row: Int, _ column: Int) {
            let head = TableCell(
                row: min(max(0, selection.head.row + row), data.rowCount - 1),
                column: min(max(0, selection.head.column + column), data.columnCount - 1)
            )
            if shift {
                var kind = selection.kind
                if kind == .all { kind = .cells }
                select(TableSelection(kind: kind, anchor: selection.anchor, head: head))
            } else {
                select(TableSelection(kind: .cells, anchor: head, head: head))
            }
        }
        switch event.keyCode {
        case 123: extend(0, -1)
        case 124: extend(0, 1)
        case 125:
            if selection.head.row == data.rowCount - 1, !shift { delegate?.tableView(self, leave: .below) } else { extend(1, 0) }
        case 126:
            if selection.head.row == 0, !shift { delegate?.tableView(self, leave: .above) } else { extend(-1, 0) }
        case 48:
            let cell = shift ? selection.head : selection.head
            move(from: cell, by: shift ? .previous : .next, caret: .all)
        case 36, 76:
            focus(selection.head, caret: .end)
        case 53:
            self.selection = nil
            delegate?.tableView(self, leave: .below)
        case 51, 117:
            deleteSelection()
        default:
            if let characters = event.characters, !characters.isEmpty, !event.modifierFlags.contains(.control),
               characters.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) {
                // Typing on a selected cell replaces its text, as in a spreadsheet.
                focus(selection.head, caret: .all)
                editor.insertText(characters, replacementRange: editor.selectedRange())
            }
        }
    }

    func deleteSelection() {
        guard let selection else { return }
        switch selection.kind {
        case .all: delegate?.tableViewDelete(self)
        case .rows where selection.rows(of: data).lowerBound >= 1: deleteRows(selection.rows(of: data))
        case .columns where selection.columns(of: data).count < data.columnCount: deleteColumns(selection.columns(of: data))
        default: clear(selection)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              window?.firstResponder === self, selection != nil,
              let key = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": paste(nil)
        case "a": selectAll(nil)
        case "\r": if event.modifierFlags.contains(.shift) { insertColumnAfterActive() } else { insertRowBelowActive() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func selectAll(_ sender: Any?) {
        endEditing()
        window?.makeFirstResponder(self)
        select(TableSelection(
            kind: .all, anchor: TableCell(row: 0, column: 0), head: TableCell(row: data.rowCount - 1, column: data.columnCount - 1)
        ))
    }

    // MARK: Clipboard

    private func selectedGrid() -> [[String]]? {
        guard let selection else { return nil }
        let rows = selection.rows(of: data), columns = selection.columns(of: data)
        return rows.map { row in columns.map { data.rows[row][$0] } }
    }

    @objc func copy(_ sender: Any?) {
        guard let grid = selectedGrid(), let selection else { return }
        var markdown = TableData(rows: grid, alignments: selection.columns(of: data).map { data.alignments[$0] })
        if selection.rows(of: data).lowerBound > 0 || selection.kind == .cells { markdown.rows.insert(markdown.rows[0].map { _ in "" }, at: 0) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(TableData.tabSeparated(grid), forType: .string)
        pasteboard.setString(Self.html(grid, header: selection.rows(of: data).lowerBound == 0), forType: .html)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        if let selection { clear(selection) }
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), let grid = TableData.grid(from: text) else { return }
        let origin = selection.map { TableCell(row: $0.rows(of: data).lowerBound, column: $0.columns(of: data).lowerBound) }
            ?? editing ?? TableCell(row: 1, column: 0)
        var new = data
        let before = (new.rowCount, new.columnCount)
        guard let filled = new.paste(grid, row: origin.row, column: origin.column) else { return }
        if new.columnCount != before.1 {
            fractions = Array(repeating: 1 / CGFloat(new.columnCount), count: new.columnCount)
        }
        endEditing()
        commit(new, action: "Paste")
        window?.makeFirstResponder(self)
        select(TableSelection(
            kind: .cells, anchor: TableCell(row: filled.rows.lowerBound, column: filled.columns.lowerBound),
            head: TableCell(row: filled.rows.upperBound, column: filled.columns.upperBound)
        ))
    }

    static func html(_ grid: [[String]], header: Bool) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        }
        let rows = grid.enumerated().map { index, row in
            "<tr>" + row.map { (header && index == 0 ? "<th>" : "<td>") + escape($0) + (header && index == 0 ? "</th>" : "</td>") }.joined() + "</tr>"
        }
        return "<table>" + rows.joined() + "</table>"
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        var target = selection
        if let cell = cell(at: point) {
            if target == nil || !(target!.contains(cell, in: data)) {
                if editing == cell { target = TableSelection(kind: .cells, anchor: cell, head: cell) }
                else {
                    endEditing()
                    target = TableSelection(kind: .cells, anchor: cell, head: cell)
                    select(target!)
                }
            }
        } else if case .rowGrip(let row)? = handle(at: point) {
            target = TableSelection(kind: .rows, anchor: TableCell(row: row, column: 0), head: TableCell(row: row, column: 0))
            select(target!)
        } else if case .columnGrip(let column)? = handle(at: point) {
            target = TableSelection(kind: .columns, anchor: TableCell(row: 0, column: column), head: TableCell(row: 0, column: column))
            select(target!)
        }
        guard let target else { return nil }
        return menu(for: target)
    }

    private func showMenu(_ menu: NSMenu, at rect: NSRect) {
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: self)
    }

    private func item(_ title: String, enabled: Bool = true, destructive: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = TableMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
        item.target = self
        item.handler = action
        item.isEnabled = enabled
        if destructive {
            item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
        }
        return item
    }

    /// The menu of a selection, as Craft's: "Edit Table" holds the shape changes, then alignment, the clipboard, the
    /// column sizes and clearing.
    func menu(for target: TableSelection) -> NSMenu {
        let rows = target.rows(of: data), columns = target.columns(of: data)
        let menu = NSMenu()
        let bodyRows = rows.lowerBound >= 1
        let rowWord = rows.count > 1 ? "Rows" : "Row"
        let columnWord = columns.count > 1 ? "Columns" : "Column"

        let edit = NSMenu(title: "Edit Table")
        edit.addItem(item("Insert Row Above", enabled: bodyRows) { [self] in insertRow(at: rows.lowerBound) })
        edit.addItem(item("Insert Row Below") { [self] in insertRow(at: rows.upperBound + 1) })
        edit.addItem(item("Insert Column Left") { [self] in insertColumn(at: columns.lowerBound) })
        edit.addItem(item("Insert Column Right") { [self] in insertColumn(at: columns.upperBound + 1) })
        edit.addItem(.separator())
        edit.addItem(item("Duplicate \(rowWord)", enabled: bodyRows) { [self] in duplicateRows(rows) })
        edit.addItem(item("Duplicate \(columnWord)") { [self] in duplicateColumns(columns) })
        edit.addItem(.separator())
        edit.addItem(item("Move \(rowWord) Up", enabled: bodyRows && rows.lowerBound > 1) { [self] in moveRows(rows, by: -1) })
        edit.addItem(item("Move \(rowWord) Down", enabled: bodyRows && rows.upperBound < data.rowCount - 1) { [self] in moveRows(rows, by: 1) })
        edit.addItem(item("Move \(columnWord) Left", enabled: columns.lowerBound > 0) { [self] in moveColumns(columns, by: -1) })
        edit.addItem(item("Move \(columnWord) Right", enabled: columns.upperBound < data.columnCount - 1) { [self] in moveColumns(columns, by: 1) })
        edit.addItem(.separator())
        edit.addItem(item("Delete \(rowWord)", enabled: bodyRows, destructive: true) { [self] in deleteRows(rows) })
        edit.addItem(item("Delete \(columnWord)", enabled: columns.count < data.columnCount, destructive: true) { [self] in deleteColumns(columns) })
        let editItem = NSMenuItem(title: "Edit Table", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        menu.addItem(editItem)

        let align = NSMenu(title: "Align")
        align.addItem(item("Left") { [self] in self.align(columns, .left) })
        align.addItem(item("Center") { [self] in self.align(columns, .center) })
        align.addItem(item("Right") { [self] in self.align(columns, .right) })
        let alignItem = NSMenuItem(title: "Align", action: nil, keyEquivalent: "")
        alignItem.submenu = align
        menu.addItem(alignItem)

        menu.addItem(.separator())
        menu.addItem(item("Cut") { [self] in cut(nil) })
        menu.addItem(item("Copy") { [self] in copy(nil) })
        menu.addItem(item("Paste") { [self] in paste(nil) })
        menu.addItem(.separator())
        menu.addItem(item("Reset Column Size") { [self] in resetColumnSizes() })
        menu.addItem(item("Clear Cell Contents", destructive: true) { [self] in clear(target) })
        menu.addItem(item("Delete Table", destructive: true) { [self] in delegate?.tableViewDelete(self) })
        return menu
    }

    /// The `⋯` beside the table: what concerns all of it.
    private func tableMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Select Table") { [self] in selectAll(nil) })
        menu.addItem(item("Add Row") { [self] in addRowAtEnd() })
        menu.addItem(item("Add Column") { [self] in addColumnAtEnd() })
        menu.addItem(.separator())
        menu.addItem(item("Copy as Markdown") { [self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(data.markdown(), forType: .string)
            Sounds.play(.copied)
        })
        menu.addItem(item("Reset Column Size") { [self] in resetColumnSizes() })
        menu.addItem(.separator())
        menu.addItem(item("Delete Table", destructive: true) { [self] in delegate?.tableViewDelete(self) })
        return menu
    }

    @objc private func runMenuItem(_ sender: TableMenuItem) {
        sender.handler?()
    }

    func resetColumnSizes() {
        fractions = Array(repeating: 1 / CGFloat(data.columnCount), count: data.columnCount)
        relayout()
        if editing != nil { positionEditor() }
    }

    /// Cmd-Return: a row under the active cell's, with the caret in it. Shift-Cmd-Return: a column after its column.
    func insertRowBelowActive() {
        guard let cell = activeCell else { return }
        var new = data
        new.insertRow(at: cell.row + 1)
        commit(new, action: "Insert Row")
        focus(TableCell(row: cell.row + 1, column: cell.column))
    }

    func insertColumnAfterActive() {
        guard let cell = activeCell else { return }
        insertColumn(at: cell.column + 1)
        focus(TableCell(row: cell.row, column: cell.column + 1))
    }

    // MARK: Accessibility

    private var accessibilityRowElements: [NSAccessibilityElement] = []

    private func updateAccessibility() {
        guard !columnWidths.isEmpty else { return }
        accessibilityRowElements = data.rows.indices.map { row in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.row)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(row == 0 ? "Header row" : "Row \(row)")
            element.setAccessibilityFrameInParentSpace(NSRect(x: tableRect.minX, y: rowY(row), width: tableWidth, height: rowHeights[row]))
            let cells = data.rows[row].indices.map { column -> NSAccessibilityElement in
                let cell = NSAccessibilityElement()
                cell.setAccessibilityRole(.cell)
                cell.setAccessibilityParent(element)
                cell.setAccessibilityLabel("Row \(row + 1), column \(column + 1)")
                cell.setAccessibilityValue(data.rows[row][column])
                cell.setAccessibilityFrameInParentSpace(rect(of: TableCell(row: row, column: column)))
                return cell
            }
            element.setAccessibilityChildren(cells)
            return element
        }
        setAccessibilityRows(accessibilityRowElements)
        setAccessibilityChildren(accessibilityRowElements + [editor])
    }
}

/// A menu item that runs a closure.
private final class TableMenuItem: NSMenuItem {
    var handler: (() -> Void)?
}

/// The text view that moves over the cell being typed in. Its undo is the note's, its Tab, Return and arrows are the
/// table's (`TableBlockView.textView(_:doCommandBy:)`), and it takes pasted text as plain text, or as cells when the
/// text is a block of them.
final class TableCellEditor: NSTextView {
    weak var table: TableBlockView?

    init(table: TableBlockView) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        super.init(frame: .zero, textContainer: container)
        self.table = table
        delegate = table
        drawsBackground = false
        isRichText = true
        importsGraphics = false
        allowsUndo = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        setAccessibilityLabel("Cell")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The editor registers no undo of its own: each change goes to the note's text, which registers it (`TableBlocks`).
    /// Undo and redo reach the note's manager through the two actions below.
    override var undoManager: UndoManager? { nil }

    @objc func undo(_ sender: Any?) { table?.delegate?.tableUndoManager?.undo() }
    @objc func redo(_ sender: Any?) { table?.delegate?.tableUndoManager?.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): table?.delegate?.tableUndoManager?.canUndo ?? false
        case #selector(redo(_:)): table?.delegate?.tableUndoManager?.canRedo ?? false
        default: super.validateUserInterfaceItem(item)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            DispatchQueue.main.async { [weak table] in
                MainActor.assumeIsolated { table?.releaseSelectionIfFocusLeft() }
            }
        }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        guard let table, event.clickCount == 1 else { return super.mouseDown(with: event) }
        table.trackCells(event, startingIn: self)
    }

    /// Several cells' worth of text goes to the cells; one line of text stays in this one.
    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), TableData.grid(from: text) != nil {
            table?.paste(sender)
        } else {
            pasteAsPlainText(sender)
        }
    }

    override func selectAll(_ sender: Any?) {
        // A second Select All, with the cell's text already selected, selects the table's cells.
        let length = (string as NSString).length
        if length == 0 || selectedRange() == NSRange(location: 0, length: length) {
            table?.selectAll(sender)
        } else {
            super.selectAll(sender)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        // Cmd-Return adds a row under the cell, Shift-Cmd-Return a column after it (Craft's).
        if key == "\r" || key == "\u{3}" {
            if flags.contains(.shift) { table?.insertColumnAfterActive() } else { table?.insertRowBelowActive() }
            return true
        }
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        let format: InlineFormat? = switch key {
        case "b": .bold
        case "i": .italic
        default: nil
        }
        guard let format, let edit = InlineFormatting.toggle(format, in: string, selection: selectedRange()) else {
            return super.performKeyEquivalent(with: event)
        }
        insertText(edit.replacement, replacementRange: edit.range)
        setSelectedRange(edit.selection)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        table?.menu(for: event)
    }
}
