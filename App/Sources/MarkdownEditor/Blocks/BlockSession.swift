import AppKit

/// The block editor at work in an `EditorController` (docs/design/BLOCK-EDITOR.md): the text view holds the page
/// (`BlockStorage`), never Markdown. The note is read into blocks when it is shown and written back from them on each
/// change; the frontmatter and the `# Title` the page title already says stay out of the page.
@MainActor
final class BlockSession {
    /// Whether notes open in the block editor: yes, unless `LOAM_BLOCK_EDITOR=0` in the environment or
    /// `defaults write <app> LoamBlockEditor -bool NO` turns it off (the editor that hid the syntax in the text,
    /// kept for a while as a way back).
    static var isOn: Bool {
        if let value = ProcessInfo.processInfo.environment["LOAM_BLOCK_EDITOR"] { return value != "0" }
        if UserDefaults.standard.object(forKey: "LoamBlockEditor") != nil { return UserDefaults.standard.bool(forKey: "LoamBlockEditor") }
        return true
    }

    weak var textView: EditorTextView?
    var theme = MarkdownTheme()
    /// The note as read: its frontmatter, what follows its blocks, and the blocks as read (their lines, kept for the
    /// ones not edited). Its own `blocks` are not kept up to date: the storage is the page.
    private var document = NoteDocument()
    /// The first heading saying the page's title, kept out of the page as the old editor hid it.
    private var titleBlock: NoteBlock?
    /// The page's title when the note was shown: a first heading saying it stays out of the page.
    private var title: String?
    /// The Markdown last read or written: a change from outside that says the same is nothing to show.
    private(set) var markdown = ""
    /// What the edits since the last change touched, to normalize and restyle only that.
    private var edited: NSRange?
    /// What was typed by the keyboard in the last change, for the Markdown shortcuts.
    private var typed: String?
    /// While the session makes an edit itself.
    private var applying = false
    /// After each styling: the controller shows the components styling leaves to it (embeds).
    var onStyled: (() -> Void)?
    /// The callouts and `<details>` folded or unfolded by a click.
    private var folds = PageFolds()

    init(textView: EditorTextView) {
        self.textView = textView
        textView.blockMode = true
        textView.onToggleBlockTask = { [weak self] paragraph in self?.toggleTask(paragraph) }
        textView.onToggleBlockFold = { [weak self] id in
            guard let self else { return }
            if folds.toggled.remove(id) == nil { folds.toggled.insert(id) }
            restyle()
        }
        textView.onCopyMarkdown = { [weak self] range in self?.markdown(of: range) }
        textView.onCopyLoamMarkdown = { [weak self] range in self?.markdown(of: range) ?? self?.inlineMarkdown(of: range) }
        textView.onPasteText = { [weak self] text in self?.paste(text) }
    }

    private var storage: NSTextStorage? { textView?.textStorage }

    // MARK: Showing

    /// Shows `text`. With `keepsSelection` (a change from outside: a field set under the title, an agent) the caret
    /// stays where it was in the text around it.
    func show(_ text: String, title: String?, keepsSelection: Bool, caret: Int?, force: Bool = false) {
        guard let textView, let storage else { return }
        if keepsSelection, text == markdown, !force { return }
        self.title = title
        var read = NoteDocument(markdown: text)
        titleBlock = nil
        if let first = read.blocks.first, first.kind == .heading(level: 1), let title, !title.isEmpty,
           first.text.string.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title) == .orderedSame {
            titleBlock = first
            read.blocks.removeFirst()
        }
        let blocks = read.blocks
        document = read
        markdown = text
        if keepsSelection, !force {
            // A change from outside (an agent, a plugin, a field under the title): only the blocks that differ are
            // replaced, so the caret, the scroll and the views of the others stay; every block is read again.
            replaceChangedBlocks(with: blocks)
            return
        }
        let selection = textView.selectedRange()
        let page = BlockStorage.attributedString(of: blocks)
        applying = true
        storage.setAttributedString(page)
        applying = false
        forgetReadBlocks(in: nil)
        theme.styleBlocks(storage, folds: folds)
        onStyled?()
        let length = storage.length
        let target = keepsSelection ? selection.location : (caret ?? 0)
        textView.setSelectedRange(NSRange(location: min(max(target, 0), length), length: 0))
        updateTypingAttributes()
        textView.needsDisplay = true
    }

    /// Reads the page again from its Markdown, the caret staying (the languages shown as components changed).
    func reload() {
        show(currentMarkdown(), title: title, keepsSelection: true, caret: nil, force: true)
    }

    /// Puts `blocks` in the page in place of what it shows, replacing only the paragraphs between the first and the
    /// last that differ, and giving the others their block as read (same text, its lines as they are now).
    private func replaceChangedBlocks(with blocks: [NoteBlock]) {
        guard let textView, let storage else { return }
        let old = BlockStorage.blocks(of: storage)
        func same(_ a: NoteBlock, _ b: NoteBlock) -> Bool {
            a.kind == b.kind && a.text == b.text && a.depth == b.depth && a.quote == b.quote && a.callout == b.callout
        }
        var prefix = 0
        while prefix < min(old.count, blocks.count), same(old[prefix], blocks[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, blocks.count) - prefix, same(old[old.count - 1 - suffix], blocks[blocks.count - 1 - suffix]) { suffix += 1 }
        let paragraphs = BlockStorage.paragraphs(of: storage).filter { $0.length > 0 }
        guard paragraphs.count == old.count else { return }
        let start = prefix < paragraphs.count ? paragraphs[prefix].location : storage.length
        let end = old.count - suffix > prefix ? NSMaxRange(paragraphs[old.count - suffix - 1]) : start
        let replacement = BlockStorage.attributedString(of: Array(blocks[prefix..<(blocks.count - suffix)]))
        let selection = textView.selectedRange()
        applying = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: start, length: end - start), with: replacement)
        let now = BlockStorage.paragraphs(of: storage).filter { $0.length > 0 }
        if now.count == blocks.count {
            for index in Array(0..<prefix) + Array((blocks.count - suffix)..<blocks.count) {
                storage.addAttribute(.noteBlock, value: BlockAttribute(blocks[index]), range: now[index])
            }
        }
        storage.endEditing()
        applying = false
        let delta = replacement.length - (end - start)
        let caret = selection.location < start ? selection.location
            : selection.location >= end ? selection.location + delta
            : start + min(selection.location - start, replacement.length)
        if replacement.length > 0 || end > start { restyle(NSRange(location: start, length: replacement.length)) } else { onStyled?() }
        textView.setSelectedRange(NSRange(location: min(max(caret, 0), storage.length), length: 0))
        updateTypingAttributes()
    }

    /// The note as Markdown, from the page now.
    func currentMarkdown() -> String {
        guard let storage else { return markdown }
        var written = document
        written.blocks = (titleBlock.map { [$0] } ?? []) + pageBlocks(of: storage)
        return written.markdown
    }

    /// The blocks read from each paragraph, by its block: a paragraph no edit touched since is not read again, so a
    /// keystroke in a long note reads one paragraph, not all of them.
    private var readBlocks: [ObjectIdentifier: (length: Int, block: NoteBlock)] = [:]

    /// Forgets what was read of the paragraphs in `range` (an edit went there), or of every paragraph.
    private func forgetReadBlocks(in range: NSRange?) {
        guard let range, let storage, storage.length > 0 else { return readBlocks = [:] }
        let ns = storage.string as NSString
        let paragraphs = ns.paragraphRange(for: NSIntersectionRange(range, NSRange(location: 0, length: ns.length)))
        storage.enumerateAttribute(.noteBlock, in: paragraphs) { value, _, _ in
            if let value = value as? BlockAttribute { readBlocks[ObjectIdentifier(value)] = nil }
        }
    }

    /// The page's blocks, the paragraphs no edit touched taken from what was read before.
    private func pageBlocks(of storage: NSTextStorage) -> [NoteBlock] {
        var result: [NoteBlock] = []
        var kept: [ObjectIdentifier: (length: Int, block: NoteBlock)] = [:]
        for paragraph in BlockStorage.paragraphs(of: storage) where paragraph.length > 0 {
            let attribute = storage.attribute(.noteBlock, at: paragraph.location, effectiveRange: nil) as? BlockAttribute
            if let attribute, let read = readBlocks[ObjectIdentifier(attribute)], read.length == paragraph.length {
                result.append(read.block)
                kept[ObjectIdentifier(attribute)] = read
                continue
            }
            let block = BlockStorage.block(in: storage, paragraph: paragraph)
                ?? NoteBlock(id: BlockIDs.next(), kind: .paragraph, text: BlockStorage.inlineText(of: storage, in: BlockStorage.content(of: paragraph, in: storage)))
            result.append(block)
            if let attribute { kept[ObjectIdentifier(attribute)] = (paragraph.length, block) }
        }
        readBlocks = kept
        return result
    }

    /// The Markdown of the blocks a selection covers, whole, for a copy; nil inside one block (plain text then).
    func markdown(of range: NSRange) -> String? {
        guard let storage else { return nil }
        let ns = storage.string as NSString
        let first = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
        guard NSMaxRange(range) > NSMaxRange(first) else { return nil }
        let blocks = BlockStorage.blocks(of: storage.attributedSubstring(from: ns.paragraphRange(for: range)))
        var copy = NoteDocument()
        copy.blocks = blocks.map { var block = $0; block.source = nil; block.before = ""; return block }
        return copy.markdown
    }

    /// The Markdown of a selection inside one block: its text and marks.
    func inlineMarkdown(of range: NSRange) -> String? {
        guard let storage, NSMaxRange(range) <= storage.length else { return nil }
        let text = BlockStorage.inlineText(of: storage, in: range)
        return InlineWriter.markdown(InlineWriter.prepared(text)).replacingOccurrences(of: String(InlineText.lineBreak), with: "\n")
    }

    // MARK: Styling

    func restyle(_ range: NSRange? = nil) {
        guard let textView, let storage, !textView.hasMarkedText() else { return }
        theme.styleBlocks(storage, in: range, folds: folds)
        onStyled?()
        textView.needsDisplay = true
    }

    /// The column's width changed: what is sized to it (tables, pictures, embeds, live blocks) follows. The
    /// paragraphs' own styles do not depend on it, so they are not styled again.
    func columnWidthChanged() {
        guard let textView, !textView.hasMarkedText() else { return }
        onStyled?()
        textView.needsDisplay = true
    }

    private var componentsPending = false

    /// A component's content arrived (a diagram's picture): the components are shown again, once for all that
    /// arrive in the same turn of the run loop. The paragraphs' styles do not depend on it: styling the whole page
    /// for each diagram cost a long frame per diagram while the page was first scrolled.
    func componentsChanged() {
        guard !componentsPending else { return }
        componentsPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.componentsPending = false
            self.columnWidthChanged()
        }
    }

    private func updateTypingAttributes() {
        guard let textView, let storage else { return }
        var fallback = theme.baseAttributes
        fallback[.noteBlock] = BlockAttribute(NoteBlock(id: BlockIDs.next(), kind: .paragraph))
        textView.typingAttributes = MarkdownTheme.blockTypingAttributes(at: textView.selectedRange().location, in: storage, fallback: fallback)
    }

    // MARK: Editing

    /// Before the text view changes `range`: notes what is touched, and keeps typing out of a component (a table, a
    /// divider), putting it in a paragraph of its own next to it. False when the session made the edit instead.
    func shouldChange(_ range: NSRange, replacement: String?) -> Bool {
        guard !applying, let storage, let textView else { return true }
        let length = (replacement as NSString?)?.length ?? 0
        let touched = NSRange(location: range.location, length: length)
        edited = edited.map { NSUnionRange($0, touched) } ?? touched
        typed = textView.isUserEdit && length > 0 && length <= 2 && replacement?.contains("\n") == false ? replacement : nil
        if let replacement, range.length == 0, !replacement.isEmpty, let place = BlockEditing.place(at: range.location, in: storage),
           BlockStorage.isAtomic(place.block.kind), place.paragraph.length > 0 {
            // Typed beside a component: a paragraph of its own after it (before it at its start).
            let before = range.location == place.paragraph.location
            let new = NoteBlock(id: BlockIDs.next(), kind: .paragraph, quote: place.block.quote, text: InlineText(replacement))
            let blocks = before ? [new, place.block] : [place.block, new]
            let caret = place.paragraph.location + (before ? length : 2 + length)
            apply(BlockEdit(range: place.paragraph, replacement: BlockStorage.attributedString(of: blocks),
                            selection: NSRange(location: caret, length: 0)))
            return false
        }
        return true
    }

    /// After the text changed: each paragraph has one block, the touched ones are styled again, a Markdown shortcut
    /// just typed turns into its block or mark. Returns the note's Markdown.
    func didChange() -> String {
        guard let textView, let storage else { return markdown }
        let range = edited ?? NSRange(location: 0, length: storage.length)
        edited = nil
        BlockStorage.normalize(storage, around: range)
        forgetReadBlocks(in: range)
        restyle(range)
        if let typed, !applying {
            self.typed = nil
            let caret = textView.selectedRange()
            if caret.length == 0, typed == " " || typed.last.map({ "*_`~-".contains($0) }) == true,
               let edit = BlockEditing.shortcut(in: storage, at: caret.location) {
                apply(edit)
                // Typing after a mark made by a shortcut is plain again.
                var attributes = textView.typingAttributes
                for key: NSAttributedString.Key in [.noteStrong, .noteEmphasis, .noteCode, .noteStrikethrough] { attributes[key] = nil }
                textView.typingAttributes = attributes
                return markdown
            }
        }
        typed = nil
        markdown = currentMarkdown()
        return markdown
    }

    /// The editor's keys: Return, Shift-Return, Backspace, Delete, Tab, Shift-Tab. True when handled.
    func command(_ selector: Selector) -> Bool {
        guard let textView, let storage else { return false }
        let selection = textView.selectedRange()
        let edit: BlockEdit?
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if selection.length > 0 {
                // Return over a selection: the selection goes, then the block splits there.
                textView.insertText("", replacementRange: selection)
                return command(selector)
            }
            edit = BlockEditing.fence(in: storage, selection: selection) ?? BlockEditing.newline(in: storage, selection: selection)
            if edit == nil, case .code = BlockEditing.place(at: selection.location, in: storage)?.block.kind {
                textView.insertText(String(InlineText.lineBreak), replacementRange: selection)
                return true
            }
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText(String(InlineText.lineBreak), replacementRange: selection)
            return true
        case #selector(NSResponder.deleteBackward(_:)) where textView.blockSelection != nil,
             #selector(NSResponder.deleteForward(_:)) where textView.blockSelection != nil:
            // A block selected by its handle goes whole, its paragraphs and their line breaks.
            let range = textView.blockSelection!.block.range
            edit = BlockEdit(range: range, replacement: NSAttributedString(),
                             selection: NSRange(location: min(range.location, storage.length - range.length), length: 0))
        case #selector(NSResponder.deleteBackward(_:)):
            edit = BlockEditing.deleteBackward(in: storage, selection: selection)
        case #selector(NSResponder.deleteForward(_:)):
            edit = BlockEditing.deleteForward(in: storage, selection: selection)
        case #selector(NSResponder.insertTab(_:)):
            edit = BlockEditing.indent(in: storage, selection: selection, outdent: false)
        case #selector(NSResponder.insertBacktab(_:)):
            edit = BlockEditing.indent(in: storage, selection: selection, outdent: true)
        default:
            edit = nil
        }
        guard let edit else { return false }
        apply(edit)
        return true
    }

    /// Makes `edit` through the text view: one undo step, saved as typing is.
    /// `scroll: false` keeps the page where it is, for an edit made away from the caret (a click on a task's box).
    func apply(_ edit: BlockEdit, scroll: Bool = true) {
        guard let textView, let storage else { return }
        if edit.range.length == 0, edit.replacement.length == 0 {
            textView.setSelectedRange(edit.selection)
            return
        }
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement.string) else { return }
        applying = true
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        applying = false
        edited = edited.map { NSUnionRange($0, NSRange(location: edit.range.location, length: edit.replacement.length)) }
            ?? NSRange(location: edit.range.location, length: edit.replacement.length)
        textView.didChangeText()
        textView.setSelectedRange(edit.selection)
        if scroll { textView.scrollRangeToVisible(edit.selection) }
        updateTypingAttributes()
    }

    // MARK: Menus and the format bar

    /// The blocks the `/` menu's built-in entries make, by entry.
    private static let slashKinds: [String: BlockKind] = [
        "heading1": .heading(level: 1), "heading2": .heading(level: 2), "heading3": .heading(level: 3),
        "body": .paragraph, "tasks": .task(checked: false), "bullets": .bullet, "numbers": .numbered(start: 1),
    ]

    /// Runs a `/`, `@` or `[[` menu entry chosen over `trigger` (the `/` and what was typed after it). A built-in entry
    /// turns the block at the caret into its kind or puts its block after it; any other (a plugin's, a note link, a
    /// date) writes Markdown, read into the page.
    func run(_ item: SlashMenuItem, replacing trigger: NSRange, isBlockEntry: Bool? = nil) {
        guard let textView, let storage else { return }
        let paragraphText = { (place: BlockEditing.Place) in (storage.string as NSString).substring(with: place.content) }
        guard let place = BlockEditing.place(at: trigger.location, in: storage) else { return }
        let localTrigger = NSRange(location: trigger.location - place.content.location, length: trigger.length)
        // A `/` menu or Insert panel entry (blocks), rather than a note link or a date written into the line.
        let isSlash = isBlockEntry
            ?? ((storage.string as NSString).substring(with: NSRange(location: trigger.location, length: min(1, trigger.length))) == "/")
        // What was typed (`@merm`), read before it goes: a note link or a date is written in its place.
        let triggerText = (paragraphText(place) as NSString).substring(with: localTrigger)
        // The trigger and its query go first.
        apply(BlockEdit(range: trigger, replacement: NSAttributedString(), selection: NSRange(location: trigger.location, length: 0)))
        guard let here = BlockEditing.place(at: trigger.location, in: storage) else { return }
        let caret = NSRange(location: trigger.location, length: 0)
        let isEmpty = here.content.length == 0

        if isSlash, let kind = Self.slashKinds[item.id] {
            if let edit = BlockEditing.setKind(kind, in: storage, selection: caret) { apply(edit) }
            textView.setSelectedRange(NSRange(location: min(trigger.location, storage.length), length: 0))
            return
        }
        if isSlash {
            var made: NoteBlock?
            switch item.id {
            case "quote":
                var block = here.block
                block.quote = max(1, block.quote)
                block.callout = nil
                if block.kind.isListItem || BlockStorage.isAtomic(block.kind) { block.kind = .paragraph }
                return apply(BlockEdit(range: here.paragraph, replacement: BlockStorage.paragraph(of: block), selection: caret))
            case "alert":
                var block = here.block
                block.quote = 1
                block.callout = Callout(kind: "NOTE", opens: true)
                block.kind = .paragraph
                block.depth = 0
                return apply(BlockEdit(range: here.paragraph, replacement: BlockStorage.paragraph(of: block), selection: caret))
            case "code":
                made = NoteBlock(id: BlockIDs.next(), kind: .code(language: ""), quote: here.block.quote)
            case "table":
                made = NoteBlock(id: BlockIDs.next(), kind: .table, quote: here.block.quote,
                                 text: InlineText("| Column | Column |\u{2028}| --- | --- |\u{2028}|  |  |"))
            case "divider":
                made = NoteBlock(id: BlockIDs.next(), kind: .divider, quote: here.block.quote)
            case "link":
                let link = BlockStorage.attributedString(of: InlineText("link", runs: [InlineRun(NSRange(location: 0, length: 4), .link(destination: "https://"))]))
                link.addAttribute(.noteBlock, value: storage.attribute(.noteBlock, at: min(here.paragraph.location, max(storage.length - 1, 0)), effectiveRange: nil) as Any,
                                  range: NSRange(location: 0, length: link.length))
                return apply(BlockEdit(range: caret, replacement: link, selection: NSRange(location: caret.location, length: 4)))
            default:
                break
            }
            if let made {
                // In place of an empty paragraph, else after the block; the caret into it, or after a component.
                let range = isEmpty ? here.paragraph : NSRange(location: NSMaxRange(here.paragraph), length: 0)
                var blocks = [made]
                if BlockStorage.isAtomic(made.kind) { blocks.append(BlockEditing.sibling(of: here.block, kind: .paragraph)) }
                let replacement = BlockStorage.attributedString(of: blocks)
                let into = range.location + (BlockStorage.isAtomic(made.kind) ? 2 : 0)
                return apply(BlockEdit(range: range, replacement: replacement, selection: NSRange(location: into, length: 0)))
            }
        }
        if isSlash {
            // A plugin's block (a diagram, a collection): its Markdown read into blocks, after the block at the caret.
            let edit = item.makeEdit("", NSRange(location: 0, length: 0))
            _ = insert(markdown: edit.replacement)
            return
        }
        // A link or a date: the entry edits the block's line as Markdown, the trigger in it as typed, and the line it
        // writes is read back into the block's text and marks.
        let text = place.block.text
        let before = BlockEditing.cut(text, NSRange(location: 0, length: localTrigger.location))
        let after = BlockEditing.cut(text, NSRange(location: NSMaxRange(localTrigger), length: text.length - NSMaxRange(localTrigger)))
        let head = InlineWriter.markdown(before)
        let line = head + triggerText + InlineWriter.markdown(after, atLineStart: false)
        let edit = item.makeEdit(line, NSRange(location: (head as NSString).length, length: (triggerText as NSString).length))
        let written = edit.applied(to: line)
        guard let read = NoteDocument(markdown: written).blocks.first else { return }
        var block = here.block
        block.text = read.text
        // The caret where the entry put it, counted in the page's text.
        let upToCaret = NoteDocument(markdown: (written as NSString).substring(to: min(edit.selection.location, (written as NSString).length)))
        let caretOffset = min(upToCaret.blocks.first.map { $0.text.length } ?? 0, block.text.length)
        // A space the reader dropped at the end of the line comes back, so typing goes on after the link.
        let trailing = written.hasSuffix(" ") && !block.text.string.hasSuffix(" ")
        if trailing { block.text = BlockEditing.joined(block.text, InlineText(" ")) }
        let target = here.content.location + min(caretOffset + (trailing && caretOffset == block.text.length - 1 ? 1 : 0), block.text.length)
        apply(BlockEdit(range: here.paragraph, replacement: BlockStorage.paragraph(of: block), selection: NSRange(location: target, length: 0)))
    }

    /// The format bar's styles active over the selection.
    func activeFormats(in selection: NSRange) -> Set<InlineFormat> {
        guard let storage, selection.length > 0, NSMaxRange(selection) <= storage.length else { return [] }
        let keys: [(InlineFormat, NSAttributedString.Key)] = [
            (.bold, .noteStrong), (.italic, .noteEmphasis), (.strikethrough, .noteStrikethrough), (.code, .noteCode), (.highlight, .noteHighlight),
        ]
        return Set(keys.filter { _, key in
            var all = true
            storage.enumerateAttribute(key, in: selection) { value, range, stop in
                let text = (storage.string as NSString).substring(with: range)
                if value == nil, text.contains(where: { !$0.isNewline }) { all = false; stop.pointee = true }
            }
            return all
        }.map(\.0))
    }

    /// A format bar button, Cmd-B or Cmd-I over the selection. False when nothing changed.
    func perform(_ action: FormatAction) -> Bool {
        guard let textView, let storage else { return false }
        let selection = textView.selectedRange()
        let mark: InlineMark
        switch action {
        case .toggle(let format):
            switch format {
            case .bold: mark = .strong
            case .italic: mark = .emphasis
            case .strikethrough: mark = .strikethrough
            case .code: mark = .code
            case .highlight: mark = .highlight(color: nil)
            }
        case .highlight(let color):
            guard let color else {
                // No colour: the highlight goes.
                guard let edit = BlockEditing.toggle(.highlight(color: nil), in: storage, selection: selection) else { return false }
                let cleared = NSMutableAttributedString(attributedString: edit.replacement)
                cleared.removeAttribute(.noteHighlight, range: NSRange(location: selection.location - edit.range.location, length: selection.length))
                apply(BlockEdit(range: edit.range, replacement: cleared, selection: selection))
                return true
            }
            mark = .highlight(color: color == .yellow ? nil : color.hex)
        case .link:
            return false
        }
        guard let edit = BlockEditing.toggle(mark, in: storage, selection: selection) else { return false }
        apply(edit)
        textView.setSelectedRange(selection)
        // A highlight just put on is drawn by the marker, left to right.
        if case .highlight = mark, selection.length > 0, selection.location < storage.length,
           storage.attribute(.noteHighlight, at: selection.location, effectiveRange: nil) != nil {
            textView.revealHighlight(in: selection)
        }
        return true
    }

    // MARK: Links

    /// The link the selection is in or on: its text's range and its destination.
    func existingLink(near selection: NSRange) -> (range: NSRange, destination: String)? {
        guard let storage, storage.length > 0 else { return nil }
        let index = min(selection.length > 0 ? selection.location : max(selection.location - 1, 0), storage.length - 1)
        var range = NSRange()
        guard let link = storage.attribute(.noteLink, at: index, longestEffectiveRange: &range,
                                           in: NSRange(location: 0, length: storage.length)) as? LinkAttribute else { return nil }
        if selection.length == 0, selection.location > NSMaxRange(range) { return nil }
        return (range, link.destination)
    }

    /// `range` becomes a link to `destination`, or stops being a link (nil): one edit.
    func setLink(_ destination: String?, over range: NSRange) {
        guard let storage, range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let paragraphs = (storage.string as NSString).paragraphRange(for: range)
        let edited = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: paragraphs))
        let local = NSRange(location: range.location - paragraphs.location, length: range.length)
        if let destination {
            edited.addAttribute(.noteLink, value: LinkAttribute(destination: destination), range: local)
        } else {
            edited.removeAttribute(.noteLink, range: local)
        }
        apply(BlockEdit(range: paragraphs, replacement: edited, selection: range))
    }

    /// Puts Markdown in at the caret, as typing would (one undo step): text alone joins the block at the caret, blocks
    /// go after it, the caret after them.
    func insert(markdown text: String) -> Bool {
        guard let textView, let storage else { return false }
        let selection = textView.selectedRange()
        var blocks = NoteDocument(markdown: text).blocks.map { block -> NoteBlock in
            var block = block
            block.id = BlockIDs.next()
            block.source = nil
            block.before = ""
            return block
        }
        guard !blocks.isEmpty else { return true }
        // The spaces around what is pasted, which Markdown drops at a paragraph's ends, separate it from the words
        // around the caret.
        let leading = String(text.prefix { $0 == " " || $0 == "\t" })
        let trailing = String(text.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        if !leading.isEmpty, !blocks[0].kind.isCode { blocks[0].text = BlockEditing.joined(InlineText(leading), blocks[0].text) }
        if !trailing.isEmpty, !text.trimmingCharacters(in: .whitespaces).isEmpty, let last = blocks.indices.last, !blocks[last].kind.isCode,
           !BlockStorage.isAtomic(blocks[last].kind) {
            blocks[last].text = BlockEditing.joined(blocks[last].text, InlineText(trailing))
        }
        if selection.length > 0 {
            // What was selected goes first, as typing over it would.
            textView.insertText("", replacementRange: selection)
        }
        let caret = textView.selectedRange().location
        if blocks.count == 1, blocks[0].kind == .paragraph {
            // Words inside the block at the caret, with their marks.
            let inline = BlockStorage.attributedString(of: blocks[0].text)
            let block = storage.length > 0 ? storage.attribute(.noteBlock, at: min(caret, storage.length - 1), effectiveRange: nil) : nil
            if let block { inline.addAttribute(.noteBlock, value: block, range: NSRange(location: 0, length: inline.length)) }
            apply(BlockEdit(range: NSRange(location: caret, length: 0), replacement: inline,
                            selection: NSRange(location: caret + inline.length, length: 0)))
            return true
        }
        guard let place = BlockEditing.place(at: caret, in: storage) else { return false }
        let block = place.block
        if BlockStorage.isAtomic(block.kind) || block.kind.isCode {
            // Beside a component or a code block: the blocks go after it.
            let end = NSMaxRange(place.paragraph)
            let page = BlockStorage.attributedString(of: blocks)
            apply(BlockEdit(range: NSRange(location: end, length: 0), replacement: page,
                            selection: NSRange(location: end + page.length - 1, length: 0)))
            return true
        }
        // The block at the caret is cut there: the first block pasted joins the text before the caret, the last one
        // the text after it, when they are text; what is between stands as blocks of their own.
        let offset = caret - place.content.location
        let before = BlockEditing.cut(block.text, NSRange(location: 0, length: offset))
        let after = BlockEditing.cut(block.text, NSRange(location: offset, length: block.text.length - offset))
        var result = blocks
        var head = block
        if result[0].kind == .paragraph, result[0].quote == 0 {
            head.text = BlockEditing.joined(before, result[0].text)
            result.removeFirst()
            result.insert(head, at: 0)
        } else if before.length > 0 || block.kind != .paragraph {
            head.text = before
            result.insert(head, at: 0)
        }
        // Where the pasted text ends: the block and the offset in it the caret goes to.
        var caretBlock = result.count - 1
        var caretOffset = BlockStorage.isAtomic(result[caretBlock].kind) ? 1 : result[caretBlock].text.length
        if after.length > 0 {
            if result.count > 1, let last = result.last, last.kind == .paragraph, last.quote == 0 {
                result[result.count - 1].text = BlockEditing.joined(last.text, after)
            } else {
                result.append(BlockEditing.sibling(of: block, text: after))
            }
        }
        let page = BlockStorage.attributedString(of: result)
        var location = place.paragraph.location
        for index in 0..<caretBlock { location += BlockStorage.paragraph(of: result[index]).length }
        caretOffset = min(caretOffset, max(0, BlockStorage.paragraph(of: result[caretBlock]).length - 1))
        apply(BlockEdit(range: place.paragraph, replacement: page, selection: NSRange(location: location + caretOffset, length: 0)))
        return true
    }

    /// A paste in the block editor: Markdown (from Loam or anywhere) read into blocks, plain text in code, and an
    /// address pasted over selected text making it a link.
    func paste(_ string: String) {
        guard let textView, let storage else { return }
        let selection = textView.selectedRange()
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if selection.length > 0, !trimmed.contains(where: \.isWhitespace),
           trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return setLink(trimmed, over: selection)
        }
        if let place = BlockEditing.place(at: selection.location, in: storage), place.block.kind.isCode, !BlockStorage.isAtomic(place.block.kind) {
            let text = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: String(InlineText.lineBreak))
            textView.insertText(text, replacementRange: selection)
            return
        }
        _ = insert(markdown: string)
    }

    /// The lines (1-based, first and last) of each block of the note's Markdown, read again only when the Markdown
    /// changed: the outline asks after every resize and layout change, and reading a long note each time was most
    /// of the work at the end of a resize.
    private func blockLines() -> [(first: Int, last: Int)] {
        if let cached = blockLinesCache, cached.markdown == markdown { return cached.lines }
        let read = NoteDocument(markdown: markdown)
        func count(_ text: String) -> Int { text.utf8.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) } }
        var starts: [(first: Int, last: Int)] = []
        var line = 1 + count(read.frontmatter)
        for block in read.blocks {
            line += count(block.before)
            let length = max(1, count(block.source?.lines ?? "\n"))
            starts.append((line, line + length - 1))
            line += length
        }
        blockLinesCache = (markdown, starts)
        return starts
    }

    private var blockLinesCache: (markdown: String, lines: [(first: Int, last: Int)])?

    /// Where lines of the note's Markdown (1-based, the frontmatter counted) start in the page: the start of the block
    /// holding each line, or of the block after it; nil past the last block.
    func offsets(ofLines lines: [Int]) -> [Int?] {
        guard let storage else { return lines.map { _ in nil } }
        var starts = blockLines()
        if titleBlock != nil, !starts.isEmpty { starts.removeFirst() }
        // The page's paragraphs that are written as blocks (an empty paragraph is not).
        let paragraphs = BlockStorage.paragraphs(of: storage).filter { paragraph in
            guard paragraph.length > 0 else { return false }
            let block = BlockStorage.block(in: storage, paragraph: paragraph)
            return !(block?.kind == .paragraph && BlockStorage.content(of: paragraph, in: storage).length == 0)
        }
        return lines.map { wanted in
            guard let index = starts.firstIndex(where: { wanted <= $0.last }), index < paragraphs.count else { return nil }
            return paragraphs[index].location
        }
    }

    /// Replaces `range` of the page without the text view's undo (a component registers its own), as a change that
    /// is saved and styled.
    func replaceWithoutUndo(_ range: NSRange, with replacement: NSAttributedString) {
        guard let textView, let storage, NSMaxRange(range) <= storage.length else { return }
        applying = true
        storage.replaceCharacters(in: range, with: replacement)
        applying = false
        let touched = NSRange(location: range.location, length: replacement.length)
        edited = edited.map { NSUnionRange($0, touched) } ?? touched
        textView.didChangeText()
    }

    /// A click on a task's box checks or unchecks it.
    private func toggleTask(_ paragraph: NSRange) {
        guard let storage, let block = BlockStorage.block(in: storage, paragraph: paragraph), case .task(let checked) = block.kind else { return }
        var toggled = block
        toggled.kind = .task(checked: !checked)
        let selection = textView?.selectedRange() ?? NSRange(location: paragraph.location, length: 0)
        apply(BlockEdit(range: paragraph, replacement: BlockStorage.paragraph(of: toggled), selection: selection), scroll: false)
    }

    func selectionDidChange() {
        guard !applying else { return }
        updateTypingAttributes()
    }

    /// After an undo or a redo, which the text view makes without saying what it touched.
    func undoDidChange() {
        guard let storage else { return }
        forgetReadBlocks(in: nil)
        BlockStorage.normalize(storage, around: NSRange(location: 0, length: storage.length))
        restyle()
    }
}
