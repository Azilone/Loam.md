import AppKit
import LoamCLI
import PluginKitUI
import SwiftUI

/// Settings > Developers, as Aside's: the `loam` command line on the PATH, and the "loam" skill in the coding
/// agents (Claude Code, Codex, OpenCode, Pi, Antigravity), so any of them can work in the vault and build plugins
/// from the terminal, guided by `loam guide`.
struct DevelopersPane: View {
    @State private var linked = CommandLineInstall.installed()
    @State private var onPath = true
    @State private var skills = AgentSkill.status()
    @State private var message: String?
    @Environment(\.themeTokens) private var theme

    /// The `loam` inside this app.
    private var executable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/loam") }

    var body: some View {
        SettingsPage(title: String(localized: "Developers")) {
            hero
            SettingsSection(title: String(localized: "Command Line")) {
                SettingsRow(
                    title: String(localized: "loam"),
                    detail: cliDetail,
                    detailColor: linked != nil && !onPath ? .orange : nil
                ) {
                    if linked == executable.path {
                        SettingsAction(title: String(localized: "Remove")) {
                            CommandLineInstall.uninstall()
                            refresh()
                        }
                    } else {
                        SettingsAction(title: linked == nil ? String(localized: "Install") : String(localized: "Update")) {
                            do {
                                try CommandLineInstall.install(executable: executable)
                                message = nil
                            } catch {
                                message = error.localizedDescription
                            }
                            refresh()
                        }
                        .disabled(!FileManager.default.isExecutableFile(atPath: executable.path))
                    }
                }
            }
            SettingsSection(
                title: String(localized: "Agent Skill"),
                subtitle: String(localized: "Tells the agent to read `loam guide`: the rules, the commands, and how to build, test and share a plugin.")
            ) {
                ForEach(skills, id: \.target) { status in
                    SettingsRow(title: status.agents, detail: skillDetail(status)) {
                        if status.installed && status.current {
                            SettingsAction(title: String(localized: "Remove")) {
                                AgentSkill.uninstall([status.target])
                                refresh()
                            }
                        } else {
                            SettingsAction(title: status.installed ? String(localized: "Update") : String(localized: "Add")) {
                                add([status.target])
                            }
                        }
                    }
                }
                SettingsRow(title: String(localized: "All agents")) {
                    SettingsAction(title: String(localized: "Add Skill to All")) { add([]) }
                }
            }
            if let message {
                SettingsNotice(text: message, symbol: "exclamationmark.triangle") { EmptyView() }
            }
            SettingsSection(title: String(localized: "Try It")) {
                SettingsRow(
                    title: String(localized: "In Claude Code, Codex or any agent"),
                    detail: String(localized: "“Make me a Loam plugin that tracks the books I read.” The agent reads the guide, builds the plugin, tests it and shows it in this window.")
                )
                SettingsRow(title: String(localized: "In a terminal"), detail: "loam guide  ·  loam list  ·  loam app info") {
                    SettingsAction(title: String(localized: "Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("loam guide", forType: .string)
                    }
                }
            }
        }
        .task { refreshPath() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Loam for agents").font(.ui(size: 20, weight: .semibold)).foregroundStyle(theme.text)
            Text("Work in your vault and build plugins from Claude Code, Codex, OpenCode, Pi and Antigravity.")
                .font(.ui(size: SettingsStyle.titleSize))
                .foregroundStyle(theme.secondaryText)
            Text(verbatim: "$ loam guide plugins")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(Color(white: 0.12)))
                .padding(.top, 6)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
    }

    private var cliDetail: String {
        guard let linked else {
            return String(localized: "Puts the app's loam in ~/.local/bin, where terminals and agents find it.")
        }
        if linked != executable.path { return String(localized: "Linked to another copy of Loam: \(linked)") }
        return onPath
            ? String(localized: "Installed: ~/.local/bin/loam")
            : String(localized: "Installed in ~/.local/bin, which is not on your shell's PATH: add it to ~/.zshrc.")
    }

    private func skillDetail(_ status: AgentSkill.Status) -> String {
        let place = (status.path as NSString).abbreviatingWithTildeInPath
        if !status.installed { return String(localized: "Not added. Goes in \(place)") }
        return status.current ? String(localized: "Added: \(place)") : String(localized: "An older version: \(place)")
    }

    private func add(_ targets: [String]) {
        do {
            try AgentSkill.install(targets)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        linked = CommandLineInstall.installed()
        skills = AgentSkill.status()
        refreshPath()
    }

    private func refreshPath() {
        Task.detached {
            let found = CommandLineInstall.folderIsOnPath()
            await MainActor.run { onPath = found }
        }
    }
}
