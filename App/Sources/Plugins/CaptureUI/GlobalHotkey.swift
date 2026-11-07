import AppKit
import Carbon.HIToolbox
import PluginKit

/// A shortcut that works whatever app is in front: Carbon's `RegisterEventHotKey`, which needs no Accessibility or
/// Input Monitoring permission (an `NSEvent` global monitor would). One per plugin; registering again replaces it.
@MainActor
final class GlobalHotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    /// The shortcut registered now, nil when none or when the system refused it (taken by another app).
    private(set) var current: KeyShortcut?

    /// Registers `shortcut`; returns false when the system refuses it.
    @discardableResult
    func register(_ shortcut: KeyShortcut?, action: @escaping () -> Void) -> Bool {
        unregister()
        guard let shortcut, let code = Self.keyCode(shortcut.key) else { return false }
        self.action = action
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
                guard let data else { return noErr }
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(data).takeUnretainedValue()
                MainActor.assumeIsolated { hotkey.action?() }
                return noErr
            }, 1, &type, me, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4C4F_414D), id: 1) // "LOAM"
        let status = RegisterEventHotKey(code, Self.carbonModifiers(shortcut.modifiers), id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else {
            reference = nil
            return false
        }
        current = shortcut
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        current = nil
    }

    func tearDown() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        action = nil
    }

    static func carbonModifiers(_ modifiers: Set<KeyShortcut.Modifier>) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    /// The virtual key code of a key name (`space`, `k`, `1`), on a US layout.
    static func keyCode(_ key: String) -> UInt32? {
        let named: [String: Int] = [
            "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "delete": kVK_Delete,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            ".": kVK_ANSI_Period, ",": kVK_ANSI_Comma, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
            "`": kVK_ANSI_Grave, "\\": kVK_ANSI_Backslash,
        ]
        return named[key.lowercased()].map(UInt32.init)
    }

    /// Reads a shortcut as menus print it (`⌃⌥Space`, `⇧⌘K`), which is what `CommandLauncher.shortcut(for:)` gives.
    static func shortcut(display: String) -> KeyShortcut? {
        var modifiers: Set<KeyShortcut.Modifier> = []
        var rest = Substring(display)
        let symbols: [Character: KeyShortcut.Modifier] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        while let first = rest.first, let modifier = symbols[first] {
            modifiers.insert(modifier)
            rest = rest.dropFirst()
        }
        let names: [String: String] = ["Space": "space", "↩": "return", "⇥": "tab", "⎋": "escape", "⌫": "delete",
                                       "↑": "up", "↓": "down", "←": "left", "→": "right"]
        let key = names[String(rest)] ?? rest.lowercased()
        guard !key.isEmpty else { return nil }
        return KeyShortcut(key, modifiers)
    }
}
