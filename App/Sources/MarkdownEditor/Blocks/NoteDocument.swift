import Foundation

/// A note as the block editor works on it: its frontmatter as written, a flat list of blocks, and what follows the
/// last block. Read from Markdown by `NoteReader`, written back by `NoteWriter`: what was not edited comes back byte
/// for byte. Foundation only, so tests drive it without an editor (docs/design/BLOCK-EDITOR.md).
public struct NoteDocument: Sendable {
    /// The YAML block that opens the note, fences and last line break included, exactly as written; empty when none.
    public var frontmatter: String
    public var blocks: [NoteBlock]
    /// What follows the last block (blank lines, reference definitions, comments), exactly as written.
    public var end: String
    /// The blocks as they were read, in the file's order, with the hidden lines before each (reference
    /// definitions, comments): when a block is deleted, its hidden lines go to the next block still there.
    var read: [(id: NoteBlock.ID, hidden: String)]

    public init(frontmatter: String = "", blocks: [NoteBlock] = [], end: String = "") {
        self.frontmatter = frontmatter
        self.blocks = blocks
        self.end = end
        read = []
    }

    init(frontmatter: String, blocks: [NoteBlock], end: String, read: [(id: NoteBlock.ID, hidden: String)]) {
        self.frontmatter = frontmatter
        self.blocks = blocks
        self.end = end
        self.read = read
    }

    /// The note as Markdown.
    public var markdown: String { NoteWriter.markdown(of: self) }

    /// Reads `markdown`.
    public init(markdown: String) { self = NoteReader.document(from: markdown) }
}

/// One block of a page: a paragraph, a heading, a list item, a task, a code block... Containers are flattened as
/// Craft and Notion do: a list item at depth 2 inside a quote is one block with `depth` 2 and `quote` 1.
public struct NoteBlock: Equatable, Sendable, Identifiable {
    public typealias ID = Int

    public var id: ID
    public var kind: BlockKind
    /// How many lists hold it: 0 for a top-level item or paragraph, 1 for an item nested once, and so on. A paragraph
    /// that continues an item (its second paragraph) has the item's depth plus one.
    public var depth: Int
    /// How many quotes hold it.
    public var quote: Int
    /// The callout it is in (`> [!NOTE]`), if any; `opens` on its first block, which writes the `[!NOTE]` line.
    public var callout: Callout?
    /// What the page shows. For a code block, the code; for a table, an embed or a raw block, its Markdown without
    /// the quote and list prefixes (the component reads it).
    public var text: InlineText
    /// The lines before it that belong to no block (blank lines, a lone `>`, reference definitions, comments), as
    /// written. Kept while the block above is still the one read above it.
    public var before: String
    /// How it was read: its lines as written and what they meant. Nil for a block made in the editor.
    var source: Source?

    struct Source: Equatable, Sendable {
        /// Its own lines, prefixes and last line break included.
        var lines: String
        /// The block as read, which the lines still say while the block is equal to it (`NoteWriter.unchanged`).
        var meaning: Meaning
        /// The block read just above it, nil for the first one.
        var previous: NoteBlock.ID?
    }

    /// What a block's lines depend on: equal, the lines as read still say the same.
    struct Meaning: Equatable, Sendable {
        var kind: BlockKind
        var depth: Int
        var quote: Int
        var callout: Callout?
        var text: InlineText
        /// The column its list nesting starts at, from the items above it (`NoteWriter.layout`).
        var indent: Int
        /// The number a numbered item shows, from the items above it.
        var number: Int?
    }

    public init(
        id: ID, kind: BlockKind, depth: Int = 0, quote: Int = 0, callout: Callout? = nil, text: InlineText = InlineText(),
        before: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.depth = depth
        self.quote = quote
        self.callout = callout
        self.text = text
        self.before = before
        source = nil
    }
}

public enum BlockKind: Hashable, Sendable {
    case paragraph
    case heading(level: Int)
    case bullet
    /// A numbered item. `start` is the number written on the first item of a list; the others count from it.
    case numbered(start: Int)
    case task(checked: Bool)
    case code(language: String)
    case table
    case divider
    /// An image link alone on its line, `![alt](destination)`: shown as what it points to.
    case embed
    /// Markdown the page has no block for (raw HTML, a heading inside a list item...): shown and edited as written.
    case raw

    /// An item of a list: bullet, numbered or task.
    public var isListItem: Bool {
        switch self {
        case .bullet, .numbered, .task: true
        default: false
        }
    }

    /// Whether its text is the Markdown itself rather than styled text: what a component reads or shows as written.
    public var isVerbatim: Bool {
        switch self {
        case .code, .table, .embed, .raw: true
        default: false
        }
    }
}

/// A GitHub-style alert: `> [!NOTE]`, `> [!WARNING] Title`.
public struct Callout: Hashable, Sendable {
    /// `NOTE`, `TIP`, `WARNING`... as written.
    public var kind: String
    /// What follows `[!KIND]` on its line, as written (a title, a fold sign).
    public var title: String
    /// Whether this block starts the callout and writes its `[!KIND]` line.
    public var opens: Bool

    public init(kind: String, title: String = "", opens: Bool) {
        self.kind = kind
        self.title = title
        self.opens = opens
    }
}

/// Text as the page shows it, and its marks: the characters a person reads and edits, never Markdown syntax.
/// `U+2028` is a line break inside a block; `U+FFFC` an atom, something with no text of its own (an inline image,
/// a date, inline HTML) carried as its Markdown by an `.atom` mark over that one character.
public struct InlineText: Hashable, Sendable, ExpressibleByStringLiteral {
    public var string: String
    /// Sorted by location then mark; a mark's runs never touch or overlap each other (`normalized`).
    public var runs: [InlineRun]

    public static let lineBreak: Character = "\u{2028}"
    public static let atom: Character = "\u{FFFC}"

    public init(_ string: String = "", runs: [InlineRun] = []) {
        self.string = string
        self.runs = runs
        normalize()
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var length: Int { string.utf16.count }

    /// The runs sorted, empty ones dropped, widened to whole characters (never half an emoji), and touching or
    /// overlapping runs of one mark joined.
    public mutating func normalize() {
        let ns = string as NSString
        let length = ns.length
        var byMark: [InlineMark: [NSRange]] = [:]
        for run in Self.oneOfAKind(runs, length: length) {
            var range = NSIntersectionRange(run.range, NSRange(location: 0, length: length))
            guard range.length > 0 else { continue }
            range = ns.rangeOfComposedCharacterSequences(for: range)
            byMark[run.mark, default: []].append(range)
        }
        var joined: [InlineRun] = []
        for (mark, ranges) in byMark {
            // An atom stands for one character: two never join.
            if case .atom = mark {
                joined += ranges.map { InlineRun($0, mark) }
                continue
            }
            var current: NSRange?
            for range in ranges.sorted(by: { $0.location < $1.location }) {
                if let open = current, range.location <= NSMaxRange(open) {
                    current = NSRange(location: open.location, length: max(NSMaxRange(open), NSMaxRange(range)) - open.location)
                } else {
                    if let open = current { joined.append(InlineRun(open, mark)) }
                    current = range
                }
            }
            if let open = current { joined.append(InlineRun(open, mark)) }
        }
        runs = joined.sorted { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.mark.order < $1.mark.order }
    }

    /// The runs with at most one highlight and one link over each character: a later run wins over an earlier one,
    /// as a colour applied over another replaces it.
    private static func oneOfAKind(_ runs: [InlineRun], length: Int) -> [InlineRun] {
        func kind(_ mark: InlineMark) -> Int? {
            switch mark {
            case .highlight: 0
            case .link: 1
            default: nil
            }
        }
        guard runs.contains(where: { kind($0.mark) != nil }) else { return runs }
        var result = runs.filter { kind($0.mark) == nil }
        for wanted in [0, 1] {
            var owner = [InlineMark?](repeating: nil, count: length)
            for run in runs where kind(run.mark) == wanted {
                let range = NSIntersectionRange(run.range, NSRange(location: 0, length: length))
                for index in range.location..<NSMaxRange(range) { owner[index] = run.mark }
            }
            var start = 0
            while start < length {
                guard let mark = owner[start] else { start += 1; continue }
                var end = start + 1
                while end < length, owner[end] == mark { end += 1 }
                result.append(InlineRun(NSRange(location: start, length: end - start), mark))
                start = end
            }
        }
        return result
    }

    /// The marks over the character at `index`.
    public func marks(at index: Int) -> [InlineMark] {
        runs.filter { NSLocationInRange(index, $0.range) }.map(\.mark)
    }
}

public struct InlineRun: Hashable, Sendable {
    public var range: NSRange
    public var mark: InlineMark

    public init(_ range: NSRange, _ mark: InlineMark) {
        self.range = range
        self.mark = mark
    }
}

public enum InlineMark: Hashable, Sendable {
    case strong
    case emphasis
    case strikethrough
    /// `<u>`: HTML only, Markdown has no underline.
    case underline
    /// `<sup>`.
    case superscript
    /// `<sub>`.
    case `subscript`
    /// `<kbd>`: a key, drawn as a keycap.
    case keyboard
    case code
    /// `<mark>`, with the colour of its `style` (`#rrggbb`) or nil for the default yellow.
    case highlight(color: String?)
    /// `[text](destination "title")`, or `<destination>` when the text is the destination.
    case link(destination: String, title: String? = nil)
    /// Something shown with no text of its own, over its one `U+FFFC`: its Markdown, written back as is.
    case atom(markdown: String)
    /// Over a `U+2028`: a hard break (`\` or two spaces before the line break) rather than a soft one.
    case hardBreak

    /// Whether the mark carries a value (a colour, a destination) that another of its kind may not share.
    var isValued: Bool {
        switch self {
        case .highlight, .link, .atom: true
        default: false
        }
    }

    /// How marks nest when written: a lower order holds a higher one (`[**a**](x)`, `**`a`**`).
    var order: Int {
        switch self {
        case .link: 0
        case .highlight: 1
        case .strong: 2
        case .emphasis: 3
        case .strikethrough: 4
        case .underline: 5
        case .superscript: 6
        case .subscript: 7
        case .keyboard: 8
        case .code: 9
        case .atom: 10
        case .hardBreak: 11
        }
    }
}
