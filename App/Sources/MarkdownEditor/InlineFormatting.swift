import Foundation

/// An inline style the format bar and Cmd+B, Cmd+I toggle on the selection. Each writes standard Markdown, or the
/// HTML `<mark>` element CommonMark allows inline, for a highlight.
public enum InlineFormat: String, CaseIterable, Sendable {
    case bold
    case italic
    case strikethrough
    case code
    case highlight

    /// What is written around the text.
    var opening: String {
        switch self {
        case .bold: "**"
        case .italic: "_"
        case .strikethrough: "~~"
        case .code: "`"
        case .highlight: "<mark>"
        }
    }

    var closing: String { self == .highlight ? "</mark>" : opening }

    /// The opening and closing syntax recognised as this style, written by Loam or by hand.
    fileprivate var pattern: (open: String, close: String) {
        switch self {
        case .bold: (#"\*\*|__"#, #"\*\*|__"#)
        // A single `_` or `*`, not the end of a bold `**`.
        case .italic: (#"(?<!_)_|(?<!\*)\*"#, #"_(?!_)|\*(?!\*)"#)
        case .strikethrough: ("~~", "~~")
        case .code: ("`", "`")
        case .highlight: (#"<mark(?:\s[^>]*)?>"#, "</mark>")
        }
    }
}

/// A highlight colour, Craft's pastel squares. Yellow is a bare `<mark>`; the others name their colour in the
/// element's `style`, which any HTML renderer shows.
public enum HighlightColor: String, CaseIterable, Sendable {
    case yellow, lime, teal, blue, purple, red, orange

    public var hex: String {
        switch self {
        case .yellow: "#f6ef6b"
        case .lime: "#cdf27a"
        case .teal: "#82ead8"
        case .blue: "#a2c6fa"
        case .purple: "#e9b2f6"
        case .red: "#f2aaa6"
        case .orange: "#f5bf7f"
        }
    }

    var opening: String { self == .yellow ? "<mark>" : #"<mark style="background: \#(hex)">"# }
}

/// Wraps and unwraps the selection in inline syntax. Pure functions of the text and the selection, so they are
/// tested without an editor. A selection over several lines is styled line by line, after each line's block syntax
/// (`#`, `-`, `1.`, `>`, `- [ ]`), as Markdown cannot carry inline style across lines.
public enum InlineFormatting {
    /// Toggles `format`: removes it when every selected line already has it, otherwise adds it where missing. The
    /// selection ends on the styled text, without its syntax. With a caret, inserts the syntax around it.
    public static func toggle(_ format: InlineFormat, in text: String, selection: NSRange) -> TextEdit? {
        if selection.length == 0 {
            let caret = selection.location + (format.opening as NSString).length
            return TextEdit(
                range: selection, replacement: format.opening + format.closing,
                selection: NSRange(location: caret, length: 0)
            )
        }
        let segments = self.segments(of: selection, in: text, format: format)
        guard !segments.isEmpty else { return nil }
        let removing = segments.allSatisfy { $0.found != nil }
        return edit(text, segments) { segment in
            if removing {
                guard let found = segment.found else { return nil }
                return ("", "", found)
            }
            return segment.found == nil ? (format.opening, format.closing, nil) : nil
        }
    }

    /// Highlights the selection in `color`, or removes its highlight when `color` is nil. A highlight already there
    /// takes the new colour.
    public static func highlight(_ color: HighlightColor?, in text: String, selection: NSRange) -> TextEdit? {
        let segments = self.segments(of: selection, in: text, format: .highlight)
        guard !segments.isEmpty else { return nil }
        return edit(text, segments) { segment in
            guard let color else {
                guard let found = segment.found else { return nil }
                return ("", "", found)
            }
            return (color.opening, "</mark>", segment.found)
        }
    }

    /// Turns the selection into a link, `[text]()`, with the caret where the destination goes.
    public static func link(in text: String, selection: NSRange) -> TextEdit {
        let ns = text as NSString
        let label = ns.substring(with: selection)
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        // A selected address links to itself.
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"), !trimmed.contains(" ") {
            let replacement = "[\(trimmed)](\(trimmed))"
            return TextEdit(
                range: selection, replacement: replacement,
                selection: NSRange(location: selection.location + 1, length: (trimmed as NSString).length)
            )
        }
        let caret = selection.location + (label as NSString).length + 3
        return TextEdit(range: selection, replacement: "[\(label)]()", selection: NSRange(location: caret, length: 0))
    }

    /// Whether every selected line has `format`, so the bar shows its button pressed.
    public static func isActive(_ format: InlineFormat, in text: String, selection: NSRange) -> Bool {
        guard selection.length > 0 else { return false }
        let segments = self.segments(of: selection, in: text, format: format)
        return !segments.isEmpty && segments.allSatisfy { $0.found != nil }
    }

    // MARK: Segments

    /// Where the syntax already around (or at the ends of) a segment is: the opening and the closing.
    struct Found: Equatable {
        let open: NSRange
        let close: NSRange
    }

    struct Segment {
        /// The selected text of one line, without its block syntax or the spaces at its ends.
        let range: NSRange
        let found: Found?
    }

    /// The selected part of each line, and the syntax of `format` already around it.
    static func segments(of selection: NSRange, in text: String, format: InlineFormat) -> [Segment] {
        let ns = text as NSString
        guard selection.length > 0, NSMaxRange(selection) <= ns.length else { return [] }
        var segments: [Segment] = []
        var lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        while lineStart < NSMaxRange(selection) {
            let line = ns.lineWithoutBreak(at: lineStart)
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: lineStart, length: 0)))
            let contentStart = line.location + blockPrefixLength(ns.substring(with: line))
            var start = max(selection.location, contentStart)
            var end = min(NSMaxRange(selection), NSMaxRange(line))
            while start < end, isSpace(ns.character(at: start)) { start += 1 }
            while end > start, isSpace(ns.character(at: end - 1)) { end -= 1 }
            if end > start {
                let range = NSRange(location: start, length: end - start)
                segments.append(Segment(range: range, found: find(format, around: range, in: line, of: ns)))
            }
            guard next > lineStart else { break }
            lineStart = next
        }
        return segments
    }

    /// The syntax of `format` just outside `range` on its line, or at its very ends.
    private static func find(_ format: InlineFormat, around range: NSRange, in line: NSRange, of ns: NSString) -> Found? {
        let (open, close) = format.pattern
        let before = NSRange(location: line.location, length: range.location - line.location)
        let after = NSRange(location: NSMaxRange(range), length: NSMaxRange(line) - NSMaxRange(range))
        if let opening = match("(?:\(open))$", in: ns, range: before),
           let closing = match("^(?:\(close))", in: ns, range: after) {
            return Found(open: opening, close: closing)
        }
        if let opening = match("^(?:\(open))", in: ns, range: range),
           let closing = match("(?:\(close))$", in: ns, range: range),
           closing.location >= NSMaxRange(opening) {
            return Found(open: opening, close: closing)
        }
        return nil
    }

    private static func match(_ pattern: String, in ns: NSString, range: NSRange) -> NSRange? {
        guard range.length > 0, let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: ns as String, range: range)?.range
    }

    /// The length of a line's block syntax: indentation, quote marks, a heading's `#`, a list marker, a task box.
    static func blockPrefixLength(_ line: String) -> Int {
        let pattern = #"^\s*(?:>\s?)*(?:#{1,6}\s+|(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return 0 }
        return match.range.length
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }

    // MARK: Building the edit

    /// Applies, per segment, a new opening and closing (replacing `found` when given, else inserted around the
    /// segment), as one edit over the lines. The selection runs from the first segment's text to the last one's.
    private static func edit(
        _ text: String,
        _ segments: [Segment],
        change: (Segment) -> (open: String, close: String, found: Found?)?
    ) -> TextEdit? {
        let ns = text as NSString
        // Replacements in the original text, in order.
        var replacements: [(range: NSRange, text: String)] = []
        var inner: [NSRange] = []
        for segment in segments {
            var content = segment.range
            if let found = segment.found, found.open.location >= segment.range.location {
                // The syntax is inside the selection: the text is what lies between.
                content = NSRange(location: NSMaxRange(found.open), length: found.close.location - NSMaxRange(found.open))
            }
            inner.append(content)
            guard let (open, close, found) = change(segment) else { continue }
            if let found {
                replacements.append((found.open, open))
                replacements.append((found.close, close))
            } else {
                replacements.append((NSRange(location: segment.range.location, length: 0), open))
                replacements.append((NSRange(location: NSMaxRange(segment.range), length: 0), close))
            }
        }
        guard let first = replacements.first, let last = replacements.last else { return nil }

        let region = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var result = ""
        var cursor = region.location
        for replacement in replacements {
            result += ns.substring(with: NSRange(location: cursor, length: replacement.range.location - cursor))
            result += replacement.text
            cursor = NSMaxRange(replacement.range)
        }
        result += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(region) - cursor))

        // Moves an offset of the original text into the new one. An insertion at the offset itself pushes a start
        // forward (the opening goes before the text) but not an end (the closing goes after it).
        func map(_ offset: Int, isStart: Bool) -> Int {
            var delta = 0
            for replacement in replacements {
                let before = isStart ? replacement.range.location <= offset : replacement.range.location < offset
                guard before, NSMaxRange(replacement.range) <= offset || replacement.range.length == 0 else { continue }
                delta += (replacement.text as NSString).length - replacement.range.length
            }
            return offset + delta
        }
        let start = map(inner.first!.location, isStart: true)
        let end = map(NSMaxRange(inner.last!), isStart: false)
        return TextEdit(range: region, replacement: result, selection: NSRange(location: start, length: max(0, end - start)))
    }
}
