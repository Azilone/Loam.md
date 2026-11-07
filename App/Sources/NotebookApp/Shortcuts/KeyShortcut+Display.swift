import PluginKit

extension KeyShortcut {
    /// The named keys a shortcut can use besides single characters, as `KeyShortcut.key` spells them.
    static let namedKeys: [String: String] = [
        "return": "↩", "enter": "⌤", "tab": "⇥", "space": "Space", "delete": "⌫", "forwarddelete": "⌦",
        "escape": "⎋", "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘",
        "pageup": "⇞", "pagedown": "⇟",
    ]

    /// The form menus show, for example `⇧⌘K`, `⌃⇥` or `⌘,`.
    public var displayString: String {
        let symbols: [Modifier: String] = [.control: "⌃", .option: "⌥", .shift: "⇧", .command: "⌘"]
        let modifierText = Modifier.canonicalOrder.filter(modifiers.contains).compactMap { symbols[$0] }.joined()
        // Letters and function keys (`f5`) print in capitals, as menus show them.
        let keyText = Self.namedKeys[key] ?? key.uppercased()
        return modifierText + keyText
    }
}
