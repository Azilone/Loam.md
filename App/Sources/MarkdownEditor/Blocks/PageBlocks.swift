import Foundation

/// The block editor's blocks as the handles, the moves and the folds see them: each paragraph of the page is a block,
/// and a list item holds the items and paragraphs nested under it. Foundation only.
enum PageBlocks {
    /// The page's blocks, in order; a list item's range holds what is nested under it (ranges nest, never cross).
    static func blocks(in storage: NSAttributedString) -> [MarkdownBlock] {
        let paragraphs = BlockStorage.paragraphs(of: storage).filter { $0.length > 0 }
        let blocks = paragraphs.map { BlockStorage.structure(in: storage, at: $0.location) }
        var result: [MarkdownBlock] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let block = blocks[index]
            var end = NSMaxRange(paragraph)
            if let block, block.kind.isListItem {
                var next = index + 1
                while next < paragraphs.count, let inner = blocks[next], inner.quote == block.quote, inner.depth > block.depth {
                    end = NSMaxRange(paragraphs[next])
                    next += 1
                }
            }
            result.append(MarkdownBlock(
                range: NSRange(location: paragraph.location, length: end - paragraph.location),
                firstLine: BlockStorage.content(of: paragraph, in: storage),
                listIndent: block.flatMap { $0.kind.isListItem ? $0.depth : nil }
            ))
        }
        return result
    }

    /// `moved` (whole paragraphs) put before the paragraph at `destination` (the page's length: at the end), as one
    /// edit. Its blocks keep their kinds; their depth follows the place they land in: no deeper than one level under
    /// the item above them, as deep as before when that allows it. Nil when it would not move.
    static func move(_ moved: NSRange, before destination: Int, in storage: NSAttributedString) -> BlockEdit? {
        guard moved.length > 0, NSMaxRange(moved) <= storage.length, destination <= storage.length,
              destination < moved.location || destination > NSMaxRange(moved) else { return nil }
        var piece = BlockStorage.blocks(of: storage.attributedSubstring(from: moved))
        guard !piece.isEmpty else { return nil }
        // The block that will be above the moved ones.
        let above: NoteBlock? = destination > 0 ? BlockEditing.place(at: destination - 1, in: storage)?.block : nil
        let allowed = above.map { $0.kind.isListItem || $0.depth > 0 ? $0.depth + 1 : 0 } ?? 0
        let shift = min(0, allowed - piece[0].depth)
        if shift != 0 { for index in piece.indices { piece[index].depth = max(0, piece[index].depth + shift) } }
        if let above, piece[0].kind.isListItem || piece[0].depth > 0 {
            for index in piece.indices where piece[index].quote != above.quote { piece[index].quote = above.quote }
        }
        let replacement = NSMutableAttributedString()
        let ns = storage.string as NSString
        if destination < moved.location {
            // Up: the moved blocks, then what was between.
            replacement.append(BlockStorage.attributedString(of: piece))
            replacement.append(storage.attributedSubstring(from: NSRange(location: destination, length: moved.location - destination)))
            let range = NSRange(location: destination, length: NSMaxRange(moved) - destination)
            return BlockEdit(range: range, replacement: replacement, selection: NSRange(location: destination, length: 0))
        }
        // Down: what was between, then the moved blocks. A last paragraph without a line break gets one.
        let between = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: NSRange(location: NSMaxRange(moved), length: destination - NSMaxRange(moved))))
        if between.length > 0, !between.string.hasSuffix("\n") {
            between.append(NSAttributedString(string: "\n", attributes: between.attributes(at: between.length - 1, effectiveRange: nil)))
        }
        replacement.append(between)
        let landed = moved.location + replacement.length
        replacement.append(BlockStorage.attributedString(of: piece))
        var range = NSRange(location: moved.location, length: destination - moved.location)
        if destination == ns.length, ns.length > 0, ns.character(at: ns.length - 1) != 10 { range.length = ns.length - moved.location }
        return BlockEdit(range: range, replacement: replacement, selection: NSRange(location: landed, length: 0))
    }

    /// Where Option-Command-Up or Down moves `block`: before the block above it of its level (up), or after the block
    /// below it (down); `.some(nil)` is the end of the page, nil when it is at the top or the bottom already.
    static func keyboardDestination(for block: MarkdownBlock, up: Bool, in blocks: [MarkdownBlock], length: Int) -> Int? {
        let peers = blocks.filter {
            $0.indent <= block.indent && NSIntersectionRange($0.range, block.range).length == 0
        }
        if up { return peers.last(where: { $0.range.location < block.range.location })?.range.location }
        guard let following = peers.first(where: { $0.range.location >= NSMaxRange(block.range) }) else { return nil }
        return peers.first { $0.range.location >= NSMaxRange(following.range) }?.range.location ?? length
    }

    /// The heading sections of the page: a heading folds what follows it, up to the next heading of its level or
    /// higher.
    static func sections(in storage: NSAttributedString) -> [HeadingFolds.Section] {
        sections(of: PageScan(storage).headings, in: storage)
    }

    /// `sections(in:)` from the page's headings, in order.
    static func sections(of headings: [(paragraph: NSRange, level: Int)], in storage: NSAttributedString) -> [HeadingFolds.Section] {
        var sections: [HeadingFolds.Section] = []
        for (index, heading) in headings.enumerated() {
            let start = NSMaxRange(heading.paragraph)
            let end = headings[(index + 1)...].first { $0.level <= heading.level }?.paragraph.location ?? storage.length
            guard end > start else { continue }
            sections.append(HeadingFolds.Section(
                heading: BlockStorage.content(of: heading.paragraph, in: storage), level: heading.level,
                body: NSRange(location: start, length: end - start)
            ))
        }
        return sections
    }
}
