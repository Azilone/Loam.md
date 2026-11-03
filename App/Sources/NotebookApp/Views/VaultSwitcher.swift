import PluginKitUI
import SwiftUI

/// The vault at the foot of the left sidebar: its name in a pill, the sync's state as a dot on its icon. A click grows
/// a glass menu above it, as "New" does below its own: the vaults opened on this Mac, then the vault's own places
/// (Sync with its state, Recently Deleted, Settings, Customize Sidebar), then a new vault or an import from another app
/// (the import page, whose agent makes a new vault).
struct VaultSwitcher: View {
    let session: ShellSession
    let host: AppModel
    /// The status bar slot's panels (the sync's state): a dot on the icon, a dot and a few words in the menu.
    var statusBar: [Panel] = []
    let openSettings: () -> Void
    let customize: () -> Void
    @State private var panel: GlassMenuPanel?
    @State private var anchor = ViewAnchor()
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: SidebarStyle.iconGap) {
                SidebarIcon("loam.vault", color: theme.sidebarAccessory(selected: false), ground: theme.sidebarGround(selected: false))
                    .frame(width: SidebarStyle.iconSize)
                    .overlay(alignment: .bottomTrailing) {
                        status(.dot).offset(x: 4, y: 4)
                    }
                Text(session.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(symbol: "chevron.up.chevron.down")
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .foregroundStyle(theme.text.opacity(SidebarStyle.titleOpacity))
            .sidebarPill(theme.text.opacity(0.06))
        }
        .buttonStyle(.press)
        .background(ViewAnchorView(anchor: anchor))
        .onDisappear { panel?.dismiss(animated: false) }
        .help(session.rootURL.path)
        .accessibilityLabel("Vault: \(session.name)")
    }

    private func status(_ style: StatusStyle) -> some View {
        ForEach(statusBar) { $0.makeView() }
            .environment(\.statusStyle, style)
            .allowsHitTesting(false)
    }

    private var sections: [GlassMenuSection] {
        let current = VaultLibrary.path(of: session.rootURL)
        let vaults = host.library.entries.map { entry in
            GlassMenuEntry(id: "vault:" + entry.id, title: entry.name, symbol: "loam.vault", isChecked: entry.id == current) {
                // After the menu has closed: opening replaces the session this menu belongs to.
                if entry.id != current { Task { @MainActor in host.openVault(entry.url) } }
            }
        }
        var places: [GlassMenuEntry] = []
        if hasCommand(Self.syncCommand) {
            places.append(GlassMenuEntry(id: "sync", title: "Sync", symbol: "arrow.triangle.2.circlepath",
                                         detail: AnyView(status(.detail))) { session.commandRunner.run(Self.syncCommand) })
        }
        if hasCommand(Self.trashCommand) {
            places.append(GlassMenuEntry(id: "trash", title: "Recently Deleted", symbol: "trash") {
                session.commandRunner.run(Self.trashCommand)
            })
        }
        places.append(GlassMenuEntry(id: "settings", title: "Settings", symbol: "gearshape", shortcut: "⌘,") { openSettings() })
        places.append(GlassMenuEntry(id: "customize", title: "Customize Sidebar…", symbol: "slider.horizontal.3") { customize() })
        let new = [
            GlassMenuEntry(id: "new", title: "New Vault…", symbol: "plus") { Task { @MainActor in host.createVault() } },
            GlassMenuEntry(id: "open", title: "Open Folder as Vault…", symbol: "folder") { Task { @MainActor in host.chooseVault() } },
            GlassMenuEntry(id: "import", title: "Import from Another App…", symbol: "square.and.arrow.down") {
                Task { @MainActor in _ = try? await session.run("import.open", [:]) }
            },
        ]
        return [GlassMenuSection(title: "Vaults", entries: vaults), GlassMenuSection(entries: places), GlassMenuSection(entries: new)]
    }

    private func hasCommand(_ id: String) -> Bool { session.runtime.kernel.commands.command(id: id) != nil }

    private func toggle() {
        let panel = panel ?? GlassMenuPanel()
        self.panel = panel
        panel.toggle(sections, opensUpward: true, by: anchor, theme: theme, colorScheme: colorScheme)
    }

    /// The commands of the sync and trash plugins, run by the menu.
    static let syncCommand = "sync.now"
    static let trashCommand = "trash.open"
}
