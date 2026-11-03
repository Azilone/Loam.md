import Foundation
import Markdown
import PluginKit

/// One heading of a note, as the Outline panel lists it and `outline.headings` returns it.
public struct OutlineHeading: Codable, Equatable, Sendable, Identifiable {
    /// 1 to 6.
    public let level: Int
    /// The heading's plain text: inline formatting, link syntax and closing `#`s removed.
    public let text: String
    /// The line the heading starts on, 1-based, counted in the whole note (frontmatter included).
    public let line: Int

    /// A line holds at most one heading, so it identifies a row.
    public var id: Int { line }

    public init(level: Int, text: String, line: Int) {
        self.level = level
        self.text = text
        self.line = line
    }
}

public enum OutlineHeadings {
    /// The ATX (`## Title`) and setext (`Title` over `===`) headings of a Markdown note, in order. Code blocks and
    /// the YAML frontmatter are skipped; headings with no text are left out.
    public static func extract(from text: String) -> [OutlineHeading] {
        var walker = Collector()
        walker.visit(Markdown.Document(parsing: withoutFrontmatter(text)))
        return walker.headings
    }

    /// The note with its frontmatter replaced by as many empty lines, so the parser does not read `---` blocks as
    /// thematic breaks or setext underlines, and line numbers still match the note.
    static func withoutFrontmatter(_ text: String) -> String {
        let (raw, yaml, body) = MarkdownFrontmatter.split(text)
        guard yaml != nil else { return text }
        return String(repeating: "\n", count: raw.filter { $0 == "\n" || $0 == "\r\n" }.count) + body
    }

    private struct Collector: MarkupWalker {
        var headings: [OutlineHeading] = []

        mutating func visitHeading(_ heading: Heading) {
            let text = plainText(heading).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let line = heading.range?.lowerBound.line else { return }
            headings.append(OutlineHeading(level: heading.level, text: text, line: line))
        }
    }

    /// The visible text of inline content: code without its backticks, links and images by their text, raw
    /// HTML dropped.
    private static func plainText(_ markup: Markup) -> String {
        switch markup {
        case let text as Markdown.Text: text.string
        case let code as InlineCode: code.code
        case is SoftBreak, is LineBreak: " "
        case is InlineHTML: ""
        default: markup.children.map(plainText).joined()
        }
    }
}
