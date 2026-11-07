import Foundation

/// The style spans of an edited text, found again for the one paragraph the edit is in instead of the whole note.
///
/// Parsing a 50 KB note takes several milliseconds, on each keystroke. Most edits are inside a paragraph (a run of lines
/// between two blank lines), and the paragraphs around it cannot change what they are: so the paragraph is parsed on
/// its own and the spans of the rest are kept, moved by the length of the edit. Whenever that could be wrong the answer
/// is nil and the caller parses the whole text: an edit with a line break, one on a blank line, anything inside a code
/// block, a table or the frontmatter, and any paragraph that holds what can reach across a blank line (a fence, HTML,
/// a table, a link reference, a divider, an indented line).
enum IncrementalSpans {
    /// The text of the last parse, in UTF-16, and what it found.
    struct Base {
        let units: [UInt16]
        let spans: [StyleSpan]
    }

    /// What, in a paragraph, makes it unsafe to parse alone: a code fence, HTML (`<mark>`, comments), a table, a link
    /// reference (`[a]: url`, `[a][b]`, a footnote), a divider or the frontmatter's fence, a math block, a tab.
    private static let unsafeText = ["```", "~~~", "<", "|", "]:", "][", "---", "$$", "\t"]

    /// The label of a link reference or footnote definition (`[a]: url`, `[^1]: note`).
    private static let definedLabel = try! NSRegularExpression(pattern: #"^ {0,3}\[([^\]\n]+)\]:"#, options: .anchorsMatchLines)

    static func spans(for text: String, units: [UInt16], after base: Base) -> [StyleSpan]? {
        let old = base.units
        let shortest = min(old.count, units.count)
        var prefix = 0
        while prefix < shortest, old[prefix] == units[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix, old[old.count - 1 - suffix] == units[units.count - 1 - suffix] { suffix += 1 }
        let oldEdit = NSRange(location: prefix, length: old.count - prefix - suffix)
        let newEdit = NSRange(location: prefix, length: units.count - prefix - suffix)
        if oldEdit.length == 0, newEdit.length == 0 { return base.spans }
        guard !hasLineBreak(old, oldEdit), !hasLineBreak(units, newEdit) else { return nil }
        let delta = newEdit.length - oldEdit.length

        // The edit must not be inside what is not made of paragraphs.
        for span in base.spans where isBlock(span.style) {
            if span.range.location <= NSMaxRange(oldEdit), oldEdit.location <= NSMaxRange(span.range) { return nil }
        }

        let ns = text as NSString
        guard var chunk = paragraph(in: ns, around: newEdit) else { return nil }
        // The frontmatter is parsed apart from the page (`MarkdownStyler.spans`): the paragraph starts after it.
        if let frontmatter = MarkdownStyler.frontmatterRange(in: ns) {
            guard newEdit.location >= NSMaxRange(frontmatter) else { return nil }
            if chunk.location < NSMaxRange(frontmatter) {
                chunk = NSRange(location: NSMaxRange(frontmatter), length: NSMaxRange(chunk) - NSMaxRange(frontmatter))
            }
        } else if chunk.location == 0, units.starts(with: Array("-".utf16)) {
            // A note that begins with `---` that is no frontmatter: a divider.
            return nil
        }
        let oldChunk = NSRange(location: chunk.location, length: chunk.length - delta)
        guard oldChunk.length >= 0, NSMaxRange(oldChunk) <= old.count else { return nil }
        let newText = ns.substring(with: chunk)
        let oldText = String(decoding: old[oldChunk.location..<NSMaxRange(oldChunk)], as: UTF16.self)
        guard isSafe(newText), isSafe(oldText) else { return nil }
        // A bracket may be a shortcut reference (`[a]`), a link only when the note defines `a` elsewhere.
        if newText.contains("[") || oldText.contains("["), ns.range(of: "]:").location != NSNotFound {
            let paragraphs = (newText + "\n" + oldText).lowercased()
            let labels = definedLabel.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)).lowercased() }
            if labels.contains(where: { paragraphs.contains("[\($0)]") }) { return nil }
        }

        var result: [StyleSpan] = []
        result.reserveCapacity(base.spans.count + 8)
        for span in base.spans where NSMaxRange(span.range) <= oldChunk.location { result.append(span) }
        for span in MarkdownStyler.spans(in: newText) {
            result.append(StyleSpan(shifted(span.style, by: chunk.location), shifted(span.range, by: chunk.location)))
        }
        for span in base.spans where span.range.location >= NSMaxRange(oldChunk) {
            result.append(StyleSpan(shifted(span.style, by: delta), shifted(span.range, by: delta)))
        }
        return result
    }

    /// Styles that cover whole blocks the paragraph rule does not hold for.
    private static func isBlock(_ style: MarkdownStyle) -> Bool {
        switch style {
        case .codeBlock, .fencedCode, .table, .frontmatter, .embed, .concealedOutside: true
        default: false
        }
    }

    private static func hasLineBreak(_ units: [UInt16], _ range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        return units[range.location..<NSMaxRange(range)].contains { $0 == 10 || $0 == 13 }
    }

    /// The lines around `edit` up to the blank lines on both sides (the breaks of its own lines included); nil when
    /// the edit is on a blank line.
    private static func paragraph(in ns: NSString, around edit: NSRange) -> NSRange? {
        guard ns.length > 0 else { return nil }
        let at = min(edit.location, ns.length - 1)
        let own = ns.lineRange(for: NSRange(location: at, length: min(edit.length, ns.length - at)))
        guard !isBlank(own, in: ns) else { return nil }
        var start = own.location
        while start > 0 {
            let previous = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(previous, in: ns) { break }
            start = previous.location
        }
        var end = NSMaxRange(own)
        while end < ns.length {
            let next = ns.lineRange(for: NSRange(location: end, length: 0))
            if isBlank(next, in: ns) { break }
            end = NSMaxRange(next)
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isBlank(_ line: NSRange, in ns: NSString) -> Bool {
        for index in line.location..<NSMaxRange(line) {
            let unit = ns.character(at: index)
            if unit != 32, unit != 10, unit != 13 { return false }
        }
        return true
    }

    /// A paragraph that parses the same alone as inside the note.
    private static func isSafe(_ text: String) -> Bool {
        for marker in unsafeText where text.contains(marker) { return false }
        // The first line cannot be a continuation of what comes before the blank line (an indented list item), and no
        // line is an indented code block.
        var first = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            if first, indent > 0 { return false }
            if indent >= 4 { return false }
            first = false
        }
        return true
    }

    private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    private static func shifted(_ style: MarkdownStyle, by offset: Int) -> MarkdownStyle {
        switch style {
        case .fencedCode(let language, let code): .fencedCode(language: language, code: shifted(code, by: offset))
        case .concealedOutside(let block): .concealedOutside(block: shifted(block, by: offset))
        case .tag(let frontmatter?): .tag(frontmatter: shifted(frontmatter, by: offset))
        default: style
        }
    }
}
