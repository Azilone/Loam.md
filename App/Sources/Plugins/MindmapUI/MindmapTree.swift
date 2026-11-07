import Foundation
import Markdown
import PluginKitUI

/// One branch of a mindmap: the note itself at the root, a heading, or a list item.
public struct MindmapNode: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// The root made from the note's name: no line of its own.
        case title
        /// An ATX (`## Text`) or setext (underlined) heading.
        case heading(level: Int, setext: Bool)
        /// A bullet or numbered list item; `checked` is nil without a `[ ]` box.
        case item(checked: Bool?)
    }

    /// The node's first line (1-based); 0 for a root made from the note's name.
    public let id: Int
    public let text: String
    public let kind: Kind
    /// The texts from the root down to this node, made unique among siblings: what a collapsed branch is saved
    /// as, so it stays collapsed when lines move, and what views are identified by.
    public let key: String
    /// The last line of the node's own text (a setext heading or a list item may wrap over several lines).
    public let textEndLine: Int
    /// The last line of the node and everything under it: a heading's whole section (up to the next heading of
    /// its level or above), a list item with its nested lists. The note's last line for the root.
    public let endLine: Int
    public var children: [MindmapNode]

    /// The line a click reveals: the node's, or the first line of the note for the root.
    public var line: Int { max(id, 1) }

    /// This node and every node below it, depth first.
    public var all: [MindmapNode] { [self] + children.flatMap(\.all) }

    public var headingLevel: Int? {
        if case .heading(let level, _) = kind { return level }
        return nil
    }

    public var isItem: Bool {
        if case .item = kind { return true }
        return false
    }

    /// The node with `key`, here or below.
    public func find(_ key: String) -> MindmapNode? {
        if self.key == key { return self }
        for child in children { if let found = child.find(key) { return found } }
        return nil
    }

    /// The parent of the node with `key`, nil for the root or a key not in the tree.
    public func parent(of key: String) -> MindmapNode? {
        for child in children {
            if child.key == key { return self }
            if let found = child.parent(of: key) { return found }
        }
        return nil
    }

    /// The node starting on `line`, here or below.
    public func node(atLine line: Int) -> MindmapNode? {
        if id == line { return self }
        for child in children { if let found = child.node(atLine: line) { return found } }
        return nil
    }
}

public enum MindmapTree {
    /// The mindmap of a note. When the note starts with its only level-1 heading, that heading is the root;
    /// otherwise the root is `title` (the file name). Headings nest by level; list items (when `includeLists`)
    /// hang under the heading they follow, nested lists under their item. Code blocks, quotes and the YAML
    /// frontmatter are skipped.
    public static func build(text: String, title: String, includeLists: Bool = true) -> MindmapNode {
        let body = withoutFrontmatter(text)
        let document = Markdown.Document(parsing: body)
        let lineCount = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count
            - (text.hasSuffix("\n") ? 1 : 0))

        let blocks = Array(document.children)
        let headings = blocks.compactMap { $0 as? Heading }.filter { !plainText($0).isEmpty }
        let firstHeading = headings.first
        let rootHeading: Heading? = {
            guard let firstHeading, firstHeading.level == 1, headings.filter({ $0.level == 1 }).count == 1
            else { return nil }
            return firstHeading
        }()

        let root = Draft(kind: .title, text: title, line: 0, textEndLine: 0, endLine: lineCount, level: 0)
        if let rootHeading, let range = rootHeading.range {
            root.kind = .heading(level: 1, setext: isSetext(rootHeading, in: body))
            root.text = plainText(rootHeading)
            root.line = range.lowerBound.line
            root.textEndLine = textEnd(of: rootHeading, in: body)
            root.level = 1
        }

        var stack: [Draft] = [root]
        var openHeadings: [Draft] = []
        for block in blocks {
            if let heading = block as? Heading {
                let text = plainText(heading)
                guard !text.isEmpty, let range = heading.range else { continue }
                if let rootLine = rootHeading?.range?.lowerBound.line, rootLine == range.lowerBound.line { continue }
                // The headings this one ends.
                for open in openHeadings where open.endLine == 0 && open.level >= heading.level {
                    open.endLine = range.lowerBound.line - 1
                }
                openHeadings.removeAll { $0.endLine != 0 }
                while stack.count > 1, stack.last!.level >= heading.level { stack.removeLast() }
                let node = Draft(
                    kind: .heading(level: heading.level, setext: isSetext(heading, in: body)),
                    text: text, line: range.lowerBound.line, textEndLine: textEnd(of: heading, in: body),
                    endLine: 0, level: heading.level
                )
                stack.last!.children.append(node)
                stack.append(node)
                openHeadings.append(node)
            } else if includeLists, let list = block as? ListItemContainer {
                stack.last!.children.append(contentsOf: items(of: list))
            }
        }
        for open in openHeadings where open.endLine == 0 { open.endLine = lineCount }
        return root.node(parentKey: nil, seen: [:]).node
    }

    private static func items(of list: ListItemContainer) -> [Draft] {
        var result: [Draft] = []
        for item in list.listItems {
            guard let range = item.range else { continue }
            let paragraph = item.children.first { $0 is Paragraph }
            let text = paragraph.map(plainText) ?? ""
            let nested = item.children.compactMap { $0 as? ListItemContainer }.flatMap(items(of:))
            if text.isEmpty {
                // An empty item: its nested items take its place.
                result.append(contentsOf: nested)
                continue
            }
            let checked: Bool? = item.checkbox.map { $0 == .checked }
            let node = Draft(
                kind: .item(checked: checked), text: text, line: range.lowerBound.line,
                textEndLine: paragraph?.range?.upperBound.line ?? range.lowerBound.line,
                endLine: range.upperBound.line, level: 7
            )
            node.children = nested
            result.append(node)
        }
        return result
    }

    /// A node under construction.
    private final class Draft {
        var kind: MindmapNode.Kind
        var text: String
        var line: Int
        var textEndLine: Int
        var endLine: Int
        var level: Int
        var children: [Draft] = []

        init(kind: MindmapNode.Kind, text: String, line: Int, textEndLine: Int, endLine: Int, level: Int) {
            self.kind = kind
            self.text = text
            self.line = line
            self.textEndLine = textEndLine
            self.endLine = endLine
            self.level = level
        }

        func node(parentKey: String?, seen: [String: Int]) -> (node: MindmapNode, seen: [String: Int]) {
            var seen = seen
            let count = seen[text, default: 0]
            seen[text] = count + 1
            let own = text + (count > 0 ? "#\(count + 1)" : "")
            let key = parentKey.map { $0 + "/" + own } ?? own
            var childSeen: [String: Int] = [:]
            var nodes: [MindmapNode] = []
            for child in children {
                let made = child.node(parentKey: key, seen: childSeen)
                childSeen = made.seen
                nodes.append(made.node)
            }
            let node = MindmapNode(
                id: line, text: text, kind: kind, key: key, textEndLine: max(textEndLine, line),
                endLine: max(endLine, line), children: nodes
            )
            return (node, seen)
        }
    }

    /// The note with its frontmatter replaced by as many empty lines, so `---` is not read as a setext underline
    /// and line numbers still match the note.
    static func withoutFrontmatter(_ text: String) -> String {
        let (raw, yaml, body) = MarkdownFrontmatter.split(text)
        guard yaml != nil else { return text }
        return String(repeating: "\n", count: raw.filter { $0 == "\n" || $0 == "\r\n" }.count) + body
    }

    private static func isSetext(_ heading: Heading, in text: String) -> Bool {
        guard let line = heading.range?.lowerBound.line else { return false }
        return !MindmapDocument.lines(of: text)[safe: line - 1, default: ""]
            .trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }

    /// The last line of a heading's text: the line above a setext underline, else its own line.
    private static func textEnd(of heading: Heading, in text: String) -> Int {
        guard let range = heading.range else { return 0 }
        if isSetext(heading, in: text) { return max(range.lowerBound.line, range.upperBound.line - 1) }
        return range.lowerBound.line
    }

    static func plainText(_ markup: Markup) -> String {
        func walk(_ markup: Markup) -> String {
            switch markup {
            case let text as Markdown.Text: text.string
            case let code as InlineCode: code.code
            case is SoftBreak, is LineBreak: " "
            case is InlineHTML: ""
            default: markup.children.map(walk).joined()
            }
        }
        return walk(markup).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Array {
    subscript(safe index: Int, default value: Element) -> Element {
        indices.contains(index) ? self[index] : value
    }
}
