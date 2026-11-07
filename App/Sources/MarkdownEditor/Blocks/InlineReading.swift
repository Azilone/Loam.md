import Foundation
import Markdown

extension InlineText {
    /// The text and marks of a paragraph's or a heading's inline nodes. Syntax becomes marks; what has no text of its
    /// own (an image, a date, inline HTML other than the marks Loam writes) becomes an atom carrying its Markdown.
    static func read(_ inlines: some Sequence<Markup>, source: SourceMap) -> InlineText {
        let inlines = Array(inlines)
        var reader = InlineReader(source: source)
        reader.atoms = InlineAtoms.ranges(in: inlines, source: source)
        for inline in inlines { reader.visit(inline) }
        return reader.finish()
    }
}

/// Syntax that Markdown reads as plain text but that stands for something with no text of its own: a link to a note
/// `[[Note]]`, `[[Note|text]]`, `[[Note#Heading]]`, an embed `![[Note]]`, a footnote `[^1]` (with its `:` where a line
/// defines it), math `$E = mc^2$`, a comment `%%...%%`. Each becomes an atom carrying it as written.
enum InlineAtoms {
    static let patterns: [NSRegularExpression] = [
        // A comment first: what it holds is hidden with it.
        try! NSRegularExpression(pattern: #"(?<!\\)%%[^\n]*?%%"#),
        try! NSRegularExpression(pattern: #"(?<!\\)!?\[\[[^\[\]\n]+?\]\]"#),
        try! NSRegularExpression(pattern: #"^\[\^[^\]\s]+\]:[ \t]*"#, options: .anchorsMatchLines),
        try! NSRegularExpression(pattern: #"(?<!\\)\[\^[^\]\s]+\]"#),
        // `$$...$$` on one line, then `$...$` as Obsidian reads it: no space inside the dollars, no digit after.
        try! NSRegularExpression(pattern: #"(?<![\\$])\$\$[^$\n]+?\$\$"#),
        try! NSRegularExpression(pattern: #"(?<![\\$])\$(?=[^\s$])[^$\n]*?[^\s\\$]\$(?![0-9$])|(?<![\\$])\$[^\s$\\]\$(?![0-9$])"#),
    ]

    /// Where the atoms of `inlines` are in the source, ascending, never overlapping. One is left as text when it does
    /// not line up with the nodes (it starts in code or a link, or cuts a mark in two).
    static func ranges(in inlines: [Markup], source: SourceMap) -> [NSRange] {
        guard let first = inlines.first.flatMap(source.range), let last = inlines.last.flatMap(source.range) else { return [] }
        let whole = NSRange(location: first.location, length: max(0, NSMaxRange(last) - first.location))
        let text = source.ns.substring(with: whole)
        guard text.contains("[") || text.contains("$") || text.contains("%%") else { return [] }
        var found: [NSRange] = []
        for pattern in patterns {
            for match in pattern.matches(in: source.string, range: whole) {
                guard !found.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                found.append(match.range)
            }
        }
        guard !found.isEmpty else { return [] }
        var nodes: [Markup] = []
        func collect(_ markup: Markup) {
            nodes.append(markup)
            for child in markup.children { collect(child) }
        }
        inlines.forEach(collect)
        return found.filter { atom in
            nodes.allSatisfy { node in
                guard let range = source.range(node), NSIntersectionRange(range, atom).length > 0 else { return true }
                let inside = range.location >= atom.location && NSMaxRange(range) <= NSMaxRange(atom)
                if inside { return true }
                if let text = node as? Text { return source.ns.substring(with: range) == text.string }
                let holds = range.location <= atom.location && NSMaxRange(range) >= NSMaxRange(atom)
                return holds && !(node is InlineCode || node is InlineHTML || node is Link || node is Image)
            }
        }.sorted { $0.location < $1.location }
    }
}

private struct InlineReader {
    let source: SourceMap
    var units: [UInt16] = []
    var runs: [InlineRun] = []
    /// HTML marks opened and not closed yet (`<mark>`, `<strong>`...): the mark and where it started.
    var openTags: [(tag: String, mark: InlineMark, start: Int)] = []
    /// The source ranges of the atoms Markdown reads as text (`InlineAtoms`), and those already written.
    var atoms: [NSRange] = []
    var emitted: Set<Int> = []

    init(source: SourceMap) { self.source = source }

    var location: Int { units.count }

    mutating func append(_ string: String) { units += string.utf16 }

    mutating func atom(_ markdown: String) {
        runs.append(InlineRun(NSRange(location: location, length: 1), .atom(markdown: markdown)))
        units.append(InlineText.atom.utf16.first!)
    }

    mutating func mark(_ mark: InlineMark, from start: Int) {
        if location > start { runs.append(InlineRun(NSRange(location: start, length: location - start), mark)) }
    }

    mutating func visit(_ markup: Markup) {
        if !atoms.isEmpty, let range = source.range(markup),
           let atom = atoms.first(where: { NSIntersectionRange($0, range).length > 0 }) {
            if range.location >= atom.location, NSMaxRange(range) <= NSMaxRange(atom) { return emit(atom) }
            if markup is Text { return appendSplitting(range) }
        }
        switch markup {
        case let text as Text:
            appendText(text.string)
        case is SoftBreak:
            append(String(InlineText.lineBreak))
        case is LineBreak:
            runs.append(InlineRun(NSRange(location: location, length: 1), .hardBreak))
            append(String(InlineText.lineBreak))
        case let code as InlineCode:
            let start = location
            append(code.code)
            mark(.code, from: start)
        case let strong as Strong:
            let start = location
            for child in strong.children { visit(child) }
            mark(.strong, from: start)
        case let emphasis as Emphasis:
            let start = location
            for child in emphasis.children { visit(child) }
            mark(.emphasis, from: start)
        case let strike as Strikethrough:
            let start = location
            for child in strike.children { visit(child) }
            mark(.strikethrough, from: start)
        case let link as Link:
            let start = location
            for child in link.children { visit(child) }
            mark(.link(destination: link.destination ?? "", title: link.title), from: start)
        case let html as InlineHTML:
            readTag(html.rawHTML)
        default:
            // An image, a symbol link, inline attributes: kept as written.
            atom(source.text(of: markup) ?? markup.format())
        }
    }

    /// An atom of `atoms`, once: the first node it covers writes it.
    private mutating func emit(_ atom: NSRange) {
        guard emitted.insert(atom.location).inserted else { return }
        self.atom(source.ns.substring(with: atom))
    }

    /// A text node holding atoms, as written (`InlineAtoms` keeps only those in text written as is): the text around
    /// them, and them.
    private mutating func appendSplitting(_ range: NSRange) {
        var cursor = range.location
        for atom in atoms where NSIntersectionRange(atom, range).length > 0 {
            if atom.location > cursor { appendText(source.ns.substring(with: NSRange(location: cursor, length: atom.location - cursor))) }
            emit(atom)
            cursor = max(cursor, NSMaxRange(atom))
        }
        if NSMaxRange(range) > cursor { appendText(source.ns.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor))) }
    }

    /// Plain text, with `==highlights==` (Obsidian's) as highlights, and the dates the Tasks plugin reads
    /// (`📅 2026-10-21`) as atoms: the page shows them as pills.
    mutating func appendText(_ string: String) {
        let ns = string as NSString
        var last = 0
        for match in Self.doubleEquals.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            appendDates(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            let start = location
            appendDates(ns.substring(with: match.range(at: 1)))
            mark(.highlight(color: nil), from: start)
            last = NSMaxRange(match.range)
        }
        appendDates(ns.substring(from: last))
    }

    /// `==text==`, the text not starting or ending with a space.
    private static let doubleEquals = try! NSRegularExpression(pattern: #"==(?=\S)([^=\n]*?\S)=="#)

    private mutating func appendDates(_ string: String) {
        let ns = string as NSString
        var last = 0
        for match in MarkdownStyler.datePattern.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            append(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            atom(ns.substring(with: match.range))
            last = NSMaxRange(match.range)
        }
        append(ns.substring(from: last))
    }

    nonisolated(unsafe) private static let openingTag = /^<(mark|strong|b|em|i|del|s|u|ins|sup|sub|kbd)(\s[^>]*)?>$/
    nonisolated(unsafe) private static let closingTag = /^<\/(mark|strong|b|em|i|del|s|u|ins|sup|sub|kbd)\s*>$/
    nonisolated(unsafe) private static let markColor = /background(?:-color)?\s*:\s*(#[0-9a-fA-F]{6})/

    /// `<mark>`, the tags Loam writes for marks Markdown cannot (`<strong>`, `<em>`, `<del>`) and the text-level ones
    /// Markdown has no syntax for (`<u>`, `<sup>`, `<sub>`, `<kbd>`) open and close a mark; any other tag is an atom.
    mutating func readTag(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = tag.wholeMatch(of: Self.openingTag) {
            let name = String(open.1).lowercased()
            let mark: InlineMark = switch name {
            case "mark": .highlight(color: open.2.flatMap { String($0).firstMatch(of: Self.markColor).map { String($0.1) } })
            case "strong", "b": .strong
            case "em", "i": .emphasis
            case "u", "ins": .underline
            case "sup": .superscript
            case "sub": .subscript
            case "kbd": .keyboard
            default: .strikethrough
            }
            openTags.append((name, mark, location))
        } else if let close = tag.wholeMatch(of: Self.closingTag),
                  let index = openTags.lastIndex(where: { $0.tag == String(close.1).lowercased() }) {
            let open = openTags.remove(at: index)
            mark(open.mark, from: open.start)
        } else {
            atom(raw)
        }
    }

    mutating func finish() -> InlineText {
        // A tag left open marks the text to the end, as a browser would show it.
        for open in openTags.reversed() { mark(open.mark, from: open.start) }
        openTags = []
        return InlineText(String(decoding: units, as: UTF16.self), runs: runs)
    }
}
