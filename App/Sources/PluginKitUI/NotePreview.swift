import Foundation

/// The first blocks of a note's body, simplified for a card (the gallery's, a folder page's): headings, list items, tasks, quotes, code lines and
/// paragraphs. Not a full CommonMark parser: a card shows a glimpse, the editor shows the note.
public struct NotePreview: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case bullet(depth: Int, text: String)
        case ordered(number: String, depth: Int, text: String)
        case task(depth: Int, done: Bool, text: String)
        case quote(String)
        case code(String)
        /// A whole fenced block with a language (` ```mermaid `, ` ```base `), which a card may draw as a plugin does
        /// in the editor (`CodeBlockPreviews`); a fence without a language stays `code` lines.
        case fenced(language: String, code: String)
        /// A row of a GFM table; `header` for its first row. The `|---|` line under the header is left out.
        case tableRow(cells: [String], header: Bool)
        case paragraph(String)
    }

    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    /// At most `limit` blocks of `text`, skipping the frontmatter and a first `# heading` equal to `title`.
    public static func parse(_ text: String, title: String, limit: Int = 14) -> NotePreview {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            lines.removeSubrange(0...end)
        }
        var blocks: [Block] = []
        var inCode = false
        /// The open fence's language and the lines read so far, while in a fenced block with a language.
        var fenced: (language: String, lines: [String])?
        var skippedTitle = false
        for line in lines {
            if blocks.count >= limit { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if let open = fenced {
                    blocks.append(.fenced(language: open.language, code: open.lines.joined(separator: "\n")))
                    fenced = nil
                } else if !inCode, let language = fenceLanguage(trimmed) {
                    fenced = (language, [])
                } else {
                    inCode.toggle()
                }
                continue
            }
            if fenced != nil {
                fenced?.lines.append(line)
                continue
            }
            if inCode {
                blocks.append(.code(line))
                continue
            }
            if trimmed.isEmpty || trimmed == "---" || trimmed == "***" { continue }
            let depth = indentDepth(line)
            if let heading = heading(trimmed) {
                if !skippedTitle, blocks.isEmpty, heading.level == 1,
                   heading.text.caseInsensitiveCompare(title) == .orderedSame {
                    skippedTitle = true
                    continue
                }
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if let item = listItem(trimmed) {
                if let task = taskItem(item.text) {
                    blocks.append(.task(depth: depth, done: task.done, text: task.text))
                } else if let number = item.number {
                    blocks.append(.ordered(number: number, depth: depth, text: item.text))
                } else {
                    blocks.append(.bullet(depth: depth, text: item.text))
                }
            } else if trimmed.hasPrefix(">") {
                // A callout's `[!NOTE]` marker is syntax, not text.
                let quoted = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"^\[![A-Za-z]+\][+-]?\s*"#, with: "", options: .regularExpression)
                if !quoted.isEmpty { blocks.append(.quote(quoted)) }
            } else if let cells = tableCells(trimmed) {
                if cells.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) { continue }
                let header: Bool
                if case .tableRow = blocks.last { header = false } else { header = true }
                blocks.append(.tableRow(cells: cells, header: header))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        if let open = fenced, blocks.count < limit {
            blocks.append(.fenced(language: open.language, code: open.lines.joined(separator: "\n")))
        }
        return NotePreview(blocks: blocks)
    }

    /// The lowercased language after an opening fence (` ```mermaid `); nil when there is none.
    private static func fenceLanguage(_ fence: String) -> String? {
        let info = fence.drop { $0 == "`" || $0 == "~" }.trimmingCharacters(in: .whitespaces)
        let word = info.prefix { !$0.isWhitespace && $0 != "{" }.lowercased()
        return word.isEmpty ? nil : word
    }

    /// The cells of a `| a | b |` line, trimmed; nil for a line that isn't a table row.
    private static func tableCells(_ line: String) -> [String]? {
        guard line.hasPrefix("|"), line.count > 1 else { return nil }
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        cells.removeFirst()
        if line.hasSuffix("|") { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    /// Nesting level from leading spaces (2 per level) or tabs.
    private static func indentDepth(_ line: String) -> Int {
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 } else if character == "\t" { spaces += 4 } else { break }
        }
        return min(spaces / 2, 4)
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (number: String?, text: String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return (nil, String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")", rest.dropFirst().first == " " else { return nil }
        return (String(digits), String(rest.dropFirst(2)))
    }

    private static func taskItem(_ text: String) -> (done: Bool, text: String)? {
        guard text.count >= 3, text.hasPrefix("["), text.dropFirst(2).first == "]" else { return nil }
        let mark = text.dropFirst().first!
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        return (mark != " ", String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces))
    }
}

/// A run of inline text: plain Markdown, a `[[wikilink]]` (shown by its alias or target) or a `#tag`.
public enum InlineRun: Equatable, Sendable {
    case text(String)
    case link(String)
    case tag(String)

    /// Splits a line into runs. Tags start at a word boundary and hold letters, digits, `_`, `-` and `/`.
    public static func split(_ line: String) -> [InlineRun] {
        var runs: [InlineRun] = []
        var buffer = ""
        var index = line.startIndex
        func flush() {
            if !buffer.isEmpty { runs.append(.text(buffer)) }
            buffer = ""
        }
        while index < line.endIndex {
            let rest = line[index...]
            if rest.hasPrefix("[["), let close = rest.range(of: "]]") {
                let inner = rest[rest.index(index, offsetBy: 2)..<close.lowerBound]
                let shown = inner.split(separator: "|", maxSplits: 1).last.map(String.init) ?? String(inner)
                flush()
                runs.append(.link(shown.split(separator: "#").first.map(String.init) ?? shown))
                index = close.upperBound
                continue
            }
            let character = line[index]
            let atBoundary = index == line.startIndex || line[line.index(before: index)].isWhitespace
            if character == "#", atBoundary {
                let body = line[line.index(after: index)...].prefix { $0.isLetter || $0.isNumber || "_-/".contains($0) }
                if !body.isEmpty, body.contains(where: { !$0.isNumber }) {
                    flush()
                    runs.append(.tag(String(body)))
                    index = body.endIndex
                    continue
                }
            }
            buffer.append(character)
            index = line.index(after: index)
        }
        flush()
        return runs
    }
}
