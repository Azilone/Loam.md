import PluginKit

/// Which command each keyboard shortcut runs: the commands' default shortcuts with the user's overrides from
/// `.loam/config.json` applied. A pure value, rebuilt whenever it is needed (it is cheap): the key monitor builds one
/// per key press, the palette one per opening, the settings window one per change.
///
/// - An override replaces the default; an empty override (`""`) removes it. An override that does not parse is
///   ignored (the default stays) and listed in `invalidOverrides`. Overrides for commands that are not registered
///   (a disabled plugin) are kept out of the table.
/// - A reserved shortcut (`ShortcutTable.reserved`: undo, copy, quit…) is never bound; a command asking for one is
///   listed in `refused`.
/// - When several commands want one shortcut, the first id in sort order gets it; all of them are listed in
///   `conflicts`.
public struct ShortcutTable: Sendable, Equatable {
    /// Standard editing and system shortcuts no command may take. Cmd+W is not one: the shell's close-tab uses it.
    public static let reserved: Set<KeyShortcut> = Set([
        "cmd+z", "shift+cmd+z", "cmd+x", "cmd+c", "cmd+v", "cmd+a", "cmd+f", "cmd+q", "cmd+h", "cmd+m", "cmd+,",
    ].compactMap(KeyShortcut.init(parsing:)))

    /// Command id to the shortcut it asks for, after overrides, without reserved ones. Includes the commands that
    /// lose a conflict: this is what a settings screen shows.
    public let assigned: [String: KeyShortcut]
    /// Shortcuts more than one command asks for, to the ids asking (sorted; the first one wins).
    public let conflicts: [KeyShortcut: [String]]
    /// Command id to the reserved shortcut it asked for and did not get.
    public let refused: [String: KeyShortcut]
    /// Command id to an override text that is not a shortcut.
    public let invalidOverrides: [String: String]

    private let byShortcut: [KeyShortcut: String]

    public init(commands: [Command], overrides: [String: String], reserved: Set<KeyShortcut> = ShortcutTable.reserved) {
        var assigned: [String: KeyShortcut] = [:]
        var refused: [String: KeyShortcut] = [:]
        var invalid: [String: String] = [:]
        for command in commands {
            var shortcut = command.shortcut
            if let text = overrides[command.id] {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    shortcut = nil
                } else if let parsed = KeyShortcut(parsing: trimmed) {
                    shortcut = parsed
                } else {
                    invalid[command.id] = text
                }
            }
            guard let shortcut else { continue }
            if reserved.contains(shortcut) {
                refused[command.id] = shortcut
            } else {
                assigned[command.id] = shortcut
            }
        }

        var claimants: [KeyShortcut: [String]] = [:]
        for (id, shortcut) in assigned { claimants[shortcut, default: []].append(id) }
        for key in claimants.keys { claimants[key]?.sort() }

        self.assigned = assigned
        self.refused = refused
        self.invalidOverrides = invalid
        self.conflicts = claimants.filter { $0.value.count > 1 }
        self.byShortcut = claimants.compactMapValues(\.first)
    }

    /// The command a shortcut runs, if any.
    public func command(for shortcut: KeyShortcut) -> String? {
        byShortcut[shortcut]
    }

    /// The shortcut that runs a command: nil when it has none, or when it loses a conflict.
    public func shortcut(for commandID: String) -> KeyShortcut? {
        guard let shortcut = assigned[commandID], byShortcut[shortcut] == commandID else { return nil }
        return shortcut
    }
}
