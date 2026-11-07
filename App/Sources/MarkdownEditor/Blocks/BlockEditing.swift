import Foundation

/// A change to the block storage: `range` replaced by `replacement` (blocks included), then `selection`. Made by the
/// pure functions of `BlockEditing`, applied by the editor through its text view so that it is one undo step.
public struct BlockEdit: Equatable {
    public let range: NSRange
    public let replacement: NSAttributedString
    public let selection: NSRange

    public init(range: NSRange, replacement: NSAttributedString, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// `storage` with the edit made. Used by tests; the editor applies edits through its text view.
    public func applied(to storage: NSAttributedString) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(attributedString: storage)
        result.replaceCharacters(in: range, with: replacement)
        return result
    }
}

/// The structure keys of the block editor, as Notion and Craft have them: Return, Backspace, Delete, Tab and the
/// Markdown shortcuts typed at the start of a block. Each looks at the paragraphs around the selection and returns the
/// edit to make, or nil when the text view's own behaviour is right. Foundation only.
public enum BlockEditing {
    /// A paragraph, its block and where its text is.
    struct Place {
        let paragraph: NSRange
        let content: NSRange
        let block: NoteBlock
    }

    static func place(at location: Int, in storage: NSAttributedString) -> Place? {
        let ns = storage.string as NSString
        guard location <= ns.length else { return nil }
        // The empty paragraph after the last line break has no block yet: it is a new paragraph.
        if location == ns.length, ns.length == 0 || ns.character(at: ns.length - 1) == 10 {
            let empty = NSRange(location: ns.length, length: 0)
            return Place(paragraph: empty, content: empty, block: NoteBlock(id: BlockIDs.next(), kind: .paragraph))
        }
        let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
        let content = BlockStorage.content(of: paragraph, in: storage)
        let block = BlockStorage.block(in: storage, paragraph: paragraph)
            ?? NoteBlock(id: BlockIDs.next(), kind: .paragraph, text: BlockStorage.inlineText(of: storage, in: content))
        return Place(paragraph: paragraph, content: content, block: block)
    }

    static func previousPlace(_ place: Place, in storage: NSAttributedString) -> Place? {
        place.paragraph.location > 0 ? self.place(at: place.paragraph.location - 1, in: storage) : nil
    }

    static func nextPlace(_ place: Place, in storage: NSAttributedString) -> Place? {
        let end = NSMaxRange(place.paragraph)
        return end < storage.length ? self.place(at: end, in: storage) : nil
    }

    /// A new block of `kind` placed like `block` (same depth, quote and callout), with `text`.
    static func sibling(of block: NoteBlock, kind: BlockKind? = nil, text: InlineText = InlineText()) -> NoteBlock {
        var callout = block.callout
        callout?.opens = false
        var kind = kind ?? block.kind
        if case .task = kind { kind = .task(checked: false) }
        if case .heading = kind { kind = .paragraph }
        if BlockStorage.isAtomic(kind) { kind = .paragraph }
        return NoteBlock(id: BlockIDs.next(), kind: kind, depth: block.depth, quote: block.quote, callout: callout, text: text)
    }

    /// The paragraphs for `blocks`, joined.
    static func paragraphs(_ blocks: [NoteBlock]) -> NSAttributedString {
        BlockStorage.attributedString(of: blocks)
    }

    // MARK: Return

    /// Return: splits the block at the caret. A list, a quote and a callout continue; the line after a heading is a
    /// paragraph; Return on an empty item moves it out a level, or out of the list; in code it starts a new line,
    /// and on an empty last line of code it leaves the code.
    public static func newline(in storage: NSAttributedString, selection: NSRange) -> BlockEdit? {
        guard selection.length == 0, let place = place(at: selection.location, in: storage) else { return nil }
        let block = place.block
        let offset = selection.location - place.content.location
        let text = block.text

        if BlockStorage.isAtomic(block.kind) {
            // Before or after the component: a paragraph there.
            let new = sibling(of: block, kind: .paragraph)
            let before = offset == 0
            let blocks = before ? [new, block] : [block, new]
            let caret = place.paragraph.location + (before ? 0 : 2)
            return BlockEdit(range: place.paragraph, replacement: paragraphs(blocks), selection: NSRange(location: caret, length: 0))
        }
        if case .code = block.kind {
            let ns = text.string as NSString
            let lineBreak = String(InlineText.lineBreak)
            if offset == ns.length, ns.hasSuffix(lineBreak) {
                // Return on the empty last line: out of the code.
                var code = block
                code.text = cut(text, NSRange(location: 0, length: ns.length - 1))
                let new = sibling(of: block, kind: .paragraph)
                let replacement = paragraphs([code, new])
                return BlockEdit(range: place.paragraph, replacement: replacement,
                                 selection: NSRange(location: place.paragraph.location + replacement.length - 1, length: 0))
            }
            return nil
        }
        if text.length == 0 {
            var moved = block
            if block.kind.isListItem, block.depth > 0 {
                moved.depth -= 1
            } else if block.kind.isListItem || block.depth > 0 {
                moved.kind = .paragraph
                moved.depth = 0
            } else if block.callout != nil, block.callout?.opens != true {
                moved.callout = nil
                moved.quote = max(0, block.quote - 1)
            } else if block.quote > 0 {
                moved.quote -= 1
            } else {
                return split(place, at: 0)
            }
            return BlockEdit(range: place.paragraph, replacement: paragraphs([moved]),
                             selection: NSRange(location: place.paragraph.location, length: 0))
        }
        return split(place, at: offset)
    }

    /// `place`'s block cut at `offset`: the text before stays in it, the text after goes into a new block like it.
    /// At the very start of a non-empty block, an empty block goes above and the block keeps its text and identity.
    private static func split(_ place: Place, at offset: Int) -> BlockEdit {
        let block = place.block
        let text = block.text
        if offset == 0, text.length > 0 {
            let above = sibling(of: block, kind: block.kind.isListItem ? block.kind : .paragraph)
            var same = block
            if same.callout?.opens == true {
                // The callout's header stays on its first block.
                var opener = above
                opener.callout = block.callout
                same.callout?.opens = false
                return BlockEdit(range: place.paragraph, replacement: paragraphs([opener, same]),
                                 selection: NSRange(location: place.paragraph.location + 1, length: 0))
            }
            return BlockEdit(range: place.paragraph, replacement: paragraphs([above, same]),
                             selection: NSRange(location: place.paragraph.location + 1, length: 0))
        }
        var first = block
        first.text = cut(text, NSRange(location: 0, length: offset))
        let rest = cut(text, NSRange(location: offset, length: text.length - offset))
        let second = sibling(of: block, text: rest)
        return BlockEdit(range: place.paragraph, replacement: paragraphs([first, second]),
                         selection: NSRange(location: place.paragraph.location + offset + 1, length: 0))
    }

    /// The part `range` of `text`, its marks with it.
    static func cut(_ text: InlineText, _ range: NSRange) -> InlineText {
        let ns = text.string as NSString
        let runs = text.runs.compactMap { run -> InlineRun? in
            let overlap = NSIntersectionRange(run.range, range)
            guard overlap.length > 0 else { return nil }
            return InlineRun(NSRange(location: overlap.location - range.location, length: overlap.length), run.mark)
        }
        return InlineText(ns.substring(with: range), runs: runs)
    }

    /// `a` then `b`, marks kept.
    static func joined(_ a: InlineText, _ b: InlineText) -> InlineText {
        let shift = a.length
        return InlineText(a.string + b.string, runs: a.runs + b.runs.map { InlineRun(NSRange(location: $0.range.location + shift, length: $0.range.length), $0.mark) })
    }

    // MARK: Backspace and Delete

    /// Backspace at the start of a block: what makes it a heading, an item, a quote or a callout goes first (an item
    /// nested in a list moves out a level), then it joins the block above. Nil anywhere else.
    public static func deleteBackward(in storage: NSAttributedString, selection: NSRange) -> BlockEdit? {
        guard selection.length == 0, let place = place(at: selection.location, in: storage),
              selection.location == place.content.location, place.paragraph.length > 0
        else { return nil }
        let block = place.block
        var changed = block
        switch block.kind {
        case .heading, .bullet, .numbered, .task:
            changed.kind = .paragraph
        case .code where block.text.length == 0:
            changed.kind = .paragraph
        case .code:
            return BlockEdit(range: NSRange(location: selection.location, length: 0), replacement: NSAttributedString(), selection: selection)
        default:
            if block.callout != nil {
                changed.callout = nil
                changed.quote = max(0, block.quote - 1)
            } else if block.quote > 0 {
                changed.quote -= 1
            } else if block.depth > 0 {
                changed.depth -= 1
            } else {
                return join(previousOf: place, in: storage)
            }
        }
        var replaced = [changed]
        var range = place.paragraph
        // A callout's first block leaving it hands its header to the next block of the callout.
        if block.callout?.opens == true, changed.callout == nil, let next = nextPlace(place, in: storage),
           next.block.callout != nil, next.block.callout?.opens == false {
            var opener = next.block
            opener.callout?.opens = true
            replaced.append(opener)
            range = NSUnionRange(range, next.paragraph)
        }
        return BlockEdit(range: range, replacement: paragraphs(replaced), selection: selection)
    }

    /// Backspace at the start of a plain paragraph: its text joins the block above, which keeps its kind. An empty
    /// paragraph under a component goes; nothing joins a component.
    private static func join(previousOf place: Place, in storage: NSAttributedString) -> BlockEdit? {
        guard let previous = previousPlace(place, in: storage) else { return nil }
        if BlockStorage.isAtomic(previous.block.kind) {
            guard place.block.text.length == 0 else {
                // The caret goes to the component instead of taking it in.
                return BlockEdit(range: NSRange(location: place.paragraph.location, length: 0), replacement: NSAttributedString(),
                                 selection: NSRange(location: previous.content.location, length: previous.content.length))
            }
            return BlockEdit(range: place.paragraph, replacement: NSAttributedString(),
                             selection: NSRange(location: NSMaxRange(previous.content), length: 0))
        }
        var merged = previous.block
        merged.text = joined(previous.block.text, place.block.text)
        return BlockEdit(range: NSUnionRange(previous.paragraph, place.paragraph), replacement: paragraphs([merged]),
                         selection: NSRange(location: NSMaxRange(previous.content), length: 0))
    }

    /// Delete at the end of a block: the block below joins it. Nil anywhere else.
    public static func deleteForward(in storage: NSAttributedString, selection: NSRange) -> BlockEdit? {
        guard selection.length == 0, let place = place(at: selection.location, in: storage),
              selection.location == NSMaxRange(place.content), let next = nextPlace(place, in: storage),
              next.paragraph.length > 0
        else { return nil }
        if BlockStorage.isAtomic(next.block.kind) || BlockStorage.isAtomic(place.block.kind) {
            return BlockEdit(range: NSRange(location: selection.location, length: 0), replacement: NSAttributedString(), selection: selection)
        }
        var merged = place.block
        merged.text = joined(place.block.text, next.block.text)
        return BlockEdit(range: NSUnionRange(place.paragraph, next.paragraph), replacement: paragraphs([merged]), selection: selection)
    }

    // MARK: Tab

    /// Tab and Shift-Tab over the blocks of `selection`: items nest one level deeper than the item above at most, and
    /// come out to the top of the list. Nil when no selected block is in a list (Tab then does its usual work).
    public static func indent(in storage: NSAttributedString, selection: NSRange, outdent: Bool) -> BlockEdit? {
        guard let first = place(at: selection.location, in: storage) else { return nil }
        if case .code = first.block.kind { return nil }
        var places = [first]
        while let last = places.last, NSMaxRange(last.paragraph) < NSMaxRange(selection), let next = nextPlace(last, in: storage),
              next.paragraph.length > 0 {
            places.append(next)
        }
        var previous = previousPlace(first, in: storage)?.block
        var blocks: [NoteBlock] = []
        var changed = false
        for place in places {
            var block = place.block
            let inList = block.kind.isListItem || block.depth > 0
            if inList {
                if outdent {
                    if block.depth > 0 { block.depth -= 1; changed = true }
                } else if let previous, previous.kind.isListItem || previous.depth > 0, previous.quote == block.quote,
                          block.depth <= previous.depth {
                    // A paragraph continuing an item is one deeper than its item already.
                    block.depth += 1
                    changed = true
                }
            }
            blocks.append(block)
            previous = block
        }
        guard changed else { return places.contains { $0.block.kind.isListItem } ? noChange(selection) : nil }
        let range = NSUnionRange(first.paragraph, places.last!.paragraph)
        return BlockEdit(range: range, replacement: paragraphs(blocks), selection: selection)
    }

    private static func noChange(_ selection: NSRange) -> BlockEdit {
        BlockEdit(range: NSRange(location: selection.location, length: 0), replacement: NSAttributedString(), selection: selection)
    }

    // MARK: Shortcuts

    nonisolated(unsafe) private static let headingShortcut = /^(#{1,6}) $/
    nonisolated(unsafe) private static let numberShortcut = /^(\d{1,9})[.)] $/
    nonisolated(unsafe) private static let fenceShortcut = /^```([^`\s]*)$/

    /// After typing at `location` (the caret, just after what was typed): a Markdown shortcut at the start of a
    /// paragraph becomes what it says, as in Notion and Craft. `# ` a heading, `- `, `* ` or `+ ` a bullet, `1. ` a
    /// numbered item, `[] ` or `[x] ` a task, `> ` a quote, `---` a divider, ```` ``` ```` then Return a code block (see
    /// `fence`). The characters typed go.
    public static func shortcut(in storage: NSAttributedString, at location: Int) -> BlockEdit? {
        guard let place = place(at: location, in: storage), place.paragraph.length > 0 else { return nil }
        let block = place.block
        let typed = (storage.string as NSString).substring(with: NSRange(location: place.content.location, length: location - place.content.location))
        guard location <= NSMaxRange(place.content), !typed.isEmpty else { return nil }
        var changed = block
        let paragraph = block.kind == .paragraph
        let boxable = paragraph || block.kind == .bullet
        if paragraph, ["- ", "* ", "+ "].contains(typed) {
            changed.kind = .bullet
        } else if boxable, ["[] ", "[ ] "].contains(typed) {
            changed.kind = .task(checked: false)
        } else if boxable, ["[x] ", "[X] "].contains(typed) {
            changed.kind = .task(checked: true)
        } else if paragraph, typed == "> ", block.depth == 0, block.callout == nil {
            changed.quote += 1
        } else if paragraph, typed == "---", block.depth == 0, place.content.length == 3 {
            let divider = NoteBlock(id: BlockIDs.next(), kind: .divider, quote: block.quote, text: InlineText())
            let after = sibling(of: block, kind: .paragraph)
            return BlockEdit(range: place.paragraph, replacement: paragraphs([divider, after]),
                             selection: NSRange(location: place.paragraph.location + 2, length: 0))
        } else if paragraph, block.depth == 0, let match = typed.wholeMatch(of: headingShortcut) {
            changed.kind = .heading(level: match.1.count)
        } else if paragraph, let match = typed.wholeMatch(of: numberShortcut), let start = Int(match.1) {
            changed.kind = .numbered(start: start)
        } else {
            return inlineShortcut(in: storage, place: place, at: location)
        }
        let typedLength = typed.utf16.count
        changed.text = cut(block.text, NSRange(location: typedLength, length: block.text.length - typedLength))
        return BlockEdit(range: place.paragraph, replacement: paragraphs([changed]),
                         selection: NSRange(location: place.paragraph.location, length: 0))
    }

    /// Return after ```` ``` ```` or ```` ```swift ```` alone in a paragraph: a code block of that language.
    public static func fence(in storage: NSAttributedString, selection: NSRange) -> BlockEdit? {
        guard selection.length == 0, let place = place(at: selection.location, in: storage),
              place.block.kind == .paragraph, selection.location == NSMaxRange(place.content),
              let match = place.block.text.string.wholeMatch(of: fenceShortcut)
        else { return nil }
        var code = place.block
        code.kind = .code(language: String(match.1))
        code.text = InlineText()
        return BlockEdit(range: place.paragraph, replacement: paragraphs([code]),
                         selection: NSRange(location: place.paragraph.location, length: 0))
    }

    /// `**text**`, `*text*`, `_text_`, `~~text~~` and `` `text` `` just closed at the caret: the text gets the mark and the
    /// markers go.
    private static func inlineShortcut(in storage: NSAttributedString, place: Place, at location: Int) -> BlockEdit? {
        let text = place.block.text
        if case .code = place.block.kind { return nil }
        let ns = text.string as NSString
        let end = location - place.content.location
        guard end > 2 else { return nil }
        let before = ns.substring(to: end)
        let shortcuts: [(marker: String, mark: InlineMark)] = [("**", .strong), ("~~", .strikethrough), ("`", .code), ("*", .emphasis), ("_", .emphasis)]
        for (marker, mark) in shortcuts where before.hasSuffix(marker) {
            let markerLength = marker.utf16.count
            let closing = end - markerLength
            // The opening marker: the last one before, with text between that does not start or end with a space.
            let search = NSRange(location: 0, length: closing)
            let opening = ns.range(of: marker, options: .backwards, range: search)
            guard opening.location != NSNotFound else { continue }
            let inner = NSRange(location: NSMaxRange(opening), length: closing - NSMaxRange(opening))
            guard inner.length > 0 else { continue }
            let content = ns.substring(with: inner)
            guard content.first?.isWhitespace == false, content.last?.isWhitespace == false else { continue }
            // `*` is not half of a `**`, and the text inside is not already code.
            if marker == "*", opening.location > 0, ns.character(at: opening.location - 1) == 42 { continue }
            if marker == "*", content.hasPrefix("*") { continue }
            if text.runs.contains(where: { $0.mark == .code && NSIntersectionRange($0.range, NSRange(location: opening.location, length: end - opening.location)).length > 0 }) { continue }
            var runs = text.runs
            runs.append(InlineRun(inner, mark))
            var marked = InlineText(text.string, runs: runs)
            // The closing marker first, so the opening one's offsets stay right.
            marked = removing(NSRange(location: closing, length: markerLength), from: marked)
            marked = removing(opening, from: marked)
            var block = place.block
            block.text = marked
            let caret = place.content.location + end - 2 * markerLength
            return BlockEdit(range: place.paragraph, replacement: paragraphs([block]), selection: NSRange(location: caret, length: 0))
        }
        return nil
    }

    /// `text` without `range`, marks moved.
    static func removing(_ range: NSRange, from text: InlineText) -> InlineText {
        joined(cut(text, NSRange(location: 0, length: range.location)),
               cut(text, NSRange(location: NSMaxRange(range), length: text.length - NSMaxRange(range))))
    }

    // MARK: Kinds and marks

    /// The format bar and Cmd-B, Cmd-I...: `mark` on the selected text, or off it when all of it has it already.
    /// Nil for an empty selection (the typing attributes change instead).
    public static func toggle(_ mark: InlineMark, in storage: NSAttributedString, selection: NSRange) -> BlockEdit? {
        guard selection.length > 0, NSMaxRange(selection) <= storage.length else { return nil }
        let ns = storage.string as NSString
        let paragraphs = ns.paragraphRange(for: selection)
        let edited = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraphs))
        let (key, value) = attribute(for: mark)
        // The selected text of each paragraph, without line breaks or components.
        var parts: [NSRange] = []
        var location = paragraphs.location
        while location < NSMaxRange(paragraphs) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            let content = BlockStorage.content(of: paragraph, in: storage)
            let part = NSIntersectionRange(content, selection)
            guard part.length > 0, let block = BlockStorage.block(in: storage, paragraph: paragraph),
                  !BlockStorage.isAtomic(block.kind), !block.kind.isCode else { continue }
            parts.append(NSRange(location: part.location - paragraphs.location, length: part.length))
        }
        guard !parts.isEmpty else { return nil }
        let allMarked = parts.allSatisfy { part in
            var marked = true
            edited.enumerateAttribute(key, in: part) { found, _, stop in
                if found == nil || (mark.isValued && !(found as AnyObject).isEqual(value)) { marked = false; stop.pointee = true }
            }
            return marked
        }
        for part in parts {
            if allMarked { edited.removeAttribute(key, range: part) } else { edited.addAttribute(key, value: value, range: part) }
        }
        return BlockEdit(range: paragraphs, replacement: edited, selection: selection)
    }

    private static func attribute(for mark: InlineMark) -> (NSAttributedString.Key, AnyObject) {
        switch mark {
        case .strong: (.noteStrong, true as NSNumber)
        case .emphasis: (.noteEmphasis, true as NSNumber)
        case .strikethrough: (.noteStrikethrough, true as NSNumber)
        case .code: (.noteCode, true as NSNumber)
        case .underline: (.noteUnderline, true as NSNumber)
        case .superscript: (.noteSuperscript, true as NSNumber)
        case .subscript: (.noteSubscript, true as NSNumber)
        case .keyboard: (.noteKeyboard, true as NSNumber)
        case .highlight(let color): (.noteHighlight, (color ?? "") as NSString)
        case .link(let destination, let title): (.noteLink, LinkAttribute(destination: destination, title: title))
        case .atom(let markdown): (.noteAtom, markdown as NSString)
        case .hardBreak: (.noteHardBreak, true as NSNumber)
        }
    }

    /// The blocks of `selection` turned into `kind` (the slash menu, the format bar): their text stays. A heading
    /// leaves a list.
    public static func setKind(_ kind: BlockKind, in storage: NSAttributedString, selection: NSRange) -> BlockEdit? {
        guard let first = place(at: selection.location, in: storage) else { return nil }
        var places = [first]
        while let last = places.last, NSMaxRange(last.paragraph) < NSMaxRange(selection), let next = nextPlace(last, in: storage),
              next.paragraph.length > 0 {
            places.append(next)
        }
        let blocks = places.map { place -> NoteBlock in
            var block = place.block
            block.kind = kind
            if case .heading = kind { block.depth = 0 }
            if !kind.isListItem, block.kind != .paragraph { block.depth = 0 }
            return block
        }
        if first.paragraph.length == 0 {
            // The empty paragraph at the end gets the kind.
            return BlockEdit(range: first.paragraph, replacement: paragraphs(blocks), selection: NSRange(location: first.paragraph.location, length: 0))
        }
        let range = NSUnionRange(first.paragraph, places.last!.paragraph)
        return BlockEdit(range: range, replacement: paragraphs(blocks), selection: selection)
    }
}
