import Foundation

/// A colour of a theme file: `#RRGGBB` or `#RRGGBBAA`, in sRGB. Components are 0...1.
public struct ThemeColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` (case does not matter); nil for anything else.
    public init?(hex: String) {
        let text = hex.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        let digits = text.dropFirst()
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit),
              let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        red = Double((rgb >> 16) & 0xFF) / 255
        green = Double((rgb >> 8) & 0xFF) / 255
        blue = Double(rgb & 0xFF) / 255
        alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    public var hex: String {
        func byte(_ component: Double) -> String { String(format: "%02X", Int((component * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    /// The relative luminance of the colour (WCAG), 0 for black to 1 for white; opacity is ignored.
    public var luminance: Double {
        func channel(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The WCAG contrast ratio with `other`, 1 to 21.
    public func contrast(with other: ThemeColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `amount` of the way from this colour to `other`, 0 to 1.
    public func mixed(with other: ThemeColor, by amount: Double) -> ThemeColor {
        ThemeColor(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount,
            alpha: alpha
        )
    }

    /// This colour, darkened on a light `background` or lightened on a dark one, just enough to reach `minimum`
    /// contrast with it; unchanged when it already does.
    public func readable(on background: ThemeColor, minimum: Double) -> ThemeColor {
        let target = background.luminance > 0.18 ? ThemeColor(red: 0, green: 0, blue: 0) : ThemeColor(red: 1, green: 1, blue: 1)
        var amount = 0.0
        var color = self
        while color.contrast(with: background) < minimum, amount < 1 {
            amount = min(1, amount + 0.02)
            color = mixed(with: target, by: amount)
        }
        return color
    }
}

/// The colours a theme may set. A nil colour keeps the system's.
public struct ThemePalette: Equatable, Sendable {
    public var accent: ThemeColor?
    public var text: ThemeColor?
    public var secondaryText: ThemeColor?
    public var background: ThemeColor?
    public var separator: ThemeColor?
    public var codeBackground: ThemeColor?
    public var link: ThemeColor?
    public var marker: ThemeColor?
    /// Headings; `text` when unset.
    public var heading: ThemeColor?
    /// Behind `==highlighted==` text without a colour of its own.
    public var highlight: ThemeColor?
    /// A tag's name; `link` when unset.
    public var tagText: ThemeColor?
    /// The pill behind a tag; a tint of `tagText` when unset.
    public var tagBackground: ThemeColor?
    /// A checked task box; `accent` when unset.
    public var checkbox: ThemeColor?
    /// The ring of an open task box.
    public var checkboxBorder: ThemeColor?
    /// The bar along a quote; `text` when unset.
    public var quoteBar: ThemeColor?
    /// Behind a quote, from its bar to the column's edge; none when unset.
    public var quoteBackground: ThemeColor?
    /// `==highlighted==` text on `highlight`; the text's own colour when unset.
    public var highlightText: ThemeColor?
    /// Around the pages: the sidebar and the window behind them.
    public var sidebar: ThemeColor?
    /// The dots of a dithered picture (the pictures on cards); `accent` when unset.
    public var ditherInk: ThemeColor?
    /// Between the dots of a dithered picture; `background` when unset.
    public var ditherPaper: ThemeColor?

    public init(
        accent: ThemeColor? = nil,
        text: ThemeColor? = nil,
        secondaryText: ThemeColor? = nil,
        background: ThemeColor? = nil,
        separator: ThemeColor? = nil,
        codeBackground: ThemeColor? = nil,
        link: ThemeColor? = nil,
        marker: ThemeColor? = nil
    ) {
        self.accent = accent
        self.text = text
        self.secondaryText = secondaryText
        self.background = background
        self.separator = separator
        self.codeBackground = codeBackground
        self.link = link
        self.marker = marker
    }

    /// The keys of `colors` in a theme file, in display order.
    public static let keys: [String] = [
        "accent", "text", "secondaryText", "background", "separator", "codeBackground", "link", "marker",
        "heading", "highlight", "tagText", "tagBackground", "checkbox", "checkboxBorder", "quoteBar", "sidebar",
    ]

    /// Keys a theme may add for a look of its own; each falls back to another colour or to nothing, so the built-in
    /// themes leave them out.
    public static let extraKeys: [String] = ["ditherInk", "ditherPaper", "quoteBackground", "highlightText"]

    /// Every key of `colors`: `keys`, then `extraKeys`.
    public static var allKeys: [String] { keys + extraKeys }

    public subscript(key: String) -> ThemeColor? {
        get {
            switch key {
            case "accent": accent
            case "text": text
            case "secondaryText": secondaryText
            case "background": background
            case "separator": separator
            case "codeBackground": codeBackground
            case "link": link
            case "marker": marker
            case "heading": heading
            case "highlight": highlight
            case "tagText": tagText
            case "tagBackground": tagBackground
            case "checkbox": checkbox
            case "checkboxBorder": checkboxBorder
            case "quoteBar": quoteBar
            case "sidebar": sidebar
            case "ditherInk": ditherInk
            case "ditherPaper": ditherPaper
            case "quoteBackground": quoteBackground
            case "highlightText": highlightText
            default: nil
            }
        }
        set {
            switch key {
            case "accent": accent = newValue
            case "text": text = newValue
            case "secondaryText": secondaryText = newValue
            case "background": background = newValue
            case "separator": separator = newValue
            case "codeBackground": codeBackground = newValue
            case "link": link = newValue
            case "marker": marker = newValue
            case "heading": heading = newValue
            case "highlight": highlight = newValue
            case "tagText": tagText = newValue
            case "tagBackground": tagBackground = newValue
            case "checkbox": checkbox = newValue
            case "checkboxBorder": checkboxBorder = newValue
            case "quoteBar": quoteBar = newValue
            case "sidebar": sidebar = newValue
            case "ditherInk": ditherInk = newValue
            case "ditherPaper": ditherPaper = newValue
            case "quoteBackground": quoteBackground = newValue
            case "highlightText": highlightText = newValue
            default: break
            }
        }
    }

    public var isEmpty: Bool { self == ThemePalette() }

    /// These colours, with the ones `overrides` sets replaced.
    public func merging(_ overrides: ThemePalette) -> ThemePalette {
        var result = self
        for key in Self.allKeys where overrides[key] != nil { result[key] = overrides[key] }
        return result
    }
}

/// Which appearance a theme is drawn in: `auto` follows the system, `light` and `dark` force it.
public enum ThemeAppearance: String, Equatable, Sendable, CaseIterable {
    case light, dark, auto
}

/// A font family named in a theme: the system font in one of its designs, or an installed family.
public enum ThemeFontFamily: Hashable, Sendable {
    public enum Design: Hashable, Sendable { case `default`, serif, monospaced, rounded }

    case system(Design)
    case named(String)

    /// "SF Pro" or "System" is the system font, "New York" its serif design, "SF Mono" its monospaced one,
    /// "SF Pro Rounded" its rounded one; any other name is an installed family.
    public init(_ name: String) {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "system", "sf pro", "sf pro text", "sf pro display", "san francisco": self = .system(.default)
        case "new york", "serif": self = .system(.serif)
        case "sf mono", "monospaced", "mono": self = .system(.monospaced)
        case "sf pro rounded", "rounded": self = .system(.rounded)
        default: self = .named(name.trimmingCharacters(in: .whitespaces))
        }
    }
}

/// How the editor draws headings, task boxes and tags, beyond colours and fonts. Every value is optional: what a
/// theme leaves out keeps the editor's own look.
public struct ThemeStyle: Equatable, Sendable {
    public enum Weight: String, Equatable, Sendable, CaseIterable { case regular, medium, semibold, bold, heavy }
    public enum Checkbox: String, Equatable, Sendable, CaseIterable { case circle, square }
    public enum TagShape: String, Equatable, Sendable, CaseIterable { case rounded, capsule }

    /// The family of headings; the body's when unset.
    public var headingFont: ThemeFontFamily?
    public var headingWeight: Weight?
    /// Sizes of `#` to `######` as multiples of the body size, 0.8...4; a shorter list keeps the editor's sizes
    /// for the levels it leaves out.
    public var headingSizes: [Double]?
    /// The heading levels (1...6) drawn with a hairline under them.
    public var headingRules: Set<Int>?
    public var checkbox: Checkbox?
    /// Whether a done task is struck through; it is dimmed either way.
    public var strikeDoneTasks: Bool?
    public var tagShape: TagShape?
    /// Room between letters of the body text in points, -1...3.
    public var letterSpacing: Double?
    /// Room between letters of headings in points, -2...3.
    public var headingLetterSpacing: Double?
    /// Room after each paragraph, as a multiple of the body size, 0...2.
    public var paragraphSpacing: Double?
    /// The corners of the whole app (`shape.corners`): "round" (each view's own), "soft", "square" or "pill".
    public var corners: String?
    /// The family of the app's own text (sidebars, toolbars, cards, menus); the system font when unset.
    public var interfaceFont: ThemeFontFamily?

    public init() {}

    public var isEmpty: Bool { self == ThemeStyle() }
}

public enum ThemeError: Error, Equatable, LocalizedError {
    /// The file is not a theme: not JSON, not an object, or a key with a value of the wrong kind.
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        }
    }
}

/// A theme as written in `.loam/themes/<name>.json` (see docs/THEMES.md). Every key is optional: what a theme does
/// not set keeps the system's look. Unknown keys are ignored, so newer files still load.
public struct Theme: Equatable, Sendable {
    public var name: String
    public var appearance: ThemeAppearance
    /// The colours for the light appearance, and for the dark one where `darkColors` does not override them.
    public var colors: ThemePalette
    /// Overrides of `colors` for the dark appearance.
    public var darkColors: ThemePalette
    public var bodyFont: ThemeFontFamily?
    public var monoFont: ThemeFontFamily?
    /// Body text size in points, 9...40.
    public var fontSize: Double?
    /// Line height as a multiple of the font's, 0.8...3.
    public var lineHeight: Double?
    /// Width of the editor's text column in points, 320...2400.
    public var columnWidth: Double?
    public var style = ThemeStyle()

    public init(
        name: String,
        appearance: ThemeAppearance = .auto,
        colors: ThemePalette = ThemePalette(),
        darkColors: ThemePalette = ThemePalette(),
        bodyFont: ThemeFontFamily? = nil,
        monoFont: ThemeFontFamily? = nil,
        fontSize: Double? = nil,
        lineHeight: Double? = nil,
        columnWidth: Double? = nil
    ) {
        self.name = name
        self.appearance = appearance
        self.colors = colors
        self.darkColors = darkColors
        self.bodyFont = bodyFont
        self.monoFont = monoFont
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.columnWidth = columnWidth
    }

    /// The colours for one appearance: `colors`, with `darkColors` on top when `dark`.
    public func palette(dark: Bool) -> ThemePalette {
        dark ? colors.merging(darkColors) : colors
    }

    /// Whether the window is drawn dark, given whether the system is: `auto` follows it.
    public func isDark(systemIsDark: Bool) -> Bool {
        switch appearance {
        case .light: false
        case .dark: true
        case .auto: systemIsDark
        }
    }

    // MARK: Parsing

    /// Reads a theme file. `fallbackName` (the file name) is used when the file has no `name`.
    /// Throws `ThemeError.invalid` with the offending key when a value has the wrong kind or a colour cannot be read.
    public static func parse(_ data: Data, fallbackName: String) throws -> Theme {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ThemeError.invalid("not valid JSON")
        }
        guard let root = object as? [String: Any] else { throw ThemeError.invalid("the file must hold a JSON object") }

        var theme = Theme(name: fallbackName)
        if let name = try string(root, "name", at: "name"), !name.trimmingCharacters(in: .whitespaces).isEmpty {
            theme.name = name
        }
        if let text = try string(root, "appearance", at: "appearance") {
            guard let appearance = ThemeAppearance(rawValue: text.lowercased()) else {
                throw ThemeError.invalid("\"appearance\" must be \"light\", \"dark\" or \"auto\", not \"\(text)\"")
            }
            theme.appearance = appearance
        }
        theme.colors = try palette(root["colors"], at: "colors")
        if let dark = try section(root, "dark", at: "dark") {
            theme.darkColors = try palette(dark["colors"], at: "dark.colors")
        }
        if let fonts = try section(root, "fonts", at: "fonts") {
            theme.bodyFont = try string(fonts, "body", at: "fonts.body").map(ThemeFontFamily.init)
            theme.monoFont = try string(fonts, "mono", at: "fonts.mono").map(ThemeFontFamily.init)
            theme.fontSize = try number(fonts, "size", at: "fonts.size").map { clamp($0, 9...40) }
            theme.style.letterSpacing = try number(fonts, "letterSpacing", at: "fonts.letterSpacing").map { clamp($0, -1...3) }
            theme.style.interfaceFont = try string(fonts, "interface", at: "fonts.interface").map(ThemeFontFamily.init)
        }
        if let editor = try section(root, "editor", at: "editor") {
            theme.lineHeight = try number(editor, "lineHeight", at: "editor.lineHeight").map { clamp($0, 0.8...3) }
            theme.columnWidth = try number(editor, "columnWidth", at: "editor.columnWidth").map { clamp($0, 320...2400) }
            theme.style.paragraphSpacing = try number(editor, "paragraphSpacing", at: "editor.paragraphSpacing").map { clamp($0, 0...2) }
        }
        if let headings = try section(root, "headings", at: "headings") {
            theme.style.headingFont = try string(headings, "font", at: "headings.font").map(ThemeFontFamily.init)
            theme.style.headingWeight = try choice(headings, "weight", at: "headings.weight")
            theme.style.headingLetterSpacing = try number(headings, "letterSpacing", at: "headings.letterSpacing")
                .map { clamp($0, -2...3) }
            theme.style.headingSizes = try numbers(headings, "sizes", at: "headings.sizes")?.prefix(6).map { clamp($0, 0.8...4) }
            theme.style.headingRules = try numbers(headings, "rules", at: "headings.rules")
                .map { Set($0.map { Int(clamp($0, 1...6)) }) }
        }
        if let tasks = try section(root, "tasks", at: "tasks") {
            theme.style.checkbox = try choice(tasks, "checkbox", at: "tasks.checkbox")
            theme.style.strikeDoneTasks = try bool(tasks, "strikethrough", at: "tasks.strikethrough")
        }
        if let tags = try section(root, "tags", at: "tags") {
            theme.style.tagShape = try choice(tags, "shape", at: "tags.shape")
        }
        if let shape = try section(root, "shape", at: "shape"), let corners = try string(shape, "corners", at: "shape.corners") {
            guard ["round", "soft", "square", "pill"].contains(corners) else {
                throw ThemeError.invalid("\"shape.corners\" must be \"round\", \"soft\", \"square\" or \"pill\", not \"\(corners)\"")
            }
            theme.style.corners = corners
        }
        // Cards, labels, icons, the sidebar's selection and the dither are Loam's own look, the same in every theme
        // (docs/THEMES.md): the keys that once chose them (`cards`, `labels`, `icons`, `sidebar`, `decor`, `home`,
        // `images`) are ignored, so an older theme still opens.
        return theme
    }

    private static func palette(_ value: Any?, at path: String) throws -> ThemePalette {
        guard let value, !(value is NSNull) else { return ThemePalette() }
        guard let map = value as? [String: Any] else { throw ThemeError.invalid("\"\(path)\" must be an object") }
        var palette = ThemePalette()
        for key in ThemePalette.allKeys {
            guard let text = try string(map, key, at: "\(path).\(key)") else { continue }
            guard let color = ThemeColor(hex: text) else {
                throw ThemeError.invalid("\"\(path).\(key)\" is \"\(text)\", not a colour (#RRGGBB or #RRGGBBAA)")
            }
            palette[key] = color
        }
        return palette
    }

    private static func section(_ map: [String: Any], _ key: String, at path: String) throws -> [String: Any]? {
        guard let value = map[key], !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else { throw ThemeError.invalid("\"\(path)\" must be an object") }
        return object
    }

    private static func string(_ map: [String: Any], _ key: String, at path: String) throws -> String? {
        guard let value = map[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw ThemeError.invalid("\"\(path)\" must be a string") }
        return text
    }

    private static func number(_ map: [String: Any], _ key: String, at path: String) throws -> Double? {
        guard let value = map[key], !(value is NSNull) else { return nil }
        // JSONSerialization reads `true` as an NSNumber too.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ThemeError.invalid("\"\(path)\" must be a number")
        }
        return number.doubleValue
    }

    private static func numbers(_ map: [String: Any], _ key: String, at path: String) throws -> [Double]? {
        guard let value = map[key], !(value is NSNull) else { return nil }
        guard let list = value as? [Any] else { throw ThemeError.invalid("\"\(path)\" must be a list of numbers") }
        return try list.map { item in
            guard let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw ThemeError.invalid("\"\(path)\" must be a list of numbers")
            }
            return number.doubleValue
        }
    }

    private static func bool(_ map: [String: Any], _ key: String, at path: String) throws -> Bool? {
        guard let value = map[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ThemeError.invalid("\"\(path)\" must be true or false")
        }
        return number.boolValue
    }

    /// One of the cases of `Choice`, by name.
    private static func choice<Choice: RawRepresentable & CaseIterable>(_ map: [String: Any], _ key: String, at path: String) throws -> Choice?
        where Choice.RawValue == String {
        guard let text = try string(map, key, at: path) else { return nil }
        guard let value = Choice(rawValue: text.lowercased()) else {
            let names = Choice.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            throw ThemeError.invalid("\"\(path)\" must be one of \(names), not \"\(text)\"")
        }
        return value
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
