import AppKit
import PluginKitUI

extension NSAttributedString.Key {
    /// On an atom's character: what the text view draws for it, a small chip with this label.
    static let blockAtomLabel = NSAttributedString.Key("Loam.blockAtomLabel")
    /// On a table's or an embed's character, until they show their component: the label of the card drawn instead.
    static let blockPlaceholder = NSAttributedString.Key("Loam.blockPlaceholder")
    /// On an atom's character: the text drawn in its place, as it is (a note link, a footnote, math), no chip.
    static let blockAtomText = NSAttributedString.Key("Loam.blockAtomText")
    /// On a quote's paragraph: how many quotes hold it, one bar each.
    static let blockQuoteDepth = NSAttributedString.Key("Loam.blockQuoteDepth")
    /// On the paragraph that folds what follows it (a callout written `[!NOTE]-`, an HTML `<details>`): a `BlockFold`.
    static let blockFold = NSAttributedString.Key("Loam.blockFold")
}

/// A callout or a `<details>` that folds: its title, whether it is folded, and its block, which a click toggles.
final class BlockFold: NSObject {
    let title: String
    let folded: Bool
    let id: NoteBlock.ID
    /// A `<details>`: its summary is drawn on its own line; a callout's title is its label.
    let isDetails: Bool

    init(title: String, folded: Bool, id: NoteBlock.ID, isDetails: Bool) {
        self.title = title
        self.folded = folded
        self.id = id
        self.isDetails = isDetails
    }
}

/// What folds on the page: callouts whose title starts with `-` (folded) or `+` (open), as Obsidian writes them, and
/// HTML `<details>` (folded unless written `open`). A click on the title toggles one (`toggled`); the Markdown never
/// changes.
struct PageFolds {
    /// The blocks whose fold was toggled from how the note writes it.
    var toggled: Set<NoteBlock.ID> = []

    /// A callout's title without its fold sign, and whether the sign folds it by default. Nil when it does not fold.
    static func calloutFold(_ callout: Callout) -> (title: String, folded: Bool)? {
        let title = callout.title.drop { $0 == " " }
        guard let sign = title.first, sign == "-" || sign == "+" else { return nil }
        return (title.dropFirst().trimmingCharacters(in: .whitespaces), sign == "-")
    }

    /// A raw block opening `<details>`: its summary, and whether it starts folded.
    static func detailsFold(_ block: NoteBlock) -> (title: String, folded: Bool)? {
        guard block.kind == .raw else { return nil }
        let text = block.text.string.replacingOccurrences(of: String(InlineText.lineBreak), with: "\n")
        guard let open = text.firstMatch(of: /^\s*<details(\s[^>]*)?>/) else { return nil }
        let summary = text.firstMatch(of: /<summary[^>]*>(.*?)<\/summary>/).map { String($0.1) } ?? "Details".uiLocalized
        let isOpen = open.1.map { $0.contains("open") } ?? false
        return (summary.trimmingCharacters(in: .whitespaces), !isOpen)
    }

    static func isDetailsEnd(_ block: NoteBlock) -> Bool {
        block.kind == .raw && block.text.string.trimmingCharacters(in: .whitespaces) == "</details>"
    }
}

/// How the block editor's storage looks: fonts, colours and paragraph styles from each paragraph's block and its
/// marks. Only display attributes change; the blocks and the marks (`BlockStorage`) stay as they are.
extension MarkdownTheme {
    /// The attributes styling sets, removed before each paragraph is styled again.
    static let blockDisplayKeys: [NSAttributedString.Key] = [
        .font, .foregroundColor, .backgroundColor, .paragraphStyle, .kern, .strikethroughStyle, .underlineStyle,
        .underlineColor, .markdownLink, .markdownCode, .markdownInlineCode, .markdownCodeBlock, .markdownQuote,
        .markdownTitle, .markdownRule, .markdownTag, .markdownDate, .cursor, .blockAtomLabel, .blockPlaceholder,
        .blockAtomText, .blockQuoteDepth, .baselineOffset, .strokeWidth, .strokeColor, .markdownHighlight, .blockFold,
    ]

    /// Styles the paragraphs of `storage` touching `range` (all of them when nil). `hasDetails`, when known, says
    /// whether the page holds a `</details>`, so a keystroke does not search the whole page for one.
    func styleBlocks(
        _ storage: NSTextStorage, in range: NSRange? = nil, today: String = DatePill.localToday(), folds: PageFolds = PageFolds(),
        hasDetails: Bool? = nil
    ) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let hidden = hasDetails == false ? [] : foldedDetails(in: storage, folds: folds)
        let whole = NSRange(location: 0, length: ns.length)
        var limit = range.map { NSIntersectionRange(ns.paragraphRange(for: NSIntersectionRange($0, whole)), whole) } ?? whole
        // A callout's or a list's look depends on its neighbours: one paragraph more on each side.
        if limit.location > 0 { limit = NSUnionRange(limit, ns.paragraphRange(for: NSRange(location: limit.location - 1, length: 0))) }
        if NSMaxRange(limit) < ns.length { limit = NSUnionRange(limit, ns.paragraphRange(for: NSRange(location: NSMaxRange(limit), length: 0))) }
        storage.beginEditing()
        defer { storage.endEditing() }
        let asked = range.map { NSIntersectionRange(ns.paragraphRange(for: NSIntersectionRange($0, whole)), whole) }
        var location = limit.location
        while location < NSMaxRange(limit) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            // A component next to the edit (a table, a collection) is left as it is: styling it again would lay it out
            // again, and the page under the caret would jump while its room is rebuilt.
            if let asked, NSIntersectionRange(asked, paragraph).length == 0,
               let block = noteBlock(at: paragraph.location, in: storage), BlockStorage.isAtomic(block.kind) { continue }
            styleParagraph(paragraph, in: storage, today: today, folds: folds, hidden: hidden)
        }
    }

    /// Where the paragraphs folded away inside a `<details>` start (its end always among them). Only a note holding
    /// a `</details>` is read through: the others pay one search.
    private func foldedDetails(in storage: NSTextStorage, folds: PageFolds) -> Set<Int> {
        let ns = storage.string as NSString
        guard ns.range(of: "</details>").location != NSNotFound else { return [] }
        var hidden = Set<Int>()
        var folded: [Bool] = []
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            guard let block = noteBlock(at: paragraph.location, in: storage) else { continue }
            if PageFolds.isDetailsEnd(block) {
                hidden.insert(paragraph.location)
                if !folded.isEmpty { folded.removeLast() }
                continue
            }
            if folded.contains(true) { hidden.insert(paragraph.location) }
            if let details = PageFolds.detailsFold(block) { folded.append(details.folded != folds.toggled.contains(block.id)) }
        }
        return hidden
    }

    /// Whether the paragraph at `location`, of a callout, is in a folded one: its first block says.
    private func isInFoldedCallout(_ location: Int, in storage: NSTextStorage, folds: PageFolds) -> Bool {
        let ns = storage.string as NSString
        var start = location
        while let block = noteBlock(at: start, in: storage), let callout = block.callout {
            if callout.opens {
                return PageFolds.calloutFold(callout).map { $0.folded != folds.toggled.contains(block.id) } ?? false
            }
            guard start > 0 else { break }
            start = ns.paragraphRange(for: NSRange(location: start - 1, length: 0)).location
        }
        return false
    }

    private func noteBlock(at index: Int, in storage: NSTextStorage) -> NoteBlock? {
        guard index >= 0, index < storage.length else { return nil }
        return (storage.attribute(.noteBlock, at: index, effectiveRange: nil) as? BlockAttribute)?.block
    }

    private func styleParagraph(_ paragraph: NSRange, in storage: NSTextStorage, today: String, folds: PageFolds, hidden: Set<Int>) {
        let ns = storage.string as NSString
        let content = BlockStorage.content(of: paragraph, in: storage)
        let block = noteBlock(at: paragraph.location, in: storage) ?? NoteBlock(id: 0, kind: .paragraph)
        for key in Self.blockDisplayKeys { storage.removeAttribute(key, range: paragraph) }
        storage.addAttributes(baseAttributes, range: paragraph)

        let style = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
        let quoteRoom = CGFloat(block.quote) * quoteIndent
        // A line of only note links has nothing but their near-empty characters: it still stands as high as a text line.
        let bodyLineHeight = round((bodyFont.ascender - bodyFont.descender + bodyFont.leading) * max(lineHeightMultiple, 1))
        var indent = quoteRoom + CGFloat(block.depth) * listIndent
        switch block.kind {
        case .heading(let level):
            let size = fontSize * headingScale(level)
            let weight = headingWeight ?? (level <= 2 ? .bold : .semibold)
            let headingFont = font(headingFamily ?? bodyFamily, size: size, weight: weight)
            storage.addAttribute(.font, value: headingFont, range: paragraph)
            if let headingColor { storage.addAttribute(.foregroundColor, value: headingColor, range: paragraph) }
            storage.addAttributes(fakeBold(headingFont, weight: weight, color: headingColor ?? textColor), range: paragraph)
            if headingLetterSpacing != 0 { storage.addAttribute(.kern, value: headingLetterSpacing, range: paragraph) }
            style.lineHeightMultiple = level == 4 ? 1.3 : 1.1
            style.paragraphSpacingBefore = headingSpaceAbove(level)
            if headingRules.contains(level) {
                style.paragraphSpacing = fontSize * (level == 1 ? 1.2 : 0.6)
                storage.addAttribute(.markdownTitle, value: level, range: content.length > 0 ? content : paragraph)
            }
        case .bullet, .numbered, .task:
            indent += listIndent
            style.minimumLineHeight = bodyLineHeight
            style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, round(fontSize * 0.06))
            // The items of a list stand close, as Craft's: a theme's room between paragraphs (Dither Green's is most
            // of a line) spread them apart. A paragraph after the list keeps its own room above.
            style.paragraphSpacing = min(style.paragraphSpacing, round(fontSize * 0.25))
            if case .task(true) = block.kind {
                storage.addAttribute(.foregroundColor, value: secondaryTextColor, range: content)
                if strikesDoneTasks { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content) }
            }
        case .code(let language) where BlockStorage.isAtomic(block.kind):
            // A diagram or a collection: its card until its picture or view shows.
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: paragraph)
            if content.length > 0 { storage.addAttribute(.blockPlaceholder, value: language.capitalized, range: content) }
            style.minimumLineHeight = round(fontSize * 3)
            style.paragraphSpacingBefore = round(fontSize * 0.5)
            style.paragraphSpacing = round(fontSize * 0.5)
        case .code(let language):
            let lines = (ns.substring(with: content) as NSString).components(separatedBy: String(InlineText.lineBreak)).count
            storage.addAttribute(.font, value: monoFont(size: fontSize * 0.87), range: paragraph)
            // The card and its line numbers cover the code, not the line break after it.
            storage.addAttributes([.markdownCode: true, .markdownCodeBlock: language], range: content.length > 0 ? content : paragraph)
            style.lineHeightMultiple = 1.3
            indent = codeGutter(lines: lines) + Self.codePadding
            style.tailIndent = -Self.codePadding
            style.paragraphSpacingBefore = Self.codePadding
            style.paragraphSpacing = Self.codePadding
        case .divider:
            storage.addAttributes([.foregroundColor: NSColor.clear, .markdownRule: true], range: paragraph)
            style.paragraphSpacingBefore = round(fontSize * 0.4)
            style.paragraphSpacing = round(fontSize * 0.4)
        case .table, .embed:
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: paragraph)
            let label = block.kind == .table ? "Table".uiLocalized : (Self.embedName(block.text.string) ?? "Picture".uiLocalized)
            if content.length > 0 { storage.addAttribute(.blockPlaceholder, value: label, range: content) }
            style.minimumLineHeight = round(fontSize * 3)
            style.paragraphSpacingBefore = round(fontSize * 0.5)
            style.paragraphSpacing = round(fontSize * 0.5)
        case .raw:
            storage.addAttribute(.foregroundColor, value: secondaryTextColor, range: paragraph)
        case .paragraph:
            style.minimumLineHeight = bodyLineHeight
            // Craft's room between two text blocks, about a third of a line (its 26 pixel lines stand 32 apart).
            if block.quote == 0 { style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, round(fontSize * 0.35)) }
            if Self.isDisplayMath(block) {
                style.alignment = .center
                style.paragraphSpacing = round(fontSize * 0.7)
                // Its one character is drawn, not set: the line keeps a line's height.
                style.minimumLineHeight = round(fontSize * 1.1 * 1.6)
            }
        }
        if block.quote > 0, !block.kind.isCode {
            let kind = block.callout.map { Self.alertKind("[!\($0.kind)]") } ?? ""
            storage.addAttribute(.markdownQuote, value: kind, range: paragraph)
            storage.addAttribute(.blockQuoteDepth, value: block.quote, range: paragraph)
            style.minimumLineHeight = max(style.minimumLineHeight, round((bodyFont.ascender - bodyFont.descender + bodyFont.leading) * max(lineHeightMultiple, 1)))
            if block.callout != nil {
                style.tailIndent = -quoteIndent
                if block.callout?.opens == true { style.paragraphSpacingBefore = Self.codePadding + calloutLabelHeight }
                let next = noteBlock(at: NSMaxRange(paragraph), in: storage)
                if next?.callout == nil || next?.callout?.opens == true { style.paragraphSpacing = Self.codePadding }
            }
        }
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        if let callout = block.callout, callout.opens, let fold = PageFolds.calloutFold(callout) {
            storage.addAttribute(.blockFold, value: BlockFold(title: fold.title, folded: fold.folded != folds.toggled.contains(block.id),
                                                               id: block.id, isDetails: false), range: paragraph)
        }
        if let details = PageFolds.detailsFold(block) {
            // The summary, drawn on one line with its chevron; the HTML stays in the text, unseen.
            storage.addAttributes([.foregroundColor: NSColor.clear, .font: NSFont.systemFont(ofSize: 0.1)], range: paragraph)
            // Its lines (`<details>`, `<summary>`...) share one line's height.
            let lines = CGFloat(max(1, block.text.string.components(separatedBy: String(InlineText.lineBreak)).count))
            style.minimumLineHeight = round(bodyFont.ascender - bodyFont.descender + bodyFont.leading) * max(lineHeightMultiple, 1) / lines
            style.maximumLineHeight = style.minimumLineHeight
            storage.addAttribute(.blockFold, value: BlockFold(title: details.title, folded: details.folded != folds.toggled.contains(block.id),
                                                               id: block.id, isDetails: true), range: paragraph)
        }
        if hidden.contains(paragraph.location) || (block.callout != nil && isInFoldedCallout(paragraph.location, in: storage, folds: folds)) {
            // Folded away: no room, no text, but the first line of a callout keeps the room of its label above it.
            storage.addAttributes([.foregroundColor: NSColor.clear, .font: NSFont.systemFont(ofSize: 0.1)], range: paragraph)
            style.minimumLineHeight = 0.1
            style.maximumLineHeight = 0.1
            if block.callout?.opens != true { style.paragraphSpacingBefore = 0 }
            style.paragraphSpacing = block.callout?.opens == true ? Self.codePadding : 0
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            return
        }
        storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
        styleMarks(in: content, of: storage, block: block, today: today)
    }

    /// Whether `block` is a `$$` formula alone: its one atom drawn centered.
    static func isDisplayMath(_ block: NoteBlock) -> Bool {
        guard block.text.length == 1, case .atom(let markdown)? = block.text.runs.first?.mark else { return false }
        return markdown.hasPrefix("$$")
    }

    /// The room on each side of a date pill in the block editor, where the caret stands before or after it.
    static let pillGap: CGFloat = 3

    /// The room above a callout's first line for its label (`NOTE`).
    var calloutLabelHeight: CGFloat { round(fontSize * 0.8 * 1.5) }

    /// The file name of an embed's `![alt](destination)`, for its card until it shows the file.
    private static func embedName(_ markdown: String) -> String? {
        guard let open = markdown.lastIndex(of: "("), let close = markdown.lastIndex(of: ")"), open < close else { return nil }
        let destination = markdown[markdown.index(after: open)..<close]
        return destination.split(separator: "/").last.map(String.init)?.removingPercentEncoding
    }

    /// The inline marks of a paragraph's text: font traits, colours, pills and chips.
    private func styleMarks(in content: NSRange, of storage: NSTextStorage, block: NoteBlock, today: String) {
        guard content.length > 0 else { return }
        let ns = storage.string as NSString
        var code: [NSRange] = []
        storage.enumerateAttributes(in: content) { attributes, range, _ in
            if attributes[.noteStrong] != nil { embolden(range, of: storage) }
            if attributes[.noteEmphasis] != nil { italicize(range, of: storage) }
            if attributes[.noteStrikethrough] != nil {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if attributes[.noteCode] != nil, !block.kind.isCode {
                mapBlockFonts(in: range, of: storage) { monoFont(size: $0.pointSize * 0.88) }
                storage.addAttributes([.markdownCode: true, .markdownInlineCode: true], range: range)
                code.append(range)
            }
            if attributes[.noteUnderline] != nil {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            for (key, rise) in [(NSAttributedString.Key.noteSuperscript, 0.4), (.noteSubscript, -0.2)] where attributes[key] != nil {
                let size = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?.pointSize ?? fontSize
                mapBlockFonts(in: range, of: storage) { NSFontManager.shared.convert($0, toSize: $0.pointSize * 0.72) }
                storage.addAttribute(.baselineOffset, value: round(size * rise), range: range)
            }
            if attributes[.noteKeyboard] != nil, attributes[.noteCode] == nil {
                // A key: a small keycap, as GitHub draws `<kbd>`, in the code pill's look.
                mapBlockFonts(in: range, of: storage) { bodyFont(size: $0.pointSize * 0.85, weight: .medium) }
                storage.addAttributes([.markdownCode: true, .markdownInlineCode: true], range: range)
                code.append(range)
            }
            if let color = attributes[.noteHighlight] as? String {
                let fill = color.isEmpty ? (highlightColor ?? Self.highlightColor(nil)) : Self.highlightColor(color)
                // Drawn by the text view as a marker's stroke (`HighlighterStroke`), not a flat box.
                storage.addAttribute(.markdownHighlight, value: fill, range: range)
                if color.isEmpty, let text = highlightTextColor { storage.addAttribute(.foregroundColor, value: text, range: range) }
            }
            if let link = attributes[.noteLink] as? LinkAttribute {
                storage.addAttributes([
                    .foregroundColor: linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: linkColor.withAlphaComponent(0.4),
                    .markdownLink: link.destination,
                    // A click opens it (`EditorTextView.mouseDown`).
                    .cursor: NSCursor.pointingHand,
                ], range: range)
            }
            if let markdown = attributes[.noteAtom] as? String { styleAtom(markdown, at: range, in: storage, block: block, today: today) }
        }
        // Room inside each code pill, which the text view draws around the text.
        for range in code {
            storage.addAttribute(.kern, value: Self.pillPadding, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
            if range.location > content.location {
                storage.addAttribute(.kern, value: Self.pillPadding, range: NSRange(location: range.location - 1, length: 1))
            }
        }
        // Tags, `#tag`, as pills: their text is the page's, nothing hidden.
        guard !block.kind.isCode, block.kind != .raw else { return }
        for match in MarkdownStyler.hashtag.matches(in: ns as String, range: content) {
            guard !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            storage.addAttributes([.foregroundColor: tagColor, .markdownTag: false], range: match.range)
            if monoTags { storage.addAttribute(.font, value: monoFont(size: round(fontSize * 0.85)), range: match.range) }
        }
    }

    /// An atom: a date as Craft's pill, anything else as a small chip naming it.
    private func styleAtom(_ markdown: String, at range: NSRange, in storage: NSTextStorage, block: NoteBlock, today: String) {
        let around = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? bodyFont
        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        storage.removeAttribute(.strikethroughStyle, range: range)
        if let match = MarkdownStyler.datePattern.firstMatch(in: markdown, range: NSRange(location: 0, length: (markdown as NSString).length)) {
            let ns = markdown as NSString
            let mark = ns.substring(with: match.range(at: 1))
            let day = ns.substring(with: match.range(at: 2))
            let font = bodyFont(size: around.pointSize * 0.94, weight: .regular)
            let pill = DatePill(day: day, today: today, completion: mark == "✅", openTask: block.kind == .task(checked: false))
            storage.addAttributes([.markdownDate: DatePillMark(pill: pill, font: font), .cursor: NSCursor.pointingHand], range: range)
            // The pill's room is the character's own width (an attachment): a kern is split between the character
            // and the one after it, which put the caret after the pill in the middle of it.
            let attachment = NSTextAttachment()
            let height = ceil(font.ascender - font.descender)
            let width = pill.width(font: font) + 2 * Self.pillGap
            // Empty: the text view draws the pill itself. TextKit gives an attachment without an image no room.
            attachment.image = NSImage(size: NSSize(width: width, height: height))
            attachment.bounds = CGRect(x: 0, y: font.descender, width: width, height: height)
            storage.addAttributes([.attachment: attachment], range: range)
            return
        }
        if let text = atomText(markdown, around: around) {
            let width = text.string.isEmpty ? 0 : ceil(text.size().width) + 2 * Self.pillGap
            // The character itself takes no room, only what is drawn: its kern.
            var attributes: [NSAttributedString.Key: Any] = [.blockAtomText: text, .kern: width, .font: NSFont.systemFont(ofSize: 0.1)]
            if let target = Self.noteLinkTarget(markdown) {
                attributes[.markdownLink] = Self.noteLinkScheme + target
                attributes[.cursor] = NSCursor.pointingHand
            }
            storage.addAttributes(attributes, range: range)
            return
        }
        let label = Self.atomLabel(markdown)
        let font = bodyFont(size: around.pointSize * 0.8, weight: .regular)
        let width = (label as NSString).size(withAttributes: [.font: font]).width + 10
        storage.addAttributes([.blockAtomLabel: label, .kern: width], range: range)
    }

    /// Where a note link points, `[[Note#Heading|text]]`: `Note#Heading`. Nil for any other atom.
    static func noteLinkTarget(_ markdown: String) -> String? {
        guard let inner = wikilinkInner(markdown) else { return nil }
        return String(inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces)
    }

    /// What a link destination starts with when it is a note link's target rather than a path or an address.
    public static let noteLinkScheme = "loam-note:"

    /// `[[...]]` or `![[...]]` without the brackets, a `\\|` (in a table) read as `|`.
    private static func wikilinkInner(_ markdown: String) -> Substring? {
        let body = markdown.hasPrefix("!") ? markdown.dropFirst() : Substring(markdown)
        guard body.hasPrefix("[["), body.hasSuffix("]]"), body.count > 4 else { return nil }
        return Substring(body.dropFirst(2).dropLast(2).replacingOccurrences(of: "\\|", with: "|"))
    }

    /// What the page shows for an atom Markdown reads as text (`InlineAtoms`): a note link's text, a footnote's number,
    /// math, nothing for a comment. Nil for the others, which are chips.
    func atomText(_ markdown: String, around: NSFont) -> NSAttributedString? {
        if let inner = Self.wikilinkInner(markdown) {
            let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            var label = parts.count > 1 ? String(parts[1]) : String(parts[0])
            if parts.count == 1 {
                // `Note#Heading` reads as Obsidian shows it, `Note > Heading`; `#Heading` alone is a heading of this note.
                let pieces = label.split(separator: "#", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                label = pieces.filter { !$0.isEmpty }.joined(separator: " › ")
            }
            return NSAttributedString(string: label, attributes: [
                .font: around, .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: linkColor.withAlphaComponent(0.4),
            ])
        }
        if markdown.hasPrefix("[^"), let close = markdown.firstIndex(of: "]") {
            let label = markdown[markdown.index(markdown.startIndex, offsetBy: 2)..<close]
            // A definition, `[^1]: `, keeps a space before its text.
            let shown = String(label) + (markdown[close...].count > 1 ? "  " : "")
            return NSAttributedString(string: shown, attributes: [
                .font: NSFontManager.shared.convert(around, toSize: around.pointSize * 0.7),
                .foregroundColor: linkColor, .baselineOffset: round(around.pointSize * 0.35),
            ])
        }
        if markdown.hasPrefix("%%") { return NSAttributedString() }
        if markdown.hasPrefix("$") {
            let display = markdown.hasPrefix("$$")
            let tex = markdown.trimmingCharacters(in: CharacterSet(charactersIn: "$").union(.whitespacesAndNewlines))
            let size = around.pointSize * (display ? 1.1 : 1)
            let font = NSFontManager.shared.convert(NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
            return MathText.attributed(tex, font: font, color: textColor)
        }
        return nil
    }

    /// What an atom's chip says: an image's alt text or file name, a tag's name.
    static func atomLabel(_ markdown: String) -> String {
        if markdown.hasPrefix("!["), let close = markdown.firstIndex(of: "]") {
            let alt = markdown[markdown.index(markdown.startIndex, offsetBy: 2)..<close]
            if !alt.isEmpty { return String(alt) }
            if let name = embedName(markdown) { return name }
        }
        let trimmed = markdown.trimmingCharacters(in: CharacterSet(charactersIn: "<>/ "))
        return String(trimmed.prefix(24))
    }

    private func mapBlockFonts(in range: NSRange, of storage: NSTextStorage, _ transform: (NSFont) -> NSFont) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            storage.addAttribute(.font, value: transform((value as? NSFont) ?? bodyFont), range: subrange)
        }
    }

    /// The typing attributes at `location`: those of the text before it in its paragraph (its block, its marks), but
    /// not a link's or an atom's, which typing never extends.
    static func blockTypingAttributes(at location: Int, in storage: NSTextStorage, fallback: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return fallback }
        let paragraph = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
        var index = location > paragraph.location ? location - 1 : location
        if location >= ns.length, location > 0, ns.character(at: ns.length - 1) == 10 {
            // After the last line break: a new paragraph.
            return fallback
        }
        index = min(index, ns.length - 1)
        var attributes = storage.attributes(at: index, effectiveRange: nil)
        for key: NSAttributedString.Key in [.noteLink, .noteAtom, .noteHardBreak, .markdownLink, .markdownDate, .markdownTag,
                                            .cursor, .blockAtomLabel, .blockPlaceholder, .markdownRule] {
            attributes[key] = nil
        }
        return attributes
    }
}

extension BlockKind {
    var isCode: Bool {
        if case .code = self { return true }
        return false
    }
}
