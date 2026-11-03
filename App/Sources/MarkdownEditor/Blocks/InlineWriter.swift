import Foundation

/// Writes `InlineText` as Markdown: marks as `**`, `*`, `~~`, backticks, `<mark>` and links; text escaped so that
/// reading it back gives the same characters. `NoteWriter` checks what it wrote and falls back to `.html` (marks as
/// `<strong>`, `<em>`, `<del>`, which never depend on the characters around them) when Markdown's rules would read it
/// otherwise.
enum InlineWriter {
    enum Style: CaseIterable {
        case markdown
        case html
    }

    static func markdown(_ text: InlineText, style: Style = .markdown, atLineStart: Bool = true) -> String {
        render(tokens(of: text), style: style, atLineStart: atLineStart)
    }

    /// `text` as it can be written: no spaces at a line's ends (Markdown drops them), no empty line (it would end the
    /// paragraph), none at the inner edges of a strong, emphasis or strikethrough (their markers would not close), and
    /// no code over a line break or an atom.
    static func prepared(_ text: InlineText) -> InlineText {
        let units = Array(text.string.utf16)
        let lineBreak = InlineText.lineBreak.utf16.first!
        var keep = [Bool](repeating: true, count: units.count)
        // Spaces at the start and the end of each line, and the break after an empty line.
        var lineStart = 0
        var keptLine = false
        for index in 0...units.count where index == units.count || units[index] == lineBreak {
            var start = lineStart
            while start < index, isSpace(units[start]) { keep[start] = false; start += 1 }
            var end = index
            while end > start, isSpace(units[end - 1]) { keep[end - 1] = false; end -= 1 }
            if end == start, index < units.count {
                // An empty line: its break goes, so no blank line splits the block.
                keep[index] = false
            } else if end > start {
                keptLine = true
            }
            lineStart = index + 1
        }
        // No break at the very end: the last kept break is before an empty last line.
        if keptLine, let last = keep.indices.last(where: { keep[$0] }), units[last] == lineBreak { keep[last] = false }
        var map = [Int](repeating: 0, count: units.count + 1)
        var kept: [UInt16] = []
        for index in units.indices {
            map[index] = kept.count
            if keep[index] { kept.append(units[index]) }
        }
        map[units.count] = kept.count
        var runs: [InlineRun] = []
        for run in text.runs {
            var start = map[run.range.location]
            var end = map[NSMaxRange(run.range)]
            switch run.mark {
            case .strong, .emphasis, .strikethrough:
                while start < end, isSpace(kept[start]) || kept[start] == lineBreak { start += 1 }
                while end > start, isSpace(kept[end - 1]) || kept[end - 1] == lineBreak { end -= 1 }
            default:
                break
            }
            guard end > start else { continue }
            if run.mark == .code {
                // Code stops at a line break or an atom.
                var from = start
                for index in start...end where index == end || kept[index] == lineBreak || kept[index] == InlineText.atom.utf16.first! {
                    if index > from { runs.append(InlineRun(NSRange(location: from, length: index - from), .code)) }
                    from = index + 1
                }
            } else {
                runs.append(InlineRun(NSRange(location: start, length: end - start), run.mark))
            }
        }
        return InlineText(String(decoding: kept, as: UTF16.self), runs: runs)
    }

    private static func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }

    // MARK: Tokens

    enum Token: Equatable {
        case open(InlineMark)
        case close(InlineMark)
        case text(String)
        case atom(String)
        case lineBreak(hard: Bool)
    }

    /// The text cut where marks start and end, with the marks opened and closed so that they nest: a mark of lower
    /// `order` always holds the ones of higher order.
    static func tokens(of text: InlineText) -> [Token] {
        let units = Array(text.string.utf16)
        let lineBreak = InlineText.lineBreak.utf16.first!
        let atom = InlineText.atom.utf16.first!
        var cuts = Set([0, units.count])
        for run in text.runs {
            cuts.insert(run.range.location)
            cuts.insert(NSMaxRange(run.range))
        }
        for index in units.indices where units[index] == lineBreak || units[index] == atom {
            cuts.insert(index)
            cuts.insert(index + 1)
        }
        let points = cuts.sorted()
        var tokens: [Token] = []
        var stack: [InlineMark] = []
        func move(to wanted: [InlineMark]) {
            var common = 0
            while common < stack.count, common < wanted.count, stack[common] == wanted[common] { common += 1 }
            while stack.count > common { tokens.append(.close(stack.removeLast())) }
            for mark in wanted[common...] {
                tokens.append(.open(mark))
                stack.append(mark)
            }
        }
        for (start, end) in zip(points, points.dropFirst()) where end > start {
            let marks = text.runs.filter { $0.range.location <= start && NSMaxRange($0.range) >= end }.map(\.mark)
            let styling = marks.filter {
                switch $0 {
                case .atom, .hardBreak: false
                default: true
                }
            }.sorted { $0.order < $1.order }
            if end - start == 1, units[start] == lineBreak {
                move(to: styling.filter { $0 != .code })
                tokens.append(.lineBreak(hard: marks.contains(.hardBreak)))
            } else if end - start == 1, units[start] == atom {
                move(to: styling.filter { $0 != .code })
                let markdown = marks.compactMap { if case .atom(let markdown) = $0 { markdown } else { nil } }.first ?? ""
                tokens.append(.atom(markdown))
            } else {
                move(to: styling)
                tokens.append(.text(String(decoding: units[start..<end], as: UTF16.self)))
            }
        }
        move(to: [])
        return tokens
    }

    // MARK: Rendering

    private static func render(_ tokens: [Token], style: Style, atLineStart: Bool) -> String {
        var out = ""
        var lineStart = atLineStart
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case .open(.code):
                // The code up to its close, between enough backticks.
                var code = ""
                var end = index + 1
                while end < tokens.count, tokens[end] != .close(.code) {
                    if case .text(let text) = tokens[end] { code += text }
                    end += 1
                }
                out += inlineCode(code)
                lineStart = false
                index = end + 1
                continue
            case .open(.link(let destination, let title)):
                // `<url>` when the text is the address itself.
                if index + 2 < tokens.count, tokens[index + 1] == .text(destination), tokens[index + 2] == .close(.link(destination: destination, title: title)),
                   title == nil, destination.wholeMatch(of: autolink) != nil {
                    out += "<\(destination)>"
                    lineStart = false
                    index += 3
                    continue
                }
                out += "["
            case .open(let mark):
                out += opening(mark, style)
            case .close(let mark):
                out += closing(mark, style)
            case .text(let text):
                let next: Character? = index + 1 < tokens.count ? (tokens[index + 1].firstCharacter) : nil
                out += escape(text, atLineStart: lineStart, before: out.last, after: next)
            case .atom(let markdown):
                out += markdown
            case .lineBreak(let hard):
                out += hard ? "\\\n" : "\n"
                lineStart = true
                index += 1
                continue
            }
            lineStart = false
            index += 1
        }
        return out
    }

    nonisolated(unsafe) private static let autolink = /[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^\s<>]*/

    private static func opening(_ mark: InlineMark, _ style: Style) -> String {
        switch mark {
        case .strong: style == .markdown ? "**" : "<strong>"
        case .emphasis: style == .markdown ? "*" : "<em>"
        case .strikethrough: style == .markdown ? "~~" : "<del>"
        case .highlight(let color): color.map { #"<mark style="background: \#($0)">"# } ?? "<mark>"
        case .underline: "<u>"
        case .superscript: "<sup>"
        case .subscript: "<sub>"
        case .keyboard: "<kbd>"
        case .link: "["
        default: ""
        }
    }

    private static func closing(_ mark: InlineMark, _ style: Style) -> String {
        switch mark {
        case .strong: style == .markdown ? "**" : "</strong>"
        case .emphasis: style == .markdown ? "*" : "</em>"
        case .strikethrough: style == .markdown ? "~~" : "</del>"
        case .highlight: "</mark>"
        case .underline: "</u>"
        case .superscript: "</sup>"
        case .subscript: "</sub>"
        case .keyboard: "</kbd>"
        case .link(let destination, let title): "](" + linkDestination(destination) + (title.map { " \"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" } ?? "") + ")"
        default: ""
        }
    }

    private static func linkDestination(_ destination: String) -> String {
        var depth = 0
        var balanced = true
        for character in destination {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1; if depth < 0 { balanced = false } }
        }
        let plain = balanced && depth == 0 && !destination.isEmpty
            && !destination.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\\" })
        if plain { return destination }
        return "<" + destination.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "<", with: "\\<").replacingOccurrences(of: ">", with: "\\>") + ">"
    }

    /// `code` between backticks: more of them than any run inside, and a space inside each when it starts or ends
    /// with a backtick or is wrapped in spaces (which a reader would strip).
    private static func inlineCode(_ code: String) -> String {
        var longest = 0
        var current = 0
        for character in code {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pads = code.hasPrefix("`") || code.hasSuffix("`")
            || (code.hasPrefix(" ") && code.hasSuffix(" ") && !code.allSatisfy { $0 == " " })
        return pads ? "\(fence) \(code) \(fence)" : fence + code + fence
    }

    // MARK: Escaping

    /// `text` with what would read as syntax escaped. `before` and `after` are the characters written around it.
    static func escape(_ text: String, atLineStart: Bool, before: Character?, after: Character?) -> String {
        let characters = Array(text)
        var out = ""
        out.reserveCapacity(text.utf8.count + 8)
        for (index, character) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1] : before
            let next = index + 1 < characters.count ? characters[index + 1] : after
            let isLineStart = atLineStart && index == 0
            switch character {
            case "\\":
                // Before punctuation it would escape it, before a line break make it a hard break.
                out += "\\\\"
            case "!" where next == "[":
                // Before a link, it would make it an image.
                out += "\\!"
            case "^" where next == "[":
                // `^[text](...)` reads as inline attributes.
                out += "\\^"
            case "`", "*", "[", "]", "|":
                out += "\\" + String(character)
            case "_":
                let inWord = (previous?.isLetter == true || previous?.isNumber == true) && (next?.isLetter == true || next?.isNumber == true)
                out += inWord ? "_" : "\\_"
            case "<":
                out += next.map { $0.isLetter || $0 == "/" || $0 == "!" || $0 == "?" } ?? false ? "\\<" : "<"
            case "~":
                // GitHub's strikethrough takes one tilde as well as two.
                out += "\\~"
            case "=" where next == "=" || previous == "=":
                // `==text==` reads as a highlight.
                out += "\\="
            case "$":
                // `$x$` reads as math.
                out += "\\$"
            case "%" where next == "%" || previous == "%":
                // `%%text%%` reads as a comment.
                out += "\\%"
            case "&":
                let rest = String(characters[(index + 1)...])
                out += rest.prefixMatch(of: entity) != nil ? "\\&" : "&"
            case "#" where isLineStart:
                // A heading only when the run of `#` is followed by a space or ends the line: `#tag` stays a tag.
                let run = characters[index...].prefix { $0 == "#" }.count
                let after = index + run < characters.count ? characters[index + run] : nil
                out += run <= 6 && (after == nil || after == " " || after == "\t" || after == "\n") ? "\\#" : "#"
            case ">" where isLineStart, "-" where isLineStart, "+" where isLineStart, "=" where isLineStart:
                // A heading, a quote, a list marker, a setext underline or a thematic break when a line starts with it.
                out += "\\" + String(character)
            case "." where isNumberedMarker(characters, index, atLineStart, next), ")" where isNumberedMarker(characters, index, atLineStart, next):
                out += "\\" + String(character)
            default:
                out.append(character)
            }
        }
        return out
    }

    /// Whether the `.` or `)` at `index` ends a number that starts the line, `1. `: an ordered list marker.
    private static func isNumberedMarker(_ characters: [Character], _ index: Int, _ atLineStart: Bool, _ next: Character?) -> Bool {
        atLineStart && index > 0 && index <= 9 && characters[..<index].allSatisfy { $0.isASCII && $0.isNumber }
            && (next == nil || next == " " || next == "\t" || next == "\n")
    }

    nonisolated(unsafe) private static let entity = /(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/
}

private extension InlineWriter.Token {
    /// The first character this token writes, to know what follows a text.
    var firstCharacter: Character? {
        switch self {
        case .text(let text): text.first
        case .atom(let markdown): markdown.first
        case .lineBreak: "\n"
        case .open(.link): "["
        case .open(.highlight), .close(.highlight), .open(.underline), .close(.underline), .open(.superscript),
             .close(.superscript), .open(.subscript), .close(.subscript), .open(.keyboard), .close(.keyboard): "<"
        case .open, .close: "*"
        }
    }
}
