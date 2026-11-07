import AppKit
import PluginKitUI

/// Notion's and Craft's block handle: six dots left of the block under the pointer. A click selects the block whole,
/// a drag moves it (a line in the accent shows where it lands). The text view does the work; the handle only draws.
final class BlockHandleView: NSView {
    static let size = NSSize(width: 18, height: 24)
    /// How far left of a block's text it stands.
    static let offset: CGFloat = 24

    var dotColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var hoverColor: NSColor = .quaternaryLabelColor
    var onMouseDown: ((NSEvent) -> Void)?
    /// The block it stands for.
    var block: MarkdownBlock?

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            hoverColor.setFill()
            NSBezierPath(continuousRoundedRect: bounds, radius: Corners.r(4)).fill()
        }
        dotColor.setFill()
        let dot: CGFloat = 2.6
        let gap: CGFloat = 5
        let originX = bounds.midX - gap / 2 - dot / 2
        let originY = bounds.midY - gap - dot / 2
        for column in 0..<2 {
            for row in 0..<3 {
                let rect = NSRect(x: originX + CGFloat(column) * gap, y: originY + CGFloat(row) * gap, width: dot, height: dot)
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }

    func show() {
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appKitDuration(0.12)
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        isHovered = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appKitDuration(0.12)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            if self?.alphaValue == 0 { self?.isHidden = true }
        }
    }
}

extension EditorTextView {
    /// The note's blocks, worked out again only when the text changed.
    var markdownBlocks: [MarkdownBlock] {
        // The block editor's blocks are its paragraphs: their kinds are in the attributes, which change without the
        // text changing.
        if blockMode, let storage = textStorage { return PageBlocks.blocks(in: storage) }
        let text = string
        if let cached = cachedBlocks, cached.text == text { return cached.blocks }
        let blocks = BlockMoving.blocks(in: text)
        cachedBlocks = (text, blocks)
        return blocks
    }

    /// The column's left edge and width, in view coordinates.
    private var column: (left: CGFloat, width: CGFloat)? {
        guard let container = textContainer else { return nil }
        return (textContainerOrigin.x + container.lineFragmentPadding, container.size.width - 2 * container.lineFragmentPadding)
    }

    /// The block whose lines are at `point`'s height, in or left of the column; nil over a blank line.
    func block(at point: NSPoint) -> MarkdownBlock? {
        guard let column, let storage = textStorage, storage.length > 0,
              point.x >= column.left - BlockHandleView.offset - BlockHandleView.size.width, point.x <= column.left + column.width
        else { return nil }
        let index = characterIndexForInsertion(at: NSPoint(x: column.left + 1, y: point.y))
        guard let block = BlockMoving.block(at: index, in: markdownBlocks, text: storage.string),
              let box = blockBox(for: block.range), point.y >= box.minY - 2, point.y <= box.maxY + 2 else { return nil }
        return block
    }

    /// The room a block takes: its lines, and the pictures and live views drawn under them (in their paragraph
    /// spacing), so a drop line goes past a picture, not through it.
    func blockBox(for range: NSRange) -> NSRect? {
        guard var box = lineBox(for: range), let storage = textStorage else { return nil }
        let searched = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        var marks: [ObjectIdentifier] = []
        for key in [NSAttributedString.Key.markdownPicture, .markdownLiveBlock] {
            storage.enumerateAttribute(key, in: searched) { value, _, _ in
                if let mark = value as? NSObject { marks.append(ObjectIdentifier(mark)) }
            }
        }
        guard !marks.isEmpty else { return box }
        let frames: [(NSObject, NSRect)] = pictureFrames(near: searched).map { ($0.0, $0.1) }
            + (blockFrames(.markdownLiveBlock, near: searched) as [(LiveBlockMark, NSRect)]).map { ($0.0, $0.1) }
        for (mark, frame) in frames where marks.contains(ObjectIdentifier(mark)) { box = box.union(frame) }
        return box
    }

    /// The first row of the block's first line, and where the block starts: where the handle and a drop line go.
    private func firstRow(of block: MarkdownBlock) -> (row: NSRect, textX: CGFloat)? {
        guard let column, let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: block.firstLine.location),
              let fragment = layout.textLayoutFragment(for: start), let line = fragment.textLineFragments.first else { return nil }
        let origin = fragment.layoutFragmentFrame.origin
        var row = line.typographicBounds.offsetBy(dx: origin.x + textContainerOrigin.x, dy: origin.y + textContainerOrigin.y)
        let first = NSRange(location: block.firstLine.location, length: min(1, block.firstLine.length))
        // A block drawn as a picture or a view has its lines hidden, with no height: the handle stands by the top of
        // what is drawn, as by a first line of text.
        if row.height < 1, let box = blockBox(for: block.range),
           let drawn = (pictureFrames(near: block.range).map(\.1)
               + (blockFrames(.markdownLiveBlock, near: block.range) as [(LiveBlockMark, NSRect)]).map(\.1))
               .first(where: { abs($0.maxY - box.maxY) < 1 }) {
            let font = theme.bodyFont
            row = NSRect(x: row.minX, y: drawn.minY, width: row.width,
                         height: (font.ascender - font.descender + font.leading) * max(theme.lineHeightMultiple, 1))
        }
        // A quote's bar and a code block's card start at the column's edge, left of their indented text: the block
        // starts there, so the handle stands left of the bar, not on it.
        if first.length > 0, [.markdownQuote, .markdownCodeBlock].contains(where: {
            storage.attribute($0, at: first.location, effectiveRange: nil) != nil
        }) {
            return (row, column.left)
        }
        // In the block editor a list item's marker (a dot, a box) is drawn left of its text: the handle stands left of
        // the marker, so a click on a box checks it.
        if blockMode, let page = (storage.attribute(.noteBlock, at: min(block.firstLine.location, max(storage.length - 1, 0)), effectiveRange: nil)
            as? BlockAttribute)?.block, page.kind.isListItem {
            return (row, max(markerX(of: page), column.left))
        }
        // A list item's text starts at its marker (a dot, a box), indented as deep as it is nested.
        let x = first.length > 0 ? segments(for: first).first?.minX ?? column.left : column.left
        return (row, max(x, column.left))
    }

    /// Shows the handle by the block under `point`, and hides it elsewhere.
    func updateBlockHandle(at point: NSPoint?) {
        // Over a selected picture's resize handle the block handle stays as it is: showing or hiding it rebuilds the
        // window's cursor rectangles, and the resize pointer flickered with the text's I-beam each time.
        if let point, let (_, frame) = selectedResizablePicture(), ResizeHandle.hit(point, on: frame) != nil { return }
        // Over the handle shown, it stays by its block: between two close blocks (two tasks) its edge reaches the next
        // one's lines, and it went from one block to the other at each move, its hand flickering with the I-beam.
        if let point, !blockHandle.isHidden, blockHandle.alphaValue > 0, blockHandle.frame.contains(point),
           let shown = blockHandle.block, markdownBlocks.contains(shown) {
            return blockHandle.show()
        }
        guard isEditable, let point, let block = block(at: point), !chevronReplacesHandle(on: block),
              let (row, textX) = firstRow(of: block) else {
            return blockHandle.hide()
        }
        if blockHandle.superview !== self {
            blockHandle.alphaValue = 0
            blockHandle.isHidden = true
            blockHandle.onMouseDown = { [weak self] event in self?.pressBlockHandle(with: event) }
            addSubview(blockHandle, positioned: .above, relativeTo: nil)
        }
        blockHandle.dotColor = theme.secondaryTextColor.withAlphaComponent(0.7)
        blockHandle.hoverColor = theme.textColor.withAlphaComponent(0.08)
        blockHandle.block = block
        let size = BlockHandleView.size
        let frame = NSRect(x: textX - BlockHandleView.offset, y: textMidY(row) - size.height / 2, width: size.width, height: size.height)
        if blockHandle.frame != frame {
            blockHandle.frame = frame
            window?.invalidateCursorRects(for: blockHandle)
        }
        blockHandle.show()
    }

    func hideBlockHandle() { blockHandle.hide() }

    /// A press on the handle: a drag moves the block to the line shown under the pointer, a click selects it.
    private func pressBlockHandle(with event: NSEvent) {
        guard let window, let block = blockHandle.block else { return }
        let start = event.locationInWindow
        var dragging = false
        var target: MarkdownBlock??
        defer { dropLine.isHidden = true }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            if !dragging, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) < 3 { continue }
            if !dragging {
                dragging = true
                NSCursor.closedHand.push()
                Haptics.levelChange()
                Sounds.play(.pickedUp)
            }
            // The text's cursor rects (its I-beam) still fire under the pointer while the loop runs: the hand stays.
            NSCursor.closedHand.set()
            autoscroll(with: next)
            let landing = dropTarget(for: block, at: convert(next.locationInWindow, from: nil))
            // A tick each time the drop line goes to another place between the blocks.
            if landing != nil, landing != target { Haptics.alignment() }
            target = landing
        }
        if dragging {
            NSCursor.pop()
            blockHandle.hide()
            if let target {
                onMoveBlock?(block, target)
                Haptics.alignment()
                Sounds.play(.dropped)
            }
            return
        }
        // A click: the block selected whole, ready to copy, cut or delete.
        var range = block.range
        let ns = string as NSString
        while range.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        window.makeFirstResponder(self)
        setSelectedRange(range)
        blockSelection = BlockSelection(block: block, range: selectedRange())
    }

    /// Craft's selected block: a tint behind the whole block (its box or dot, the items nested in it, a picture under
    /// it), in the selection's colour, where selected text would leave the box hidden under its highlight.
    func drawBlockSelection() {
        guard let selection = blockSelection, selectedRange() == selection.range, let column,
              let box = blockBox(for: selection.block.range), let (row, textX) = firstRow(of: selection.block) else { return }
        // From where the first row's text starts (the line height's extra room sits above the glyphs) to the block's end.
        let top = row.minY + row.height * (1 - 1 / max(theme.lineHeightMultiple, 1))
        let left = textX - 6
        let tint = NSRect(x: left, y: top - 3, width: column.left + column.width + 6 - left, height: box.maxY - top + 6)
        let active = window?.isKeyWindow == true && window?.firstResponder === self
        (active ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        NSBezierPath(continuousRoundedRect: tint, radius: Corners.r(6)).fill()
    }

    /// The last line with text before `location`, without its break; nil at the top of the note.
    private func lineAbove(_ location: Int) -> NSRange? {
        let ns = string as NSString
        var end = min(location, ns.length)
        while end > 0 {
            let line = ns.lineWithoutBreak(at: end - 1)
            if !ns.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty { return line }
            end = line.location
        }
        return nil
    }

    /// Where a block dragged to `point` lands (the block it goes before, nil for the end of the note), shown by a line
    /// in the accent; nil where it cannot land.
    func dropTarget(for block: MarkdownBlock, at point: NSPoint) -> MarkdownBlock?? {
        guard let column else { return nil }
        let drawn = drawnRange()
        let blocks = markdownBlocks
        var best: (target: MarkdownBlock?, y: CGFloat, x: CGFloat)?
        func consider(_ target: MarkdownBlock?, y: CGFloat, x: CGFloat) {
            if best == nil || abs(y - point.y) < abs(best!.y - point.y) { best = (target, y, x) }
        }
        let multiple = max(theme.lineHeightMultiple, 1)
        for (index, candidate) in blocks.enumerated() where !NSLocationInRange(candidate.range.location, block.range) {
            guard NSIntersectionRange(candidate.range, drawn).length > 0 || NSLocationInRange(candidate.range.location, drawn),
                  let (row, textX) = firstRow(of: candidate) else { continue }
            // The line stands in the gap above the block, half way between the line over it and its own text (the
            // line height's extra room sits above the glyphs), not on the top of its first row. The line over it, not
            // the block before it: a nested item's block before it is its parent's sibling, above the parent's own
            // text, and half way to it was through the parent.
            let top = row.minY + row.height * (1 - 1 / multiple)
            let above = lineAbove(candidate.range.location).flatMap { blockBox(for: $0) }
            consider(candidate, y: above.map { ($0.maxY + top) / 2 } ?? top - 4, x: textX)
        }
        if let last = blocks.last, NSMaxRange(last.range) >= NSMaxRange(drawn) - 1, let box = blockBox(for: last.range) {
            consider(nil, y: box.maxY + 4, x: column.left)
        }
        guard let best else {
            dropLine.isHidden = true
            return nil
        }
        if dropLine.superview !== self { addSubview(dropLine, positioned: .above, relativeTo: nil) }
        dropLine.layer?.backgroundColor = theme.accentColor.cgColor
        dropLine.frame = NSRect(x: best.x, y: best.y - 1, width: column.left + column.width - best.x, height: 2)
        dropLine.isHidden = false
        return .some(best.target)
    }
}
