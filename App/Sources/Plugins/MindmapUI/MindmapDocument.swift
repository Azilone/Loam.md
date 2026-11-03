import Foundation

/// A topic of a mindmap: its text and the topics under it. A reference, so edits move whole branches; `id` is
/// what views and the selection follow, kept across re-parses (`MindmapDocument.reuseIDs`) so changes animate.
public final class MindTopic: Identifiable {
    public var id: String
    public var text: String
    public var children: [MindTopic]

    public init(_ text: String = "", children: [MindTopic] = [], id: String = MindTopic.makeID()) {
        self.id = id
        self.text = text
        self.children = children
    }

    nonisolated(unsafe) private static var counter = 0
    public static func makeID() -> String {
        counter += 1
        return "t\(counter)"
    }

    /// This topic and every topic below it, depth first.
    public var all: [MindTopic] { [self] + children.flatMap(\.all) }

    public var descendantCount: Int { children.reduce(0) { $0 + 1 + $1.descendantCount } }

    public func copy() -> MindTopic {
        MindTopic(text, children: children.map { $0.copy() }, id: id)
    }

    /// The same texts, in the same shape.
    public func sameContent(as other: MindTopic) -> Bool {
        text == other.text && children.count == other.children.count
            && zip(children, other.children).allSatisfy { $0.sameContent(as: $1) }
    }
}

/// A mindmap note, in the format the Obsidian "Native Mindmap" plugin uses, so maps move between the two:
///
///     ---
///     mindmap-plugin: basic
///     ---
///
///     # Central topic
///
///     - Branch
///     	- Sub topic
///
/// The first level-1 heading is the central topic and the nested list is the tree. Anything else in the note is
/// kept and written back after the list. `mindmap-layout:` in the frontmatter picks the layout, and
/// `mindmap-right: 2` keeps the first two branches on the right of the central topic and the others on its left
/// (written once a branch is moved to a side on purpose; without it, the map balances the sides when it opens).
public struct MindmapDocument {
    public static let flag = "mindmap-plugin"

    public var frontmatter: String
    public var root: MindTopic
    public var extra: String

    public init(frontmatter: String = "", root: MindTopic, extra: String = "") {
        self.frontmatter = frontmatter
        self.root = root
        self.extra = extra
    }

    // MARK: - Reading

    public static func parse(_ text: String, title: String) -> MindmapDocument {
        var body = Substring(text)
        var frontmatter = ""
        if let range = frontmatterRange(in: text) {
            frontmatter = String(text[range]).trimmingCharacters(in: .newlines)
            body = text[range.upperBound...]
        }
        let root = MindTopic(title)
        var builder = ListBuilder(root: root)
        var extra: [String] = []
        var titleFound = false
        var last: MindTopic?
        var fence: String?

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            // Code blocks are kept as they are.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                extra.append(line)
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                extra.append(line)
                last = nil
                continue
            }
            if let item = listItem(line) {
                last = builder.add(indent: item.indent, text: item.text)
                continue
            }
            if !titleFound, root.children.isEmpty, extra.isEmpty, let heading = h1(line) {
                root.text = heading
                titleFound = true
                continue
            }
            // An indented continuation of a list item.
            if let item = last, line.first == " " || line.first == "\t", !trimmed.isEmpty {
                item.text = (item.text + " " + trimmed).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.isEmpty {
                if !extra.isEmpty { extra.append("") }
                continue
            }
            extra.append(line)
            last = nil
        }
        let rest = extra.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return MindmapDocument(frontmatter: frontmatter, root: root, extra: rest)
    }

    public func serialized() -> String {
        var parts: [String] = []
        if !frontmatter.isEmpty { parts += [frontmatter, ""] }
        let title = root.text.trimmingCharacters(in: .whitespaces)
        parts.append("# " + (title.isEmpty ? "Untitled" : title))
        let list = Self.markdownList(root.children)
        if !list.isEmpty { parts += ["", list] }
        if !extra.isEmpty { parts += ["", extra] }
        return parts.joined(separator: "\n") + "\n"
    }

    /// Topics as a nested Markdown list, one tab per level.
    public static func markdownList(_ topics: [MindTopic], depth: Int = 0) -> String {
        var lines: [String] = []
        func walk(_ topic: MindTopic, _ depth: Int) {
            let line = String(repeating: "\t", count: depth) + "- " + topic.text
            lines.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
            for child in topic.children { walk(child, depth + 1) }
        }
        for topic in topics { walk(topic, depth) }
        return lines.joined(separator: "\n")
    }

    /// Pasted text (a Markdown list, or plain lines indented by level) as new topics.
    public static func parseFragment(_ text: String) -> [MindTopic] {
        let root = MindTopic()
        var builder = ListBuilder(root: root)
        for rawLine in text.components(separatedBy: .newlines) {
            guard !rawLine.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let item = listItem(rawLine) {
                builder.add(indent: item.indent, text: item.text)
            } else {
                let indent = indentWidth(String(rawLine.prefix { $0 == " " || $0 == "\t" }))
                let text = rawLine.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "^#+\\s+", with: "", options: .regularExpression)
                builder.add(indent: indent, text: text)
            }
        }
        return root.children
    }

    /// Gives the topics of `next` the ids of the topics at the same place in `previous`, so a re-parse after an
    /// outside change animates instead of rebuilding every view.
    public static func reuseIDs(from previous: MindTopic, into next: MindTopic) {
        next.id = previous.id
        for (old, new) in zip(previous.children, next.children) { reuseIDs(from: old, into: new) }
    }

    /// Whether a note can be shown and edited as a mindmap without losing its structure: it has the mindmap flag,
    /// or no heading other than a leading `# title`.
    public static func isMindmapNote(_ text: String) -> Bool {
        if hasFlag(text) { return true }
        var seenContent = false
        var fence = false
        var body = Substring(text)
        if let range = frontmatterRange(in: text) { body = text[range.upperBound...] }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence.toggle() }
            if fence || trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#"), trimmed.drop(while: { $0 == "#" }).first == " " {
                if seenContent || h1(String(line)) == nil { return false }
            }
            seenContent = true
        }
        return true
    }

    /// The note has `mindmap-plugin:` in its frontmatter.
    public static func hasFlag(_ text: String) -> Bool {
        guard let range = frontmatterRange(in: text) else { return false }
        return text[range].range(of: "(?m)^\(flag):", options: .regularExpression) != nil
    }

    // MARK: - Layout settings

    public var layout: MindmapLayoutMode? {
        property("mindmap-layout").map(MindmapLayoutMode.init(storedValue:)) ?? nil
    }

    public mutating func setLayout(_ mode: MindmapLayoutMode) {
        setProperty("mindmap-layout", mode.rawValue)
    }

    /// How many branches are drawn on the right of the central topic, the others on its left; nil balances them.
    public var rightCount: Int? {
        get { property("mindmap-right").flatMap { Int($0) }.map { max($0, 0) } }
        set { setProperty("mindmap-right", newValue.map(String.init)) }
    }

    /// A frontmatter value, without quotes.
    private func property(_ name: String) -> String? {
        guard let match = frontmatter.range(of: "(?m)^\(name):[ \\t]*[\"']?([\\w-]+)", options: .regularExpression)
        else { return nil }
        let value = frontmatter[match].dropFirst(name.count + 1)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        return value.isEmpty ? nil : value
    }

    /// Sets a frontmatter line, adding the frontmatter if needed; nil removes the line.
    private mutating func setProperty(_ name: String, _ value: String?) {
        let pattern = "(?m)^\(name):.*$"
        let exists = frontmatter.range(of: pattern, options: .regularExpression) != nil
        guard let value else {
            guard exists else { return }
            frontmatter = frontmatter.replacingOccurrences(
                of: "(?m)^\(name):.*\\n?", with: "", options: .regularExpression)
            if frontmatter.replacingOccurrences(of: "\\s", with: "", options: .regularExpression) == "------" {
                frontmatter = ""
            }
            return
        }
        let line = "\(name): \(value)"
        if exists {
            frontmatter = frontmatter.replacingOccurrences(of: pattern, with: line, options: .regularExpression)
        } else if !frontmatter.isEmpty, frontmatter.hasSuffix("---") {
            frontmatter = String(frontmatter.dropLast(3)) + line + "\n---"
        } else {
            frontmatter = "---\n\(line)\n---"
        }
    }

    // MARK: - Helpers

    static func lines(of text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    private static func frontmatterRange(in text: String) -> Range<String.Index>? {
        guard text.hasPrefix("---") else { return nil }
        let pattern = "\\A---\\r?\\n[\\s\\S]*?\\r?\\n---[ \\t]*(?:\\r?\\n|\\z)"
        return text.range(of: pattern, options: .regularExpression)
    }

    private static func listItem(_ line: String) -> (indent: Int, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        var marker = 0
        if let first = rest.first, "-*+".contains(first) {
            marker = 1
        } else {
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count < 10, let delimiter = rest.dropFirst(digits.count).first,
                  ".)".contains(delimiter) else { return nil }
            marker = digits.count + 1
        }
        let after = rest.dropFirst(marker)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        // `---` or `***` is a thematic break, not an item.
        if marker == 1, rest.filter({ !$0.isWhitespace }).allSatisfy({ $0 == rest.first }), rest.count >= 3 {
            return nil
        }
        return (indentWidth(String(indent)), after.trimmingCharacters(in: .whitespaces))
    }

    private static func h1(_ line: String) -> String? {
        guard line.hasPrefix("# ") || line.hasPrefix("#\t") else { return nil }
        let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func indentWidth(_ whitespace: String) -> Int {
        whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private struct ListBuilder {
        let root: MindTopic
        var stack: [(indent: Int, topic: MindTopic)] = []

        init(root: MindTopic) { self.root = root }

        @discardableResult
        mutating func add(indent: Int, text: String) -> MindTopic {
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            let parent = stack.last?.topic ?? root
            let topic = MindTopic(text)
            parent.children.append(topic)
            stack.append((indent, topic))
            return topic
        }
    }
}
