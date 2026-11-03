import PluginKitUI
import WorkspaceModel

/// The shell's own commands: they act on the workspace and the sidebars, so they reach the menus, the palette,
/// the CLI and agents like any plugin command. Default shortcuts are declared here; `KeyMonitor` runs them.
extension ShellSession {
    private struct ShellCommand {
        let id: String
        let title: String
        let summary: String
        let shortcut: KeyShortcut?
        let action: @MainActor @Sendable (WorkspaceController) -> Void
    }

    private static let commands: [ShellCommand] = [
        ShellCommand(
            id: "workspace.new-tab",
            title: "New tab",
            summary: "Opens a new tab showing the home page after the selected tab of the focused pane.",
            shortcut: KeyShortcut("t", [.command]),
            action: { $0.openNewTab() }
        ),
        ShellCommand(
            id: "workspace.close-tab",
            title: "Close tab",
            summary: "Closes the selected tab of the focused pane; a pane left empty disappears.",
            shortcut: KeyShortcut("w", [.command]),
            action: { $0.closeActiveTab() }
        ),
        ShellCommand(
            id: "workspace.reopen-closed-tab",
            title: "Reopen closed tab",
            summary: "Opens the last tab closed in this session again, in a new tab of the focused pane.",
            shortcut: KeyShortcut("t", [.command, .shift]),
            action: { $0.reopenClosedTab() }
        ),
        ShellCommand(
            id: "workspace.back",
            title: "Back",
            summary: "Shows what the active tab showed before, as the page toolbar's Back does.",
            shortcut: KeyShortcut("[", [.command]),
            action: { $0.goBack() }
        ),
        ShellCommand(
            id: "workspace.forward",
            title: "Forward",
            summary: "Shows again what Back took away from the active tab.",
            shortcut: KeyShortcut("]", [.command]),
            action: { $0.goForward() }
        ),
        ShellCommand(
            id: "workspace.split-right",
            title: "Split right",
            summary: "Opens the active tab again in a new pane to the right of the focused pane.",
            shortcut: nil,
            action: { $0.splitActive(.trailing) }
        ),
        ShellCommand(
            id: "workspace.split-down",
            title: "Split down",
            summary: "Opens the active tab again in a new pane below the focused pane.",
            shortcut: nil,
            action: { $0.splitActive(.bottom) }
        ),
        ShellCommand(
            id: "workspace.next-tab",
            title: "Next tab",
            summary: "Selects the next tab of the focused pane, wrapping around to the first.",
            shortcut: KeyShortcut("tab", [.control]),
            action: { $0.selectAdjacentTab(1) }
        ),
        ShellCommand(
            id: "workspace.previous-tab",
            title: "Previous tab",
            summary: "Selects the previous tab of the focused pane, wrapping around to the last.",
            shortcut: KeyShortcut("tab", [.control, .shift]),
            action: { $0.selectAdjacentTab(-1) }
        ),
        ShellCommand(
            id: "sidebar.toggle-leading",
            title: "Toggle left sidebar",
            summary: "Shows or hides the left sidebar and the panels plugins put in it.",
            shortcut: nil,
            action: { $0.toggleSidebar(.leading) }
        ),
        ShellCommand(
            id: "sidebar.toggle-trailing",
            title: "Toggle right sidebar",
            summary: "Shows or hides the right sidebar and the panels plugins put in it.",
            shortcut: nil,
            action: { $0.toggleSidebar(.trailing) }
        ),
    ]

    /// The ids of the shell commands, for the menus.
    public static var commandIDs: [String] { commands.map(\.id) }

    func registerShellCommands() throws {
        for command in Self.commands {
            let action = command.action
            try registerShell(Command(
                id: command.id,
                title: command.title,
                summary: command.summary,
                shortcut: command.shortcut
            ) { [weak workspace] _ in
                await MainActor.run {
                    if let workspace { action(workspace) }
                }
                return ""
            })
        }
    }

    /// Runs a registered command by id (a menu item, the palette). Throws when it is not registered.
    public func run(_ id: String, _ arguments: [String: String] = [:]) async throws -> String {
        guard let command = runtime.kernel.commands.command(id: id) else { throw ShellError.unknownCommand(id) }
        return try await command.handler(arguments)
    }
}

public enum ShellError: Error, Equatable {
    case unknownCommand(String)
}
