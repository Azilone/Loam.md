import Foundation
import Markdown

/// Writes a `NoteDocument` as Markdown. A block that is as it was read gets its lines back as written, and so do
/// the lines between two such blocks still next to each other; anything edited is written in canonical Markdown.
enum NoteWriter {
    /// Where a block's list nesting starts and the number a numbered item shows, from the blocks above it.
    struct Layout: Equatable {
        var indent: Int
        var number: Int?
    }

    static func markdown(of document: NoteDocument) -> String {
        // An empty paragraph is a blank line in Markdown: it has nothing to write, unless it was read so (a callout's
        // `[!NOTE]` line alone).
        let blocks = document.blocks.filter {
            !($0.kind == .paragraph && $0.text.string.isEmpty && $0.callout?.opens != true && $0.source?.meaning.text.string.isEmpty != true)
        }
        let layout = layout(of: blocks)
        let unchanged = blocks.indices.map { isUnchanged(blocks[$0], layout[$0]) }
        let carried = hiddenLinesOfDeleted(document)

        var out = document.frontmatter
        var previousLines = ""
        for index in blocks.indices {
            let block = blocks[index]
            let previous = index > 0 ? blocks[index - 1] : nil
            let keepsGap = block.source?.previous == previous?.id && unchanged[index] && (index == 0 || unchanged[index - 1])
            let hidden = (carried[block.id] ?? "") + (keepsGap ? "" : hiddenLines(of: block.before))
            let gap: String
            if keepsGap, carried[block.id] == nil {
                gap = block.before
            } else if !hidden.isEmpty {
                // Reference definitions and comments stand apart, between blank lines.
                gap = (previous == nil ? "" : "\n") + hidden + (keepsGap ? block.before : "\n")
            } else if block.source?.previous == previous?.id, isBlank(block.before),
                      previous.map({ canonicalGap(from: $0, to: block) != "" && $0.quote == block.quote }) ?? true {
                // Still under the same block, an edited block keeps the blank lines written before it (the one after
                // the frontmatter too), where a blank line is wanted anyway.
                gap = block.before
            } else {
                gap = previous.map { canonicalGap(from: $0, to: block) } ?? ""
            }
            // A last line written without a line break gets one once something follows it.
            if !previousLines.isEmpty, !previousLines.hasSuffix("\n") { out += "\n" }
            out += gap
            var lines = unchanged[index] ? block.source!.lines : render(block, layout[index])
            // A divider opening the file would open a frontmatter.
            if out.isEmpty, lines == "---\n" { lines = "***\n" }
            out += lines
            previousLines = lines
        }
        let tail = carried[0].map { (blocks.isEmpty ? "" : "\n") + $0 } ?? ""
        if !previousLines.isEmpty, !previousLines.hasSuffix("\n"), !(tail + document.end).isEmpty { out += "\n" }
        out += tail + document.end
        return out
    }

    // MARK: Layout

    /// The indent and number each block is written with: an item's children start at its text's column, and a
    /// numbered item counts from the first item of its list.
    static func layout(of blocks: [NoteBlock]) -> [Layout] {
        var result: [Layout] = []
        result.reserveCapacity(blocks.count)
        /// The column where an item's text starts, per depth, for the items above.
        var columns: [Int] = []
        var counters: [Int?] = []
        var quote = 0
        for block in blocks {
            if block.quote != quote || block.callout?.opens == true {
                columns = []
                counters = []
                quote = block.quote
            }
            let depth = block.depth
            if depth == 0, !block.kind.isListItem {
                columns = []
                counters = []
            }
            let indent = depth == 0 ? 0 : (depth - 1 < columns.count ? columns[depth - 1] : depth * 2)
            var number: Int?
            if block.kind.isListItem {
                if columns.count > depth { columns.removeLast(columns.count - depth) }
                if counters.count > depth + 1 { counters.removeLast(counters.count - depth - 1) }
                while counters.count <= depth { counters.append(nil) }
                if case .numbered(let start) = block.kind {
                    number = (counters[depth].map { $0 + 1 }) ?? start
                    counters[depth] = number
                } else {
                    counters[depth] = nil
                }
                columns.append(indent + marker(block.kind, number: number).utf16.count)
            } else if depth > 0 {
                // A paragraph or code inside an item: the items deeper than it are over.
                if columns.count > depth { columns.removeLast(columns.count - depth) }
                if counters.count > depth { counters.removeLast(counters.count - depth) }
            }
            result.append(Layout(indent: indent, number: number))
        }
        return result
    }

    /// The marker that starts an item's first line, its space included; the box is part of the text's column only
    /// for nesting purposes, so it is not counted.
    private static func marker(_ kind: BlockKind, number: Int?) -> String {
        switch kind {
        case .numbered: "\(number ?? 1). "
        default: "- "
        }
    }

    private static func isUnchanged(_ block: NoteBlock, _ layout: Layout) -> Bool {
        guard let source = block.source else { return false }
        return source.meaning == NoteBlock.Meaning(
            kind: block.kind, depth: block.depth, quote: block.quote, callout: block.callout, text: block.text,
            indent: layout.indent, number: layout.number
        )
    }

    // MARK: Gaps

    /// What separates `previous` and `block` when their lines as written cannot be kept: nothing between items of a
    /// list, a `>` line between paragraphs of one quote, a blank line elsewhere.
    static func canonicalGap(from previous: NoteBlock, to block: NoteBlock) -> String {
        let sameQuote = previous.quote == block.quote && block.quote > 0
            && block.callout?.opens != true && (previous.callout == nil) == (block.callout == nil)
        if previous.quote > 0 || block.quote > 0, !sameQuote {
            let shared = min(previous.quote, block.quote)
            // Leaving a nested quote for its parent needs the parent's blank line, or the text runs on lazily.
            return shared > 0 && previous.quote != block.quote && block.callout?.opens != true ? quoteBlank(shared) : "\n"
        }
        if block.kind.isListItem, previous.kind.isListItem || previous.depth > 0 { return "" }
        return block.quote > 0 ? quoteBlank(block.quote) : "\n"
    }

    private static func quoteBlank(_ quote: Int) -> String {
        Array(repeating: ">", count: quote).joined(separator: " ") + "\n"
    }

    /// Whether `gap` is one or more empty lines (no `>`, nothing hidden).
    private static func isBlank(_ gap: String) -> Bool {
        !gap.isEmpty && gap.allSatisfy { $0 == "\n" || $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    /// The lines of `gap` that say something (reference definitions, comments): never dropped.
    static func hiddenLines(of gap: String) -> String {
        gap.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.allSatisfy { $0 == " " || $0 == "\t" || $0 == ">" || $0 == "\r" } }
            .map { $0 + "\n" }
            .joined()
    }

    /// The hidden lines before blocks that were deleted, keyed by the id of the next block still there (0: the end).
    private static func hiddenLinesOfDeleted(_ document: NoteDocument) -> [NoteBlock.ID: String] {
        let present = Set(document.blocks.map(\.id))
        var carried: [NoteBlock.ID: String] = [:]
        var pending = ""
        for read in document.read {
            if present.contains(read.id) {
                if !pending.isEmpty {
                    carried[read.id, default: ""] += pending
                    pending = ""
                }
            } else {
                pending += read.hidden
            }
        }
        if !pending.isEmpty { carried[0, default: ""] += pending }
        return carried
    }

    // MARK: Blocks

    /// `block` in canonical Markdown, every line with its quote and list prefix and its line break. Text is written
    /// with Markdown's markers when they read back as the same text and marks, else with HTML tags.
    static func render(_ block: NoteBlock, _ layout: Layout) -> String {
        guard !block.kind.isVerbatim, block.kind != .divider else { return lines(of: block, layout, style: .markdown) }
        var block = block
        block.text = InlineWriter.prepared(block.text)
        if case .heading = block.kind {
            block.text.string = block.text.string.replacingOccurrences(of: String(InlineText.lineBreak), with: " ")
        }
        for style in InlineWriter.Style.allCases {
            // Read back without the list indent, which only says where the block sits.
            let check = lines(of: block, Layout(indent: 0, number: layout.number), style: style)
            let read = NoteReader.document(from: check).blocks
            if read.count == 1, read[0].text == block.text { return lines(of: block, layout, style: style) }
        }
        return lines(of: block, layout, style: .html)
    }

    private static func lines(of block: NoteBlock, _ layout: Layout, style: InlineWriter.Style) -> String {
        let quote = String(repeating: "> ", count: block.quote)
        let pad = String(repeating: " ", count: layout.indent)
        var lines: [String] = []
        if let callout = block.callout, callout.opens { lines.append("[!\(callout.kind)]\(callout.title)") }
        let text = block.text
        switch block.kind {
        case .paragraph:
            lines += InlineWriter.markdown(text, style: style).components(separatedBy: "\n")
        case .heading(let level):
            var content = InlineWriter.markdown(text, style: style, atLineStart: false)
            // `#`s ending a heading after a space are its closing sequence, which a reader drops.
            if content.hasSuffix("#") { content.insert("\\", at: content.index(before: content.endIndex)) }
            lines.append(String(repeating: "#", count: level) + " " + content)
        case .bullet, .task, .numbered:
            var marker = marker(block.kind, number: layout.number)
            if case .task(let checked) = block.kind { marker += checked ? "[x] " : "[ ] " }
            let content = InlineWriter.markdown(text, style: style, atLineStart: !marker.hasSuffix("] ")).components(separatedBy: "\n")
            let hang = String(repeating: " ", count: marker.utf16.count)
            for (index, line) in content.enumerated() {
                lines.append(index == 0 ? (line.isEmpty ? String(marker.dropLast()) : marker + line) : hang + line)
            }
        case .code(let language):
            let code = text.string.replacingOccurrences(of: String(InlineText.lineBreak), with: "\n")
            let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: code) + 1))
            lines.append(fence + language)
            if !code.isEmpty { lines += code.components(separatedBy: "\n") }
            lines.append(fence)
        case .divider:
            lines.append("---")
        case .table, .embed, .raw:
            lines += text.string.components(separatedBy: String(InlineText.lineBreak))
        }
        return lines.map { line in
            let prefixed = quote + pad + line
            // No trailing space after a bare `>` on an empty line.
            return (line.isEmpty ? String(prefixed.reversed().drop { $0 == " " }.reversed()) : prefixed) + "\n"
        }.joined()
    }

    private static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0
        var current = 0
        for c in text {
            current = c == character ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}
