import AppKit
import PluginKitUI

extension NSAttributedString.Key {
    /// The destination of a link, on its visible text. A click opens it.
    static let markdownLink = NSAttributedString.Key("Loam.markdownLink")
    /// On the three characters of a task box; the value is whether it is checked.
    static let markdownTaskBox = NSAttributedString.Key("Loam.markdownTaskBox")
    /// On code, where the `/` menu and list shortcuts stay out of the way.
    static let markdownCode = NSAttributedString.Key("Loam.markdownCode")
    /// On a level 1 heading, which the text view underlines with a hairline.
    static let markdownTitle = NSAttributedString.Key("Loam.markdownTitle")
    /// On the invisible `-`, `*` or `+` of a list item, where the text view draws a bullet.
    static let markdownBullet = NSAttributedString.Key("Loam.markdownBullet")
    /// On a quote, which the text view marks with a bar on its left. The value is the kind of a GitHub alert
    /// (`note`, `warning`...), drawn as a tinted card instead, or an empty string for a plain quote.
    static let markdownQuote = NSAttributedString.Key("Loam.markdownQuote")
    /// On a code block, which the text view draws on a rounded card. The value is its language, possibly empty.
    static let markdownCodeBlock = NSAttributedString.Key("Loam.markdownCodeBlock")
    /// On inline code, which the text view draws as a rounded pill.
    static let markdownInlineCode = NSAttributedString.Key("Loam.markdownInlineCode")
    /// On an invisible `---` divider, where the text view draws a hairline.
    static let markdownRule = NSAttributedString.Key("Loam.markdownRule")
    /// On a tag, which the text view draws as a pill. The value is true when the text view also draws its `#`
    /// (a tag of the frontmatter, written without one).
    static let markdownTag = NSAttributedString.Key("Loam.markdownTag")
    /// On a hidden `📅 2026-10-21`, which the text view draws as a date pill (the value, a `DatePillMark`). Clicking
    /// it opens the day (`onOpenDate`); Option-click selects it, which shows the text.
    static let markdownDate = NSAttributedString.Key("Loam.markdownDate")
}

/// A date pill and the font of the text around it, as the text view draws it.
/// How the editor shows Markdown. The note is always the same Markdown file; this is only how it looks.
public enum SyntaxMode: Equatable, Sendable {
    /// A page: formatting drawn, no syntax character visible, whatever the caret or the selection does.
    case rendered
    /// The Markdown as written, syntax shown, as "View Source" asks.
    case source
}

struct DatePillMark {
    let pill: DatePill
    let font: NSFont
}

/// Fonts and colours of the editor. The defaults are the system's semantic colours, so light and dark mode follow;
/// a host (the editor plugin, from the app's theme) replaces the ones its theme sets.
public struct MarkdownTheme: Equatable {
    /// A font family: the system font in one of its designs, or an installed family by name.
    public enum FontFamily: Equatable {
        case system(NSFontDescriptor.SystemDesign)
        case named(String)
    }

    public var fontSize: CGFloat = 16
    public var lineHeightMultiple: CGFloat = 1.42
    /// Width of the text column; the editor centres it in wider windows.
    public var columnWidth: CGFloat = 720
    public var bodyFamily: FontFamily = .system(.default)
    public var monoFamily: FontFamily = .system(.monospaced)

    public var textColor: NSColor = MarkdownTheme.pageTextColor
    public var secondaryTextColor: NSColor = .secondaryLabelColor
    public var accentColor: NSColor = .controlAccentColor
    public var linkColor: NSColor = .controlAccentColor
    /// The dimmed Markdown syntax.
    public var markerColor: NSColor = .tertiaryLabelColor
    public var codeBackgroundColor: NSColor = .quaternarySystemFill
    public var backgroundColor: NSColor = .textBackgroundColor

    // What a theme may set beyond the colours above; nil keeps the editor's own look.
    /// Headings; `textColor` when nil. A theme that sets a text colour but no heading colour has nil (`init(tokens:)`).
    public var headingColor: NSColor? = MarkdownTheme.pageHeadingColor
    public var headingFamily: FontFamily?
    public var headingWeight: NSFont.Weight?
    /// Sizes of `#` to `######` as multiples of `fontSize`, replacing Craft's for the levels the list has.
    public var headingScales: [CGFloat] = []
    /// The heading levels drawn with a hairline under them.
    public var headingRules: Set<Int> = [1]
    /// Behind `==highlighted==` text without a colour of its own; Craft's yellow when nil.
    public var highlightColor: NSColor?
    /// The text of `==highlighted==` text without a colour of its own; its own colour when nil.
    public var highlightTextColor: NSColor?
    /// A tag's name and the pill behind it; `linkColor` and a tint of the name when nil.
    public var tagTextColor: NSColor?
    public var tagBackgroundColor: NSColor?
    public var capsuleTags = false
    /// Tags in the mono font, a little smaller, as Loam's labels.
    public var monoTags = true
    /// A checked task box and the ring of an open one; the accent and a dimmed secondary colour when nil.
    public var checkboxColor: NSColor?
    public var checkboxBorderColor: NSColor?
    public var squareCheckboxes = false
    public var strikesDoneTasks = true
    /// Room between letters, in points, of the body and of headings.
    public var letterSpacing: CGFloat = 0
    public var headingLetterSpacing: CGFloat = 0
    /// Room after each paragraph, in points.
    public var paragraphSpacing: CGFloat = 0
    /// The bar along a quote; `textColor` when nil.
    public var quoteBarColor: NSColor?
    /// Dividers and the hairline under headings; a tint of `textColor` when nil.
    public var ruleColor: NSColor?
    /// Behind a quote, from its bar to the column's edge; none when nil.
    public var quoteBackgroundColor: NSColor?

    public init() {}

    /// The page text, a soft gray: #56585C, #F4F4F4 in dark mode. Headings are a step darker (`pageHeadingColor`).
    public static let pageTextColor = NSColor(name: "pageText") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF4 / 255, alpha: 1)
            : NSColor(srgbRed: 0x56 / 255, green: 0x58 / 255, blue: 0x5C / 255, alpha: 1)
    }

    /// The headings and the title of a theme that sets no text colour: #38393C, #F4F4F4 in dark mode.
    public static let pageHeadingColor = NSColor(name: "pageHeading") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF4 / 255, alpha: 1)
            : NSColor(srgbRed: 0x38 / 255, green: 0x39 / 255, blue: 0x3C / 255, alpha: 1)
    }

    var bodyFont: NSFont { font(bodyFamily, size: fontSize, weight: .regular) }

    /// A thin stroke that thickens a heading drawn in a family without the weight asked for (a theme's font with only
    /// a medium cut asked for semibold); none when the font has it. The stroke is in `color`, or the text's when nil.
    func fakeBold(_ font: NSFont, weight: NSFont.Weight, color: NSColor?) -> [NSAttributedString.Key: Any] {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let actual = (traits?[.weight] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
        guard weight.rawValue - actual > 0.04 else { return [:] }
        // Stroke width is a percentage of the size: a negative one fills and strokes, thickening the letters.
        var stroke: [NSAttributedString.Key: Any] = [.strokeWidth: -min(3, (weight.rawValue - actual) * 25)]
        if let color { stroke[.strokeColor] = color }
        return stroke
    }

    /// The body family at `size` and `weight`; the system font when the family is not installed.
    func bodyFont(size: CGFloat, weight: NSFont.Weight) -> NSFont { font(bodyFamily, size: size, weight: weight) }

    func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { font(monoFamily, size: size, weight: weight) }

    var tagColor: NSColor { tagTextColor ?? linkColor }

    func font(_ family: FontFamily, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        switch family {
        case .system(.monospaced):
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case .system(let design):
            let system = NSFont.systemFont(ofSize: size, weight: weight)
            guard design != .default, let descriptor = system.fontDescriptor.withDesign(design) else { return system }
            return NSFont(descriptor: descriptor, size: size) ?? system
        case .named(let name):
            let bold = weight >= .semibold
            return NSFontManager.shared.font(
                withFamily: name, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size
            ) ?? NSFont(name: name, size: size) ?? font(.system(.default), size: size, weight: weight)
        }
    }

    /// Craft's text styles (its `PageStyles/default.css`, written for a 17 pixel body): Title 24 bold, Subtitle 22
    /// bold, Heading 20 semibold, Strong 18 semibold, for `#` to `####`.
    func headingScale(_ level: Int) -> CGFloat {
        if level >= 1, level <= headingScales.count { return headingScales[level - 1] }
        return switch level {
        case 1: 24 / 17
        case 2: 22 / 17
        case 3: 20 / 17
        case 4: 18 / 17
        default: 1
        }
    }

    /// The room Craft leaves above a heading (Title 48, Subtitle 36, Heading 28, Strong 16 on its 17 pixel body),
    /// less the blank line Markdown already puts there.
    func headingSpaceAbove(_ level: Int) -> CGFloat {
        let craft: CGFloat = switch level {
        case 1: 48
        case 2: 36
        case 3: 28
        default: 16
        }
        return max(0, craft / 17 * fontSize - fontSize * lineHeightMultiple)
    }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = paragraphSpacing
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: paragraphStyle]
        if letterSpacing != 0 { attributes[.kern] = letterSpacing }
        return attributes
    }

    /// Restyles `storage`, or only `limit` (whole paragraphs and whole tables) of it. Only attributes change, never
    /// the characters. The `.concealable` and `.invisible` syntax is hidden unless `revealing` (the selection)
    /// reaches into it; nil reveals everything. `today` (`YYYY-MM-DD`) names the date pills.
    func apply(_ spans: [StyleSpan], to storage: NSTextStorage, revealing: NSRange? = nil, in limit: NSRange? = nil,
        today: String = DatePill.localToday()
    ) {
        let whole = limit.map { NSIntersectionRange($0, NSRange(location: 0, length: storage.length)) }
            ?? NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(baseAttributes, range: whole)

        // Order matters: sizes first, then font traits, then colours, then the dimmed markers on top.
        let relevant = limit == nil ? spans : spans.filter { NSIntersectionRange($0.range, whole).length > 0 }
        for span in relevant.sorted(by: { rank($0.style) < rank($1.style) }) {
            let range = NSIntersectionRange(span.range, whole)
            guard range.length > 0 else { continue }
            switch span.style {
            case .heading(let level):
                let size = fontSize * headingScale(level)
                let weight = headingWeight ?? (level <= 2 ? .bold : .semibold)
                let headingFont = font(headingFamily ?? bodyFamily, size: size, weight: weight)
                storage.addAttribute(.font, value: headingFont, range: range)
                if let headingColor { storage.addAttribute(.foregroundColor, value: headingColor, range: range) }
                storage.addAttributes(fakeBold(headingFont, weight: weight, color: headingColor ?? textColor), range: range)
                if headingLetterSpacing != 0 { storage.addAttribute(.kern, value: headingLetterSpacing, range: range) }
                let style = NSMutableParagraphStyle()
                style.lineHeightMultiple = level == 4 ? 1.3 : 1.1
                style.paragraphSpacing = paragraphSpacing
                style.paragraphSpacingBefore = headingSpaceAbove(level)
                if headingRules.contains(level) {
                    // Room for the hairline under the heading.
                    style.paragraphSpacing = fontSize * (level == 1 ? 1.2 : 0.6)
                    storage.addAttribute(.markdownTitle, value: level, range: range)
                }
                storage.addAttribute(.paragraphStyle, value: style, range: paragraphs(range, in: storage))
            case .table:
                // Shown as a component, which hides these lines (`EditorController.applyTableBlocks`).
                break
            case .codeBlock:
                styleCodeBlock(span.range, within: whole, in: storage)
            case .frontmatter:
                storage.addAttribute(.font, value: monoFont(size: fontSize * 0.85), range: range)
                storage.addAttribute(.foregroundColor, value: secondaryTextColor, range: range)
            case .inlineCode:
                mapFonts(in: range, of: storage) { font in
                    monoFont(size: font.pointSize * 0.88)
                }
                storage.addAttributes([.markdownCode: true, .markdownInlineCode: true], range: range)
                // Room inside the pill the text view draws: after the opening backtick and the last character.
                if range.length > 2 {
                    storage.addAttribute(.kern, value: Self.pillPadding, range: NSRange(location: range.location, length: 1))
                    storage.addAttribute(.kern, value: Self.pillPadding, range: NSRange(location: NSMaxRange(range) - 2, length: 1))
                }
            case .strong:
                embolden(range, of: storage)
            case .emphasis:
                italicize(range, of: storage)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .highlight(let color):
                storage.addAttribute(.backgroundColor, value: color == nil ? highlightColor ?? Self.highlightColor(nil) : Self.highlightColor(color), range: range)
                if color == nil, let text = highlightTextColor { storage.addAttribute(.foregroundColor, value: text, range: range) }
            case .quote:
                styleQuote(span.range, within: whole, in: storage)
            case .link(let destination):
                storage.addAttributes([
                    .foregroundColor: linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: linkColor.withAlphaComponent(0.4),
                    .markdownLink: destination,
                    // A click opens it (`EditorTextView.mouseDown`).
                    .cursor: NSCursor.pointingHand,
                ], range: range)
            case .listMarker(let depth):
                storage.addAttribute(.foregroundColor, value: textColor, range: range)
                // A bullet list's `-` is drawn as a dot; a task item's is drawn as nothing (its box is the mark).
                let marker = (storage.string as NSString).substring(with: range)
                let isBullet = ["-", "*", "+"].contains(marker)
                let isTask = Self.isTaskItem(after: range, in: storage)
                if isBullet, revealing.map({ !Self.reveals($0, range) }) ?? false {
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
                    if !isTask { storage.addAttribute(.markdownBullet, value: true, range: range) }
                }
                layOutListItem(marker: range, depth: depth, isBullet: isBullet, isTask: isTask, in: storage, revealing: revealing)
            case .taskBox(let checked):
                storage.addAttributes([
                    // Drawn by the text view as a round checkbox; the characters keep its room.
                    .foregroundColor: revealing.map({ Self.reveals($0, range) }) ?? true ? accentColor : NSColor.clear,
                    .markdownTaskBox: checked,
                    .cursor: NSCursor.pointingHand,
                ], range: range)
                // Hidden, the box keeps just the room of the round box drawn there (Craft's 22 points to the text).
                let isShown = revealing.map { Self.reveals($0, range) } ?? true
                mapFonts(in: range, of: storage) { monoFont(size: isShown ? $0.pointSize : $0.pointSize * 0.62, weight: .medium) }
            case .completedTask:
                storage.addAttribute(.foregroundColor, value: secondaryTextColor, range: range)
                if strikesDoneTasks {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            case .alert:
                let kind = Self.alertKind((storage.string as NSString).substring(with: range))
                storage.addAttribute(.foregroundColor, value: Self.alertColor(kind, accent: accentColor), range: range)
                mapFonts(in: range, of: storage) { bodyFont(size: $0.pointSize * 0.8, weight: .bold) }
                storage.addAttribute(.kern, value: 0.6, range: range)
            case .marker:
                storage.addAttribute(.foregroundColor, value: markerColor, range: range)
            case .concealable:
                guard let revealing, !Self.reveals(revealing, range) else { continue }
                storage.addAttributes(Self.concealed, range: range)
            case .invisible:
                guard let revealing, !Self.reveals(revealing, range) else { continue }
                storage.addAttributes([.foregroundColor: NSColor.clear, .backgroundColor: NSColor.clear], range: range)
                let text = (storage.string as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)
                if !text.hasPrefix(">") { storage.addAttribute(.markdownRule, value: true, range: range) }
            case .concealedOutside(let block):
                guard let revealing, !Self.reveals(revealing, block) else { continue }
                storage.addAttributes(Self.concealed, range: range)
            case .tag(let frontmatter):
                if let frontmatter {
                    guard let revealing, !Self.reveals(revealing, frontmatter) else { continue }
                    let font = monoTags ? monoFont(size: round(fontSize * 0.82)) : bodyFont(size: fontSize * 0.9, weight: .regular)
                    storage.addAttributes([.font: font, .foregroundColor: tagColor, .markdownTag: true], range: range)
                    // Room for the `#` and the pill's edge, on the hidden character before the name.
                    if range.location > 0 {
                        let hash = ("#" as NSString).size(withAttributes: [.font: font]).width
                        storage.addAttribute(.kern, value: hash + Self.tagPadding, range: NSRange(location: range.location - 1, length: 1))
                    }
                } else {
                    storage.addAttributes([.foregroundColor: tagColor, .markdownTag: false], range: range)
                    if monoTags { storage.addAttribute(.font, value: monoFont(size: round(fontSize * 0.85)), range: range) }
                }
            case .date(let day, let completion, let openTask):
                guard let revealing, !Self.reveals(revealing, range) else { continue }
                let around = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? bodyFont
                let font = bodyFont(size: around.pointSize * 0.94, weight: .regular)
                let pill = DatePill(day: day, today: today, completion: completion, openTask: openTask)
                storage.addAttributes(Self.concealed, range: range)
                // A checked task's strikethrough would run through the pill's room and the space before it.
                let before = range.location > 0 && (storage.string as NSString).character(at: range.location - 1) == 32 ? 1 : 0
                storage.removeAttribute(.strikethroughStyle, range: NSRange(location: range.location - before, length: range.length + before))
                storage.addAttributes([.markdownDate: DatePillMark(pill: pill, font: font), .cursor: NSCursor.pointingHand], range: range)
                // The pill's room, after the last hidden character.
                storage.addAttribute(.kern, value: pill.width(font: font), range: NSRange(location: NSMaxRange(range) - 1, length: 1))
            case .fencedCode, .embed:
                // Drawn as a picture or an embed when the host shows it (`EditorController.applyPictures`, `applyEmbeds`).
                break
            }
        }
    }

    private func rank(_ style: MarkdownStyle) -> Int {
        switch style {
        case .heading, .codeBlock, .table, .frontmatter: 0
        case .inlineCode: 1
        case .strong, .emphasis, .taskBox, .quote: 2
        case .marker: 4
        case .concealable, .invisible, .concealedOutside: 5
        case .date: 6
        default: 3
        }
    }

    /// A highlight's colour: the pastel itself in light mode, toned down on a dark page so the text stays readable.
    static func highlightColor(_ hex: String?) -> NSColor {
        let base = NSColor(hex: hex ?? "") ?? NSColor(hex: "#f6ef6b")!
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? base.withAlphaComponent(0.4) : base
        }
    }

    /// Room between a pill's edge and its text.
    static let tagPadding: CGFloat = 4
    /// Room above and below the text of a table row, and on each side of a cell's text.
    static let tableRowPadding: CGFloat = 7
    static let tableCellPadding: CGFloat = 12

    /// Hidden syntax: a vanishing font and no colour, so it takes no room and cannot be seen. The characters stay.
    static var concealed: [NSAttributedString.Key: Any] { [
        .font: NSFont.systemFont(ofSize: 0.01),
        .foregroundColor: NSColor.clear,
        .backgroundColor: NSColor.clear,
    ] }

    /// What the selection that styling reveals syntax for is, in each mode: nowhere when rendered (the text shows no
    /// syntax whatever the caret or the selection does), everywhere when showing the source.
    static func revealing(_ mode: SyntaxMode) -> NSRange {
        switch mode {
        case .rendered: NSRange(location: Int.max / 2, length: 0)
        case .source: NSRange(location: 0, length: Int.max / 2)
        }
    }

    /// Whether the selection is working inside a block (a diagram's or a collection's code): a caret strictly inside
    /// it, or a selection within it. A selection that merely reaches into it (Select All) does not enter it.
    static func enters(_ selection: NSRange, _ block: NSRange) -> Bool {
        if selection.length == 0 {
            return selection.location > block.location && selection.location < NSMaxRange(block)
        }
        return selection.location >= block.location && NSMaxRange(selection) <= NSMaxRange(block)
    }

    /// Whether the selection shows the syntax in `range`: a caret strictly inside it, or a selection overlapping it.
    /// A caret just before or after stays out, so opening a note or typing after `**bold**` shows no syntax.
    static func reveals(_ selection: NSRange, _ range: NSRange) -> Bool {
        if selection.length == 0 {
            return selection.location > range.location && selection.location < NSMaxRange(range)
        }
        return NSIntersectionRange(selection, range).length > 0
    }

    /// Whether a `[ ]` or `[x]` follows the list marker at `range`.
    static func isTaskItem(after range: NSRange, in storage: NSTextStorage) -> Bool {
        let ns = storage.string as NSString
        var index = NSMaxRange(range)
        while index < ns.length, ns.character(at: index) == 32 { index += 1 }
        return index < ns.length && ns.character(at: index) == 91
            && storage.attribute(.markdownTaskBox, at: index, effectiveRange: nil) != nil
    }

    private func paragraphs(_ range: NSRange, in storage: NSTextStorage) -> NSRange {
        (storage.string as NSString).paragraphRange(for: range)
    }

    /// Strong text: its fonts' bold cut, or `fakeBold`'s stroke where the family has none (Gerstner Programm, the
    /// Dither themes' font, stops at medium), which left bold looking like the text around it.
    func embolden(_ range: NSRange, of storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let bold = ((value as? NSFont) ?? bodyFont).adding(.bold)
            storage.addAttribute(.font, value: bold, range: subrange)
            // No stroke colour: it is then the text's own, whatever colour comes after (a link's).
            storage.addAttributes(fakeBold(bold, weight: .bold, color: nil), range: subrange)
        }
    }

    /// Emphasised text: its fonts' italic cut, or the letters slanted where the family has none (Gerstner Programm).
    func italicize(_ range: NSRange, of storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let upright = (value as? NSFont) ?? bodyFont
            var italic = upright.adding(.italic)
            // A family without a bold italic cut answers with its regular italic: bold text then lost its weight, so
            // the bold cut is slanted instead.
            if italic.traitWeight < upright.traitWeight - 0.1 {
                italic = upright
            }
            // A font sheared to about a sans serif italic's slant (12°): TextKit 2 draws no `.obliqueness`.
            // A unit matrix and the size apart: the system font's descriptor already carries its size, which a
            // transform scaled by the size multiplied again into letters a page tall.
            if !italic.fontDescriptor.symbolicTraits.contains(.italic),
               let slanted = NSFont(
                   descriptor: italic.fontDescriptor.withMatrix(AffineTransform(m11: 1, m12: 0, m21: 0.21, m22: 1, tX: 0, tY: 0)),
                   size: italic.pointSize
               ) {
                italic = slanted
            }
            storage.addAttribute(.font, value: italic, range: subrange)
        }
    }

    private func mapFonts(in range: NSRange, of storage: NSTextStorage, _ transform: (NSFont) -> NSFont) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? bodyFont
            storage.addAttribute(.font, value: transform(font), range: subrange)
        }
    }

    /// Room on each side of an inline code pill's text.
    static let pillPadding: CGFloat = 3
    /// Room between a code block's card and its text.
    static let codePadding: CGFloat = 14
    /// The room on each side of a code block's line numbers.
    static let gutterPadding: CGFloat = 10
    /// How far a quote's text sits from the column's edge, right of its bar.
    var quoteIndent: CGFloat { round(fontSize * 1.1) }
    /// How far each level of a list is indented, and where an item's text starts after its marker: Craft's 22
    /// points on its 15 point body.
    var listIndent: CGFloat { round(fontSize * 22 / 15) }

    /// Craft's list items: the marker a little in from the edge (a level further per nesting), the text a fixed
    /// step after it whatever the marker's width, wrapped lines under the text, and a little room between items.
    /// The leading spaces take no room; the marker's (or the task box's) kerning sets the text's start.
    private func layOutListItem(
        marker: NSRange, depth: Int, isBullet: Bool, isTask: Bool, in storage: NSTextStorage, revealing: NSRange?
    ) {
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: marker)
        let isQuoted = storage.attribute(.markdownQuote, at: marker.location, effectiveRange: nil) != nil
        let base = (isQuoted ? quoteIndent : 0) + CGFloat(depth) * listIndent
        // Spaces (and a quote's `>`) before the marker: hidden, the paragraph's indent replaces them.
        if marker.location > paragraph.location {
            storage.addAttributes(Self.concealed, range: NSRange(location: paragraph.location, length: marker.location - paragraph.location))
        }
        var contentStart = NSMaxRange(marker)
        while contentStart < NSMaxRange(paragraph), [32, 9].contains(ns.character(at: contentStart)) { contentStart += 1 }
        let shown = revealing.map { Self.reveals($0, marker) } ?? true
        var kernAt = marker.location + marker.length - 1
        var start = base + (isBullet && !isTask ? 4 : 0)
        if isTask, contentStart + 3 <= NSMaxRange(paragraph), !shown {
            // The task's `- ` takes no room: its round box stands where the bullet would.
            storage.addAttributes(Self.concealed, range: NSRange(location: marker.location, length: contentStart - marker.location))
            start = base
            kernAt = contentStart + 2
            contentStart += 3
            while contentStart < NSMaxRange(paragraph), [32, 9].contains(ns.character(at: contentStart)) { contentStart += 1 }
        }
        let style = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        let prefixWidth = storage.attributedSubstring(from: NSRange(location: paragraph.location, length: contentStart - paragraph.location)).size().width
        let textStart = base + listIndent
        let extra = textStart - start - prefixWidth
        if extra > 0, kernAt >= 0, kernAt < storage.length {
            let existing = (storage.attribute(.kern, at: kernAt, effectiveRange: nil) as? CGFloat) ?? 0
            storage.addAttribute(.kern, value: existing + extra, range: NSRange(location: kernAt, length: 1))
        }
        style.firstLineHeadIndent = start
        style.headIndent = max(textStart, start + prefixWidth)
        style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, round(fontSize * 0.28))
        storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
    }

    /// A quote: indented, in the body colour, the text view drawing a bar on its left (Craft's focus block), or a
    /// tinted card for a GitHub alert (`> [!NOTE]`). Every line lines up, those without a `>` too. Its kind comes
    /// from its first line even when only some of its lines (`limit`) are restyled.
    private func styleQuote(_ range: NSRange, within limit: NSRange, in storage: NSTextStorage) {
        let ns = storage.string as NSString
        let firstLine = ns.substring(with: ns.lineRange(for: NSRange(location: range.location, length: 0)))
        let kind = firstLine.range(of: #"^\s*>\s*\[![A-Za-z]+\]"#, options: .regularExpression).map { Self.alertKind(String(firstLine[$0])) } ?? ""
        storage.addAttribute(.markdownQuote, value: kind, range: NSIntersectionRange(range, limit))
        let paragraphs = paragraphs(range, in: storage)
        let isCard = !kind.isEmpty
        var location = paragraphs.location
        while location < NSMaxRange(paragraphs) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            guard NSIntersectionRange(paragraph, limit).length > 0 else { continue }
            let style = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent = quoteIndent
            style.headIndent = quoteIndent
            // A line holding only its hidden `>` (just after Return) would shrink to the hidden font's height: no
            // bar, no caret. It keeps the body line's height.
            style.minimumLineHeight = round((bodyFont.ascender - bodyFont.descender + bodyFont.leading) * max(lineHeightMultiple, 1))
            if isCard {
                style.tailIndent = -quoteIndent
                if paragraph.location == paragraphs.location { style.paragraphSpacingBefore = Self.codePadding }
                if NSMaxRange(paragraph) >= NSMaxRange(paragraphs) { style.paragraphSpacing = Self.codePadding }
            }
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }

    /// A code block: the mono font on a rounded card (drawn by the text view) with room around the text, the
    /// fences hidden. The card's top and bottom padding is the hidden fences' paragraph spacing.
    private func styleCodeBlock(_ range: NSRange, within limit: NSRange, in storage: NSTextStorage) {
        let ns = storage.string as NSString
        storage.addAttribute(.font, value: monoFont(size: fontSize * 0.87), range: NSIntersectionRange(range, limit))
        let firstLine = ns.lineWithoutBreak(at: range.location)
        let opener = ns.substring(with: firstLine).trimmingCharacters(in: .whitespaces)
        let isFenced = opener.hasPrefix("```") || opener.hasPrefix("~~~")
        let language = isFenced ? opener.drop { $0 == "`" || $0 == "~" }.trimmingCharacters(in: .whitespaces) : ""
        storage.addAttributes([.markdownCode: true, .markdownCodeBlock: language], range: NSIntersectionRange(range, limit))
        let paragraphs = paragraphs(range, in: storage)
        // Room on the left for the line numbers the text view draws, as Craft's code blocks have.
        let lines = ns.substring(with: paragraphs).components(separatedBy: "\n").count - (isFenced ? 2 : 0)
        let indent = codeGutter(lines: lines) + Self.codePadding
        var location = paragraphs.location
        while location < NSMaxRange(paragraphs) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            guard NSIntersectionRange(paragraph, limit).length > 0 else { continue }
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.3
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.tailIndent = -Self.codePadding
            let isFirst = paragraph.location == paragraphs.location
            let isLast = NSMaxRange(paragraph) >= NSMaxRange(paragraphs)
            if isFenced {
                if isFirst { style.paragraphSpacing = Self.codePadding - 2 }
                if isLast, !isFirst { style.paragraphSpacingBefore = Self.codePadding - 2 }
            } else {
                if isFirst { style.paragraphSpacingBefore = Self.codePadding }
                if isLast { style.paragraphSpacing = Self.codePadding }
            }
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }

    /// The width of a code block's line-number column for `lines` lines, its separator included.
    func codeGutter(lines: Int) -> CGFloat {
        let digits = CGFloat(max(2, String(max(lines, 1)).count))
        let digit = ("0" as NSString).size(withAttributes: [.font: monoFont(size: fontSize * 0.8)]).width
        return (digits * digit + 2 * Self.gutterPadding).rounded(.up)
    }

    /// `note`, `tip`, `important`, `warning` or `caution` from `[!NOTE]` (or `> [!NOTE]`).
    static func alertKind(_ label: String) -> String {
        label.drop { $0 != "!" }.dropFirst().prefix { $0.isLetter }.lowercased()
    }

    /// GitHub's colours for its alerts.
    static func alertColor(_ kind: String, accent: NSColor) -> NSColor {
        switch kind {
        case "tip": .systemGreen
        case "important": .systemPurple
        case "warning": .systemOrange
        case "caution": .systemRed
        default: accent
        }
    }
}

extension NSColor {
    /// `#rrggbb`.
    convenience init?(hex: String) {
        guard hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255, alpha: 1
        )
    }
}

extension NSFont {
    /// Its weight, from -1 (ultra light) to 1 (black); 0 is regular.
    var traitWeight: CGFloat {
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
    }

    func adding(_ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
