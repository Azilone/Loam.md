import Foundation

/// One entry of the `/` menu. It only ever inserts standard Markdown.
public struct SlashMenuItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name shown next to the title.
    public let symbol: String
    /// Extra words the filter matches, such as `h1` or `todo`.
    public let keywords: [String]
    /// The group the menu lists it under before anything is typed ("Text Style", "Lists"...), as in Craft.
    public let section: String
    /// A short label drawn instead of the symbol, such as `H1`.
    public let badge: String?
    /// Asks for pictures in an Open panel and inserts them as dropped files, when the host takes files. `makeEdit`
    /// is the fallback when it does not.
    public let picksImages: Bool
    /// Builds the edit. `trigger` is the `/` and the filter text typed after it; the edit replaces it.
    public let makeEdit: @Sendable (_ text: String, _ trigger: NSRange) -> TextEdit

    public init(
        id: String,
        title: String,
        symbol: String,
        keywords: [String] = [],
        section: String = SlashMenu.insertSection,
        badge: String? = nil,
        picksImages: Bool = false,
        makeEdit: @escaping @Sendable (_ text: String, _ trigger: NSRange) -> TextEdit
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.keywords = keywords
        self.section = section
        self.badge = badge
        self.picksImages = picksImages
        self.makeEdit = makeEdit
    }
}

public enum SlashMenu {
    /// The section of entries plugins add.
    public static let insertSection = "Insert"

    /// The built-in entries, grouped and named as Craft's `/` menu names them.
    public static let standardItems: [SlashMenuItem] = [
        .linePrefix("heading1", "Title", "textformat.size.larger", ["h1", "heading", "title"], "# ", section: "Text Style", badge: "H1"),
        .linePrefix("heading2", "Subtitle", "textformat.size", ["h2", "heading", "subtitle"], "## ", section: "Text Style", badge: "H2"),
        .linePrefix("heading3", "Heading", "textformat.size.smaller", ["h3", "heading"], "### ", section: "Text Style", badge: "H3"),
        .linePrefix("body", "Body", "textformat", ["text", "paragraph", "plain", "normal"], "", section: "Text Style", badge: "Aa"),
        .linePrefix("tasks", "Todo List", "checkmark.square", ["todo", "checkbox", "task"], "- [ ] ", section: "Lists"),
        .linePrefix("bullets", "Bullet List", "list.bullet", ["ul", "bullet", "list"], "- ", section: "Lists"),
        .linePrefix("numbers", "Numbered List", "list.number", ["ol", "number", "list"], "1. ", section: "Lists"),
        .linePrefix("quote", "Quote", "text.quote", ["blockquote", "citation"], "> ", section: "Blocks"),
        .block("alert", "Callout", "exclamationmark.bubble", ["alert", "callout", "note", "warning", "tip"], "> [!NOTE]\n> ", "", "", section: "Blocks"),
        .block("code", "Code", "chevron.left.forwardslash.chevron.right", ["code", "fence", "pre"], "```\n", "", "\n```", section: "Blocks"),
        .block("table", "Table", "tablecells", ["table", "grid", "columns"], "| ", "Column", " | Column |\n| --- | --- |\n|  |  |", section: "Blocks"),
        .block("divider", "Line", "minus", ["hr", "rule", "line", "separator", "divider"], "---\n", "", "", section: "Blocks"),
        .inline("link", "Link", "link", ["url", "href"], "[", "text", "](https://)"),
        .inline("image", "Image", "photo", ["img", "picture", "photo"], "![", "description", "](image.png)", picksImages: true),
    ]

    /// The entries matching `query` (the text typed after `/`), in menu order: those with a title word or a
    /// keyword starting with it first, then those whose title merely contains it.
    public static func filter(_ items: [SlashMenuItem], query: String) -> [SlashMenuItem] {
        let query = query.lowercased()
        guard !query.isEmpty else { return items }
        let prefixMatches = items.filter { item in
            let title = item.title.lowercased()
            return title.hasPrefix(query) || title.split(separator: " ").contains { $0.hasPrefix(query) }
                || item.keywords.contains { $0.hasPrefix(query) }
        }
        let containsMatches = items.filter { item in
            !prefixMatches.contains { $0.id == item.id } && item.title.lowercased().contains(query)
        }
        return prefixMatches + containsMatches
    }

    /// Whether a `/` typed at `location` opens the menu: at the start of a line or after a space.
    public static func opensMenu(in text: String, at location: Int) -> Bool {
        guard location > 0 else { return true }
        let previous = (text as NSString).character(at: location - 1)
        return previous == 10 || previous == 13 || previous == 32 || previous == 9
    }
}

// MARK: - Kinds of entries

/// Matches the block syntax at the start of a line, so a new prefix replaces it instead of piling up.
private func blockPrefixLength(_ line: String) -> Int {
    let pattern = /^[ \t]*(#{1,6}[ \t]+|>[ \t]?|(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)*/
    return line.prefixMatch(of: pattern).map { $0.0.utf16.count } ?? 0
}

extension SlashMenuItem {
    /// Turns the current line into a heading, list item or quote.
    static func linePrefix(
        _ id: String, _ title: String, _ symbol: String, _ keywords: [String], _ prefix: String,
        section: String, badge: String? = nil
    ) -> SlashMenuItem {
        SlashMenuItem(id: id, title: title, symbol: symbol, keywords: keywords, section: section, badge: badge) { text, trigger in
            let ns = text as NSString
            let line = ns.lineWithoutBreak(at: trigger.location)
            let before = ns.substring(with: NSRange(location: line.location, length: trigger.location - line.location))
            let existing = blockPrefixLength(before)
            let rest = String(before.utf16.dropFirst(existing)) ?? ""
            let replacement = prefix + rest
            let range = NSRange(location: line.location, length: NSMaxRange(trigger) - line.location)
            return TextEdit(
                range: range,
                replacement: replacement,
                selection: NSRange(location: line.location + replacement.utf16.count, length: 0)
            )
        }
    }

    /// Inserts a block on its own lines, with `placeholder` (or the caret) between `head` and `tail`.
    static func block(
        _ id: String, _ title: String, _ symbol: String, _ keywords: [String], _ head: String, _ placeholder: String,
        _ tail: String, section: String
    ) -> SlashMenuItem {
        SlashMenuItem(id: id, title: title, symbol: symbol, keywords: keywords, section: section) { text, trigger in
            let ns = text as NSString
            let line = ns.lineWithoutBreak(at: trigger.location)
            let before = ns.substring(with: NSRange(location: line.location, length: trigger.location - line.location))
            var lead = ""
            if !before.trimmingCharacters(in: .whitespaces).isEmpty {
                lead = "\n\n"
            } else if line.location > 0 {
                // A block right under a paragraph line can merge with it (`---` would make it a heading).
                let previous = ns.lineWithoutBreak(at: line.location - 1)
                if !ns.substring(with: previous).trimmingCharacters(in: .whitespaces).isEmpty { lead = "\n" }
            }
            let replacement = lead + head + placeholder + tail
            let caret = trigger.location + (lead + head).utf16.count
            return TextEdit(
                range: trigger,
                replacement: replacement,
                selection: NSRange(location: caret, length: placeholder.utf16.count)
            )
        }
    }

    /// Inserts inline syntax at the caret, with `placeholder` selected so typing replaces it.
    static func inline(
        _ id: String, _ title: String, _ symbol: String, _ keywords: [String], _ head: String, _ placeholder: String,
        _ tail: String, picksImages: Bool = false
    ) -> SlashMenuItem {
        SlashMenuItem(id: id, title: title, symbol: symbol, keywords: keywords, picksImages: picksImages) { _, trigger in
            TextEdit(
                range: trigger,
                replacement: head + placeholder + tail,
                selection: NSRange(location: trigger.location + head.utf16.count, length: placeholder.utf16.count)
            )
        }
    }
}
