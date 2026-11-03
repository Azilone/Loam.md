import AppKit

extension NSAttributedString.Key {
    /// On the last character of a table shown as a component; the value is a `TableMark`.
    static let markdownTableBlock = NSAttributedString.Key("Loam.markdownTableBlock")
}

/// The room a table's view takes below its hidden lines, in the paragraph spacing of the last one, as a picture's.
final class TableMark: NSObject, BlockMark {
    let block: TableBlock
    let size: NSSize
    var caret: Int? { nil }

    init(block: TableBlock, size: NSSize) {
        self.block = block
        self.size = size
    }

    // Equal when it stands for the same table at the same size, so restyling twice leaves the text as it was.
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableMark else { return false }
        return other.block === block && other.size == size
    }

    override var hash: Int { ObjectIdentifier(block).hashValue }
}

/// What the editor keeps for one table: its view, where its lines are in the note, and what the view last wrote there.
@MainActor
final class TableBlock {
    let view = TableBlockView(frame: .zero)
    /// The table's lines, without the last line break, at the last restyle.
    var range: NSRange
    /// The Markdown at `range`.
    var markdown: String
    /// The height the text's room was last made for.
    var markedHeight: CGFloat = 0
    /// Whether the view has been put in its room yet: until then it would show at the text's top left.
    var placed = false

    init(range: NSRange, markdown: String) {
        self.range = range
        self.markdown = markdown
    }
}

/// A run of typing in one cell, so its keystrokes undo together.
struct TableTyping {
    weak var block: TableBlock?
    var cell: TableCell?
    var at: Date
}

extension EditorController {
    /// Shows each GFM table as a component. The table's lines stay in the text, hidden and out of the selection's
    /// reach (`textView(_:willChangeSelectionFromCharacterRange:toCharacterRange:)`, `shouldChangeTextIn`); the
    /// component edits them as cells and writes `| a | b |` back. Blocks keep their view from one restyle to the
    /// next: matched by their text, else by their rank.
    func applyTableBlocks(_ spans: [StyleSpan], to storage: NSTextStorage, limit: NSRange? = nil) {
        guard let textView else { return }
        let ns = storage.string as NSString
        var old = tableBlocks
        var found: [(range: NSRange, table: TableData, markdown: String)] = []
        for span in spans where span.style == .table {
            guard let (table, range) = TableData.parse(span.range, in: ns), NSMaxRange(range) <= ns.length else { continue }
            found.append((range, table, ns.substring(with: range)))
        }
        var kept: [TableBlock?] = found.map { entry in
            guard let index = old.firstIndex(where: { $0.markdown == entry.markdown }) else { return nil }
            return old.remove(at: index)
        }
        for index in kept.indices where kept[index] == nil && !old.isEmpty { kept[index] = old.removeFirst() }
        for gone in old { gone.view.removeFromSuperview() }

        var blocks: [TableBlock] = []
        for (index, entry) in found.enumerated() {
            let block = kept[index] ?? TableBlock(range: entry.range, markdown: entry.markdown)
            block.range = entry.range
            block.markdown = entry.markdown
            block.view.delegate = self
            blocks.append(block)
            // A table the restyle did not reach, with the text it had, keeps its view and its marks in the storage:
            // typing elsewhere in a long note does not touch it.
            if kept[index] != nil, let limit,
               NSIntersectionRange(limit, NSRange(location: entry.range.location, length: entry.range.length + 1)).length == 0 {
                continue
            }
            block.view.update(entry.table, width: textView.columnWidth, theme: theme, fractions: nil)
            // The lines and the break after them take no room.
            var hidden = entry.range
            if NSMaxRange(hidden) < ns.length, ns.character(at: NSMaxRange(hidden)) == 10 { hidden.length += 1 }
            storage.addAttributes(MarkdownTheme.concealed, range: hidden)
            mark(block, in: storage)
        }
        tableBlocks = blocks
        for block in blocks where block.view.superview == nil { textView.addSubview(block.view) }
    }

    /// Reserves the room of a table's view under its last line and marks where it goes.
    func mark(_ block: TableBlock, in storage: NSTextStorage) {
        guard let textView else { return }
        let ns = storage.string as NSString
        let range = block.range
        guard NSMaxRange(range) <= ns.length, range.length > 0 else { return }
        let last = NSMaxRange(range) - 1
        let paragraph = ns.paragraphRange(for: NSRange(location: last, length: 0))
        let style = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        let height = block.view.tableHeight
        style.paragraphSpacing = height + 2 * PictureMark.margin
        storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
        storage.addAttribute(
            .markdownTableBlock,
            value: TableMark(block: block, size: NSSize(width: textView.columnWidth, height: height)),
            range: NSRange(location: last, length: 1)
        )
        block.markedHeight = height
    }

    /// Places each table's view in its room.
    func positionTableViews() {
        guard let textView, !tableBlocks.isEmpty else { return }
        // A table under a folded heading has no room: hidden until it unfolds.
        // A table far from the screen is not laid out yet: hidden until it is placed, not over the note's top.
        for block in tableBlocks { block.view.isHidden = !block.placed || textView.isFolded(block.range.location) }
        for (mark, frame) in textView.blockFrames(.markdownTableBlock, near: textView.placedRange) as [(TableMark, NSRect)] {
            let block = mark.block
            guard tableBlocks.contains(where: { $0 === block }) else { continue }
            if !block.placed {
                block.placed = true
                block.view.isHidden = textView.isFolded(block.range.location)
            }
            if block.view.superview !== textView { textView.addSubview(block.view) }
            let target = block.view.frame(forTableOrigin: NSPoint(x: frame.minX.rounded(), y: frame.minY.rounded()))
            if block.view.frame != target { block.view.frame = target }
        }
    }

    /// Removes every table view (another note is shown).
    func removeTableBlocks() {
        for block in tableBlocks { block.view.removeFromSuperview() }
        tableBlocks = []
    }

    private func block(for view: TableBlockView) -> TableBlock? {
        tableBlocks.first { $0.view === view }
    }

    // MARK: Writing a table back

    /// Replaces `range` of the note's text, as an edit the table makes: it goes past the guard that keeps the
    /// text's own editing out of a table, and the text view reports it as a change (saved, restyled).
    private func replaceTableText(_ range: NSRange, with text: String) {
        guard let textView, let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        applyingTableEdit = true
        storage.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        applyingTableEdit = false
    }

    /// Undoing a table edit: the table that starts at `location` goes back to `markdown`.
    func restoreTable(at location: Int, markdown: String, action: String) {
        guard let textView, let storage = textView.textStorage,
              let found = TableData.at(location, in: storage.string as NSString) else { return }
        let current = (storage.string as NSString).substring(with: found.range)
        undo.registerUndo(withTarget: self) { $0.restoreTable(at: location, markdown: current, action: action) }
        undo.setActionName(action)
        replaceTableText(found.range, with: markdown)
    }

    /// A table's lines replaced, or removed, as one undoable edit.
    func replaceTableLines(_ range: NSRange, with text: String, action: String) {
        guard let textView, let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        let old = (storage.string as NSString).substring(with: range)
        let length = (text as NSString).length
        undo.registerUndo(withTarget: self) { target in
            target.replaceTableLines(NSRange(location: range.location, length: length), with: old, action: action)
        }
        undo.setActionName(action)
        replaceTableText(range, with: text)
    }

    // MARK: Focus

    /// The keyboard goes into the table (the caret reached its lines): to the first or the last row.
    func enterTable(_ block: TableBlock, fromBelow: Bool) {
        let view = block.view
        guard view.window != nil, tableBlocks.contains(where: { $0 === block }) else { return }
        let row = fromBelow ? view.data.rowCount - 1 : 0
        view.focus(TableCell(row: row, column: 0), caret: fromBelow ? .end : .start)
        moveTextSelection(to: NSRange(location: block.range.location, length: 0))
    }

    /// Sets the text view's selection without the table guard taking it for a caret entering a table.
    func moveTextSelection(to range: NSRange) {
        guard let textView else { return }
        movingSelectionForTable = true
        textView.setSelectedRange(range)
        movingSelectionForTable = false
    }

    /// Whether `range` of the text lies in a table's lines in a way only the table may edit: an insertion point or a
    /// selection that touches them without covering them all.
    func isInsideTable(_ range: NSRange) -> TableBlock? {
        tableBlocks.first { block in
            let lines = NSRange(location: block.range.location, length: block.range.length + 1)
            if range.length == 0 { return range.location >= block.range.location && range.location <= NSMaxRange(block.range) }
            let covers = range.location <= block.range.location && NSMaxRange(range) >= NSMaxRange(block.range)
            return !covers && NSIntersectionRange(range, lines).length > 0
        }
    }

    /// The selection moved: one that reaches into a table takes the table whole, or sends the keyboard into it.
    func adjustSelectionForTables(from old: NSRange, to new: NSRange) -> NSRange {
        guard !tableBlocks.isEmpty, !movingSelectionForTable, let textView, !applyingTableEdit else { return new }
        for block in tableBlocks {
            let lines = block.range
            if new.length == 0 {
                guard new.location >= lines.location, new.location <= NSMaxRange(lines) else { continue }
                // Only a key or the mouse puts the keyboard into a table: a note opening with its caret in one does not.
                if let event = NSApp.currentEvent, [.keyDown, .leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type),
                   textView.window?.firstResponder === textView {
                    let fromBelow = old.location > NSMaxRange(lines)
                    DispatchQueue.main.async { [weak self, weak block] in
                        MainActor.assumeIsolated {
                            guard let self, let block else { return }
                            self.enterTable(block, fromBelow: fromBelow)
                        }
                    }
                }
                return new
            }
            let inside = new.location >= lines.location && NSMaxRange(new) <= NSMaxRange(lines)
            if inside {
                // A selection inside the lines (a placeholder the slash menu selected, Select All reaching only
                // them): the cell it is in takes the keyboard with its text selected, or the whole table is selected.
                DispatchQueue.main.async { [weak self, weak block] in
                    MainActor.assumeIsolated {
                        guard let self, let block else { return }
                        self.selectTable(block, covering: new)
                    }
                }
                return new
            }
            let overlaps = NSIntersectionRange(new, NSRange(location: lines.location, length: lines.length + 1)).length > 0
            if overlaps { return NSUnionRange(new, NSRange(location: lines.location, length: lines.length)) }
        }
        return new
    }

    private func selectTable(_ block: TableBlock, covering selection: NSRange) {
        guard let textView, textView.window?.firstResponder === textView else { return }
        let ns = textView.string as NSString
        let view = block.view
        if let row = TableRow.at(selection.location, in: ns), !row.isDelimiter(in: ns),
           NSMaxRange(selection) <= NSMaxRange(row.line) {
            let lineRows = lineIndex(of: row.line.location, in: block)
            let column = (0..<row.cellCount).first { selection.location <= row.bounds[$0 + 1] } ?? 0
            view.focus(TableCell(row: lineRows, column: min(column, view.data.columnCount - 1)), caret: .all)
        } else {
            view.selectAll(nil)
        }
        moveTextSelection(to: NSRange(location: block.range.location, length: 0))
    }

    /// The table row (0 is the header) of the line starting at `location`.
    private func lineIndex(of location: Int, in block: TableBlock) -> Int {
        let ns = (textView?.string ?? "") as NSString
        var index = 0
        var line = ns.lineWithoutBreak(at: block.range.location)
        while line.location < location, NSMaxRange(line) < ns.length {
            line = ns.lineWithoutBreak(at: NSMaxRange(line) + 1)
            index += 1
        }
        // The delimiter line is not a row.
        return min(max(0, index == 0 ? 0 : index - 1), block.view.data.rowCount - 1)
    }

    /// Tells each table whether the text's selection covers it.
    func updateTableSelection() {
        guard let textView else { return }
        let selection = textView.selectedRange()
        for block in tableBlocks {
            block.view.isSelectedAsText = selection.length > 0
                && selection.location <= block.range.location && NSMaxRange(selection) >= NSMaxRange(block.range)
        }
    }
}

extension EditorController: TableBlockViewDelegate {
    var tableUndoManager: UndoManager? { undo }

    func tableView(_ view: TableBlockView, edited data: TableData, action: String, coalescing: Bool) {
        if blockSession != nil { return blockTableEdited(view, data: data, action: action, coalescing: coalescing) }
        guard let block = block(for: view), let textView, let storage = textView.textStorage else { return }
        let range = block.range
        let ns = storage.string as NSString
        guard NSMaxRange(range) <= ns.length else { return }
        let old = ns.substring(with: range)
        let markdown = data.markdown()
        guard old != markdown else { return }
        let merges = coalescing && lastTableTyping.map {
            $0.block === block && $0.cell == view.editing && Date().timeIntervalSince($0.at) < 1.2
        } ?? false
        if !merges, !undo.isUndoing, !undo.isRedoing {
            let location = range.location
            undo.registerUndo(withTarget: self) { $0.restoreTable(at: location, markdown: old, action: action) }
            undo.setActionName(action)
        }
        lastTableTyping = coalescing ? TableTyping(block: block, cell: view.editing, at: Date()) : nil
        block.markdown = markdown
        replaceTableText(range, with: markdown)
        moveTextSelection(to: NSRange(location: block.range.location, length: 0))
    }

    func tableViewDidChangeHeight(_ view: TableBlockView) {
        // Not inside the view's own layout or drawing.
        DispatchQueue.main.async { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view, let block = self.block(for: view), let storage = self.textView?.textStorage,
                      abs(block.markedHeight - view.tableHeight) > 0.5 else { return }
                storage.beginEditing()
                self.mark(block, in: storage)
                storage.endEditing()
                self.positionTableViews()
                self.textView?.needsDisplay = true
            }
        }
    }

    func tableView(_ view: TableBlockView, leave exit: TableExit) {
        if blockSession != nil { return blockTableLeave(view, exit: exit) }
        guard let block = block(for: view), let textView, let storage = textView.textStorage else { return }
        textView.window?.makeFirstResponder(textView)
        let length = storage.length
        let lines = block.range
        switch exit {
        case .above:
            if lines.location > 0 {
                moveTextSelection(to: NSRange(location: lines.location - 1, length: 0))
            } else {
                // A table at the very top: a line of its own above it for the caret.
                undo.registerUndo(withTarget: self) { $0.replaceTableLines(NSRange(location: 0, length: 1), with: "", action: "Add Line") }
                undo.setActionName("Add Line")
                applyingTableEdit = true
                storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n")
                textView.didChangeText()
                applyingTableEdit = false
                moveTextSelection(to: NSRange(location: 0, length: 0))
            }
        case .below:
            let end = NSMaxRange(lines)
            if end >= length {
                undo.registerUndo(withTarget: self) { $0.replaceTableLines(NSRange(location: end, length: 2), with: "", action: "Add Line") }
                undo.setActionName("Add Line")
                applyingTableEdit = true
                storage.replaceCharacters(in: NSRange(location: end, length: 0), with: "\n\n")
                textView.didChangeText()
                applyingTableEdit = false
                moveTextSelection(to: NSRange(location: end + 2, length: 0))
            } else {
                moveTextSelection(to: NSRange(location: min(end + 1, length), length: 0))
            }
        }
        textView.scrollRangeToVisible(textView.selectedRange())
        textView.keepCaretInView()
    }

    func tableViewDelete(_ view: TableBlockView) {
        if blockSession != nil { return blockTableDelete(view) }
        guard let block = block(for: view), let textView, let storage = textView.textStorage else { return }
        var range = block.range
        let ns = storage.string as NSString
        // With the line break that ends it.
        if NSMaxRange(range) < ns.length { range.length += 1 }
        replaceTableLines(range, with: "", action: "Delete Table")
        textView.window?.makeFirstResponder(textView)
        moveTextSelection(to: NSRange(location: min(range.location, storage.length), length: 0))
    }

    func tableView(_ view: TableBlockView, open link: String, modifiers: NSEvent.ModifierFlags) {
        textView?.onOpenLink?(link, modifiers)
    }
}
