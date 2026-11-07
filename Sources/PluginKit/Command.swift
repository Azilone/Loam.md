import Foundation

/// A unit of behaviour registered once and exposed everywhere: the command palette,
/// the CLI, the AI assistant's tools and a future MCP server.
public struct Command: Sendable {
    public let id: String
    public let title: String
    public let summary: String
    /// The default shortcut. The user's choice in `.loam/config.json` overrides it.
    public let shortcut: KeyShortcut?
    /// Whether the shortcut applies now, asked by the shell before a key press runs the command: when it says no,
    /// the key goes on to the focused view. So a view's own shortcut (the mindmap's ⌘↑, while the map has the
    /// keyboard) never takes the key from the others (the caret's ⌘↑ in a note). Nil: always. The palette, the CLI
    /// and agents run the command whatever it says.
    public let isShortcutEnabled: (@MainActor @Sendable () -> Bool)?
    /// A key the command's own view handles while it has the keyboard (the mindmap's Tab adds a child), shown by the
    /// palette next to the command. It is not a shortcut: the shell never binds it and `.loam/config.json` cannot
    /// change it.
    public let viewKey: KeyShortcut?
    /// False for a command made for the CLI and agents: it needs arguments, or answers with data (JSON) the palette
    /// cannot show. The palette leaves it out; the CLI and agents still run it.
    public let isInPalette: Bool
    public let handler: @Sendable ([String: String]) async throws -> String

    public init(
        id: String,
        title: String,
        summary: String,
        shortcut: KeyShortcut? = nil,
        isShortcutEnabled: (@MainActor @Sendable () -> Bool)? = nil,
        viewKey: KeyShortcut? = nil,
        handler: @escaping @Sendable ([String: String]) async throws -> String
    ) {
        self.init(
            id: id, title: title, summary: summary, shortcut: shortcut, isShortcutEnabled: isShortcutEnabled,
            viewKey: viewKey, isInPalette: true, handler: handler
        )
    }

    /// `isInPalette` has no default, so a call without it keeps using the initializer above: plugins built against
    /// an older app still load.
    public init(
        id: String,
        title: String,
        summary: String,
        shortcut: KeyShortcut? = nil,
        isShortcutEnabled: (@MainActor @Sendable () -> Bool)? = nil,
        viewKey: KeyShortcut? = nil,
        isInPalette: Bool,
        handler: @escaping @Sendable ([String: String]) async throws -> String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.shortcut = shortcut
        self.isShortcutEnabled = isShortcutEnabled
        self.viewKey = viewKey
        self.isInPalette = isInPalette
        self.handler = handler
    }
}

public enum CommandError: Error, Equatable {
    case duplicate(id: String)
    case missingArgument(name: String)
}

public extension Dictionary where Key == String, Value == String {
    /// A required command argument, or a `CommandError.missingArgument`.
    func require(_ name: String) throws -> String {
        guard let value = self[name], !value.isEmpty else { throw CommandError.missingArgument(name: name) }
        return value
    }
}

public enum JSON {
    /// Pretty, key-sorted JSON: the output format commands return to the CLI and the AI tools.
    public static func string<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public protocol CommandRegistry: AnyObject {
    func register(_ command: Command, owner: String) throws
    func unregister(id: String)
    func command(id: String) -> Command?
    var all: [Command] { get }
}
