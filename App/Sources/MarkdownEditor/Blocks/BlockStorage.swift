import Foundation

/// What the block editor's text storage holds: each block's visible text as one paragraph ending in `\n`, the block
/// itself over the whole paragraph (`.noteBlock`), and its inline marks as attributes. No Markdown syntax is ever in
/// it. A table, an embed or a divider is a single `U+FFFC` whose block carries its Markdown. Foundation only.
public extension NSAttributedString.Key {
    /// A `BlockAttribute`, over a whole paragraph and its line break.
    static let noteBlock = NSAttributedString.Key("Loam.noteBlock")
    static let noteStrong = NSAttributedString.Key("Loam.noteStrong")
    static let noteEmphasis = NSAttributedString.Key("Loam.noteEmphasis")
    static let noteStrikethrough = NSAttributedString.Key("Loam.noteStrikethrough")
    static let noteCode = NSAttributedString.Key("Loam.noteCode")
    static let noteUnderline = NSAttributedString.Key("Loam.noteUnderline")
    static let noteSuperscript = NSAttributedString.Key("Loam.noteSuperscript")
    static let noteSubscript = NSAttributedString.Key("Loam.noteSubscript")
    static let noteKeyboard = NSAttributedString.Key("Loam.noteKeyboard")
    /// The highlight's colour, `#rrggbb`, or an empty string for the default yellow.
    static let noteHighlight = NSAttributedString.Key("Loam.noteHighlight")
    /// A `LinkAttribute`.
    static let noteLink = NSAttributedString.Key("Loam.noteLink")
    /// The Markdown of an atom, over its `U+FFFC`.
    static let noteAtom = NSAttributedString.Key("Loam.noteAtom")
    /// Over a `U+2028`: a hard break.
    static let noteHardBreak = NSAttributedString.Key("Loam.noteHardBreak")
}

/// The block a paragraph of the storage is. Compared by identity: two paragraphs never share one (`normalize`).
public final class BlockAttribute: NSObject, @unchecked Sendable {
    public let block: NoteBlock

    public init(_ block: NoteBlock) { self.block = block }

    public override var description: String { "BlockAttribute(\(block.id), \(block.kind))" }
}

/// A link's destination and title; equal when they are, so a link's characters form one run.
public final class LinkAttribute: NSObject, @unchecked Sendable {
    public let destination: String
    public let title: String?

    public init(destination: String, title: String? = nil) {
        self.destination = destination
        self.title = title
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? LinkAttribute else { return false }
        return destination == other.destination && title == other.title
    }

    public override var hash: Int { destination.hashValue ^ (title?.hashValue ?? 0) }
}

/// New block ids, unique in the process.
public enum BlockIDs {
    nonisolated(unsafe) private static var last = 1_000_000
    private static let lock = NSLock()

    public static func next() -> NoteBlock.ID {
        lock.lock()
        defer { lock.unlock() }
        last += 1
        return last
    }
}

public enum BlockStorage {
    static let atom = String(InlineText.atom)

    /// The languages whose code blocks the editor shows as a component (a diagram, a collection), lowercased: set by
    /// the editor from its plugins.
    nonisolated(unsafe) public static var componentLanguages: Set<String> = []

    /// Blocks shown as one character, their Markdown in the block: the page draws a component in their place.
    static func isAtomic(_ kind: BlockKind) -> Bool {
        switch kind {
        case .table, .embed, .divider: true
        case .code(let language): componentLanguages.contains(language.lowercased())
        default: false
        }
    }

    // MARK: Building

    /// The storage for `blocks`: one paragraph each, every one ending in `\n`.
    public static func attributedString(of blocks: [NoteBlock]) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for block in blocks { result.append(paragraph(of: block)) }
        return result
    }

    /// One block's paragraph, its line break included.
    public static func paragraph(of block: NoteBlock) -> NSAttributedString {
        let paragraph = NSMutableAttributedString()
        if isAtomic(block.kind) {
            paragraph.append(NSAttributedString(string: atom))
        } else {
            paragraph.append(attributedString(of: block.text))
        }
        paragraph.append(NSAttributedString(string: "\n"))
        paragraph.addAttribute(.noteBlock, value: BlockAttribute(block), range: NSRange(location: 0, length: paragraph.length))
        return paragraph
    }

    /// `text` with its marks as attributes.
    public static func attributedString(of text: InlineText) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: text.string)
        for run in text.runs {
            let (key, value) = attribute(for: run.mark)
            result.addAttribute(key, value: value, range: run.range)
        }
        return result
    }

    private static func attribute(for mark: InlineMark) -> (NSAttributedString.Key, Any) {
        switch mark {
        case .strong: (.noteStrong, true)
        case .emphasis: (.noteEmphasis, true)
        case .strikethrough: (.noteStrikethrough, true)
        case .code: (.noteCode, true)
        case .underline: (.noteUnderline, true)
        case .superscript: (.noteSuperscript, true)
        case .subscript: (.noteSubscript, true)
        case .keyboard: (.noteKeyboard, true)
        case .highlight(let color): (.noteHighlight, color ?? "")
        case .link(let destination, let title): (.noteLink, LinkAttribute(destination: destination, title: title))
        case .atom(let markdown): (.noteAtom, markdown)
        case .hardBreak: (.noteHardBreak, true)
        }
    }

    // MARK: Reading

    /// The paragraphs of `storage`, each with its line break, and the empty one after the last line break.
    public static func paragraphs(of storage: NSAttributedString) -> [NSRange] {
        let ns = storage.string as NSString
        var result: [NSRange] = []
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            result.append(range)
            location = NSMaxRange(range)
        }
        result.append(NSRange(location: ns.length, length: 0))
        return result
    }

    /// The block of the paragraph at `range`, with its text read from the storage (not for an atomic block, whose
    /// text is its Markdown, kept in the block). Nil for a paragraph without a block, which `normalize` gives one.
    public static func block(in storage: NSAttributedString, paragraph range: NSRange) -> NoteBlock? {
        guard range.length > 0, let attribute = storage.attribute(.noteBlock, at: range.location, effectiveRange: nil) as? BlockAttribute
        else { return nil }
        var block = attribute.block
        if !isAtomic(block.kind) { block.text = inlineText(of: storage, in: content(of: range, in: storage)) }
        return block
    }

    /// The block of the paragraph starting at `location` as its attribute holds it: kind, depth, quote, without reading
    /// its text (quick, for what only needs the structure: folds, handles).
    public static func structure(in storage: NSAttributedString, at location: Int) -> NoteBlock? {
        guard location < storage.length else { return nil }
        return (storage.attribute(.noteBlock, at: location, effectiveRange: nil) as? BlockAttribute)?.block
    }

    /// The blocks of `storage`, in order. The empty paragraph after the last line break is not one.
    public static func blocks(of storage: NSAttributedString) -> [NoteBlock] {
        paragraphs(of: storage).compactMap { range in
            guard range.length > 0 else { return nil }
            return block(in: storage, paragraph: range) ?? NoteBlock(id: BlockIDs.next(), kind: .paragraph,
                                                                   text: inlineText(of: storage, in: content(of: range, in: storage)))
        }
    }

    /// The paragraph's text without its line break.
    public static func content(of paragraph: NSRange, in storage: NSAttributedString) -> NSRange {
        let ns = storage.string as NSString
        var range = paragraph
        while range.length > 0, [10, 13, 0x2029].contains(ns.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        return range
    }

    /// The text and marks of `range`.
    public static func inlineText(of storage: NSAttributedString, in range: NSRange) -> InlineText {
        let text = (storage.string as NSString).substring(with: range)
        var runs: [InlineRun] = []
        storage.enumerateAttributes(in: range) { attributes, run, _ in
            let local = NSRange(location: run.location - range.location, length: run.length)
            if attributes[.noteStrong] != nil { runs.append(InlineRun(local, .strong)) }
            if attributes[.noteEmphasis] != nil { runs.append(InlineRun(local, .emphasis)) }
            if attributes[.noteStrikethrough] != nil { runs.append(InlineRun(local, .strikethrough)) }
            if attributes[.noteCode] != nil { runs.append(InlineRun(local, .code)) }
            if attributes[.noteUnderline] != nil { runs.append(InlineRun(local, .underline)) }
            if attributes[.noteSuperscript] != nil { runs.append(InlineRun(local, .superscript)) }
            if attributes[.noteSubscript] != nil { runs.append(InlineRun(local, .subscript)) }
            if attributes[.noteKeyboard] != nil { runs.append(InlineRun(local, .keyboard)) }
            if let color = attributes[.noteHighlight] as? String { runs.append(InlineRun(local, .highlight(color: color.isEmpty ? nil : color))) }
            if let link = attributes[.noteLink] as? LinkAttribute {
                runs.append(InlineRun(local, .link(destination: link.destination, title: link.title)))
            }
            if attributes[.noteHardBreak] != nil {
                // Only over the line breaks.
                let ns = text as NSString
                for index in local.location..<NSMaxRange(local) where ns.character(at: index) == InlineText.lineBreak.utf16.first! {
                    runs.append(InlineRun(NSRange(location: index, length: 1), .hardBreak))
                }
            }
            if let markdown = attributes[.noteAtom] as? String {
                // One atom per object replacement character.
                let ns = text as NSString
                for index in local.location..<NSMaxRange(local) where ns.character(at: index) == InlineText.atom.utf16.first! {
                    runs.append(InlineRun(NSRange(location: index, length: 1), .atom(markdown: markdown)))
                }
            }
        }
        return InlineText(text, runs: runs)
    }

    // MARK: Normalizing

    /// Makes the paragraphs touching `range` well formed after an edit: each has exactly one block over all of it, a
    /// block is never on two paragraphs (the second of a split gets a new one), and a paragraph that lost its block
    /// (typed or pasted without one) becomes a paragraph block. Two blocks in one paragraph (a line break deleted
    /// between them) leave the first. Returns whether anything changed.
    @discardableResult
    public static func normalize(_ storage: NSMutableAttributedString, around range: NSRange) -> Bool {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return false }
        let start = ns.paragraphRange(for: NSRange(location: min(range.location, ns.length - 1), length: 0)).location
        // One paragraph before the edit too, which may share its block with the first edited one.
        let from = start > 0 ? ns.paragraphRange(for: NSRange(location: start - 1, length: 0)).location : start
        let end = min(NSMaxRange(range), ns.length)
        let to = end < ns.length ? NSMaxRange(ns.paragraphRange(for: NSRange(location: end, length: 0))) : ns.length
        var changed = false
        var seen = Set<ObjectIdentifier>()
        var location = from
        storage.beginEditing()
        defer { storage.endEditing() }
        while location < to {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            var values: [BlockAttribute?] = []
            storage.enumerateAttribute(.noteBlock, in: paragraph) { value, _, _ in values.append(value as? BlockAttribute) }
            let first = values.compactMap { $0 }.first
            var uniform = values.allSatisfy { $0 != nil && $0 === first }
            var attribute = first ?? BlockAttribute(NoteBlock(id: BlockIDs.next(), kind: .paragraph))
            if seen.contains(ObjectIdentifier(attribute)) {
                // The second half of a split paragraph: the same kind of block, new.
                var block = attribute.block
                block.id = BlockIDs.next()
                block.source = nil
                block.before = ""
                if case .heading = block.kind { block.kind = .paragraph }
                if block.callout?.opens == true { block.callout?.opens = false }
                attribute = BlockAttribute(block)
                uniform = false
            }
            seen.insert(ObjectIdentifier(attribute))
            if first == nil || !uniform {
                storage.addAttribute(.noteBlock, value: attribute, range: paragraph)
                changed = true
            }
        }
        return changed
    }
}
