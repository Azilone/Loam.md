import AppKit
import MarkdownEditor
import PluginKitUI

public extension MarkdownTheme {
    /// The editor's look for the app's theme: its fonts, line height and column, and the colours it sets. A colour
    /// the theme leaves out keeps the editor's system one, so the standard tokens give today's editor exactly.
    init(tokens: ThemeTokens) {
        self.init()
        fontSize = tokens.bodySize
        lineHeightMultiple = tokens.lineHeight
        columnWidth = tokens.columnWidth
        bodyFamily = Self.family(tokens.bodyFamily)
        monoFamily = Self.family(tokens.monoFamily)

        let palette = tokens.palette
        if let color = palette.text { textColor = NSColor(color) }
        if let color = palette.secondaryText { secondaryTextColor = NSColor(color) }
        if let color = palette.accent { accentColor = NSColor(color) }
        // Links follow the accent unless the theme sets them apart, as in `Theme.tokens`.
        if let color = palette.link ?? palette.accent { linkColor = NSColor(color) }
        if let color = palette.marker { markerColor = NSColor(color) }
        if let color = palette.codeBackground { codeBackgroundColor = NSColor(color) }
        if let color = palette.background { backgroundColor = NSColor(color) }
        headingColor = palette.heading.map(NSColor.init) ?? (palette.text == nil ? Self.pageHeadingColor : nil)
        highlightColor = palette.highlight.map(NSColor.init)
        highlightTextColor = palette.highlightText.map(NSColor.init)
        tagTextColor = palette.tagText.map(NSColor.init)
        tagBackgroundColor = palette.tagBackground.map(NSColor.init)
        checkboxColor = palette.checkbox.map(NSColor.init)
        checkboxBorderColor = palette.checkboxBorder.map(NSColor.init)
        quoteBarColor = palette.quoteBar.map(NSColor.init)
        quoteBackgroundColor = palette.quoteBackground.map(NSColor.init)
        ruleColor = palette.separator.map(NSColor.init)

        let style = tokens.style
        headingFamily = style.headingFont.map(Self.family)
        headingWeight = style.headingWeight.map(Self.weight)
        headingScales = style.headingSizes?.map { CGFloat($0) } ?? []
        if let rules = style.headingRules { headingRules = rules }
        squareCheckboxes = style.checkbox == .square
        strikesDoneTasks = style.strikeDoneTasks ?? true
        capsuleTags = style.tagShape == .capsule
        letterSpacing = style.letterSpacing.map { CGFloat($0) } ?? 0
        headingLetterSpacing = style.headingLetterSpacing.map { CGFloat($0) } ?? 0
        paragraphSpacing = style.paragraphSpacing.map { CGFloat($0) * tokens.bodySize } ?? 0
    }

    private static func weight(_ weight: ThemeStyle.Weight) -> NSFont.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    private static func family(_ family: ThemeFontFamily) -> FontFamily {
        switch family {
        case .system(.default): .system(.default)
        case .system(.serif): .system(.serif)
        case .system(.monospaced): .system(.monospaced)
        case .system(.rounded): .system(.rounded)
        case .named(let name): .named(name)
        }
    }
}

extension NSColor {
    convenience init(_ color: ThemeColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
