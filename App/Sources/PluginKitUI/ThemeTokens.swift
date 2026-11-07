import SwiftUI

/// The colours, fonts and spacing of the current theme. Plugins read them from the environment
/// (`@Environment(\.themeTokens)`) instead of hard-coding values, so a theme from `.loam/themes/` restyles every
/// plugin at once. The shell builds them from the chosen `Theme` for the window's appearance (`Theme.tokens`).
public struct ThemeTokens: Equatable, Sendable {
    public struct Spacing: Equatable, Sendable {
        public var small: CGFloat
        public var medium: CGFloat
        public var large: CGFloat

        public init(small: CGFloat, medium: CGFloat, large: CGFloat) {
            self.small = small
            self.medium = medium
            self.large = large
        }
    }

    public var accent: Color
    public var text: Color
    public var secondaryText: Color
    public var background: Color
    public var separator: Color
    /// Behind inline code and code blocks.
    public var codeBackground: Color
    public var link: Color
    /// The dimmed Markdown syntax (`#`, `**`, `[[`).
    public var marker: Color
    public var bodyFont: Font
    public var monoFont: Font
    /// The body text size in points, for the places that need a number rather than a `Font` (the editor).
    public var bodySize: CGFloat
    /// Line height as a multiple of the font's.
    public var lineHeight: CGFloat
    /// Width of the editor's text column in points.
    public var columnWidth: CGFloat
    /// The families behind `bodyFont` and `monoFont`, for views that build platform fonts (the editor).
    public var bodyFamily: ThemeFontFamily
    public var monoFamily: ThemeFontFamily
    /// The colours the theme sets explicitly; empty for `.standard`. Views drawing outside SwiftUI (AppKit) read
    /// it to keep their own system colours where the theme sets none.
    public var palette: ThemePalette
    /// How the editor draws headings, task boxes and tags; empty for `.standard`.
    public var style = ThemeStyle()
    public var spacing: Spacing

    public init(
        accent: Color,
        text: Color,
        secondaryText: Color,
        background: Color,
        separator: Color,
        codeBackground: Color = ThemeTokens.systemCodeBackground,
        link: Color = .accentColor,
        marker: Color = ThemeTokens.systemMarker,
        bodyFont: Font,
        monoFont: Font,
        bodySize: CGFloat,
        lineHeight: CGFloat = 1.2,
        columnWidth: CGFloat = 720,
        bodyFamily: ThemeFontFamily = .system(.default),
        monoFamily: ThemeFontFamily = .system(.monospaced),
        palette: ThemePalette = ThemePalette(),
        spacing: Spacing
    ) {
        self.accent = accent
        self.text = text
        self.secondaryText = secondaryText
        self.background = background
        self.separator = separator
        self.codeBackground = codeBackground
        self.link = link
        self.marker = marker
        self.bodyFont = bodyFont
        self.monoFont = monoFont
        self.bodySize = bodySize
        self.lineHeight = lineHeight
        self.columnWidth = columnWidth
        self.bodyFamily = bodyFamily
        self.monoFamily = monoFamily
        self.palette = palette
        self.spacing = spacing
    }

    /// The system look: semantic colours, so light and dark mode follow, and the editor's 16 pt body size.
    public static let standard = ThemeTokens(
        accent: .accentColor,
        text: .primary,
        secondaryText: .secondary,
        background: systemBackground,
        separator: systemSeparator,
        // A calm reading page: 16 points on a line of about 1.7 times the size (1.42 of the font's own line height),
        // measured on a reference notebook whose text column reads clean.
        bodyFont: .system(size: 16),
        monoFont: .system(size: 15, design: .monospaced),
        bodySize: 16,
        lineHeight: 1.42,
        spacing: Spacing(small: 4, medium: 8, large: 16)
    )

    #if os(macOS)
    private static let systemBackground = Color(nsColor: .textBackgroundColor)
    private static let systemSeparator = Color(nsColor: .separatorColor)
    public static let systemCodeBackground = Color(nsColor: .quaternarySystemFill)
    public static let systemMarker = Color(nsColor: .tertiaryLabelColor)
    #else
    private static let systemBackground = Color(uiColor: .systemBackground)
    private static let systemSeparator = Color(uiColor: .separator)
    public static let systemCodeBackground = Color(uiColor: .quaternarySystemFill)
    public static let systemMarker = Color(uiColor: .tertiaryLabel)
    #endif
}

public extension Color {
    /// The colour of a theme file, in sRGB.
    init(_ color: ThemeColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

public extension Font {
    /// The font of `family` at `size`.
    static func theme(_ family: ThemeFontFamily, size: CGFloat) -> Font {
        switch family {
        case .system(let design):
            switch design {
            case .default: .system(size: size)
            case .serif: .system(size: size, design: .serif)
            case .monospaced: .system(size: size, design: .monospaced)
            case .rounded: .system(size: size, design: .rounded)
            }
        case .named(let name): .custom(name, size: size)
        }
    }
}

public extension Theme {
    /// The tokens of this theme drawn `dark` or light: its colours where it sets them, the system's elsewhere.
    func tokens(dark: Bool) -> ThemeTokens {
        let palette = palette(dark: dark)
        let base = ThemeTokens.standard
        let size = fontSize.map { CGFloat($0) } ?? base.bodySize
        let bodyFamily = bodyFont ?? base.bodyFamily
        let monoFamily = monoFont ?? base.monoFamily
        let accent = palette.accent.map(Color.init) ?? base.accent
        var tokens = ThemeTokens(
            accent: accent,
            text: palette.text.map(Color.init) ?? base.text,
            secondaryText: palette.secondaryText.map(Color.init) ?? base.secondaryText,
            background: palette.background.map(Color.init) ?? base.background,
            separator: palette.separator.map(Color.init) ?? base.separator,
            codeBackground: palette.codeBackground.map(Color.init) ?? base.codeBackground,
            // Links follow the accent unless the theme sets them apart.
            link: palette.link.map(Color.init) ?? accent,
            marker: palette.marker.map(Color.init) ?? base.marker,
            bodyFont: .theme(bodyFamily, size: size),
            monoFont: .theme(monoFamily, size: size - 1),
            bodySize: size,
            lineHeight: lineHeight.map { CGFloat($0) } ?? base.lineHeight,
            columnWidth: columnWidth.map { CGFloat($0) } ?? base.columnWidth,
            bodyFamily: bodyFamily,
            monoFamily: monoFamily,
            palette: palette,
            spacing: base.spacing
        )
        tokens.style = style
        return tokens
    }

    /// The scheme the window is forced into, nil to follow the system.
    var colorScheme: ColorScheme? {
        switch appearance {
        case .light: .light
        case .dark: .dark
        case .auto: nil
        }
    }
}

/// The family of the app's own text, as the window's theme sets it (`fonts.interface`). The shell sets it before the
/// views read it; a change redraws the window, as for `Corners.cap`.
public enum InterfaceFont {
    nonisolated(unsafe) public static var family: ThemeFontFamily = .system(.default)
}

public extension Font {
    /// The app's own text at `size`: the system font, or the family the theme sets for the interface. Use it where
    /// a view would write `.system(size:weight:)`.
    static func ui(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch InterfaceFont.family {
        case .system(let design):
            switch design {
            case .default: .system(size: size, weight: weight)
            case .serif: .system(size: size, weight: weight, design: .serif)
            case .monospaced: .system(size: size, weight: weight, design: .monospaced)
            case .rounded: .system(size: size, weight: weight, design: .rounded)
            }
        case .named(let name): .custom(name, size: size).weight(weight)
        }
    }
}

public extension EnvironmentValues {
    /// The current theme. The shell sets it at the root of the window.
    @Entry var themeTokens: ThemeTokens = .standard
}

extension ThemePalette {
    /// Whether the sidebar colour is dark under light pages (Ink): the sidebars and the window's own buttons on it
    /// then draw as in dark mode, in `canvasText` (`ThemeTokens.onCanvas`).
    public var hasDarkCanvas: Bool {
        guard let canvas = sidebar, let page = background else { return false }
        func luminance(_ c: ThemeColor) -> Double { 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue }
        return luminance(canvas) < 0.25 && luminance(page) > 0.6
    }

    /// The text on a dark canvas.
    public static let canvasText = ThemeColor(red: 0.93, green: 0.93, blue: 0.93)
}

extension ThemeTokens {
    public var hasDarkCanvas: Bool { palette.hasDarkCanvas }

    /// The tokens for what sits on a dark canvas: light text and hairlines, the accent kept.
    public var onCanvas: ThemeTokens {
        var tokens = self
        tokens.text = Color(ThemePalette.canvasText)
        tokens.secondaryText = Color(white: 0.56)
        tokens.marker = Color(white: 0.42)
        tokens.separator = Color(white: 1, opacity: 0.1)
        tokens.background = palette.sidebar.map(Color.init) ?? .black
        return tokens
    }
}
