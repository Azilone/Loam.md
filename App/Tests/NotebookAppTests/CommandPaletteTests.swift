import AppKit
import BuiltinUIPlugins
import Foundation
import SwiftUI
import PluginKitUI
import XCTest
@testable import NotebookApp

/// Counts the runs of its command, so tests can see the palette and the keys run it.
final class RecordingCommandPlugin: UIPlugin {
    static let manifest = PluginManifest(id: "test.recording", name: "Recording", version: "1.0")
    static let calls = Calls()
    /// Whether `test.scoped`'s shortcut applies, as a view with the keyboard would say.
    nonisolated(unsafe) static var scopedKeyApplies = false

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
        func reset() { lock.withLock { count = 0 } }
    }

    init() {}

    @MainActor func activateUI(context: PluginContext) throws {
        let calls = Self.calls
        try context.registerCommand(Command(
            id: "test.record",
            title: "Record a call",
            summary: "Counts how many times it ran, for the palette tests.",
            shortcut: KeyShortcut("k", [.command, .shift])
        ) { _ in
            calls.increment()
            return "Recorded."
        })
        try context.registerCommand(Command(
            id: "test.scoped",
            title: "Scoped key",
            summary: "Counts too, but its shortcut only applies while scopedKeyApplies says so.",
            shortcut: KeyShortcut("up", [.command]),
            isShortcutEnabled: { RecordingCommandPlugin.scopedKeyApplies }
        ) { _ in
            calls.increment()
            return ""
        })
        try context.registerCommand(Command(
            id: "test.view-key",
            title: "View key",
            summary: "Runs from Tab in its own view, which the palette shows.",
            viewKey: KeyShortcut("tab")
        ) { _ in "" })
        try context.registerCommand(Command(
            id: "test.needs-argument",
            title: "Needs an argument",
            summary: "Fails without a name argument, for the palette tests."
        ) { arguments in
            try arguments.require("name")
        })
        try context.registerCommand(Command(
            id: "test.json",
            title: "Returns JSON",
            summary: "Returns a JSON object, which the palette does not show."
        ) { _ in "{\n  \"a\" : 1\n}" })
        try context.registerCommand(Command(
            id: "test.agents-only",
            title: "Agents only",
            summary: "Made for the CLI and agents: the palette leaves it out.",
            isInPalette: false
        ) { _ in "[]" })
    }
}

@MainActor
final class CommandPaletteTests: ShellTestCase {
    override func setUp() async throws {
        try await super.setUp()
        RecordingCommandPlugin.calls.reset()
    }

    private func key(_ text: String) -> KeyShortcut {
        KeyShortcut(parsing: text)!
    }

    private func openPalette(_ session: ShellSession) async throws {
        _ = try await session.run("palette.open")
        XCTAssertTrue(session.quickPick.isPresented)
    }

    func testThePaletteListsCommandsWithTheirShortcuts() async throws {
        let session = try openSession(ui: [ShellTestPlugin.self, RecordingCommandPlugin.self])
        try await openPalette(session)
        let rows = session.quickPick.results
        XCTAssertEqual(session.quickPick.placeholder, "Run a command…")
        XCTAssertFalse(rows.contains { $0.id == "palette.open" }, "the palette does not list itself")
        XCTAssertFalse(rows.contains { $0.id == "test.agents-only" }, "nor the commands made for the CLI and agents")
        XCTAssertNotNil(rows.first { $0.id == "settings.plugins" }, "Manage plugins opens Settings")
        let record = try XCTUnwrap(rows.first { $0.id == "test.record" })
        XCTAssertEqual(record.title, "Record a call")
        XCTAssertEqual(record.subtitle, "Counts how many times it ran, for the palette tests.")
        XCTAssertEqual(record.detail, "⇧⌘K")
        XCTAssertEqual(rows.first { $0.id == "workspace.close-tab" }?.detail, "⌘W")
        XCTAssertNil(rows.first { $0.id == "test.hello" }?.detail)
        // Grouped by plugin, the shell's last, each section sorted by title.
        XCTAssertEqual(rows.last?.section, "Window")
        XCTAssertEqual(record.symbol != nil, true)
        // "Recent" keeps the order commands ran in (other tests run some), so only the plugins' sections are sorted.
        for section in Set(rows.compactMap(\.section)) where section != CommandPalette.recentSection {
            let titles = rows.filter { $0.section == section }.map(\.title)
            XCTAssertEqual(titles, titles.sorted { $0.lowercased() < $1.lowercased() }, section)
        }

        session.quickPick.query = "rec cal"
        XCTAssertEqual(session.quickPick.results.first?.id, "test.record")
        session.quickPick.query = "split-down"
        XCTAssertEqual(session.quickPick.results.first?.id, "workspace.split-down", "ids match too")
    }

    func testChoosingARowRunsTheCommand() async throws {
        let session = try openSession(ui: [ShellTestPlugin.self, RecordingCommandPlugin.self])
        try await openPalette(session)
        session.quickPick.query = "record"
        XCTAssertEqual(session.quickPick.results.first?.id, "test.record")
        session.quickPick.chooseSelected()
        XCTAssertFalse(session.quickPick.isPresented)
        try await waitUntil { RecordingCommandPlugin.calls.value == 1 }
        try await waitUntil { session.commandRunner.toast != nil }
        XCTAssertEqual(session.commandRunner.toast?.text, "Recorded.")
        XCTAssertEqual(session.commandRunner.toast?.kind, .success, "a command that answers is done: a green mark")
    }

    func testOverridesChangeThePaletteDetailAndTheKeys() async throws {
        try write(".loam/config.json", #"{ "version": 1, "shortcuts": { "test.record": "ctrl+opt+r", "workspace.close-tab": "" } }"#)
        let session = try openSession(ui: [ShellTestPlugin.self, RecordingCommandPlugin.self])
        try await openPalette(session)
        XCTAssertEqual(session.quickPick.results.first { $0.id == "test.record" }?.detail, "⌃⌥R")
        XCTAssertNil(session.quickPick.results.first { $0.id == "workspace.close-tab" }?.detail)
        session.quickPick.dismiss()

        XCTAssertNil(session.commandID(forKey: key("shift+cmd+k")))
        XCTAssertNil(session.commandID(forKey: key("cmd+w")))
        XCTAssertTrue(session.handleKey(key("ctrl+opt+r")))
        try await waitUntil { RecordingCommandPlugin.calls.value == 1 }
    }

    func testKeysRunCommandsExceptWhileTheQuickPickIsUp() async throws {
        let session = try openSession(ui: [ShellTestPlugin.self, RecordingCommandPlugin.self])
        XCTAssertEqual(session.commandID(forKey: key("cmd+p")), "palette.open")
        XCTAssertEqual(session.commandID(forKey: key("ctrl+tab")), "workspace.next-tab")
        XCTAssertFalse(session.handleKey(key("cmd+j")))
        XCTAssertTrue(session.handleKey(key("shift+cmd+k")))
        try await waitUntil { RecordingCommandPlugin.calls.value == 1 }

        session.showPalette()
        XCTAssertNil(session.commandID(forKey: key("shift+cmd+k")))
        XCTAssertFalse(session.handleKey(key("shift+cmd+k")))
    }

    func testAShortcutThatDoesNotApplyLeavesTheKeyToTheFocusedView() async throws {
        RecordingCommandPlugin.scopedKeyApplies = false
        defer { RecordingCommandPlugin.scopedKeyApplies = false }
        let session = try openSession(ui: [ShellTestPlugin.self, RecordingCommandPlugin.self])
        XCTAssertEqual(session.commandID(forKey: key("cmd+up")), "test.scoped")
        XCTAssertFalse(session.handleKey(key("cmd+up")), "the caret keeps ⌘↑")
        RecordingCommandPlugin.scopedKeyApplies = true
        XCTAssertTrue(session.handleKey(key("cmd+up")))
        try await waitUntil { RecordingCommandPlugin.calls.value == 1 }

        // The palette runs it whatever the key says.
        RecordingCommandPlugin.scopedKeyApplies = false
        try await openPalette(session)
        XCTAssertEqual(session.quickPick.results.first { $0.id == "test.scoped" }?.detail, "⌘↑")
        session.quickPick.query = "scoped key"
        session.quickPick.chooseSelected()
        try await waitUntil { RecordingCommandPlugin.calls.value == 2 }
    }

    func testAViewsOwnKeyIsShownButNeverBound() async throws {
        try write(".loam/config.json", #"{ "version": 1, "shortcuts": { "test.view-key": "" } }"#)
        let session = try openSession(ui: [ShellTestPlugin.self, RecordingCommandPlugin.self])
        XCTAssertNil(session.commandID(forKey: key("tab")), "the shell leaves Tab to the view")
        XCTAssertNil(session.shortcutTable().shortcut(for: "test.view-key"))
        try await openPalette(session)
        XCTAssertEqual(session.quickPick.results.first { $0.id == "test.view-key" }?.detail, "⇥",
                       "the palette shows the key, which no override removes")
    }

    func testClosingThePickerGivesTheKeyboardBack() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let map = FocusableView()
        let field = FocusableView()
        window.contentView?.addSubview(map)
        window.contentView?.addSubview(field)
        let focus = PickerFocus()

        window.makeFirstResponder(map)
        focus.shown(in: window)
        window.makeFirstResponder(nil)
        focus.hidden(in: window)
        try await waitUntil { window.firstResponder === map }

        // Unless something took the keyboard meanwhile.
        focus.shown(in: window)
        window.makeFirstResponder(field)
        focus.hidden(in: window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(window.firstResponder === field)
    }

    func testCmdOReachesTheQuickSwitcher() async throws {
        let session = try openSession(ui: builtinUIPlugins)
        XCTAssertEqual(session.shortcutTable().command(for: key("cmd+o")), "switcher.open")
        XCTAssertTrue(session.shortcutTable().conflicts.isEmpty, "\(session.shortcutTable().conflicts)")
        XCTAssertTrue(session.handleKey(key("cmd+o")))
        try await waitUntil { session.quickPick.isPresented }
        XCTAssertEqual(session.quickPick.placeholder, "Open a note…")
    }

    func testRunnerExplainsMissingArgumentsAndErrors() async throws {
        let session = try openSession(ui: [ShellTestPlugin.self, RecordingCommandPlugin.self])
        await session.commandRunner.run("test.needs-argument").value
        XCTAssertEqual(
            session.commandRunner.toast?.text,
            "“Needs an argument” needs arguments (name); run it from the loam command line."
        )
        XCTAssertEqual(session.commandRunner.toast?.isError, true)

        session.commandRunner.dismissToast()
        await session.commandRunner.run("test.json").value
        XCTAssertNil(session.commandRunner.toast, "JSON is for the CLI, not a toast")

        await session.commandRunner.run("nope.missing").value
        XCTAssertEqual(session.commandRunner.toast?.isError, true)
    }

    func testToastGoesAway() async throws {
        let runner = CommandRunner(toastDuration: .milliseconds(20)) { _ in nil }
        runner.show("Hello", isError: false)
        XCTAssertEqual(runner.toast?.text, "Hello")
        try await waitUntil { runner.toast == nil }
    }

    func testTheWindowRendersThePaletteAndAToast() async throws {
        let session = try openSession(ui: [ShellTestPlugin.self, RecordingCommandPlugin.self])
        try await openPalette(session)
        session.commandRunner.show("Something happened.", isError: true)
        let size = CGSize(width: 900, height: 600)
        let hosting = NSHostingView(rootView: ShellWindow(session: session))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.frame.size, size)
        window.close()
    }

    func testOutputWorthAToast() {
        XCTAssertEqual(CommandRunner.message(for: "  Done.\n"), "Done.")
        XCTAssertNil(CommandRunner.message(for: ""))
        XCTAssertNil(CommandRunner.message(for: "[1, 2]"))
        XCTAssertNil(CommandRunner.message(for: "{\n  \"notes\" : 80\n}"))
        XCTAssertEqual(CommandRunner.message(for: #"{ "message" : "Up to date.", "ahead" : 0 }"#), "Up to date.")
        XCTAssertNil(CommandRunner.message(for: "a\nb\nc\nd"))
        XCTAssertNil(CommandRunner.message(for: String(repeating: "x", count: 300)))
    }
}

/// A view that takes the keyboard, as a note's text or a mindmap does.
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
