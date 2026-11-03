import AppKit
import PluginKit
import XCTest
@testable import NotebookApp

final class ShortcutTableTests: XCTestCase {
    private func command(_ id: String, _ shortcut: String? = nil) -> Command {
        Command(id: id, title: id, summary: "A test command.", shortcut: shortcut.flatMap(KeyShortcut.init(parsing:))) { _ in "" }
    }

    private func key(_ text: String) -> KeyShortcut {
        KeyShortcut(parsing: text)!
    }

    func testDefaultsAreBound() {
        let table = ShortcutTable(commands: [command("a.one", "cmd+k"), command("a.two")], overrides: [:])
        XCTAssertEqual(table.command(for: key("cmd+k")), "a.one")
        XCTAssertEqual(table.shortcut(for: "a.one"), key("cmd+k"))
        XCTAssertNil(table.shortcut(for: "a.two"))
        XCTAssertNil(table.command(for: key("cmd+j")))
        XCTAssertTrue(table.conflicts.isEmpty)
    }

    func testOverridesReplaceAndEmptyRemoves() {
        let table = ShortcutTable(
            commands: [command("a.one", "cmd+k"), command("a.two", "cmd+j"), command("a.three")],
            overrides: ["a.one": "Shift+Command+K", "a.two": "", "a.three": "ctrl+opt+t", "gone.plugin": "cmd+g"]
        )
        XCTAssertEqual(table.shortcut(for: "a.one"), key("shift+cmd+k"))
        XCTAssertNil(table.command(for: key("cmd+k")))
        XCTAssertNil(table.shortcut(for: "a.two"))
        XCTAssertNil(table.command(for: key("cmd+j")))
        XCTAssertEqual(table.command(for: key("opt+ctrl+t")), "a.three")
        XCTAssertNil(table.command(for: key("cmd+g")), "overrides of unregistered commands are ignored")
    }

    func testInvalidOverridesAreIgnoredAndListed() {
        let table = ShortcutTable(
            commands: [command("a.one", "cmd+k")],
            overrides: ["a.one": "hyper+k"]
        )
        XCTAssertEqual(table.shortcut(for: "a.one"), key("cmd+k"), "the default stays")
        XCTAssertEqual(table.invalidOverrides, ["a.one": "hyper+k"])
    }

    func testReservedShortcutsAreRefused() {
        let table = ShortcutTable(
            commands: [command("a.copy", "cmd+c"), command("a.undo"), command("a.close", "cmd+w")],
            overrides: ["a.undo": "shift+cmd+z"]
        )
        XCTAssertNil(table.command(for: key("cmd+c")))
        XCTAssertNil(table.command(for: key("shift+cmd+z")))
        XCTAssertNil(table.shortcut(for: "a.copy"))
        XCTAssertEqual(table.refused, ["a.copy": key("cmd+c"), "a.undo": key("shift+cmd+z")])
        XCTAssertEqual(table.command(for: key("cmd+w")), "a.close", "Cmd+W is not reserved")
        for text in ["cmd+z", "shift+cmd+z", "cmd+x", "cmd+c", "cmd+v", "cmd+a", "cmd+f", "cmd+q", "cmd+h", "cmd+m", "cmd+,"] {
            XCTAssertTrue(ShortcutTable.reserved.contains(key(text)), text)
        }
        XCTAssertEqual(ShortcutTable.reserved.count, 11)
    }

    func testConflictsAreDeterministic() {
        let commands = [command("z.last", "cmd+k"), command("a.first", "cmd+k"), command("m.middle")]
        for order in [commands, commands.reversed()] {
            let table = ShortcutTable(commands: order, overrides: ["m.middle": "cmd+k"])
            XCTAssertEqual(table.command(for: key("cmd+k")), "a.first")
            XCTAssertEqual(table.conflicts, [key("cmd+k"): ["a.first", "m.middle", "z.last"]])
            XCTAssertEqual(table.shortcut(for: "a.first"), key("cmd+k"))
            XCTAssertNil(table.shortcut(for: "z.last"), "the loser has no working shortcut")
            XCTAssertEqual(table.assigned["z.last"], key("cmd+k"), "but its choice is still known")
        }
    }

    func testDisplayStrings() {
        XCTAssertEqual(key("shift+cmd+k").displayString, "⇧⌘K")
        XCTAssertEqual(key("cmd+p").displayString, "⌘P")
        XCTAssertEqual(key("ctrl+tab").displayString, "⌃⇥")
        XCTAssertEqual(key("ctrl+shift+tab").displayString, "⌃⇧⇥")
        XCTAssertEqual(key("ctrl+opt+shift+cmd+return").displayString, "⌃⌥⇧⌘↩")
        XCTAssertEqual(key("cmd+,").displayString, "⌘,")
        XCTAssertEqual(key("opt+left").displayString, "⌥←")
        XCTAssertEqual(key("cmd+f5").displayString, "⌘F5")
        XCTAssertEqual(key("cmd+space").displayString, "⌘Space")
    }

    @MainActor
    func testShortcutFromEvent() throws {
        func event(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )!
        }
        XCTAssertEqual(KeyShortcut(event: event("o", .command)), key("cmd+o"))
        XCTAssertEqual(KeyShortcut(event: event("K", [.command, .shift])), key("shift+cmd+k"))
        XCTAssertEqual(KeyShortcut(event: event("\t", .control, keyCode: 48)), key("ctrl+tab"))
        XCTAssertEqual(KeyShortcut(event: event("\u{19}", [.control, .shift], keyCode: 48)), key("ctrl+shift+tab"))
        XCTAssertEqual(KeyShortcut(event: event("\u{F702}", [.option, .function], keyCode: 123)), key("opt+left"))
        XCTAssertEqual(KeyShortcut(event: event("\r", .command, keyCode: 36)), key("cmd+return"))
        // Shift with an arrow: AppKit's unshifted characters are control codes, the key is still the arrow.
        XCTAssertEqual(KeyShortcut(event: event("\u{F702}", [.shift, .option, .command, .function], keyCode: 123)),
                       key("opt+shift+cmd+left"))
    }

    @MainActor
    func testShortcutFromMenuItem() {
        let item = NSMenuItem(title: "Palette", action: nil, keyEquivalent: "p")
        XCTAssertEqual(KeyShortcut(menuItem: item), key("cmd+p"))
        item.keyEquivalent = "O"
        XCTAssertEqual(KeyShortcut(menuItem: item), key("shift+cmd+o"))
        item.keyEquivalent = "w"
        item.keyEquivalentModifierMask = [.command, .option]
        XCTAssertEqual(KeyShortcut(menuItem: item), key("opt+cmd+w"))
        item.keyEquivalent = ""
        XCTAssertNil(KeyShortcut(menuItem: item))

        let menu = NSMenu()
        let submenu = NSMenu()
        let parent = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
        let close = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        submenu.addItem(close)
        menu.autoenablesItems = false
        submenu.autoenablesItems = false
        XCTAssertTrue(KeyMonitor.menu(menu, hasEnabledItemFor: key("cmd+w")))
        XCTAssertFalse(KeyMonitor.menu(menu, hasEnabledItemFor: key("cmd+o")))
        close.isEnabled = false
        XCTAssertFalse(KeyMonitor.menu(menu, hasEnabledItemFor: key("cmd+w")))
    }
}
