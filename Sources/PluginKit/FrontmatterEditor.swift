import Foundation

/// Line-level edits of YAML frontmatter that leave everything else in the note as it was: other keys, their
/// order, comments, blank lines, line endings and the body. `note-query`'s `setProperty` and the plugins that write
/// a new note's properties use it.
public enum FrontmatterEditor {
    /// The note with `key` set to `value`, or removed when `value` is nil. Returns `text` unchanged when there is
    /// nothing to do (removing a key that is not there).
    ///
    /// - A top-level `key: value` line is replaced in place, with its indented continuation lines (a block list
    ///   or map, a multi-line value); a trailing ` # comment` on a plain one-line value is kept. The key is found
    ///   as written, else ignoring case (as reads do), so `Status:` is edited rather than joined by `status:`.
    /// - A list of plain values is written as a block list (`- a` lines, as Obsidian writes them), unless the key
    ///   held a flow list (`[a, b]`) that stays one.
    /// - A new key goes on its own line just before the closing `---`.
    /// - A note without frontmatter gets one at the top; removing its last key removes it.
    public static func setting(_ key: String, to value: PropertyValue?, in text: String) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let split = MarkdownFrontmatter.split(text)
        guard let yaml = split.yaml else {
            guard let value else { return text }
            return "---" + newline + block(key, value, newline: newline) + newline + "---" + newline + text
        }
        let opening = split.raw.hasPrefix("---\r\n") ? "---\r\n" : "---\n"
        let closing = String(split.raw.dropFirst(opening.count + yaml.count))

        // Lines keep their own terminator, so joining them gives back `yaml` exactly.
        var lines = linesKeepingTerminators(yaml)
        let found = lines.firstIndex(where: { topLevelKey(of: $0) == key })
            ?? lines.firstIndex(where: { topLevelKey(of: $0)?.caseInsensitiveCompare(key) == .orderedSame })
        if let start = found {
            var end = start + 1
            while end < lines.count, isContinuation(lines, at: end) { end += 1 }
            let terminator = terminatorOf(lines[end - 1])
            if let value {
                let wasFlow = end == start + 1 && isFlowList(lines[start])
                let comment = end == start + 1 ? trailingComment(of: lines[start]) : ""
                let prefix = keyPrefix(of: lines[start])
                let replacement: String
                if !wasFlow, let items = blockItems(value) {
                    let lineEnd = terminator.isEmpty ? newline : terminator
                    replacement = prefix + items.map { lineEnd + "  - " + $0 }.joined() + terminator
                } else {
                    replacement = prefix + (value == .null ? "" : " " + serialize(value, flow: false)) + comment + terminator
                }
                lines.replaceSubrange(start..<end, with: [replacement])
            } else {
                lines.removeSubrange(start..<end)
                if lines.allSatisfy({ content($0).trimmingCharacters(in: .whitespaces).isEmpty }) { return split.body }
            }
        } else {
            guard let value else { return text }
            if let last = lines.last, terminatorOf(last).isEmpty { lines[lines.count - 1] += newline }
            lines.append(block(key, value, newline: newline) + newline)
        }
        return opening + lines.joined() + closing + split.body
    }

    /// `key: value`, or `key:` and its `- item` lines for a list of plain values, without a final terminator.
    public static func block(_ key: String, _ value: PropertyValue, newline: String) -> String {
        guard let items = blockItems(value) else { return line(key, value) }
        return serializeString(key, flow: false) + ":" + items.map { newline + "  - " + $0 }.joined()
    }

    /// The items of a non-empty list of scalars, serialized; nil for anything else (written in flow style).
    private static func blockItems(_ value: PropertyValue) -> [String]? {
        guard case .list(let elements) = value, !elements.isEmpty else { return nil }
        var items: [String] = []
        for element in elements {
            switch element {
            case .list, .map: return nil
            default: items.append(serialize(element, flow: false))
            }
        }
        return items
    }

    /// Whether a one-line `key: [...]` holds a flow list.
    private static func isFlowList(_ line: String) -> Bool {
        let text = content(line)
        guard let range = keyRange(text) else { return false }
        return text[range.upperBound...].drop(while: { $0 == " " || $0 == "\t" }).first == "["
    }

    /// `key: value`, without a line terminator.
    public static func line(_ key: String, _ value: PropertyValue) -> String {
        let name = serializeString(key, flow: false) + ":"
        if case .null = value { return name }
        return name + " " + serialize(value, flow: false)
    }

    /// YAML for a value: plain scalars where they read back as the same value, double quotes otherwise, flow
    /// style (`[a, b]`, `{k: v}`) for lists and maps.
    public static func serialize(_ value: PropertyValue, flow: Bool) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            if number.isNaN { return ".nan" }
            if number.isInfinite { return number < 0 ? "-.inf" : ".inf" }
            if number == number.rounded(), abs(number) < 1e15 { return String(Int(number)) }
            return String(number)
        case .string(let text):
            return serializeString(text, flow: flow)
        case .list(let elements):
            return "[" + elements.map { serialize($0, flow: true) }.joined(separator: ", ") + "]"
        case .map(let map):
            let pairs = map.keys.sorted().map { serializeString($0, flow: true) + ": " + serialize(map[$0]!, flow: true) }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }

    public static func serializeString(_ text: String, flow: Bool) -> String {
        needsQuotes(text, flow: flow) ? quoted(text) : text
    }

    private static let reservedWords: Set<String> = [
        "true", "false", "yes", "no", "on", "off", "y", "n", "null", "~",
        ".inf", "-.inf", "+.inf", ".nan", "<<", "=",
    ]
    private static let indicators: Set<Character> = [
        "-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`",
    ]

    /// Whether a plain scalar would read back as something else (a bool, number, null, date or structure), or
    /// not parse at all.
    private static func needsQuotes(_ text: String, flow: Bool) -> Bool {
        guard let first = text.first, let last = text.last else { return true }
        if first.isWhitespace || last.isWhitespace { return true }
        if reservedWords.contains(text.lowercased()) { return true }
        if indicators.contains(first) { return true }
        if last == ":" || text.contains(": ") || text.contains(" #") || text.contains(":\t") { return true }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return true }
        if flow, text.contains(where: { ",[]{}".contains($0) }) { return true }
        // Anything that may read as a number or a timestamp, except a plain date (which the graph reads back as
        // the same text). Quoting a few strings that would not need it is harmless.
        if isPlainDate(text) { return false }
        if text.range(of: #"^[+.]?[0-9]"#, options: .regularExpression) != nil {
            return !text.contains(" ") || isTimestamp(text)
        }
        return false
    }

    private static func isPlainDate(_ text: String) -> Bool {
        text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
    }

    private static func isTimestamp(_ text: String) -> Bool {
        text.range(of: #"^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}"#, options: .regularExpression) != nil
    }

    private static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\x%02X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    // MARK: Lines

    private static func linesKeepingTerminators(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            // "\r\n" is one Character in Swift.
            if character == "\n" || character == "\r\n" {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func terminatorOf(_ line: String) -> String {
        if line.hasSuffix("\r\n") { return "\r\n" }
        if line.hasSuffix("\n") { return "\n" }
        return ""
    }

    private static func content(_ line: String) -> String {
        String(line.dropLast(terminatorOf(line).isEmpty ? 0 : 1))
    }

    /// Lines that belong to the key above: indented ones, and `- item` lines of a block list written at the
    /// key's own indentation (`tags:` then `- a`).
    /// Blank lines count when more continuation lines follow them (inside a `|` block, say).
    private static func isContinuation(_ lines: [String], at index: Int) -> Bool {
        let text = content(lines[index])
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return index + 1 < lines.count && isContinuation(lines, at: index + 1)
        }
        let first = text.first!
        return first == " " || first == "\t" || text == "-" || text.hasPrefix("- ")
    }

    /// The text before the value, `key:` as written (quoted or not).
    private static func keyPrefix(of line: String) -> String {
        let text = content(line)
        guard let range = keyRange(text) else { return text }
        return String(text[..<range.upperBound])
    }

    /// The key of a top-level `key: value` line, unquoted.
    private static func topLevelKey(of line: String) -> String? {
        let text = content(line)
        guard let first = text.first, first != " ", first != "\t", first != "#", first != "-" else { return nil }
        guard let range = keyRange(text) else { return nil }
        let raw = String(text[..<text.index(before: range.upperBound)]).trimmingCharacters(in: .whitespaces)
        if raw.count >= 2, let quote = raw.first, quote == "\"" || quote == "'", raw.last == quote {
            let inner = String(raw.dropFirst().dropLast())
            return quote == "'" ? inner.replacingOccurrences(of: "''", with: "'") : unescape(inner)
        }
        return raw
    }

    /// The range of `key:` (through the colon) in a line, honouring a quoted key.
    private static func keyRange(_ text: String) -> Range<String.Index>? {
        var index = text.startIndex
        if let quote = text.first, quote == "\"" || quote == "'" {
            index = text.index(after: index)
            while index < text.endIndex {
                if text[index] == "\\", quote == "\"" {
                    index = text.index(after: index)
                    if index < text.endIndex { index = text.index(after: index) }
                    continue
                }
                if text[index] == quote { break }
                index = text.index(after: index)
            }
            guard index < text.endIndex else { return nil }
            index = text.index(after: index)
        }
        while index < text.endIndex {
            if text[index] == ":" {
                let after = text.index(after: index)
                if after == text.endIndex || text[after] == " " || text[after] == "\t" {
                    return text.startIndex..<after
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// ` # comment` after a plain (unquoted, not flow) one-line value, or "".
    private static func trailingComment(of line: String) -> String {
        let text = content(line)
        guard let range = keyRange(text) else { return "" }
        let value = text[range.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
        guard let first = value.first, !"\"'[{|>".contains(first) else { return "" }
        guard let hash = value.range(of: " #") ?? value.range(of: "\t#") else { return "" }
        var start = hash.lowerBound
        while start > value.startIndex, " \t".contains(value[value.index(before: start)]) { start = value.index(before: start) }
        return String(value[start...])
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
