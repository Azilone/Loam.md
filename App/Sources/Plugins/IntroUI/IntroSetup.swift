import AppKit
import LoamCLI
import ObsidianImportPlugin
import PluginKitUI
import SwiftUI

/// The cards after the welcome, one choice each: where the vault lives, the user's coding agent, the Obsidian notes
/// it moves in (when there are some), the plugins to start with and the look. Each choice is on by default; Continue
/// applies it, Skip leaves it. At the end, a welcome note.
@MainActor
@Observable
final class IntroSetup {
    enum Step: String, CaseIterable, Hashable {
        case folder, agent, migrate, plugins, look
    }

    /// A theme the look card offers: its id for `themes.use` and its name. Its picture is Loam wearing it
    /// (`Resources/Brand/Shots/look-<id>.jpg`).
    struct Look: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static let looks: [Look] = [
        Look(id: "dither-green", name: "Dither Green"),
        Look(id: "dither", name: "Dither"),
        Look(id: "ink", name: "Ink"),
        Look(id: "dracula", name: "Dracula"),
    ]

    /// A set of plugins to start with: the ones it turns off.
    struct Preset: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
        let off: [String]
    }

    /// The plugins a preset may turn off, all on in `everything`.
    static let optional = ["meetings", "habit-tracker", "projects", "canvas", "excalidraw", "mindmap"]

    static let presets: [Preset] = [
        Preset(id: "everything", name: String(localized: "Everything"),
               detail: String(localized: "Tasks, projects, habits, meetings, boards"), off: []),
        Preset(id: "tasks", name: String(localized: "Notes and tasks"),
               detail: String(localized: "Daily notes, tasks and projects"),
               off: ["meetings", "habit-tracker", "canvas", "excalidraw", "mindmap"]),
        Preset(id: "writing", name: String(localized: "Just writing"),
               detail: String(localized: "Notes and daily notes, nothing else"), off: optional),
    ]

    var preset = presets[0].id
    /// The look picked; Loam wears it at once, behind the card.
    var look = looks[0].id {
        didSet { if look != oldValue { run("themes.use", ["name": look]) } }
    }
    var agentTools = true

    /// What the cards do, set by the plugin: run a command with arguments, install the `loam` command and the skill,
    /// write and open the welcome note (with the Obsidian vault moved in and the note that tells how, if any).
    @ObservationIgnored var run: (String, [String: String]) -> Void = { _, _ in }
    @ObservationIgnored var installAgentTools: () -> Void = {}
    @ObservationIgnored var welcome: (ObsidianVault?, String?) -> Void = { _, _ in }

    init() {}

    /// Continue on `step`: its choice applied. The folder and the migration are the onboarding's own.
    func apply(_ step: Step) {
        switch step {
        case .folder, .migrate: break
        case .plugins:
            let off = Set(Self.presets.first { $0.id == preset }?.off ?? [])
            for id in Self.optional { run(off.contains(id) ? "plugins.disable" : "plugins.enable", ["id": id]) }
        case .look: run("themes.use", ["name": look])
        case .agent: if agentTools { installAgentTools() }
        }
    }

    static let welcomePath = String(localized: "Welcome to Loam") + ".md"

    /// What the user pastes into their coding agent: Loam's command line and its migration guide, into the vault
    /// they chose rather than a new one, with Obsidian's vault named when there is one (the guide then asks only
    /// whether to keep its folders).
    static func migrationPrompt(cli: String, vault: String, obsidian: ObsidianVault?) -> String {
        func short(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        var lines = [
            "Migrate my notes into Loam. Run \"\(short(cli))\" guide migrate and follow it, "
                + "writing into my vault \"\(short(vault))\" (--vault) instead of a new one.",
        ]
        if let obsidian { lines.append("My notes are in Obsidian: \"\(short(obsidian.path))\".") }
        return lines.joined(separator: "\n")
    }

    /// The `loam` command and the skill, put where the coding agents find them. Errors are left to Settings >
    /// Developers, which shows what is installed.
    nonisolated static func installLoamTools() {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/loam")
        if FileManager.default.isExecutableFile(atPath: executable.path) {
            try? CommandLineInstall.install(executable: executable)
        }
        _ = try? AgentSkill.install()
    }

    /// The note a new vault opens on (`welcomePath`): where the notes are, the four things to know, and, when the
    /// user copied the migration prompt, what their agent does with it (`reportPath`: a note that tells what to check).
    static func welcomeNote(vaultPath: String, imported: ObsidianVault?, reportPath: String?, shortcut: (String) -> String?) -> String {
        func key(_ id: String, _ fallback: String) -> String { "`\(shortcut(id) ?? fallback)`" }
        // The note is named by its file, "Welcome to Loam": no heading repeats it.
        var lines = [
            String(localized: "Your notes are plain Markdown files in `\(vaultPath)`. Any app can open them, and nothing leaves your Mac unless you turn on sync."),
            "",
            "## " + String(localized: "Four things to know"),
            "",
            "- [ ] " + String(localized: "\(key("explorer.new-note", "⌘N")) writes a new note"),
            "- [ ] " + String(localized: "\(key("switcher.open", "⌘O")) finds any note by name"),
            "- [ ] " + String(localized: "\(key("palette.open", "⌘P")) runs any command"),
            "- [ ] " + String(localized: "\(key("assistant.toggle", "⌘J")) asks the Assistant, which works in your notes"),
        ]
        if let imported {
            lines += [
                "",
                "## " + String(localized: "Your Obsidian notes"),
                "",
                String(localized: "Paste the prompt you copied into your agent: it moves the notes of \(imported.name) into this vault and keeps `Migration log.md` here. Obsidian keeps its own copy."),
            ]
            if let reportPath {
                lines.append(String(localized: "[\((reportPath as NSString).deletingPathExtension)](\(reportPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? reportPath)) lists what was moved and what to check."))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
