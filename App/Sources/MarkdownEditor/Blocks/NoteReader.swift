import Foundation
import Markdown

/// Reads Markdown into a `NoteDocument`. Every line of the file ends up in exactly one place (the frontmatter, a
/// block's own lines, the lines before a block, or the end), so writing an unedited document gives the file back.
enum NoteReader {
    static func document(from markdown: String) -> NoteDocument {
        let whole = markdown as NSString
        let frontmatterRange = MarkdownStyler.frontmatterRange(in: whole)
        let frontmatter = frontmatterRange.map { whole.substring(with: $0) } ?? ""
        var body = frontmatterRange.map { whole.substring(from: NSMaxRange($0)) } ?? markdown
        // A substring of an NSString (or a text that came from one) is a bridged string, which Swift walks a
        // character at a time through Objective-C: a third of the reading of a long note went there.
        body.makeContiguousUTF8()

        let lines = Lines(body)
        let source = SourceMap(body)
        var leaves: [Leaf] = []
        for child in Document(parsing: body, options: [.disableSmartOpts]).children {
            guard let range = lines.lineRange(of: child) else { continue }
            var walker = Walker(source: source, lines: lines)
            if let found = walker.leaves(of: child, in: Context()), Self.isOrdered(found, within: range) {
                leaves += found
            } else {
                // Something the page has no block for (a quote inside a list item, a heading in an item...): the
                // whole of it, shown as written.
                leaves.append(Leaf(lines: range, kind: .raw, context: Context(), text: InlineText(lines.joined(range))))
            }
        }

        var blocks: [NoteBlock] = []
        var next = 1
        for leaf in leaves {
            let gapStart = blocks.isEmpty ? 1 : leaves[blocks.count - 1].lines.upperBound + 1
            var block = NoteBlock(
                id: next, kind: leaf.kind, depth: leaf.context.depth, quote: leaf.context.quote,
                callout: leaf.context.callout, text: leaf.text,
                before: lines.text(from: gapStart, to: leaf.lines.lowerBound - 1)
            )
            block.source = NoteBlock.Source(
                lines: lines.text(of: leaf.lines),
                meaning: NoteBlock.Meaning(kind: block.kind, depth: block.depth, quote: block.quote, callout: block.callout,
                                           text: block.text, indent: 0, number: nil),
                previous: blocks.last?.id
            )
            blocks.append(block)
            next += 1
        }
        let endStart = leaves.last.map { $0.lines.upperBound + 1 } ?? 1
        let end = lines.text(from: endStart, to: lines.count)

        // What the layout says now is what the lines were written for.
        let layout = NoteWriter.layout(of: blocks)
        for index in blocks.indices {
            blocks[index].source?.meaning.indent = layout[index].indent
            blocks[index].source?.meaning.number = layout[index].number
        }
        let read = blocks.map { (id: $0.id, hidden: NoteWriter.hiddenLines(of: $0.before)) }
        return NoteDocument(frontmatter: frontmatter, blocks: blocks, end: end, read: read)
    }

    /// Where `markdown` can be cut after `after` UTF-16 units so that reading the part before the cut gives the
    /// first blocks of the whole note, as reading the whole gives them: at a blank line followed by a line that starts
    /// a paragraph or a heading at its first column, outside the frontmatter, a fence or an HTML comment. Nil for a
    /// note too short to gain from it, without such a place, or with what reaches across the note (reference
    /// definitions, footnotes, `<details>` and raw HTML blocks that may hold blank lines).
    static func headLength(of markdown: String, after: Int) -> Int? {
        let ns = markdown as NSString
        guard ns.length > 2 * after, !reachesAcross(ns) else { return nil }
        let start = MarkdownStyler.frontmatterRange(in: ns).map(NSMaxRange) ?? 0
        var fence: (character: unichar, count: Int)?
        var inComment = false
        var previousBlank = false
        var location = start
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(line) }
            let text = ns.substring(with: line).trimmingCharacters(in: .newlines)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if inComment {
                if trimmed.contains("-->") { inComment = false }
                previousBlank = false
                continue
            }
            let indent = text.prefix { $0 == " " }.count
            if indent < 4, let first = trimmed.utf16.first, first == 96 || first == 126 {
                let count = trimmed.utf16.prefix { $0 == first }.count
                if count >= 3 {
                    if let open = fence {
                        if open.character == first, count >= open.count,
                           trimmed.utf16.dropFirst(count).allSatisfy({ $0 == 32 || $0 == 9 }) { fence = nil }
                    } else {
                        fence = (first, count)
                    }
                    previousBlank = false
                    continue
                }
            }
            if fence != nil { continue }
            if let open = trimmed.range(of: "<!--"), !trimmed[open.upperBound...].contains("-->") {
                inComment = true
                previousBlank = false
                continue
            }
            if trimmed.isEmpty {
                previousBlank = true
                continue
            }
            if previousBlank, line.location >= after, indent == 0,
               let first = text.unicodeScalars.first, first == "#" || CharacterSet.letters.contains(first) {
                return line.location
            }
            previousBlank = false
        }
        return nil
    }

    /// Whether `text` holds what a part of it cannot be read without: a reference definition or a footnote (a line
    /// starting `[label]:`), `<details>` or a raw HTML block that may hold blank lines. One pass over its characters:
    /// searching for each took 3 ms of a long note's opening.
    private static func reachesAcross(_ text: NSString) -> Bool {
        let length = text.length
        var units = [unichar](repeating: 0, count: length)
        text.getCharacters(&units, range: NSRange(location: 0, length: length))
        let tags: [[unichar]] = ["details", "pre", "script", "style", "textarea", "![cdata["].map { Array($0.utf16) }
        var lineStart = true
        var index = 0
        while index < length {
            let unit = units[index]
            if unit == 10 {
                lineStart = true
                index += 1
                continue
            }
            if lineStart {
                lineStart = false
                var at = index
                while at < length, at - index < 3, units[at] == 32 { at += 1 }
                if at < length, units[at] == 91 {
                    var end = at + 1
                    while end < length, units[end] != 93, units[end] != 10 { end += 1 }
                    if end + 1 < length, end > at + 1, units[end] == 93, units[end + 1] == 58 { return true }
                }
            }
            if unit == 60 {
                for tag in tags where index + tag.count < length {
                    var matches = true
                    for (offset, expected) in tag.enumerated() {
                        var found = units[index + 1 + offset]
                        if found >= 65, found <= 90 { found += 32 }
                        if found != expected { matches = false; break }
                    }
                    if matches { return true }
                }
            }
            index += 1
        }
        return false
    }

    /// Whether the leaves of one top-level block each have lines of their own, in order, inside its lines.
    private static func isOrdered(_ leaves: [Leaf], within range: ClosedRange<Int>) -> Bool {
        var last = range.lowerBound - 1
        for leaf in leaves {
            guard leaf.lines.lowerBound > last, leaf.lines.upperBound <= range.upperBound else { return false }
            last = leaf.lines.upperBound
        }
        return true
    }
}

/// A block found in the tree, before it gets its place in the document.
private struct Leaf {
    var lines: ClosedRange<Int>
    var kind: BlockKind
    var context: Context
    var text: InlineText
}

/// Where a leaf sits: inside how many lists and quotes, in which callout.
private struct Context {
    var depth = 0
    var quote = 0
    var callout: Callout?
}

/// The body's lines, 1-based as swift-markdown counts them, each with its line break.
struct Lines {
    private let ns: NSString
    /// UTF-16 offset where each line starts, plus the end of the text.
    private let starts: [Int]

    init(_ text: String) {
        ns = text as NSString
        var starts = [0]
        var location = 0
        while location < ns.length {
            let end = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            starts.append(end)
            location = end
        }
        if starts.count == 1 { starts.append(0) }
        self.starts = starts
    }

    /// How many lines there are; a text without any has one empty line.
    var count: Int { starts.count - 1 }

    /// Lines `from` to `to` (1-based, inclusive), line breaks included; empty when `to < from`.
    func text(from: Int, to: Int) -> String {
        let first = max(from, 1)
        let last = min(to, count)
        guard first <= last else { return "" }
        // Native, not a bridged NSString: the lines are written back on each keystroke, and appending a bridged
        // string goes character by character.
        var text = ns.substring(with: NSRange(location: starts[first - 1], length: starts[last] - starts[first - 1]))
        text.makeContiguousUTF8()
        return text
    }

    func text(of range: ClosedRange<Int>) -> String { text(from: range.lowerBound, to: range.upperBound) }

    /// The lines of `range` without their line breaks, joined by `U+2028`: a block's text.
    func joined(_ range: ClosedRange<Int>) -> String {
        range.map(content(of:)).joined(separator: String(InlineText.lineBreak))
    }

    /// The line `n` without its line break.
    func content(of line: Int) -> String {
        var text = self.text(from: line, to: line)
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    /// The lines a node spans. A range that ends at the very start of a line ends on the line before.
    func lineRange(of markup: Markup) -> ClosedRange<Int>? {
        guard let range = markup.range else { return nil }
        let first = range.lowerBound.line
        var last = range.upperBound.line
        if range.upperBound.column <= 1, last > first { last -= 1 }
        return min(first, count)...min(max(first, last), count)
    }
}

private struct Walker {
    let source: SourceMap
    let lines: Lines

    /// The leaves of `markup`, or nil when it holds something the page cannot show as blocks.
    mutating func leaves(of markup: Markup, in context: Context) -> [Leaf]? {
        guard let range = lines.lineRange(of: markup) else { return [] }
        switch markup {
        case let paragraph as Paragraph:
            if let image = Self.embed(paragraph) {
                return [Leaf(lines: range, kind: .embed, context: context, text: InlineText(source.text(of: image) ?? ""))]
            }
            let written = (source.text(of: paragraph) ?? "").trimmingCharacters(in: .whitespaces)
            if written.count > 4, written.hasPrefix("%%"), written.hasSuffix("%%"), !written.dropFirst(2).dropLast(2).contains("%%") {
                // A comment, as Obsidian writes them: shows nothing, its lines stay between blocks as written.
                return []
            }
            if written.count > 4, written.hasPrefix("$$"), written.hasSuffix("$$"), !written.dropFirst(2).dropLast(2).contains("$$") {
                // Display math: one atom, its lines as written (without the quote's `>`), which the page draws as a formula.
                let markdown = stripped(range, context).replacingOccurrences(of: String(InlineText.lineBreak), with: "\n")
                return [Leaf(lines: range, kind: .paragraph, context: context,
                             text: InlineText(String(InlineText.atom), runs: [InlineRun(NSRange(location: 0, length: 1), .atom(markdown: markdown))]))]
            }
            var text = InlineText.read(paragraph.children, source: source)
            if context.callout?.opens == true {
                // The callout's `[!NOTE]` line is its header, not text: it is written from the callout.
                text = Self.droppingFirstLine(text)
            }
            return [Leaf(lines: range, kind: .paragraph, context: context, text: text)]
        case let heading as Heading:
            guard context.depth == 0 else { return nil }
            return [Leaf(lines: range, kind: .heading(level: heading.level), context: context,
                         text: InlineText.read(heading.children, source: source))]
        case let code as CodeBlock:
            var text = code.code
            if text.hasSuffix("\n") { text.removeLast() }
            return [Leaf(lines: range, kind: .code(language: code.language ?? ""), context: context,
                         text: InlineText(text.replacingOccurrences(of: "\n", with: String(InlineText.lineBreak))))]
        case is ThematicBreak:
            return [Leaf(lines: range, kind: .divider, context: context, text: InlineText())]
        case is Table:
            return [Leaf(lines: range, kind: .table, context: context, text: InlineText(stripped(range, context)))]
        case let html as HTMLBlock:
            let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            // A comment shows nothing: its lines stay between blocks, as written.
            if raw.hasPrefix("<!--"), raw.hasSuffix("-->"), !raw.dropFirst(4).dropLast(3).contains("-->") { return [] }
            return [Leaf(lines: range, kind: .raw, context: context, text: InlineText(stripped(range, context)))]
        case let quote as BlockQuote:
            guard context.depth == 0, context.callout == nil else { return nil }
            var inner = context
            inner.quote += 1
            if context.quote == 0, let callout = callout(opening: quote) { inner.callout = callout }
            var result: [Leaf] = []
            for child in quote.children {
                guard let found = leaves(of: child, in: inner) else { return nil }
                result += found
                if !found.isEmpty { inner.callout?.opens = false }
            }
            return result
        case let list as UnorderedList:
            return items(of: Array(list.listItems), ordered: nil, in: context)
        case let list as OrderedList:
            return items(of: Array(list.listItems), ordered: Int(list.startIndex), in: context)
        default:
            return nil
        }
    }

    private mutating func items(of items: [ListItem], ordered start: Int?, in context: Context) -> [Leaf]? {
        var result: [Leaf] = []
        for item in items {
            guard let itemLines = lines.lineRange(of: item) else { continue }
            let kind: BlockKind = if let start { .numbered(start: start) }
                else if let box = item.checkbox { .task(checked: box == .checked) }
                else { .bullet }
            let children = Array(item.children)
            guard let first = children.first else {
                // An empty item: its marker line.
                result.append(Leaf(lines: itemLines.lowerBound...itemLines.lowerBound, kind: kind, context: context, text: InlineText()))
                continue
            }
            guard let paragraph = first as? Paragraph, let range = lines.lineRange(of: paragraph),
                  range.lowerBound == itemLines.lowerBound
            else { return nil }
            var text = InlineText.read(paragraph.children, source: source)
            var itemKind = kind
            if kind == .bullet, let box = Self.box(starting: text) {
                // GitHub shows a task inside a quote, and an empty one; the parser knows neither.
                itemKind = .task(checked: box)
                text = Self.dropping(min(4, text.length), from: text)
            }
            result.append(Leaf(lines: range, kind: itemKind, context: context, text: text))
            var inner = context
            inner.depth += 1
            for child in children.dropFirst() {
                switch child {
                case is Paragraph, is CodeBlock, is UnorderedList, is OrderedList:
                    guard let found = leaves(of: child, in: inner) else { return nil }
                    result += found
                default:
                    return nil
                }
            }
        }
        return result
    }

    /// The lines of `range` without the quote and list prefixes `context` puts before them, joined by `U+2028`.
    private func stripped(_ range: ClosedRange<Int>, _ context: Context) -> String {
        range.map { line in
            var content = Substring(lines.content(of: line))
            for _ in 0..<context.quote {
                content = content.drop { $0 == " " || $0 == "\t" }
                if content.first == ">" { content = content.dropFirst() }
                if content.first == " " { content = content.dropFirst() }
            }
            return String(content)
        }.joined(separator: String(InlineText.lineBreak))
    }

    /// Whether `text` starts with a task's box as plain text, `[ ] ` or `[x] `, or is one: checked or not.
    private static func box(starting text: InlineText) -> Bool? {
        guard let prefix = String(text.string.utf16.prefix(4)), text.runs.allSatisfy({ $0.range.location >= 4 }) else { return nil }
        switch prefix {
        case "[ ] ", "[ ]": return false
        case "[x] ", "[X] ", "[x]", "[X]": return true
        default: return nil
        }
    }

    /// `text` without its first `count` UTF-16 units.
    private static func dropping(_ count: Int, from text: InlineText) -> InlineText {
        let ns = text.string as NSString
        let runs = text.runs.map { InlineRun(NSRange(location: $0.range.location - count, length: $0.range.length), $0.mark) }
        return InlineText(ns.substring(from: count), runs: runs)
    }

    /// The image of a paragraph that holds nothing else (spaces aside).
    private static func embed(_ paragraph: Paragraph) -> Image? {
        var image: Image?
        for child in paragraph.children {
            if let found = child as? Image, image == nil { image = found }
            else if let text = child as? Text, text.string.allSatisfy(\.isWhitespace) { continue }
            else { return nil }
        }
        return image
    }

    nonisolated(unsafe) private static let calloutHeader = /^\[!([A-Za-z]+)\]([^\n]*)$/

    /// The callout `quote` opens, when the first line of its first paragraph is `[!KIND]` (read from the source: the
    /// parser splits brackets into several texts).
    private func callout(opening quote: BlockQuote) -> Callout? {
        guard let paragraph = quote.children.first(where: { _ in true }) as? Paragraph,
              let range = lines.lineRange(of: paragraph)
        else { return nil }
        var line = Substring(lines.content(of: range.lowerBound)).drop { $0 == " " || $0 == "\t" }
        guard line.first == ">" else { return nil }
        line = line.dropFirst().drop { $0 == " " || $0 == "\t" }
        guard let match = String(line).wholeMatch(of: Self.calloutHeader) else { return nil }
        return Callout(kind: String(match.1), title: String(match.2), opens: true)
    }

    /// `text` from its second line on: what a callout's first paragraph says under its `[!KIND]` line.
    private static func droppingFirstLine(_ text: InlineText) -> InlineText {
        let ns = text.string as NSString
        let breakAt = ns.range(of: String(InlineText.lineBreak))
        guard breakAt.location != NSNotFound else { return InlineText() }
        let start = NSMaxRange(breakAt)
        let runs = text.runs.compactMap { run -> InlineRun? in
            let range = NSIntersectionRange(run.range, NSRange(location: start, length: ns.length - start))
            guard range.length > 0 else { return nil }
            return InlineRun(NSRange(location: range.location - start, length: range.length), run.mark)
        }
        return InlineText(ns.substring(from: start), runs: runs)
    }
}

extension SourceMap {
    /// The Markdown of `markup`, as written.
    func text(of markup: Markup) -> String? {
        guard let range = range(markup) else { return nil }
        return ns.substring(with: range)
    }
}
