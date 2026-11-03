import Foundation

/// A keyboard shortcut such as `shift+cmd+o`, stored as that text in `.loam/config.json`.
///
/// The text form lists the modifiers in one canonical order, the order macOS menus show them
/// (Control, Option, Shift, Command), so two spellings of one shortcut compare and print the same:
/// `cmd+shift+o` and `Shift+Command+O` both become `shift+cmd+o`.
public struct KeyShortcut: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Modifier: String, Codable, Sendable, CaseIterable {
        case command, shift, option, control

        /// The order modifiers are written in.
        public static let canonicalOrder: [Modifier] = [.control, .option, .shift, .command]

        /// The short name used in the text form.
        public var token: String {
            switch self {
            case .control: return "ctrl"
            case .option: return "opt"
            case .shift: return "shift"
            case .command: return "cmd"
            }
        }

        /// Accepts the short and long names, and `alt` for Option. Expects lowercase.
        init?(token: String) {
            switch token {
            case "cmd", "command": self = .command
            case "shift": self = .shift
            case "opt", "option", "alt": self = .option
            case "ctrl", "control": self = .control
            default: return nil
            }
        }
    }

    /// A lowercase character (`k`, `,`, `+`) or a named key (`return`, `left`, `space`). Lowercase so that
    /// `K` and `k` are the same shortcut: Shift is always written as a modifier.
    public let key: String
    public let modifiers: Set<Modifier>

    public init(_ key: String, _ modifiers: Set<Modifier> = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Parses `cmd+shift+k`, in any case and modifier order. Returns nil for an empty key, an unknown
    /// modifier, or a modifier used as the key (`cmd+shift`). `cmd++` is Command and the `+` key.
    public init?(parsing text: String) {
        var parts = text.lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let key: String
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            key = "+"
            parts.removeLast(2)
        } else {
            key = parts.removeLast()
        }
        guard !key.isEmpty, Modifier(token: key) == nil else { return nil }
        var modifiers: Set<Modifier> = []
        for part in parts {
            guard let modifier = Modifier(token: part) else { return nil }
            modifiers.insert(modifier)
        }
        self.init(key, modifiers)
    }

    /// The canonical text form, for example `ctrl+opt+shift+cmd+k`. `KeyShortcut(parsing:)` reads it back.
    public var description: String {
        (Modifier.canonicalOrder.filter(modifiers.contains).map(\.token) + [key]).joined(separator: "+")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let shortcut = KeyShortcut(parsing: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a shortcut: \(text)")
        }
        self = shortcut
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
