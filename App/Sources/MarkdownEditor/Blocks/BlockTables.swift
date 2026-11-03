import AppKit

/// The block editor's tables: a table block is one character in the page; its view (`TableBlockView`, the same as
/// the old editor's) sits in the room under it and edits the block's Markdown, `| a | b |` lines, as cells.
extension EditorController {
    /// The Markdown of a table block's text, its lines joined by line breaks.
    static func tableMarkdown(_ block: NoteBlock) -> String {
        block.text.string.replacingOccurrences(of: String(InlineText.lineBreak), with: "\n")
    }

    /// Shows every table block of the page: called after each styling, with all of them. Views follow their table
    /// from one styling to the next: matched by their Markdown, else by their rank.
    func applyBlockTables() {
        guard let textView, let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        var found: [(location: Int, table: TableData, markdown: String)] = []
        var seen = Set<ObjectIdentifier>()
        if storage.length > 0 {
            storage.enumerateAttribute(.noteBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let attribute = value as? BlockAttribute, attribute.block.kind == .table,
                      seen.insert(ObjectIdentifier(attribute)).inserted else { return }
                let content = BlockStorage.content(of: ns.paragraphRange(for: range), in: storage)
                let markdown = Self.tableMarkdown(attribute.block)
                guard content.length == 1,
                      let (table, _) = TableData.parse(NSRange(location: 0, length: (markdown as NSString).length), in: markdown as NSString)
                else { return }
                found.append((content.location, table, markdown))
            }
        }
        var old = tableBlocks
        var kept: [TableBlock?] = found.map { entry in
            guard let index = old.firstIndex(where: { $0.markdown == entry.markdown }) else { return nil }
            return old.remove(at: index)
        }
        for index in kept.indices where kept[index] == nil && !old.isEmpty { kept[index] = old.removeFirst() }
        for gone in old { gone.view.removeFromSuperview() }
        var blocks: [TableBlock] = []
        storage.beginEditing()
        for (index, entry) in found.enumerated() {
            let block = kept[index] ?? TableBlock(range: NSRange(location: entry.location, length: 1), markdown: entry.markdown)
            block.range = NSRange(location: entry.location, length: 1)
            block.markdown = entry.markdown
            block.view.delegate = self
            block.view.update(entry.table, width: textView.columnWidth, theme: theme, fractions: nil)
            blocks.append(block)
            // The character takes no room; the paragraph's spacing below it is the table's.
            // Only what changed is set: any attribute set again lays the table's paragraph out again, and the page
            // jumped on each keystroke.
            storage.setIfChanged(MarkdownTheme.concealed, range: block.range)
            storage.removeIfPresent(.blockPlaceholder, range: block.range)
            let paragraph = ns.paragraphRange(for: block.range)
            if let style = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle {
                style.minimumLineHeight = 0
                style.paragraphSpacingBefore = 0
                style.paragraphSpacing = block.view.tableHeight + 2 * PictureMark.margin
                storage.setIfChanged([.paragraphStyle: style], range: paragraph)
            }
            storage.setIfChanged([.markdownTableBlock: TableMark(block: block, size: NSSize(width: textView.columnWidth, height: block.view.tableHeight))],
                                 range: block.range)
            block.markedHeight = block.view.tableHeight
        }
        storage.endEditing()
        tableBlocks = blocks
        for block in blocks where block.view.superview == nil { textView.addSubview(block.view) }
        positionTableViews()
    }

    /// The table block whose view is `view`, with its paragraph and its block as the page holds them now.
    private func blockTable(for view: TableBlockView) -> (table: TableBlock, paragraph: NSRange, block: NoteBlock)? {
        guard let table = tableBlocks.first(where: { $0.view === view }), let storage = textView?.textStorage,
              table.range.location < storage.length else { return nil }
        let paragraph = (storage.string as NSString).paragraphRange(for: table.range)
        guard let block = BlockStorage.block(in: storage, paragraph: paragraph), block.kind == .table else { return nil }
        return (table, paragraph, block)
    }

    /// A table's cells changed: its block takes the Markdown, one undo step per edit (a run of typing in a cell is
    /// one).
    func blockTableEdited(_ view: TableBlockView, data: TableData, action: String, coalescing: Bool) {
        guard let (table, paragraph, block) = blockTable(for: view) else { return }
        let markdown = data.markdown()
        let old = Self.tableMarkdown(block)
        guard markdown != old else { return }
        let merges = coalescing && lastTableTyping.map {
            $0.block === table && $0.cell == view.editing && Date().timeIntervalSince($0.at) < 1.2
        } ?? false
        if !merges, !undo.isUndoing, !undo.isRedoing {
            let location = paragraph.location
            undo.registerUndo(withTarget: self) { $0.restoreBlockTable(at: location, markdown: old, action: action) }
            undo.setActionName(action)
        }
        lastTableTyping = coalescing ? TableTyping(block: table, cell: view.editing, at: Date()) : nil
        table.markdown = markdown
        replaceTableBlock(at: paragraph, with: markdown)
    }

    /// Undoing a table's edit: its block goes back to `markdown`, and the redo is registered.
    func restoreBlockTable(at location: Int, markdown: String, action: String) {
        guard let storage = textView?.textStorage, location < storage.length else { return }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        guard let block = BlockStorage.block(in: storage, paragraph: paragraph), block.kind == .table else { return }
        let current = Self.tableMarkdown(block)
        undo.registerUndo(withTarget: self) { $0.restoreBlockTable(at: location, markdown: current, action: action) }
        undo.setActionName(action)
        replaceTableBlock(at: paragraph, with: markdown)
    }

    /// The table block at `paragraph` holds `markdown` now: written to the page past the text view's own undo (the
    /// table registers its own), saved as any change.
    private func replaceTableBlock(at paragraph: NSRange, with markdown: String) {
        guard let textView, let storage = textView.textStorage, let blockSession,
              var block = BlockStorage.block(in: storage, paragraph: paragraph) else { return }
        block.text = InlineText(markdown.replacingOccurrences(of: "\n", with: String(InlineText.lineBreak)))
        let selection = textView.selectedRange()
        blockSession.replaceWithoutUndo(paragraph, with: BlockStorage.paragraph(of: block))
        moveTextSelection(to: selection.location <= storage.length ? selection : NSRange(location: paragraph.location, length: 0))
    }

    /// The keyboard leaves a table: the caret goes to the block above or below it, or to a new paragraph there when
    /// there is none.
    func blockTableLeave(_ view: TableBlockView, exit: TableExit) {
        guard let textView, let blockSession, let storage = textView.textStorage,
              let (_, paragraph, block) = blockTable(for: view) else { return }
        textView.window?.makeFirstResponder(textView)
        switch exit {
        case .above:
            if paragraph.location > 0 {
                moveTextSelection(to: NSRange(location: paragraph.location - 1, length: 0))
            } else {
                let new = BlockEditing.sibling(of: block, kind: .paragraph)
                blockSession.apply(BlockEdit(range: NSRange(location: 0, length: 0), replacement: BlockStorage.paragraph(of: new),
                                             selection: NSRange(location: 0, length: 0)))
            }
        case .below:
            let end = NSMaxRange(paragraph)
            if end < storage.length {
                moveTextSelection(to: NSRange(location: end, length: 0))
            } else {
                let new = BlockEditing.sibling(of: block, kind: .paragraph)
                blockSession.apply(BlockEdit(range: NSRange(location: end, length: 0), replacement: BlockStorage.paragraph(of: new),
                                             selection: NSRange(location: end, length: 0)))
            }
        }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// The table's Delete: its block goes, as one edit.
    func blockTableDelete(_ view: TableBlockView) {
        guard let textView, let blockSession, let (_, paragraph, _) = blockTable(for: view) else { return }
        textView.window?.makeFirstResponder(textView)
        blockSession.apply(BlockEdit(range: paragraph, replacement: NSAttributedString(),
                                     selection: NSRange(location: paragraph.location, length: 0)))
    }
}
