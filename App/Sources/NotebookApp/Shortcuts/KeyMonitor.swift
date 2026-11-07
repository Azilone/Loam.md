import AppKit
import PluginKit

/// Runs commands from their keyboard shortcuts while a vault window is open: a local key-down monitor that looks
/// the key up and swallows the event when a command took it.
///
/// It only looks at key presses for its window that carry Command or Control (so typing is never affected), and
/// leaves a key to the menu bar when an enabled menu item has the same key equivalent: the menus call the same
/// commands, and standard items (Close, New Note, the palette's own Cmd+P) keep working as menus do.
@MainActor
final class KeyMonitor {
    /// The window whose key presses are looked at; others (settings, panels, alerts) are left alone.
    weak var window: NSWindow?
    private var handle: (@MainActor (KeyShortcut) -> Bool)?
    private var token: Any?

    init() {}

    /// Starts looking at key presses. `handle` returns true when it ran a command for the shortcut.
    func start(handle: @escaping @MainActor (KeyShortcut) -> Bool) {
        self.handle = handle
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.process(event) ?? false }
            return handled ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        handle = nil
    }

    private func process(_ event: NSEvent) -> Bool {
        guard let handle, let window, event.window === window else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) else { return false }
        guard let shortcut = KeyShortcut(event: event) else { return false }
        if let menu = NSApp.mainMenu, Self.menu(menu, hasEnabledItemFor: shortcut) { return false }
        return handle(shortcut)
    }

    static func menu(_ menu: NSMenu, hasEnabledItemFor shortcut: KeyShortcut) -> Bool {
        menu.update()
        for item in menu.items {
            if let submenu = item.submenu {
                if Self.menu(submenu, hasEnabledItemFor: shortcut) { return true }
            } else if item.isEnabled, !item.isHidden, KeyShortcut(menuItem: item) == shortcut {
                return true
            }
        }
        return false
    }
}
