import PluginKit

/// The palette's way into the settings window: "Settings" opens it, "Manage plugins" opens it on the plugins (what
/// "List plugins" did for the CLI, now left out of the palette).
extension ShellSession {
    func registerSettingsCommands() throws {
        try registerShell(Command(
            id: "settings.open",
            title: "Settings",
            summary: "Opens the settings window where it was left."
        ) { [weak self] _ in
            await MainActor.run { self?.openSettings?(nil, nil) }
            return ""
        })
        try registerShell(Command(
            id: "settings.appearance",
            title: "Appearance and Language",
            summary: "Opens Settings on Appearance: light or dark, the accent colour, the theme and the app's language."
        ) { [weak self] _ in
            await MainActor.run { self?.openSettings?(.appearance, nil) }
            return ""
        })
        try registerShell(Command(
            id: "settings.developers",
            title: "Developers: Loam for Agents",
            summary: "Opens Settings on Developers: put the loam command line on the PATH and add the \"loam\" skill to "
                + "Claude Code, Codex and other coding agents."
        ) { [weak self] _ in
            await MainActor.run { self?.openSettings?(.developers, nil) }
            return ""
        })
        try registerShell(Command(
            id: "vaults.manage",
            title: "Manage vaults",
            summary: "Opens Settings on Vaults: the vaults opened on this Mac, to open one, reveal it or take it off the list."
        ) { [weak self] _ in
            await MainActor.run { self?.openSettings?(.vaults, nil) }
            return ""
        })
        try registerShell(Command(
            id: "vaults.create",
            title: "New Vault…",
            summary: "Asks for a name and a folder, makes an empty vault there and opens it in place of this one."
        ) { [weak self] _ in
            await MainActor.run { self?.host?.createVault() }
            return ""
        })
        try registerShell(Command(
            id: "vaults.open",
            title: "Open Folder as Vault…",
            summary: "Asks for a folder of Markdown notes and opens it as the vault, in place of this one."
        ) { [weak self] _ in
            await MainActor.run { self?.host?.chooseVault() }
            return ""
        })
        try registerShell(Command(
            id: "settings.plugins",
            title: "Manage plugins",
            summary: "Opens Settings on the list of plugins, to turn them on and off and change their settings. "
                + "Optional argument: id (a plugin, whose page opens)."
        ) { [weak self] arguments in
            let plugin = arguments["id"].flatMap { $0.isEmpty ? nil : $0 }
            await MainActor.run { self?.openSettings?(.plugins, plugin) }
            return ""
        })
    }
}
