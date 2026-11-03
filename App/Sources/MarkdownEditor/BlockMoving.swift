import Foundation

/// A note seen as Notion's and Craft's blocks, over plain Markdown: a heading, a paragraph, a list item (with the
/// items nested under it), a quote, a code block, a table, a divider. The file stays Markdown; a block is only the
/// lines one piece of it takes, so it can be picked up whole by its handle and moved.
public struct MarkdownBlock: Equatable, Sendable {
    /// Its whole lines, with the last line's break when it has one.
    public let range: NSRange
    /// Its first line, without the break: where its handle stands.
    public let firstLine: NSRange
    /// The list item's indent in columns; nil for anything but a list item.
    public let listIndent: Int?

    var indent: Int { listIndent ?? 0 }
}

public enum BlockMoving {
    /// The note's blocks, in order. A list item's block holds the items under it, which are blocks of their own too:
    /// the ranges nest, never cross. Blank lines and the frontmatter belong to none.
    public static func blocks(in text: String) -> [MarkdownBlock] {
        let ns = text as NSString
        var lines: [NSRange] = []
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            lines.append(line)
            location = NSMaxRange(line)
        }
        func content(_ index: Int) -> String { ns.substring(with: ns.lineWithoutBreak(at: lines[index].location)) }
        func isBlank(_ index: Int) -> Bool { content(index).trimmingCharacters(in: .whitespaces).isEmpty }
        func block(_ first: Int, _ last: Int, listIndent: Int? = nil) -> MarkdownBlock {
            let range = NSRange(location: lines[first].location, length: NSMaxRange(lines[last]) - lines[first].location)
            return MarkdownBlock(range: range, firstLine: ns.lineWithoutBreak(at: lines[first].location), listIndent: listIndent)
        }

        var blocks: [MarkdownBlock] = []
        var index = 0
        // The frontmatter is the note's properties, not a block.
        if !lines.isEmpty, content(0) == "---", let close = (1..<lines.count).first(where: { content($0) == "---" }) {
            index = close + 1
        }
        // The last line of the list items read so far: a line in it that starts no item is part of an item.
        var itemsEnd = -1
        while index < lines.count {
            if isBlank(index) || (index <= itemsEnd && listIndent(content(index)) == nil) {
                index += 1
                continue
            }
            let line = content(index)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = fence(trimmed) {
                var end = index + 1
                while end < lines.count, !content(end).trimmingCharacters(in: .whitespaces).hasPrefix(fence) { end += 1 }
                end = min(end, lines.count - 1)
                blocks.append(block(index, end))
                index = end + 1
            } else if let indent = listIndent(line) {
                // The item, its wrapped and indented lines, and the items nested under it.
                var end = index
                var next = index + 1
                while next < lines.count {
                    if isBlank(next) {
                        // A blank line inside the item only when an indented line follows it.
                        let after = (next + 1..<lines.count).first { !isBlank($0) }
                        guard let after, leadingColumns(content(after)) > indent else { break }
                        next = after
                        continue
                    }
                    let text = content(next)
                    // Deeper lines, and a paragraph's lazy lines right under it, are the item's.
                    guard leadingColumns(text) > indent || !isBlockStart(text) else { break }
                    end = next
                    next += 1
                }
                blocks.append(block(index, end, listIndent: indent))
                itemsEnd = max(itemsEnd, end)
                // The nested items are blocks too: they are read inside the parent's lines.
                index += 1
            } else if trimmed.hasPrefix("|") || trimmed.hasPrefix(">") {
                let marker = trimmed.first
                var end = index
                while end + 1 < lines.count, content(end + 1).trimmingCharacters(in: .whitespaces).first == marker { end += 1 }
                blocks.append(block(index, end))
                index = end + 1
            } else if isSingleLine(trimmed) {
                blocks.append(block(index, index))
                index += 1
            } else {
                // A paragraph: up to a blank line or the start of another kind of block.
                var end = index
                while end + 1 < lines.count, !isBlank(end + 1), !isBlockStart(content(end + 1)) { end += 1 }
                blocks.append(block(index, end))
                index = end + 1
            }
        }
        return blocks
    }

    /// The innermost block whose lines hold `location` (the end of a last line without a break included); a
    /// location on a blank line has none.
    public static func block(at location: Int, in blocks: [MarkdownBlock], text: String) -> MarkdownBlock? {
        let ns = text as NSString
        return blocks.filter {
            NSLocationInRange(location, $0.range)
                || (location == NSMaxRange($0.range) && location == ns.length && !text.hasSuffix("\n"))
        }
        .min { $0.range.length < $1.range.length }
    }

    /// Moves `block` before `target` (nil: to the end of the note), as one edit. The block's lines go whole; the
    /// lines around keep the blank lines they had, with one added where Markdown would otherwise glue two blocks
    /// together (a paragraph under a list item would become part of it). The block takes its own spacing along: a
    /// blank line under it only when it had one (above it, for the note's last block), so a heading set right on its
    /// text, moved away and back, is right on it again. A list item takes the indent of the items it lands among.
    /// Nil when it would not move (onto itself, or into itself).
    public static func move(_ block: MarkdownBlock, before target: MarkdownBlock?, in text: String) -> TextEdit? {
        let ns = text as NSString
        let all = blocks(in: text)
        var target = target
        // Anything but an item dropped among an item's nested items would split the item: it goes under the list.
        if block.listIndent == nil, let nested = target,
           let root = all.filter({ $0.listIndent != nil && $0.range.location < nested.range.location && NSLocationInRange(nested.range.location, $0.range) }).min(by: { $0.range.location < $1.range.location }) {
            target = all.first { $0.range.location >= NSMaxRange(root.range) && !overlaps($0, block) }
        }
        if let target, NSLocationInRange(target.range.location, block.range) { return nil }
        // The last block, to the end: already there.
        if target == nil, ns.substring(from: NSMaxRange(block.range)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }

        // Where it lands, among which neighbours.
        var insertion = target?.range.location ?? ns.length
        let above = all.last { NSMaxRange($0.range) <= insertion && !overlaps($0, block) && $0.range.location < insertion }
        // An item dropped under a list's last item, before what follows the list, joins the list: it goes right
        // under that item, and the blank lines that close the list stay below it.
        var joinsList = false
        if block.listIndent != nil, let target, target.listIndent == nil, let above, above.listIndent != nil,
           NSMaxRange(above.range) < insertion, ns.character(at: NSMaxRange(above.range) - 1) == 10,
           ns.substring(with: NSRange(location: NSMaxRange(above.range), length: insertion - NSMaxRange(above.range)))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertion = NSMaxRange(above.range)
            joinsList = true
        }
        let landingIndent: Int? = {
            guard block.listIndent != nil else { return nil }
            if let target, let indent = target.listIndent { return indent }
            if let above, let indent = above.listIndent { return indent }
            return 0
        }()

        // Right after itself (only blank lines between) at the same indent: already there.
        let rest = NSRange(location: NSMaxRange(block.range), length: max(0, insertion - NSMaxRange(block.range)))
        if insertion >= NSMaxRange(block.range), ns.substring(with: rest).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           landingIndent == block.listIndent { return nil }

        // The block's text, ending with a line break, at its new indent.
        var moved = ns.substring(with: block.range)
        if !moved.hasSuffix("\n") { moved += "\n" }
        if let landingIndent, let indent = block.listIndent, landingIndent != indent {
            moved = reindent(moved, by: landingIndent - indent)
        }
        let movedIsItem = block.listIndent != nil
        let movedLines = moved.dropLast().components(separatedBy: "\n")

        // What is taken out: the block and the blank lines after it; at the end of the note, the blank lines before.
        let next = all.first { $0.range.location >= NSMaxRange(block.range) }
        // The blank line the block keeps from one of its own sides.
        let spaced: Bool = {
            if let next { return next.range.location > NSMaxRange(block.range) }
            return block.range.location > 0 && isBlankLine(lineContent(ns, endingAt: block.range.location))
        }()
        var removal: NSRange
        if let next {
            removal = NSRange(location: block.range.location, length: next.range.location - block.range.location)
            // Between two list items, the blank line above goes too: the list closes up again.
            if next.listIndent != nil, let before = all.last(where: { NSMaxRange($0.range) <= block.range.location }),
               before.listIndent != nil, block.listIndent == nil {
                removal = NSRange(location: NSMaxRange(before.range), length: NSMaxRange(removal) - NSMaxRange(before.range))
            }
        } else {
            // Only the blank lines above go with it: the line above may be its parent item's.
            var start = block.range.location
            while start > 0 {
                let line = ns.lineRange(for: NSRange(location: start - 1, length: 0))
                guard ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                start = line.location
            }
            removal = NSRange(location: start, length: ns.length - start)
        }
        // What stands in for it: a blank line when the blocks it leaves would otherwise touch and glue together (a
        // quote under a list item joins it, two quotes become one).
        var filler = ""
        if next != nil {
            if ns.substring(to: removal.location).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The first block of the note: the blank lines above it go too, so the note starts with its text.
                // (The frontmatter's closing `---` is not blank: a note with one never gets here.)
                removal = NSRange(location: 0, length: NSMaxRange(removal))
            } else {
                if glues(lineContent(ns, endingAt: removal.location), lineContent(ns, at: NSMaxRange(removal))) { filler = "\n" }
            }
        }

        // What goes in: a blank line above when the line above would swallow it, the block, a blank line below
        // unless both are list items.
        var inserted = ""
        // Landing in the hole it leaves: the block takes the filler's place, under the line above the hole.
        let fillsTheHole = insertion == NSMaxRange(removal) && removal.location > 0
        if fillsTheHole { filler = "" }
        if insertion > 0 {
            if ns.character(at: insertion - 1) != 10 { inserted += "\n" }
            let line = lineContent(ns, endingAt: fillsTheHole ? removal.location : insertion)
            let bothItems = movedIsItem && listIndent(line) != nil
            // At the end of the note the block's own spacing goes above it, where it had it.
            if glues(line, movedLines[0]) || (target == nil && spaced && !isBlankLine(line) && !bothItems) { inserted += "\n" }
        }
        inserted += moved
        if let target, !joinsList {
            let bothItems = movedIsItem && target.listIndent != nil
            let first = ns.substring(with: target.firstLine)
            if glues(movedLines[movedLines.count - 1], first) || (spaced && !bothItems) { inserted += "\n" }
        }

        let result = NSMutableString(string: text)
        if insertion >= NSMaxRange(removal) {
            result.replaceCharacters(in: NSRange(location: insertion, length: 0), with: inserted)
            result.replaceCharacters(in: removal, with: filler)
        } else {
            result.replaceCharacters(in: removal, with: filler)
            result.replaceCharacters(in: NSRange(location: insertion, length: 0), with: inserted)
        }
        // At the end of the note: no blank lines left after the last block.
        var new = result as String
        if target == nil { while new.hasSuffix("\n\n") { new.removeLast() } }
        // A divider that ends up on the first line would open a frontmatter down to the next one: `***` is the same
        // divider without that.
        if MarkdownStyler.frontmatterRange(in: ns) == nil, MarkdownStyler.frontmatterRange(in: new as NSString) != nil {
            new = "***" + new.dropFirst(3)
        }

        let movedStart: Int = {
            let shift = insertion >= NSMaxRange(removal) ? (filler as NSString).length - removal.length : 0
            return insertion + shift + (inserted as NSString).range(of: moved).location
        }()
        return edit(from: text, to: new, selection: NSRange(location: movedStart, length: 0))
    }

    /// The block a keyboard move (Option-Command-Up or Down) puts `block` before, and whether it moves at all:
    /// over the block above or below it at its own level. The outer optional is nil when it cannot move; the inner one
    /// nil for the end of the note.
    public static func keyboardTarget(for block: MarkdownBlock, up: Bool, in text: String) -> MarkdownBlock?? {
        let all = blocks(in: text)
        let peers = all.filter { $0.indent <= block.indent && !overlaps($0, block) }
        if up {
            guard let previous = peers.last(where: { $0.range.location < block.range.location }) else { return nil }
            return .some(previous)
        }
        guard let following = peers.first(where: { $0.range.location >= NSMaxRange(block.range) }) else { return nil }
        let after = peers.first { $0.range.location >= NSMaxRange(following.range) }
        return .some(after)
    }

    /// Deletes `block` (Delete on a block selected by its handle): its lines go whole, break included, so no empty
    /// line stays in its place, and the blank lines that were on each side of it leave one between their neighbours.
    /// The caret goes where the block was.
    public static func delete(_ block: MarkdownBlock, in text: String) -> TextEdit {
        let ns = text as NSString
        var range = NSIntersectionRange(block.range, NSRange(location: 0, length: ns.length))
        func isBlank(_ line: NSRange) -> Bool { ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if NSMaxRange(range) == ns.length, range.location > 0, ns.character(at: NSMaxRange(range) - 1) != 10 {
            // The note's last line has no break of its own: the one before it goes with it.
            range = NSRange(location: range.location - 1, length: range.length + 1)
        } else if range.location > 0, isBlank(ns.lineRange(for: NSRange(location: range.location - 1, length: 0))) {
            if NSMaxRange(range) == ns.length {
                // Last in the note: the blank line above it would be left trailing.
                let above = ns.lineRange(for: NSRange(location: range.location - 1, length: 0))
                range = NSRange(location: above.location, length: NSMaxRange(range) - above.location)
            } else if isBlank(ns.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))) {
                range.length += ns.lineRange(for: NSRange(location: NSMaxRange(range), length: 0)).length
            }
        }
        let caret = min(range.location, ns.length - range.length)
        return TextEdit(range: range, replacement: "", selection: NSRange(location: caret, length: 0))
    }

    // MARK: Lines

    /// The line that ends just before `location` (a line start, or the end of the note), without its break.
    private static func lineContent(_ ns: NSString, endingAt location: Int) -> String {
        guard location > 0 else { return "" }
        return ns.substring(with: ns.lineWithoutBreak(at: min(location, ns.length) - 1))
    }

    /// The line at `location`, without its break.
    private static func lineContent(_ ns: NSString, at location: Int) -> String {
        guard location < ns.length else { return "" }
        return ns.substring(with: ns.lineWithoutBreak(at: location))
    }

    private static func isBlankLine(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Whether `lower` written right under `upper`, with no blank line between them, would be read as part of
    /// `upper`'s block: text under a paragraph, a list item, a quote or a table row joins it. A heading, a divider or a
    /// code fence ends its block on its own line, and a heading or a fence starts one under anything. Two list items
    /// make one list, as they should. `---` under text would turn it into a heading: that glues too.
    static func glues(_ upper: String, _ lower: String) -> Bool {
        guard !isBlankLine(upper), !isBlankLine(lower), listIndent(upper) == nil || listIndent(lower) == nil else { return false }
        let above = upper.trimmingCharacters(in: .whitespaces)
        let below = lower.trimmingCharacters(in: .whitespaces)
        if isSingleLine(above) || fence(above) != nil || fence(below) != nil { return false }
        return !isSingleLine(below) || (isDivider(below) && below.hasPrefix("-"))
    }

    static func overlaps(_ a: MarkdownBlock, _ b: MarkdownBlock) -> Bool {
        NSIntersectionRange(a.range, b.range).length > 0
    }

    private static func fence(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func leadingColumns(_ line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 } else if character == "\t" { columns += 4 } else { break }
        }
        return columns
    }

    /// The indent of a list item's marker (`-`, `*`, `+`, `1.`, `1)`), nil for a line that starts none.
    static func listIndent(_ line: String) -> Int? {
        let indent = leadingColumns(line)
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let first = rest.first, "-*+".contains(first) {
            let after = rest.dropFirst()
            // `---` and `***` are dividers, not items.
            guard after.first == " " || after.isEmpty, !isDivider(String(rest)) else { return nil }
            return indent
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")" else { return nil }
        let space = after.dropFirst()
        return space.first == " " || space.isEmpty ? indent : nil
    }

    private static func isDivider(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// A line that is a block of its own: a heading, a divider.
    private static func isSingleLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("#") && (trimmed.drop { $0 == "#" }.first == " " || trimmed.allSatisfy { $0 == "#" }) || isDivider(trimmed)
    }

    /// A line that starts another block, ending the paragraph above it.
    private static func isBlockStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return isSingleLine(trimmed) || fence(trimmed) != nil || listIndent(line) != nil
            || trimmed.hasPrefix(">") || trimmed.hasPrefix("|")
    }

    private static func reindent(_ text: String, by delta: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map { line in
            guard !line.isEmpty else { return line }
            if delta > 0 { return String(repeating: " ", count: delta) + line }
            var removed = 0
            var rest = Substring(line)
            while removed < -delta, let first = rest.first, first == " " || first == "\t" {
                removed += first == "\t" ? 4 : 1
                rest = rest.dropFirst()
            }
            return String(rest)
        }.joined(separator: "\n")
    }

    /// The smallest replacement turning `old` into `new`.
    private static func edit(from old: String, to new: String, selection: NSRange) -> TextEdit {
        let a = old as NSString
        let b = new as NSString
        var prefix = 0
        while prefix < a.length, prefix < b.length, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < a.length - prefix, suffix < b.length - prefix,
              a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: prefix, length: a.length - prefix - suffix)
        let replacement = b.substring(with: NSRange(location: prefix, length: b.length - prefix - suffix))
        return TextEdit(range: range, replacement: replacement, selection: selection)
    }
}
