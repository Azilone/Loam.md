import AppKit
import Observation
import SwiftUI

/// A colour per folder: the one the user picked, else one picked from its name, so each folder keeps its own as in
/// Craft's sidebar.
public enum FolderTint {
    public static let colors: [Color] = [
        Color(.sRGB, red: 0.42, green: 0.45, blue: 0.94),
        Color(.sRGB, red: 0.94, green: 0.63, blue: 0.13),
        Color(.sRGB, red: 0.18, green: 0.70, blue: 0.42),
        Color(.sRGB, red: 0.18, green: 0.38, blue: 0.88),
        Color(.sRGB, red: 0.90, green: 0.28, blue: 0.30),
        Color(.sRGB, red: 0.84, green: 0.55, blue: 0.96),
    ]

    /// The colours a folder can be given, in the order of Craft's colour picker.
    public static let palette: [String] = [
        "#232326", "#58585E", "#A1A1A8", "#A62FC2", "#6C22E0", "#2B40BF",
        "#2F66F6", "#3F96BF", "#2F7C72", "#3E9E6A", "#5BC75F", "#8CC93C",
        "#E8B03A", "#DD7A2C", "#E65A2A", "#D8322A", "#D93279",
    ]

    @MainActor
    public static func color(for path: String) -> Color {
        if let hex = FolderStyles.shared.custom[path]?.color, let color = color(hex: hex) { return color }
        return hashed(path)
    }

    /// The colour the user gave `path`, if any.
    @MainActor
    public static func custom(for path: String) -> Color? {
        FolderStyles.shared.custom[path]?.color.flatMap(color(hex:))
    }

    /// The colour picked from the name alone.
    public static func hashed(_ path: String) -> Color {
        // A stable hash: `hashValue` changes from one launch to the next.
        let sum = path.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return colors[sum % colors.count]
    }

    public static func color(hex: String) -> Color? {
        ThemeColor(hex: hex).map(Color.init)
    }
}

/// What the user gave a folder: an icon (an SF Symbol name or an emoji) and a colour (`#RRGGBB`); nil keeps the
/// default.
public struct FolderStyle: Codable, Equatable, Hashable, Sendable {
    public var icon: String?
    public var color: String?

    public init(icon: String? = nil, color: String? = nil) {
        self.icon = icon
        self.color = color
    }

    public var isEmpty: Bool { icon == nil && color == nil }
}

/// A folder's icon as drawn.
public enum FolderIcon: Equatable, Sendable {
    case symbol(String)
    case emoji(String)

    /// An emoji when `text` is one character drawn as an emoji, else an SF Symbol name.
    public init(_ text: String) {
        self = Self.isEmoji(text) ? .emoji(text) : .symbol(text)
    }

    public static func isEmoji(_ text: String) -> Bool {
        guard text.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation || text.unicodeScalars.count > 1 && scalar.properties.isEmoji
    }
}

/// The folders' icons and colours for every view that draws a folder: the ones the user picked (kept by the file
/// explorer in its settings) and the ones plugins give the folders they own (`FolderIcons`). One vault is open at a
/// time, so one store serves the window, as `DragSession` does.
@MainActor
@Observable
public final class FolderStyles {
    public static let shared = FolderStyles()

    /// The user's picks, by folder path.
    public var custom: [String: FolderStyle] = [:]
    /// The SF Symbols plugins give their folders, by path.
    public var pluginSymbols: [String: String] = [:]

    public init() {}

    /// The icon of `path`: the user's, else the plugin's, else `fallback` (a folder, or the collection it opens as).
    public func icon(for path: String, fallback: String) -> FolderIcon {
        if let icon = custom[path]?.icon { return FolderIcon(icon) }
        if let symbol = pluginSymbols[path] { return .symbol(symbol) }
        return .symbol(fallback)
    }
}

/// A folder's icon in its colour: an SF Symbol tinted, or an emoji as it is.
public struct FolderIconView: View {
    let icon: FolderIcon
    let color: Color
    /// Nil: the font around it.
    let size: CGFloat?
    /// On a filled sidebar selection: drawn white, whatever its colour, so it stays visible on the accent.
    let onAccent: Bool
    @Environment(\.themeTokens) private var theme

    public init(_ icon: FolderIcon, color: Color, size: CGFloat? = nil) {
        self.init(icon, color: color, size: size, onAccent: false)
    }

    public init(_ icon: FolderIcon, color: Color, size: CGFloat? = nil, onAccent: Bool) {
        self.icon = icon
        self.color = color
        self.size = size
        self.onAccent = onAccent
    }

    public var body: some View {
        switch icon {
        case .symbol(let name):
            Image(symbol: name)
                .font(size.map { .ui(size: $0) })
                // Icons are drawn in the text's colours: a folder's own colour does not tint its symbol.
                .foregroundStyle(onAccent ? .white.opacity(0.9) : theme.secondaryText)
                .contentTransition(.symbolEffect(.replace.downUp))
        case .emoji(let emoji):
            if let size {
                ThemedEmoji(emoji: emoji, size: size, ink: onAccent ? .white : nil)
            } else {
                // The font around it: an emoji in a row of the sidebar, at its text's size.
                ThemedEmoji(emoji: emoji, size: SidebarStyle.fontSize, ink: onAccent ? .white : nil)
            }
        }
    }
}
