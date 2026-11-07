import AppKit
import Foundation
import LoamCore
import PluginKit
import PluginKitUI

/// What the app tells `AppAnalytics`: the facts `app_launch` carries, the commands used, the events plugins report.
/// Everything here is an id of something Loam ships or a count in a range (docs/ANALYTICS.md); never a note, a path
/// or a name the user chose, and a third-party plugin or command never shows up.
extension AppModel {
    /// The ids of the plugins compiled into the app.
    var builtinPluginIDs: Set<String> {
        Set((configuration.logicPlugins + configuration.uiPlugins).map { $0.manifest.id })
    }

    /// The facts about the app and the open vault, read when `app_launch` goes out.
    func analyticsContext() async -> [String: String] {
        var facts: [String: String] = [
            "appearance": NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light",
            "vaults": AppAnalytics.bucket(library.entries.count, edges: [2, 3, 5, 10]),
            "first_run": startedFirstRun ? "true" : "false",
            "channel": updater.channel.rawValue,
            "auto_update": updater.checksAutomatically ? "true" : "false",
            "has_obsidian": obsidianVaults().isEmpty ? "false" : "true",
        ]
        guard let session else { return facts }
        facts["safe_mode"] = session.isSafeMode ? "true" : "false"
        facts["location"] = Self.vaultLocation(session.rootURL)
        let theme = session.themes.selectedName ?? ThemeStore.defaultName
        if BuiltInThemes.all.contains(where: { $0.id == theme }) { facts["theme"] = theme }
        let root = session.rootURL
        let notes = await Task.detached { try? Vault(rootURL: root).markdownPaths().count }.value
        if let notes { facts["notes"] = AppAnalytics.bucket(notes, edges: AppAnalytics.sizeEdges) }
        facts.merge(await pluginFacts(session)) { _, new in new }
        return facts
    }

    /// The built-in plugins the user turned off or that failed to start, by id, and how many of the vault's own
    /// plugins there are (their names stay on the Mac).
    private func pluginFacts(_ session: ShellSession) async -> [String: String] {
        guard let json = try? await session.run("plugins.list"),
              let rows = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]]
        else { return [:] }
        let builtin = builtinPluginIDs
        func ids(_ matching: ([String: Any]) -> Bool) -> String {
            let list = rows.filter { builtin.contains($0["id"] as? String ?? "") && matching($0) }
                .compactMap { $0["id"] as? String }.sorted().joined(separator: ",")
            // Whole ids only: a cut id would be an id nobody ships.
            guard list.count > 480, let cut = list.prefix(480).lastIndex(of: ",") else { return list }
            return String(list[..<cut])
        }
        var facts: [String: String] = [:]
        let off = ids { ($0["enabled"] as? Bool) == false }
        if !off.isEmpty { facts["plugins_off"] = off }
        let failed = ids { $0["failed"] is String }
        if !failed.isEmpty { facts["plugins_failed"] = failed }
        let own = rows.filter { ($0["source"] as? String) == "vault" }.count
        facts["plugins_vault"] = AppAnalytics.bucket(own, edges: [1, 2, 5, 10])
        return facts
    }

    /// Where the vault lives, in a few kinds of place and never its path.
    static func vaultLocation(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.contains("/Mobile Documents/") { return "icloud" }
        if path.contains("/CloudStorage/") || path.contains("/Dropbox") { return "cloud_storage" }
        if path.hasPrefix("/Volumes/") { return "external" }
        if path.hasPrefix(home + "/Documents") { return "documents" }
        if path.hasPrefix(home + "/Desktop") { return "desktop" }
        return "other"
    }

    /// A command about to run (the menu, the palette, a shortcut): counted once per run, when Loam ships it. Turning a
    /// built-in plugin on or off and picking a built-in theme have their own events.
    func trackCommand(_ id: String, _ arguments: [String: String]) {
        guard analytics.isAvailable, let session else { return }
        let commands = session.runtime.kernel.commands
        guard let owner = commands.owner(of: id), owner == "core" || owner == "shell" || builtinPluginIDs.contains(owner) else { return }
        switch id {
        case "plugins.enable", "plugins.disable":
            if let plugin = arguments["id"], builtinPluginIDs.contains(plugin) {
                analytics.track("plugin_toggled", ["plugin": plugin, "enabled": id == "plugins.enable" ? "true" : "false"])
            }
        case "themes.use":
            if let theme = arguments["name"], BuiltInThemes.all.contains(where: { $0.id == theme }) {
                analytics.track("theme_changed", ["theme": theme])
            }
        default:
            guard commands.command(id: id)?.isInPalette == true else { return }
            commandsUsed.insert(id)
            analytics.track("command_used", ["command": id], once: id)
        }
    }

    /// Listens for what plugins report (`UsageEvent`) and for the notes the user adds, for `session_end`. Called each
    /// time a vault opens; the listeners of the vault before go.
    func listenForUsage() {
        usageListener?()
        guard let events = session?.runtime.kernel.events else { return }
        let reported = events.on(UsageEvent.self) { @Sendable [weak self] event in
            Task { @MainActor in self?.analytics.track(event.name, event.properties) }
        }
        let changed = events.on(VaultChanged.self) { @Sendable [weak self] event in
            // A few files at once is someone writing; dozens is an import or a sync, which is not counted here.
            let added = event.changes.filter { $0.kind == .added && $0.path.lowercased().hasSuffix(".md") }.count
            guard added > 0, event.changes.count <= 3 else { return }
            Task { @MainActor in self?.notesCreated += added }
        }
        usageListener = { reported(); changed() }
    }

    /// The end of the run: how long it lasted, what was used and written, in ranges.
    func reportSessionEnd() {
        analytics.reportSessionEnd([
            "commands_used": AppAnalytics.bucket(commandsUsed.count, edges: [1, 5, 15, 40]),
            "notes_created": AppAnalytics.bucket(notesCreated, edges: [1, 3, 10, 30]),
        ])
    }
}
