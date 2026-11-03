import Foundation
import Markdown

/// What a stretch of Markdown source looks like in the editor.
public enum MarkdownStyle: Hashable, Sendable {
    case heading(level: Int)
    case strong
    case emphasis
    case strikethrough
    /// The text of a `<mark>` element, on its colour (`#rrggbb` from its `style`), or the default yellow when nil.
    case highlight(color: String?)
    case inlineCode
    case codeBlock
    case quote
    /// The visible text of a link; the destination is what a click opens.
    case link(destination: String)
    /// `-`, `*`, `+`, `1.` at the start of a list item; `depth` is how many lists hold it (0 at the top).
    case listMarker(depth: Int)
    /// The `[ ]` or `[x]` of a task list item. Clicking it toggles the task.
    case taskBox(checked: Bool)
    /// The text of a checked task.
    case completedTask
    case table
    case frontmatter
    /// `[!NOTE]`, `[!WARNING]`... at the start of a GitHub-style alert.
    case alert
    /// Syntax characters (`#`, `**`, `` ` ``, `](url)`...): kept visible, dimmed.
    case marker
    /// Syntax the editor hides, taking no room, unless the caret is inside it, as Craft shows a formatted document:
    /// `#`, `**`, `_`, `~~`, `` ` ``, a link's brackets and destination, code fences, a setext underline. Always on
    /// top of a `marker`.
    case concealable
    /// Syntax the editor makes invisible but keeps the room of, because it draws something in its place: a `---`
    /// divider (a hairline). Shown again when the caret is inside it.
    case invisible
    /// Syntax hidden, taking no room, unless the selection reaches into `block`: the `tags: [`, commas and brackets
    /// around the tags of the frontmatter, shown as YAML again while the caret is in the frontmatter.
    case concealedOutside(block: NSRange)
    /// A tag, drawn as Craft's: a pill, tinted with the link colour. Inline, the range is `#tag`; in the frontmatter
    /// it is the bare name in `block`, drawn with a `#` before it unless the selection reaches into `block`.
    case tag(frontmatter: NSRange?)
    /// A day written as the task convention writes it, `📅 2026-10-21` or `due:2026-10-21` (a due date) or
    /// `✅ 2026-10-21` (done that day), drawn as Craft's date pill ("Today", "Wed, Oct 21") unless the selection
    /// reaches into it. `openTask`: on the line of an unchecked task, where a past due date is overdue.
    case date(day: String, completion: Bool, openTask: Bool)
    /// A closed fenced code block with a language (` ```mermaid `), the whole block from fence to fence. `code` is
    /// the text between the fences. A host may draw it as a picture (`PictureRenderer`); otherwise it is a code
    /// block like any other.
    case fencedCode(language: String, code: NSRange)
    /// A line holding nothing but an image link, `![alt](destination)`: the whole line. A host may show what it points
    /// to in its place (`EmbedProvider`): a picture, a player; otherwise it is a link like any other.
    case embed(destination: String, alt: String)
}

public struct StyleSpan: Hashable, Sendable {
    public let range: NSRange
    public let style: MarkdownStyle

    /// Where the selection shows the syntax the editor hides or draws over: the span itself, or the frontmatter
    /// for its tags. Nil for what looks the same wherever the caret is.
    var revealRange: NSRange? {
        switch style {
        case .concealable, .invisible, .listMarker, .taskBox, .date: range
        case .concealedOutside(let block): block
        case .tag(let frontmatter): frontmatter
        case .fencedCode: range
        // The line and the line breaks around it, so a caret at either end of the line shows the link too.
        case .embed: NSRange(location: max(0, range.location - 1), length: range.length + (range.location > 0 ? 2 : 1))
        default: nil
        }
    }

    public init(_ style: MarkdownStyle, _ range: NSRange) {
        self.range = range
        self.style = style
    }
}

/// Turns Markdown source into style spans, in UTF-16 offsets (`NSString` ranges). The text itself is never
/// changed: the editor shows the plain source, styled.
public enum MarkdownStyler {
    public static func spans(in text: String) -> [StyleSpan] {
        let source = SourceMap(text)
        var spans: [StyleSpan] = []

        var parsed = text
        if let frontmatter = frontmatterRange(in: source.ns) {
            spans.append(StyleSpan(.frontmatter, frontmatter))
            let opening = source.line(at: frontmatter.location)
            let closing = source.line(at: max(frontmatter.location, NSMaxRange(frontmatter) - 1))
            for fence in [opening, closing] { spans.append(StyleSpan(.marker, fence)) }
            let tags = frontmatterTags(in: frontmatter, of: source.ns)
            spans += tags
            // Craft shows a page, not its metadata: the YAML takes no room, only the tags stay, as pills, until
            // the caret goes into it (the note's properties are in the Note Info panel).
            var location = frontmatter.location
            while location < NSMaxRange(frontmatter) {
                let line = source.ns.lineRange(for: NSRange(location: location, length: 0))
                let hasTag = tags.contains { span in
                    if case .tag = span.style { return NSIntersectionRange(span.range, line).length > 0 }
                    return false
                }
                if !hasTag { spans.append(StyleSpan(.concealedOutside(block: frontmatter), line)) }
                location = NSMaxRange(line)
            }
            // Keep the line numbers of everything after it, so source locations stay valid.
            let newlines = source.ns.substring(with: frontmatter).filter { $0 == "\n" }.count
            parsed = String(repeating: "\n", count: newlines) + source.ns.substring(from: NSMaxRange(frontmatter))
        }

        var collector = Collector(source: source, spans: [], openTask: nil)
        collector.visit(Document(parsing: parsed))
        spans += collector.spans
        spans += highlights(in: source.ns, outside: spans)
        spans += wikilinks(in: source.ns, outside: spans)
        spans += referenceDefinitions(in: source.ns, outside: spans)
        // Once each: inline HTML (`<mark>`) can be marked by two passes, and the count must not depend on the context.
        var seen = Set<StyleSpan>()
        return spans.filter { $0.range.length > 0 && seen.insert($0).inserted }
    }

    /// A backslash before an ASCII punctuation character: Markdown's escape.
    static let escape = try! NSRegularExpression(pattern: #"\\(?=[!-/:-@\[-`{-~])"#)

    /// `[label]: destination "title"`: a link reference definition, which the parser takes out of the text.
    static let referenceDefinition = try! NSRegularExpression(pattern: #"^ {0,3}\[(?!\^)[^\]\n]+\]:[ \t]*\S.*$"#, options: .anchorsMatchLines)

    /// The lines that define link references, hidden: they hold no text for the reader. Not in code, not in the
    /// frontmatter, and only where a paragraph does not run on into them.
    static func referenceDefinitions(in ns: NSString, outside spans: [StyleSpan]) -> [StyleSpan] {
        let skipped = spans.filter { [.inlineCode, .codeBlock, .frontmatter, .table].contains($0.style) }.map(\.range)
        var result: [StyleSpan] = []
        var previousStarts = true
        var location = 0
        let string = ns as String
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            var bare = line
            while bare.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(bare) - 1)) { bare.length -= 1 }
            // A definition starts with `[`, after at most three spaces: most lines are ruled out by one look.
            var first = bare.location
            while first < NSMaxRange(bare), first < bare.location + 3, ns.character(at: first) == 32 { first += 1 }
            let isDefinition = first < NSMaxRange(bare) && ns.character(at: first) == 91
                && referenceDefinition.firstMatch(in: string, range: bare)?.range == bare
                && !skipped.contains { NSIntersectionRange($0, bare).length > 0 }
            if isDefinition && previousStarts {
                // The line break goes too, or the line would stay as a blank one.
                let hidden = NSRange(location: bare.location, length: line.length)
                result.append(StyleSpan(.marker, hidden))
                result.append(StyleSpan(.concealable, hidden))
            }
            previousStarts = bare.length == 0 || isDefinition
            location = NSMaxRange(line)
        }
        return result
    }

    static let mark = try! NSRegularExpression(
        pattern: #"<mark(?:\s+style="background(?:-color)?:\s*(#[0-9a-fA-F]{6})[^"]*")?\s*>(.+?)</mark>"#
    )

    /// `<mark>` elements on one line: the text on its colour, the tags hidden like the other syntax. Not in code.
    static func highlights(in ns: NSString, outside spans: [StyleSpan]) -> [StyleSpan] {
        let code = spans.filter { [.inlineCode, .codeBlock, .frontmatter].contains($0.style) }.map(\.range)
        var result: [StyleSpan] = []
        for match in mark.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
            guard !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let text = match.range(at: 2)
            let color = match.range(at: 1).location == NSNotFound ? nil : ns.substring(with: match.range(at: 1))
            result.append(StyleSpan(.highlight(color: color), text))
            for tag in [
                NSRange(location: match.range.location, length: text.location - match.range.location),
                NSRange(location: NSMaxRange(text), length: NSMaxRange(match.range) - NSMaxRange(text)),
            ] {
                result.append(StyleSpan(.marker, tag))
                result.append(StyleSpan(.concealable, tag))
            }
        }
        return result
    }

    static let wikilink = try! NSRegularExpression(pattern: #"(?<![\\!])\[\[([^\[\]|\n]+?)(\\?\|[^\[\]\n]+?)?\]\]"#)

    /// `[[Note]]` and `[[Note|text]]` (`[[Note\\|text]]` in a table, as Obsidian writes it) on one line: the text a link to the note (`MarkdownTheme.noteLinkScheme`), the
    /// brackets and the target before a `|` hidden like a link's syntax. Not in code.
    static func wikilinks(in ns: NSString, outside spans: [StyleSpan]) -> [StyleSpan] {
        guard ns.range(of: "[[").location != NSNotFound else { return [] }
        let code = spans.filter { [.inlineCode, .codeBlock, .frontmatter].contains($0.style) }.map(\.range)
        var result: [StyleSpan] = []
        for match in wikilink.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
            guard !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let target = match.range(at: 1)
            let alias = match.range(at: 2)
            let bar = alias.location == NSNotFound ? 0 : (ns.character(at: alias.location) == 92 ? 2 : 1)
            let shown = alias.location == NSNotFound ? target : NSRange(location: alias.location + bar, length: alias.length - bar)
            result.append(StyleSpan(.link(destination: MarkdownTheme.noteLinkScheme + ns.substring(with: target)), shown))
            for hidden in [
                NSRange(location: match.range.location, length: shown.location - match.range.location),
                NSRange(location: NSMaxRange(shown), length: NSMaxRange(match.range) - NSMaxRange(shown)),
            ] where hidden.length > 0 {
                result.append(StyleSpan(.marker, hidden))
                result.append(StyleSpan(.concealable, hidden))
            }
        }
        return result
    }

    /// The `tags` property of the frontmatter as pills: each name a `.tag`, the rest of its lines hidden. Reads
    /// `tags: [a, b]`, `tags: a, b` and a block list (`tags:` then `  - a` lines).
    static func frontmatterTags(in block: NSRange, of ns: NSString) -> [StyleSpan] {
        var spans: [StyleSpan] = []
        var location = NSMaxRange(ns.lineRange(for: NSRange(location: block.location, length: 0)))
        var inList = false
        while location < NSMaxRange(block) {
            let lineWithBreak = ns.lineRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(lineWithBreak) }
            var line = lineWithBreak
            while line.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(line) - 1)) { line.length -= 1 }
            guard NSMaxRange(line) < NSMaxRange(block) else { break }
            let text = ns.substring(with: line)
            var valueStart: Int
            if text.hasPrefix("tags:") {
                valueStart = line.location + 5
                inList = text.dropFirst(5).trimmingCharacters(in: .whitespaces).isEmpty
                if inList {
                    spans.append(StyleSpan(.concealedOutside(block: block), line))
                    continue
                }
            } else if inList, text.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                valueStart = line.location + (text as NSString).range(of: "-").location + 1
            } else {
                inList = false
                continue
            }
            // Names are runs of anything but separators; the rest of the line is hidden.
            var hiddenFrom = line.location
            var index = valueStart
            while index <= NSMaxRange(line) {
                let isSeparator = index == NSMaxRange(line) || Self.tagSeparators.contains(ns.character(at: index))
                if isSeparator { index += 1; continue }
                var end = index
                while end < NSMaxRange(line), !Self.tagSeparators.contains(ns.character(at: end)) { end += 1 }
                // A space just before a name stays, as the gap between two pills.
                let gapEnd = index > hiddenFrom && ns.character(at: index - 1) == 32 && index - 1 > valueStart ? index - 1 : index
                if gapEnd > hiddenFrom { spans.append(StyleSpan(.concealedOutside(block: block), NSRange(location: hiddenFrom, length: gapEnd - hiddenFrom))) }
                var name = NSRange(location: index, length: end - index)
                if ns.character(at: index) == 35, name.length > 1 { name = NSRange(location: index + 1, length: name.length - 1) }
                if name.location > index { spans.append(StyleSpan(.concealedOutside(block: block), NSRange(location: index, length: 1))) }
                spans.append(StyleSpan(.tag(frontmatter: block), name))
                hiddenFrom = end
                index = end
            }
            if NSMaxRange(line) > hiddenFrom {
                spans.append(StyleSpan(.concealedOutside(block: block), NSRange(location: hiddenFrom, length: NSMaxRange(line) - hiddenFrom)))
            }
        }
        return spans
    }

    /// Space, tab, `,`, `[`, `]`, `"`, `'`.
    private static let tagSeparators: Set<unichar> = [32, 9, 44, 91, 93, 34, 39]

    /// `#tag` in the text, as `NoteParser` reads it: not after a letter, a digit, `/`, `&` or `#`.
    static let hashtag = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_/&#])#[\\p{L}\\p{N}_][\\p{L}\\p{N}_/-]*")

    /// `📅 2026-10-21`, `due:2026-10-21` and `✅ 2026-10-21`, as the Tasks plugin reads them. Group 1 is the mark,
    /// group 2 the day.
    static let datePattern = try! NSRegularExpression(
        pattern: "(📅|✅|(?<!\\S)due:)\\s?([0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01]))(?![0-9])"
    )

    /// A YAML block that opens the note: `---` on the first line, closed by `---` or `...`.
    static func frontmatterRange(in ns: NSString) -> NSRange? {
        guard ns.hasPrefix("---\n") || ns.hasPrefix("---\r\n") else { return nil }
        var location = NSMaxRange(ns.lineRange(for: NSRange(location: 0, length: 0)))
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if content == "---" || content == "..." {
                return NSRange(location: 0, length: NSMaxRange(line))
            }
            location = NSMaxRange(line)
        }
        return nil
    }
}

/// Converts swift-markdown source locations (1-based line, 1-based UTF-8 column) to UTF-16 offsets.
struct SourceMap {
    let ns: NSString
    /// The same text as a `String`, once: the regex calls take one, and bridging `ns` back costs a copy each time.
    let string: String
    private let utf16ByUTF8: [Int]
    private let lineStarts: [Int]

    init(_ text: String) {
        ns = text as NSString
        string = text
        var map: [Int] = []
        map.reserveCapacity(text.utf8.count + 1)
        var lineStarts = [0]
        var utf8 = 0
        var utf16 = 0
        for scalar in text.unicodeScalars {
            let width8 = UTF8.width(scalar)
            for _ in 0..<width8 { map.append(utf16) }
            utf8 += width8
            utf16 += UTF16.width(scalar)
            if scalar == "\n" { lineStarts.append(utf8) }
        }
        map.append(utf16)
        utf16ByUTF8 = map
        self.lineStarts = lineStarts
    }

    func offset(_ location: SourceLocation) -> Int {
        let line = min(max(location.line, 1), lineStarts.count)
        let utf8 = min(lineStarts[line - 1] + max(location.column - 1, 0), utf16ByUTF8.count - 1)
        return utf16ByUTF8[utf8]
    }

    func range(_ markup: Markup) -> NSRange? {
        guard let range = markup.range else { return nil }
        let start = offset(range.lowerBound)
        let end = max(start, offset(range.upperBound))
        return NSRange(location: start, length: end - start)
    }

    /// The line containing `location`, without its line break.
    func line(at location: Int) -> NSRange {
        var line = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        while line.length > 0, isNewline(ns.character(at: NSMaxRange(line) - 1)) { line.length -= 1 }
        return line
    }

    func character(at index: Int) -> unichar? {
        index >= 0 && index < ns.length ? ns.character(at: index) : nil
    }

    /// Number of consecutive `character` from `index`.
    func run(of character: Character, from index: Int, limit: Int) -> Int {
        let code = character.utf16.first!
        var count = 0
        while index + count < limit, ns.character(at: index + count) == code { count += 1 }
        return count
    }

    private func isNewline(_ c: unichar) -> Bool { c == 10 || c == 13 }
}

private struct Collector {
    let source: SourceMap
    var spans: [StyleSpan]
    /// While visiting a task item's text: whether it is unchecked.
    var openTask: Bool?
    /// While visiting the children of an emphasis or strong: its range and marker width.
    var enclosing: (range: NSRange, width: Int)?

    mutating func add(_ style: MarkdownStyle, _ range: NSRange) {
        spans.append(StyleSpan(style, range))
    }

    mutating func visitChildren(_ markup: Markup) {
        for child in markup.children { visit(child) }
    }

    mutating func visit(_ markup: Markup) {
        guard let range = source.range(markup) else { return visitChildren(markup) }
        switch markup {
        case let heading as Heading:
            visitHeading(heading, range)
        case is Strong:
            symmetric(markup, .strong, range, width: 2)
        case is Emphasis:
            symmetric(markup, .emphasis, range, width: 1)
        case is Strikethrough:
            symmetric(markup, .strikethrough, range, width: source.run(of: "~", from: range.location, limit: NSMaxRange(range)))
        case is InlineCode:
            let ticks = source.run(of: "`", from: range.location, limit: NSMaxRange(range))
            add(.inlineCode, range)
            markEnds(range, width: ticks)
        case let code as CodeBlock:
            visitCodeBlock(code, range)
        case is BlockQuote:
            visitQuote(markup, range)
        case let item as ListItem:
            visitListItem(item, range)
        case let link as Link:
            visitLink(link, range, destination: link.destination ?? "")
        case let image as Image:
            visitLink(markup, range, destination: nil, imageSource: image.source)
            let line = source.line(at: range.location)
            if NSMaxRange(range) <= NSMaxRange(line),
               source.ns.substring(with: line).trimmingCharacters(in: .whitespaces) == source.ns.substring(with: range) {
                add(.embed(destination: image.source ?? "", alt: image.plainText), line)
            }
        case is ThematicBreak:
            add(.marker, source.line(at: range.location))
            add(.invisible, source.line(at: range.location))
        case is Table:
            visitTable(markup, range)
        case is HTMLBlock, is InlineHTML:
            add(.marker, range)
            // A comment is for the file's readers, not the page's.
            if source.ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<!--") {
                add(.concealable, range)
            }
        case is Text:
            guard !(markup.parent is Link) else { return }
            // Most text holds none of these: a plain character search first spares three regex passes per text node.
            func holds(_ character: String) -> Bool { source.ns.range(of: character, range: range).location != NSNotFound }
            // A backslash that escapes a character (`\*`) is syntax, not text.
            if holds("\\") {
                for match in MarkdownStyler.escape.matches(in: source.string, range: range) {
                    let backslash = NSRange(location: match.range.location, length: 1)
                    add(.marker, backslash)
                    add(.concealable, backslash)
                }
            }
            if holds("#") {
                for match in MarkdownStyler.hashtag.matches(in: source.string, options: .withTransparentBounds, range: range) {
                    add(.tag(frontmatter: nil), match.range)
                }
            }
            // A date is written `YYYY-MM-DD`.
            if holds("-") {
                for match in MarkdownStyler.datePattern.matches(in: source.string, options: .withTransparentBounds, range: range) {
                    let mark = source.ns.substring(with: match.range(at: 1))
                    add(.date(day: source.ns.substring(with: match.range(at: 2)), completion: mark == "✅", openTask: openTask == true), match.range)
                }
            }
        default:
            visitChildren(markup)
        }
    }

    // MARK: Inline

    mutating func symmetric(_ markup: Markup, _ style: MarkdownStyle, _ range: NSRange, width: Int) {
        // `***both***` is reported as an emphasis and a strong over the same characters: the inner one is inside the
        // outer one's markers.
        var inner = range
        if let outer = enclosing, outer.range == range, range.length > 2 * outer.width {
            inner = NSRange(location: range.location + outer.width, length: range.length - 2 * outer.width)
        }
        add(style, inner)
        markEnds(inner, width: width)
        let saved = enclosing
        enclosing = (range, width)
        visitChildren(markup)
        enclosing = saved
    }

    mutating func markEnds(_ range: NSRange, width: Int) {
        guard width > 0, range.length >= 2 * width else { return }
        for end in [NSRange(location: range.location, length: width), NSRange(location: NSMaxRange(range) - width, length: width)] {
            add(.marker, end)
            add(.concealable, end)
        }
    }

    mutating func visitLink(_ markup: Markup, _ range: NSRange, destination: String?, imageSource: String? = nil) {
        let isImage = destination == nil
        let open = isImage ? 2 : 1
        let opener = source.character(at: range.location)
        guard opener == (isImage ? 33 : 91) else {
            // An autolink, `<https://...>`: the angle brackets are hidden like a link's. A bare URL is all link.
            guard let destination else { return visitChildren(markup) }
            if opener == 60, range.length > 2, source.character(at: NSMaxRange(range) - 1) == 62 {
                for bracket in [NSRange(location: range.location, length: 1), NSRange(location: NSMaxRange(range) - 1, length: 1)] {
                    add(.marker, bracket)
                    add(.concealable, bracket)
                }
                add(.link(destination: destination), NSRange(location: range.location + 1, length: range.length - 2))
            } else {
                add(.link(destination: destination), range)
            }
            return visitChildren(markup)
        }
        let children = Array(markup.children).compactMap { source.range($0) }
        let textStart = children.first?.location ?? range.location + open
        let textEnd = children.last.map(NSMaxRange) ?? textStart
        let opening = NSRange(location: range.location, length: textStart - range.location)
        let closing = NSRange(location: textEnd, length: NSMaxRange(range) - textEnd)
        add(.marker, opening)
        if let destination { add(.link(destination: destination), NSRange(location: textStart, length: textEnd - textStart)) }
        add(.marker, closing)
        // An image shows its alt text, as a link to the file; without one it keeps its syntax, as hiding it would leave
        // nothing on the line.
        let hasAlt = textEnd > textStart
        if isImage, hasAlt, let imageSource {
            add(.link(destination: imageSource), NSRange(location: textStart, length: textEnd - textStart))
        }
        if !isImage || hasAlt {
            add(.concealable, opening)
            add(.concealable, closing)
        }
        visitChildren(markup)
    }

    // MARK: Blocks

    mutating func visitHeading(_ heading: Heading, _ range: NSRange) {
        let first = source.line(at: range.location)
        let text = source.ns.substring(with: first)
        if text.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            add(.heading(level: heading.level), first)
            let leadingSpaces = text.prefix { $0 == " " }.count
            let hashes = source.run(of: "#", from: first.location + leadingSpaces, limit: NSMaxRange(first))
            var markerEnd = first.location + leadingSpaces + hashes
            while markerEnd < NSMaxRange(first), source.character(at: markerEnd) == 32 { markerEnd += 1 }
            add(.marker, NSRange(location: first.location, length: markerEnd - first.location))
            // The `#`s of a heading with no text yet show, so what is being typed is seen.
            if markerEnd < NSMaxRange(first) {
                add(.concealable, NSRange(location: first.location, length: markerEnd - first.location))
            }
            if let closing = text.range(of: #"\s+#+\s*$"#, options: .regularExpression), closing.lowerBound > text.startIndex {
                let start = first.location + text.utf16.distance(from: text.startIndex, to: closing.lowerBound)
                if start >= markerEnd {
                    add(.marker, NSRange(location: start, length: NSMaxRange(first) - start))
                    add(.concealable, NSRange(location: start, length: NSMaxRange(first) - start))
                }
            }
        } else {
            // Setext: text lines, then a `===` or `---` underline.
            let lastText = Array(heading.children).compactMap { source.range($0) }.last.map(NSMaxRange) ?? NSMaxRange(first)
            let lastLine = source.line(at: lastText)
            // A lone `-` under a text is a list item being started (Return then Tab in a list gives `- text` then
            // `  - `): an empty item cannot follow a paragraph, so Markdown reads a setext heading. It shows as the
            // item it will be once it has text.
            if NSMaxRange(lastLine) + 1 < source.ns.length {
                let underline = source.line(at: NSMaxRange(lastLine) + 1)
                if source.ns.substring(with: underline).trimmingCharacters(in: .whitespaces) == "-" {
                    var depth = 0
                    var parent = heading.parent
                    while let node = parent {
                        if node is ListItem { depth += 1 }
                        parent = node.parent
                    }
                    let dash = source.ns.range(of: "-", range: underline)
                    add(.listMarker(depth: depth), dash)
                    return visitChildren(heading)
                }
            }
            add(.heading(level: heading.level), NSRange(location: first.location, length: NSMaxRange(lastLine) - first.location))
            if NSMaxRange(lastLine) + 1 < source.ns.length {
                add(.marker, source.line(at: NSMaxRange(lastLine) + 1))
                add(.concealable, source.line(at: NSMaxRange(lastLine) + 1))
            }
        }
        visitChildren(heading)
    }

    mutating func visitCodeBlock(_ code: CodeBlock, _ range: NSRange) {
        let first = source.line(at: range.location)
        var block = NSRange(location: first.location, length: max(0, NSMaxRange(range) - first.location))
        let trimmedEnd = source.line(at: max(block.location, NSMaxRange(block) - 1))
        if NSMaxRange(trimmedEnd) < NSMaxRange(block) { block.length = NSMaxRange(trimmedEnd) - block.location }
        let opener = source.ns.substring(with: first).trimmingCharacters(in: .whitespaces)
        if opener.hasPrefix("```") || opener.hasPrefix("~~~") {
            add(.marker, first)
            add(.concealable, first)
            let last = source.line(at: max(first.location, NSMaxRange(block) - 1))
            let closer = source.ns.substring(with: last).trimmingCharacters(in: .whitespaces)
            if last.location > first.location, closer.hasPrefix(String(opener.prefix(3))) {
                add(.marker, last)
                add(.concealable, last)
                if let language = code.language?.split(separator: " ").first.map({ $0.lowercased() }), !language.isEmpty {
                    let start = min(NSMaxRange(first) + 1, last.location)
                    let end = max(start, last.location - 1)
                    add(.fencedCode(language: language, code: NSRange(location: start, length: end - start)), block)
                }
            } else {
                // An unclosed fence runs to the end of the note.
                block.length = source.ns.length - block.location
            }
        }
        add(.codeBlock, block)
    }

    mutating func visitQuote(_ quote: Markup, _ range: NSRange) {
        let block = clampToLines(range)
        add(.quote, block)
        var location = block.location
        var isFirst = true
        while location < NSMaxRange(block) {
            let line = source.line(at: location)
            var end = line.location
            while end < NSMaxRange(line), let c = source.character(at: end), c == 32 || c == 62 { end += 1 }
            // The `>` takes no room: the quote is indented and the editor draws its bar instead.
            add(.marker, NSRange(location: line.location, length: end - line.location))
            add(.concealable, NSRange(location: line.location, length: end - line.location))
            if isFirst {
                let rest = source.ns.substring(with: NSRange(location: end, length: NSMaxRange(line) - end))
                if let alert = rest.range(of: #"^\[![A-Za-z]+\]"#, options: .regularExpression) {
                    let label = NSRange(location: end, length: rest.utf16.distance(from: alert.lowerBound, to: alert.upperBound))
                    add(.alert, label)
                    // `[!NOTE]` reads as NOTE, the title of the callout.
                    for bracket in [NSRange(location: label.location, length: 2), NSRange(location: NSMaxRange(label) - 1, length: 1)] {
                        add(.marker, bracket)
                        add(.concealable, bracket)
                    }
                }
                isFirst = false
            }
            location = NSMaxRange(line) + 1
        }
        visitChildren(quote)
    }

    mutating func visitListItem(_ item: ListItem, _ range: NSRange) {
        let line = source.line(at: range.location)
        var cursor = range.location
        while cursor < NSMaxRange(line), source.character(at: cursor) == 32 { cursor += 1 }
        let markerStart = cursor
        while cursor < NSMaxRange(line), let c = source.character(at: cursor), !(c == 32 || c == 9) { cursor += 1 }
        var depth = 0
        var parent = item.parent
        while let node = parent {
            if node is ListItem { depth += 1 }
            parent = node.parent
        }
        add(.listMarker(depth: depth), NSRange(location: markerStart, length: cursor - markerStart))
        while cursor < NSMaxRange(line), let c = source.character(at: cursor), c == 32 || c == 9 { cursor += 1 }
        if let checkbox = item.checkbox, cursor + 3 <= NSMaxRange(line), source.character(at: cursor) == 91 {
            let checked = checkbox == .checked
            add(.taskBox(checked: checked), NSRange(location: cursor, length: 3))
            if checked, let first = Array(item.children).first, let content = source.range(first) {
                let start = max(content.location, cursor + 3)
                add(.completedTask, NSRange(location: start, length: max(0, NSMaxRange(clampToLines(content)) - start)))
            }
        }
        let outer = openTask
        openTask = item.checkbox.map { $0 == .unchecked }
        visitChildren(item)
        openTask = outer
    }

    mutating func visitTable(_ table: Markup, _ range: NSRange) {
        // The editor shows the table as a component (`TableBlockView`) and hides these lines.
        add(.table, clampToLines(range))
    }

    /// Drops a trailing line break or an end that swift-markdown places at the start of the next line.
    func clampToLines(_ range: NSRange) -> NSRange {
        guard range.length > 0 else { return range }
        let last = source.line(at: NSMaxRange(range) - 1)
        let end = min(NSMaxRange(range), NSMaxRange(last))
        return NSRange(location: range.location, length: max(0, end - range.location))
    }
}
