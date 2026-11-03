import PluginKit
import PluginKitUI

/// The command palette (Cmd+P): every registered command in the quick pick, with its shortcut on the right (or the
/// key its view handles, `Command.viewKey`). With nothing typed, the commands run lately come first under "Recent",
/// then every command under the plugin that registered it; typing ranks them all by fuzzy title (or id). Commands
/// made for the CLI and agents (`Command.isInPalette` false) are left out. Choosing a row runs the command through
/// the `CommandRunner`.
enum CommandPalette {
    static let commandID = "palette.open"
    static let recentSection = "Recent"

    /// Where a command is listed and the symbol of its row: its plugin's name and icon.
    struct Placement: Equatable {
        let section: String
        let symbol: String
    }

    /// The shell's own commands: listed under "Window", each with its symbol.
    static let shellSection = "Window"
    static let shellSymbols: [String: String] = [
        "workspace.new-tab": "plus.square.on.square",
        "workspace.close-tab": "xmark",
        "workspace.split-right": "rectangle.split.2x1",
        "workspace.split-down": "rectangle.split.1x2",
        "workspace.next-tab": "chevron.right.2",
        "workspace.previous-tab": "chevron.left.2",
        "sidebar.toggle-leading": "sidebar.left",
        "sidebar.toggle-trailing": "sidebar.right",
        "settings.open": "gearshape",
        "settings.plugins": "puzzlepiece.extension",
    ]

    /// The palette's rows for a query, best first. A command matches on its title or its id, whichever scores
    /// higher; ties keep the commands' order (sorted by title).
    static func items(
        for query: String,
        commands: [Command],
        shortcuts: ShortcutTable,
        recent: [String] = [],
        placement: (Command) -> Placement? = { _ in nil }
    ) -> [QuickPickItem] {
        let sorted = commands
            .filter { $0.id != commandID && $0.isInPalette }
            .sorted { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) }
        func row(_ command: Command, section: String?) -> QuickPickItem {
            let place = placement(command)
            return QuickPickItem(
                id: command.id,
                title: command.title.uiLocalized,
                subtitle: command.summary.uiLocalized,
                symbol: place?.symbol,
                detail: (shortcuts.shortcut(for: command.id) ?? command.viewKey)?.displayString,
                section: section,
                subtitleOnSelection: true
            )
        }
        guard query.allSatisfy(\.isWhitespace) else {
            return sorted.enumerated()
                .compactMap { offset, command -> (Int, Command, Int)? in
                    let scores = [Fuzzy.score(query, in: command.title), Fuzzy.score(query, in: command.id)]
                    guard let best = scores.compactMap({ $0 }).max() else { return nil }
                    return (offset, command, best)
                }
                .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
                .map { row($0.1, section: nil) }
        }
        // Nothing typed: Recent, then one section per plugin, the sections by name with the shell's last.
        let byID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recentRows = recent.compactMap { byID[$0] }.map { row($0, section: recentSection) }
        let grouped = Dictionary(grouping: sorted) { placement($0)?.section ?? "" }
        let names = grouped.keys.sorted { a, b in
            if (a == shellSection) != (b == shellSection) { return b == shellSection }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return recentRows + names.flatMap { name in
            (grouped[name] ?? []).map { row($0, section: name.isEmpty ? nil : name) }
        }
    }
}

extension ShellSession {
    /// The shortcut table for the commands registered now and the vault's overrides.
    public func shortcutTable() -> ShortcutTable {
        ShortcutTable(commands: runtime.kernel.commands.all, overrides: runtime.config.config.shortcuts)
    }

    /// The command a key press should run, or nil (no binding, or the quick pick is up and handles its keys).
    func commandID(forKey shortcut: KeyShortcut) -> String? {
        let id = shortcutTable().command(for: shortcut)
        guard quickPick.isPresented else { return id }
        // While the popup is up, only its tabs' shortcuts (⌘O, ⌘P) act: they switch tab in place.
        guard let id, quickPick.tabs.contains(where: { $0.commandID == id }) else { return nil }
        return id
    }

    /// A tab's shortcut while the popup is up switches to it, keeping the query; any other runs the command.
    private func runFromKey(_ command: Command) {
        if quickPick.isPresented {
            quickPick.switchTab(to: command.id)
        } else {
            commandRunner.run(command)
        }
    }

    /// Runs the command bound to a shortcut. Returns false when there is none, or when the command says its
    /// shortcut does not apply now (`Command.isShortcutEnabled`), so the key goes on its way.
    func handleKey(_ shortcut: KeyShortcut) -> Bool {
        guard let id = commandID(forKey: shortcut), let command = runtime.kernel.commands.command(id: id),
              command.isShortcutEnabled?() ?? true else { return false }
        runFromKey(command)
        return true
    }

    /// Shows the palette with the commands registered now.
    public func showPalette() {
        let commands = runtime.kernel.commands.all
        let shortcuts = shortcutTable()
        let runner = commandRunner
        let recent = runner.recent
        let placements = commandPlacements(commands)
        quickPick.prepare(commandID: CommandPalette.commandID)
        quickPick.show(
            placeholder: "Run a command…",
            items: { query in
                CommandPalette.items(
                    for: query, commands: commands, shortcuts: shortcuts, recent: recent, placement: { placements[$0.id] }
                )
            },
            choose: { item in
                runner.remember(item.id)
                runner.run(item.id)
            }
        )
    }

    /// Each command's section and symbol: the name and icon of the plugin that registered it.
    func commandPlacements(_ commands: [Command]) -> [String: CommandPalette.Placement] {
        let manifests = Dictionary(runtime.host.manifests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placements: [String: CommandPalette.Placement] = [:]
        for command in commands {
            let owner = runtime.kernel.commands.owner(of: command.id)
            if owner == "shell" {
                placements[command.id] = .init(
                    section: CommandPalette.shellSection,
                    symbol: CommandPalette.shellSymbols[command.id] ?? "macwindow"
                )
            } else if let owner, let manifest = manifests[owner] {
                placements[command.id] = .init(section: manifest.name, symbol: manifest.icon ?? "puzzlepiece.extension")
            } else {
                // The runtime's own (plugins, settings): no plugin to name them after.
                placements[command.id] = .init(section: "Loam", symbol: "gearshape")
            }
        }
        return placements
    }

    /// The popup's two tabs: notes (the quick switcher, when it is loaded) and commands.
    func configureQuickPickTabs() {
        let shortcuts = shortcutTable()
        func tab(_ id: String, _ title: String, symbol: String, noun: String) -> QuickPickController.Tab? {
            guard runtime.kernel.commands.command(id: id) != nil else { return nil }
            return .init(
                commandID: id, title: title, shortcut: shortcuts.shortcut(for: id)?.displayString ?? "",
                symbol: symbol, noun: noun
            )
        }
        quickPick.tabs = [
            tab("switcher.open", "Notes", symbol: "doc.text.magnifyingglass", noun: "notes"),
            tab(CommandPalette.commandID, "Commands", symbol: "chevron.left.forwardslash.chevron.right", noun: "commands"),
        ].compactMap { $0 }
        let quickPick = quickPick
        let runner = commandRunner
        runner.willRun = { quickPick.prepare(commandID: $0) }
        quickPick.openTab = { runner.run($0) }
    }

    func registerPaletteCommand() throws {
        try registerShell(Command(
            id: CommandPalette.commandID,
            title: "Command palette",
            summary: "Shows a popup listing every command, to find one by fuzzy name and run it.",
            shortcut: KeyShortcut("p", [.command])
        ) { [weak self] _ in
            await MainActor.run { self?.showPalette() }
            return ""
        })
    }
}
