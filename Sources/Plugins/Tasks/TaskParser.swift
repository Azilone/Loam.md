import Foundation
import PluginKit

/// Reads the tasks of one note. Pure functions of the text, so the index, the toggle and the tests share them.
enum TaskParser {
    /// The parts of a task-list line: `<indent><marker> [<state>] <body>`.
    struct TaskLine {
        /// Where the state character (` `, `x` or `X`) is, in the line's characters.
        let stateOffset: Int
        let done: Bool
        let body: String
    }

    /// Splits text into lines on `\n` only, so a line of a CRLF note keeps its `\r` and joining with `\n` gives the
    /// text back exactly.
    static func lines(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    /// A line without its trailing `\r`.
    static func content(_ line: String) -> (text: String, carriageReturn: Bool) {
        if line.unicodeScalars.last == "\r" {
            var scalars = line.unicodeScalars
            scalars.removeLast()
            return (String(scalars), true)
        }
        return (line, false)
    }

    /// Every task of a note, in line order.
    static func tasks(in text: String, path: String) -> [TaskItem] {
        let split = MarkdownFrontmatter.split(text)
        let frontmatterLines = split.raw.unicodeScalars.filter { $0 == "\n" }.count
        let project = split.yaml.flatMap(projectProperty) ?? VaultPath.directory(of: path)
        var tasks: [TaskItem] = []
        forEachBodyLine(lines(text), skipping: frontmatterLines) { index, line in
            guard let task = taskLine(line) else { return }
            tasks.append(item(task, path: path, line: index + 1, project: project))
        }
        return tasks
    }

    /// Calls `body` with the index and content (no `\r`) of every line after the frontmatter that is not inside a
    /// fenced code block (nor a fence line itself).
    static func forEachBodyLine(_ lines: [String], skipping: Int, _ body: (Int, String) -> Void) {
        var fence: (character: Character, count: Int)?
        for index in lines.indices where index >= skipping {
            let line = content(lines[index]).text
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix { $0 == first }.count
                if count >= 3 {
                    if let open = fence {
                        if first == open.character, count >= open.count,
                           trimmed.dropFirst(count).allSatisfy({ $0 == " " || $0 == "\t" }) {
                            fence = nil
                        }
                    } else if first == "~" || !trimmed.dropFirst(count).contains("`") {
                        fence = (first, count)
                    }
                    continue
                }
            }
            if fence == nil { body(index, line) }
        }
    }

    /// The parts of `- [ ] body` (also `*`, `+`, `1.`, `1)`, any indent), else nil. The body must not be empty.
    static func taskLine(_ line: String) -> TaskLine? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 }
        guard index < characters.count else { return nil }
        if "-*+".contains(characters[index]) {
            index += 1
        } else {
            let start = index
            while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
            guard index > start, index - start <= 9, index < characters.count,
                  characters[index] == "." || characters[index] == ")" else { return nil }
            index += 1
        }
        let afterMarker = index
        while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 }
        guard index > afterMarker, index + 2 < characters.count, characters[index] == "[",
              characters[index + 2] == "]" else { return nil }
        let state = characters[index + 1]
        guard state == " " || state == "x" || state == "X" else { return nil }
        let after = index + 3
        guard after == characters.count || characters[after] == " " || characters[after] == "\t" else { return nil }
        let body = String(characters[after...]).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return TaskLine(stateOffset: index + 1, done: state != " ", body: body)
    }

    // MARK: Metadata

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants: failing to compile one is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let datePattern = "([0-9]{4}-[0-9]{2}-[0-9]{2})"
    private static let dueEmoji = regex("📅\\s*" + datePattern)
    private static let dueWord = regex("(?<!\\S)due:\\s?" + datePattern + "(?!\\S)")
    static let completion = regex("\\s*✅\\s*" + datePattern)
    private static let highPriority = regex("⏫\\uFE0F?|(?<!\\S)!high(?!\\S)")
    private static let lowPriority = regex("🔽\\uFE0F?|(?<!\\S)!low(?!\\S)")
    /// The note graph's hashtag rule, so a task's tags are the tags the graph sees.
    private static let hashtag = regex("(?<![\\p{L}\\p{N}_/&#])#([\\p{L}\\p{N}_][\\p{L}\\p{N}_/-]*)")
    private static let spaces = regex("[ \\t]{2,}")

    static func item(_ task: TaskLine, path: String, line: Int, project: String) -> TaskItem {
        var text = task.body
        let due = take(dueEmoji, from: &text) ?? take(dueWord, from: &text)
        let completed = take(completion, from: &text)
        var priority = TaskPriority.normal
        if take(highPriority, from: &text, group: 0) != nil { priority = .high }
        if take(lowPriority, from: &text, group: 0) != nil, priority == .normal { priority = .low }
        text = replace(spaces, in: text, with: " ").trimmingCharacters(in: .whitespaces)
        return TaskItem(
            path: path,
            line: line,
            text: text,
            done: task.done,
            due: due,
            completed: completed,
            priority: priority,
            tags: matches(hashtag, in: text),
            project: project
        )
    }

    /// The first match's group, after removing every match from `text`.
    private static func take(_ expression: NSRegularExpression, from text: inout String, group: Int = 1) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let first = expression.firstMatch(in: text, range: range),
              let captured = Range(first.range(at: group), in: text) else { return nil }
        let value = String(text[captured])
        text = replace(expression, in: text, with: " ")
        return value
    }

    static func replace(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func matches(_ expression: NSRegularExpression, in text: String) -> [String] {
        expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: Project

    /// The frontmatter `project` property as text: a plain or quoted value, the first element of a list, and a
    /// `[[wikilink]]` without its brackets. Nil when absent or empty.
    static func projectProperty(_ yaml: String) -> String? {
        let lines = lines(yaml).map { content($0).text }
        guard let index = lines.firstIndex(where: { line in
            guard let colon = line.firstIndex(of: ":"), line.first.map({ !" \t#-".contains($0) }) == true else { return false }
            let key = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return key.lowercased() == "project"
        }) else { return nil }
        var value = String(lines[index][lines[index].index(after: lines[index].firstIndex(of: ":")!)...])
            .trimmingCharacters(in: .whitespaces)
        if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
        if value.isEmpty, index + 1 < lines.count {
            // A block list: the first `- item` below the key.
            let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
            if next.hasPrefix("- ") { value = String(next.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        } else if value.hasPrefix("["), !value.hasPrefix("[[") {
            value = String(value.dropFirst().dropLast(value.hasSuffix("]") ? 1 : 0))
            value = value.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
            value = String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("[["), value.hasSuffix("]]") {
            value = String(value.dropFirst(2).dropLast(2))
            if let bar = value.firstIndex(of: "|") { value = String(value[..<bar]) }
        }
        value = value.trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "null" || value == "~" ? nil : value
    }
}
