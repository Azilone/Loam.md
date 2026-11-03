import PluginKitUI
import AppKit

/// What the block editor draws in a paragraph's margin from its block, not from characters: a bullet's dot, a
/// task's round box, a numbered item's number, a callout's label, and the cards of tables and embeds until they show
/// their component; inside the text, the chips of atoms.
extension EditorTextView {
    /// The column's left edge, where indents start.
    var columnLeft: CGFloat { textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) }

    /// Where a list item's marker starts, from the column's left edge.
    func markerX(of block: NoteBlock) -> CGFloat {
        columnLeft + CGFloat(block.quote) * theme.quoteIndent + CGFloat(block.depth) * theme.listIndent
    }

    func drawBlockDecorations(in drawn: NSRange) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let start = ns.paragraphRange(for: NSRange(location: min(drawn.location, ns.length - 1), length: 0)).location
        var location = start
        while location < min(NSMaxRange(drawn) + 1, ns.length) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            guard let block = (storage.attribute(.noteBlock, at: paragraph.location, effectiveRange: nil) as? BlockAttribute)?.block,
                  let box = lineBox(for: NSRange(location: paragraph.location, length: 1)) else { continue }
            switch block.kind {
            case .bullet:
                let size: CGFloat = 5.5
                theme.textColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: markerX(of: block) + 4.5, y: textMidY(box) - size / 2, width: size, height: size)).fill()
            case .task(let checked):
                drawTaskBox(checked: checked, x: markerX(of: block) + 1, midY: textMidY(box), height: box.height)
            case .numbered:
                let number = "\(number(ofItemAt: paragraph, in: storage))." as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: theme.bodyFont, .foregroundColor: theme.textColor]
                let size = number.size(withAttributes: attributes)
                number.draw(at: NSPoint(x: markerX(of: block) + 2, y: textMidY(box) - size.height / 2), withAttributes: attributes)
            case .table, .embed, .code:
                guard let label = storage.attribute(.blockPlaceholder, at: paragraph.location, effectiveRange: nil) as? String else { break }
                drawPlaceholder(label, kind: block.kind, in: box)
            default:
                break
            }
            let fold = storage.attribute(.blockFold, at: paragraph.location, effectiveRange: nil) as? BlockFold
            if let fold, fold.isDetails, let whole = lineBox(for: BlockStorage.content(of: paragraph, in: storage)) {
                drawFoldTitle(fold, at: NSPoint(x: markerX(of: block), y: whole.midY), color: theme.textColor,
                              font: theme.bodyFont(size: theme.fontSize, weight: .medium))
            }
            if let callout = block.callout, callout.opens {
                let kind = MarkdownTheme.alertKind("[!\(callout.kind)]")
                let title = fold?.title ?? callout.title.trimmingCharacters(in: .whitespaces)
                let label = (title.isEmpty ? callout.kind.uppercased() : title) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: theme.bodyFont(size: theme.fontSize * 0.8, weight: .bold),
                    .foregroundColor: MarkdownTheme.alertColor(kind, accent: theme.accentColor),
                    .kern: 0.6,
                ]
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: columnLeft + theme.quoteIndent, y: box.minY - size.height - 2), withAttributes: attributes)
                if let fold {
                    drawChevron(folded: fold.folded, at: NSPoint(x: columnLeft + theme.quoteIndent + size.width + 10, y: box.minY - size.height / 2 - 2),
                                color: attributes[.foregroundColor] as? NSColor ?? theme.textColor)
                }
            }
        }
        storage.enumerateAttribute(.blockAtomText, in: NSIntersectionRange(drawn, whole)) { value, range, _ in
            guard let text = value as? NSAttributedString, text.length > 0 else { return }
            for segment in segments(for: range) {
                drawAtomText(text, at: segment)
            }
        }
        storage.enumerateAttribute(.blockAtomLabel, in: NSIntersectionRange(drawn, whole)) { value, range, _ in
            guard let label = value as? String else { return }
            for segment in segments(for: range) {
                drawAtomChip(label, at: segment)
            }
        }
    }

    /// The number a numbered item shows: its list's first number plus the items of its level above it.
    func number(ofItemAt paragraph: NSRange, in storage: NSTextStorage) -> Int {
        let ns = storage.string as NSString
        guard let block = (storage.attribute(.noteBlock, at: paragraph.location, effectiveRange: nil) as? BlockAttribute)?.block,
              case .numbered(var start) = block.kind else { return 1 }
        var count = 0
        var location = paragraph.location
        while location > 0 {
            let previous = ns.paragraphRange(for: NSRange(location: location - 1, length: 0))
            location = previous.location
            guard let above = (storage.attribute(.noteBlock, at: previous.location, effectiveRange: nil) as? BlockAttribute)?.block,
                  above.quote == block.quote, above.kind.isListItem || above.depth > 0 else { break }
            if above.depth > block.depth || (above.depth == block.depth && !above.kind.isListItem) { continue }
            guard above.depth == block.depth, case .numbered(let first) = above.kind else { break }
            count += 1
            start = first
        }
        return start + count
    }

    private func drawTaskBox(checked: Bool, x: CGFloat, midY: CGFloat, height: CGFloat) {
        let size = min(height, 16)
        let circle = NSRect(x: x, y: midY - size / 2, width: size, height: size)
        let square = theme.squareCheckboxes
        let shape = { (rect: NSRect) in
            square ? NSBezierPath(continuousRoundedRect: rect, radius: Corners.r(rect.width * 0.28)) : NSBezierPath(ovalIn: rect)
        }
        if checked {
            (theme.checkboxColor ?? theme.accentColor).setFill()
            shape(circle).fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: circle.minX + size * 0.28, y: circle.midY))
            tick.line(to: NSPoint(x: circle.minX + size * 0.44, y: circle.minY + size * 0.68))
            tick.line(to: NSPoint(x: circle.minX + size * 0.74, y: circle.minY + size * 0.32))
            tick.lineWidth = 1.6
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            let ring = shape(circle.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            (theme.checkboxBorderColor ?? theme.secondaryTextColor.withAlphaComponent(0.6)).setStroke()
            ring.stroke()
        }
    }

    private func drawPlaceholder(_ label: String, kind: BlockKind, in box: NSRect) {
        guard let container = textContainer else { return }
        let card = NSRect(x: columnLeft, y: box.minY + 2, width: container.size.width - 2 * container.lineFragmentPadding, height: box.height - 4)
        let path = NSBezierPath(continuousRoundedRect: card, radius: Corners.r(8))
        theme.codeBackgroundColor.setFill()
        path.fill()
        theme.textColor.withAlphaComponent(0.07).setStroke()
        path.lineWidth = 1
        path.stroke()
        let symbol = switch kind {
        case .table: "▦  "
        case .embed: "◧  "
        default: "◇  "
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont(size: theme.fontSize * 0.87, weight: .medium),
            .foregroundColor: theme.secondaryTextColor,
        ]
        let text = (symbol + label) as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: card.minX + 14, y: card.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawAtomChip(_ label: String, at segment: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: theme.bodyFont(size: theme.fontSize * 0.8, weight: .regular),
            .foregroundColor: theme.secondaryTextColor,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        let chip = NSRect(x: segment.minX + 1, y: textMidY(segment) - size.height / 2 - 1, width: size.width + 6, height: size.height + 2)
        let path = NSBezierPath(continuousRoundedRect: chip, radius: Corners.r(4))
        theme.codeBackgroundColor.setFill()
        path.fill()
        (label as NSString).draw(at: NSPoint(x: chip.minX + 3, y: chip.minY + 1), withAttributes: attributes)
    }

    /// An atom drawn as text in the room its character keeps (`MarkdownTheme.pillGap` on each side): on the line's
    /// baseline, as the text around it.
    private func drawAtomText(_ text: NSAttributedString, at segment: NSRect) {
        // The text view is flipped: the line's baseline sits below its middle by half the body's cap room.
        let baseline = textMidY(segment) + (theme.bodyFont.ascender + theme.bodyFont.descender) / 2
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), &ascent, nil, nil)
        text.draw(at: NSPoint(x: segment.minX + MarkdownTheme.pillGap, y: baseline - ascent))
    }

    /// A `<details>` summary: a chevron, then its title.
    private func drawFoldTitle(_ fold: BlockFold, at origin: NSPoint, color: NSColor, font: NSFont) {
        drawChevron(folded: fold.folded, at: NSPoint(x: origin.x + 6, y: origin.y), color: theme.secondaryTextColor)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (fold.title as NSString).size(withAttributes: attributes)
        (fold.title as NSString).draw(at: NSPoint(x: origin.x + 18, y: origin.y - size.height / 2), withAttributes: attributes)
    }

    /// A small chevron centred on `center`: pointing right when folded, down when open.
    private func drawChevron(folded: Bool, at center: NSPoint, color: NSColor) {
        let path = NSBezierPath()
        let r: CGFloat = 3.5
        if folded {
            path.move(to: NSPoint(x: center.x - r / 2, y: center.y - r))
            path.line(to: NSPoint(x: center.x + r / 2, y: center.y))
            path.line(to: NSPoint(x: center.x - r / 2, y: center.y + r))
        } else {
            path.move(to: NSPoint(x: center.x - r, y: center.y - r / 2))
            path.line(to: NSPoint(x: center.x, y: center.y + r / 2))
            path.line(to: NSPoint(x: center.x + r, y: center.y - r / 2))
        }
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// The fold whose title is under `point` (a `<details>` summary's line, a folding callout's label): its block.
    func blockFoldTitle(at point: NSPoint) -> NoteBlock.ID? {
        guard let storage = textStorage, storage.length > 0, let container = textContainer else { return nil }
        let ns = storage.string as NSString
        var found: NoteBlock.ID?
        storage.enumerateAttribute(.blockFold, in: NSRange(location: 0, length: ns.length)) { value, range, stop in
            guard let fold = value as? BlockFold, let box = lineBox(for: NSRange(location: range.location, length: 1)) else { return }
            let lines = fold.isDetails ? lineBox(for: BlockStorage.content(of: ns.paragraphRange(for: range), in: storage)) ?? box : box
            let hit = fold.isDetails
                ? NSRect(x: columnLeft, y: lines.minY, width: container.size.width, height: lines.height)
                : NSRect(x: columnLeft, y: box.minY - theme.calloutLabelHeight - 6, width: container.size.width, height: theme.calloutLabelHeight + 6)
            if hit.contains(point) {
                found = fold.id
                stop.pointee = true
            }
        }
        return found
    }

    /// The component card under `point` (a diagram not drawn yet or that does not draw): its character's location.
    func blockComponentCard(at point: NSPoint) -> Int? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: min(index, ns.length - 1), length: 0))
        guard let block = (storage.attribute(.noteBlock, at: paragraph.location, effectiveRange: nil) as? BlockAttribute)?.block,
              case .code = block.kind, storage.attribute(.blockPlaceholder, at: paragraph.location, effectiveRange: nil) != nil,
              let box = lineBox(for: NSRange(location: paragraph.location, length: 1)), box.insetBy(dx: 0, dy: -4).contains(NSPoint(x: box.midX, y: point.y))
        else { return nil }
        return paragraph.location
    }

    /// The task whose round box is under `point`: its paragraph.
    func blockTaskBox(at point: NSPoint) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: min(index, ns.length - 1), length: 0))
        guard let block = (storage.attribute(.noteBlock, at: paragraph.location, effectiveRange: nil) as? BlockAttribute)?.block,
              case .task = block.kind, let box = lineBox(for: NSRange(location: paragraph.location, length: 1)) else { return nil }
        let x = markerX(of: block)
        let hit = NSRect(x: x - 4, y: box.minY, width: theme.listIndent + 2, height: box.height)
        return hit.contains(point) ? paragraph : nil
    }
}
