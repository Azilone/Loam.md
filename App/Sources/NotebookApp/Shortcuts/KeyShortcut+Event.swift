import AppKit
import PluginKit

extension KeyShortcut {
    /// The shortcut of a key press, or nil for a key with no name (a bare modifier, a dead key).
    public init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Set<Modifier> = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        var characters = event.charactersIgnoringModifiers ?? ""
        // Shift is a modifier, not part of the key: Shift-Cmd-/ is `shift+cmd+/`, not `shift+cmd+?`.
        // Function keys (arrows, Home, F-keys) report private-use characters, and the unshifted ones are control codes.
        if modifiers.contains(.shift), let first = characters.first, !first.isLetter,
           !(0xF700...0xF8FF).contains(first.unicodeScalars.first?.value ?? 0),
           let unshifted = event.characters(byApplyingModifiers: []), unshifted.count == 1 {
            characters = unshifted
        }
        guard let key = Self.keyName(characters) else { return nil }
        self.init(key, modifiers)
    }

    /// The shortcut of a menu item's key equivalent, or nil when it has none.
    init?(menuItem: NSMenuItem) {
        let equivalent = menuItem.keyEquivalent
        guard !equivalent.isEmpty, let key = Self.keyName(equivalent) else { return nil }
        let flags = menuItem.keyEquivalentModifierMask
        var modifiers: Set<Modifier> = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) || equivalent != equivalent.lowercased() { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self.init(key, modifiers)
    }

    /// `KeyShortcut.key` for the characters AppKit reports: a lowercase character, or a named key.
    static func keyName(_ characters: String) -> String? {
        guard characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x0D: return "return"
        case 0x03: return "enter"
        case 0x09, 0x19: return "tab"  // Shift-Tab reports backtab
        case 0x20: return "space"
        case 0x08, 0x7F: return "delete"
        case 0x1B: return "escape"
        case 0xF700: return "up"
        case 0xF701: return "down"
        case 0xF702: return "left"
        case 0xF703: return "right"
        case 0xF704...0xF70F: return "f\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "forwarddelete"
        case 0xF729: return "home"
        case 0xF72B: return "end"
        case 0xF72C: return "pageup"
        case 0xF72D: return "pagedown"
        case 0xF700...0xF8FF: return nil  // other function keys
        default:
            guard !CharacterSet.controlCharacters.contains(scalar) else { return nil }
            return characters.lowercased()
        }
    }
}
