import AppKit
import PluginKitUI
import SwiftUI

/// The settings window (Cmd+,), laid out as Craft's settings: a sidebar of panes on the window's grey (the vault,
/// then Appearance, Sidebars and Shortcuts, then the plugins and each one with settings, then About) and the pane as
/// a white page. It follows the open vault: a new session (another vault, leaving safe mode) rebuilds it.
public struct SettingsView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let session = model.session {
                SettingsWindow(model: model, session: session, navigation: model.settingsNavigation)
                    .id(ObjectIdentifier(session))
                    // The vault's look: light or dark as its window is, its accent and colours.
                    .themed(by: session.themes)
            } else {
                ContentUnavailableView("No vault open", symbol: "folder", description: Text("Open a vault first."))
            }
        }
        .frame(minWidth: 760, idealWidth: 880, maxWidth: .infinity, minHeight: 520, idealHeight: 660, maxHeight: .infinity)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

private struct SettingsWindow: View {
    let model: AppModel
    let session: ShellSession
    @Bindable var navigation: SettingsNavigation
    @State private var plugins: PluginManagerModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(session: session, plugins: plugins, navigation: navigation)
                .frame(width: 228)
                .onCanvas(theme)
            Group {
                if let plugins {
                    // Switching sections cross-fades the panes in place: no movement, the page does not slide.
                    pane(plugins)
                        .id(navigation.pane)
                        .transition(.opacity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(Motion.crossfade, value: navigation.pane)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .page()
            .padding([.top, .bottom, .trailing], Glass.gap)
        }
        .background { WindowCanvas().ignoresSafeArea() }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.settingsNavigation, navigation)
        .task {
            let created = PluginManagerModel(
                session: session,
                relaunch: model.canRelaunch ? { @MainActor in model.relaunch() } : nil
            )
            await created.refresh()
            plugins = created
        }
        // The rows follow what changed elsewhere (the palette, the CLI) when a pane opens.
        .onChange(of: navigation.pane) { Task { await plugins?.refresh() } }
    }

    @ViewBuilder
    private func pane(_ plugins: PluginManagerModel) -> some View {
        switch navigation.pane {
        case .vaults:
            VaultsPane(model: model)
        case .appearance:
            AppearancePane(themes: session.themes)
        case .sidebars:
            SidebarsPane(session: session)
        case .shortcuts:
            ShortcutsPane(session: session)
        case .plugins:
            PluginsPane(model: plugins, navigation: navigation)
        case .developers:
            DevelopersPane()
        case .about:
            AboutPane(model: model)
        }
    }
}

/// The settings sidebar: the vault, then the panes in groups, About at the bottom. The rows are the main window's
/// sidebar rows (`sidebarRow`).
private struct SettingsSidebar: View {
    let session: ShellSession
    let plugins: PluginManagerModel?
    let navigation: SettingsNavigation
    /// The plugin whose row was in the sidebar when its page opened: the row stays while the page is open, even once
    /// the plugin is turned off there.
    @State private var keptPluginID: String?
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsVaultHeader(name: session.name, isSafeMode: session.isSafeMode)
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    Text("General").sidebarSectionTitle()
                    row(.vaults)
                    row(.appearance)
                    row(.sidebars)
                    row(.shortcuts)
                    row(.developers)
                    Text("Plugins").sidebarSectionTitle()
                    row(.plugins, title: String(localized: "All Plugins"))
                    // A plugin with settings gets its own row, as a feature of Craft does.
                    ForEach(pluginsWithSettings) { plugin in
                        SettingsSidebarRow(
                            title: plugin.name,
                            isSelected: navigation.pane == .plugins && navigation.pluginID == plugin.id
                        ) {
                            PluginIconView(symbol: plugin.icon, imageURL: plugins?.iconFileURL(of: plugin.id), size: 18)
                        } select: {
                            navigation.open(.plugins, plugin: plugin.id)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            Spacer(minLength: 0)
            row(.about)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, SidebarStyle.columnPadding)
        .onChange(of: navigation.pluginID, initial: true) { _, id in
            keptPluginID = plugins?.sidebarPluginIDs().contains { $0 == id } == true ? id : nil
        }
        .onChange(of: plugins == nil) {
            keptPluginID = plugins?.sidebarPluginIDs().contains { $0 == navigation.pluginID } == true
                ? navigation.pluginID : nil
        }
    }

    /// The enabled plugins that have settings, by name, and the one whose page is open if its row was there.
    private var pluginsWithSettings: [PluginStatusRow] {
        guard let plugins else { return [] }
        let kept = keptPluginID == navigation.pluginID ? keptPluginID : nil
        return plugins.sidebarPluginIDs(keeping: kept).compactMap { plugins.row($0) }
    }

    private func row(_ pane: SettingsPane, title: String? = nil) -> some View {
        // All Plugins stays selected on the page of a plugin without a row of its own, as Craft keeps the parent.
        let isSelected = navigation.pane == pane && (pane != .plugins || navigation.pluginID.map { id in
            !pluginsWithSettings.contains { $0.id == id }
        } ?? true)
        return SettingsSidebarRow(title: title ?? pane.title, isSelected: isSelected) {
            Image(symbol: pane.symbol)
                .font(.ui(size: 13))
                .foregroundStyle(theme.sidebarAccessory(selected: isSelected))
                .frame(width: 18)
        } select: {
            navigation.open(pane)
        }
    }
}

private struct SettingsSidebarRow<Icon: View>: View {
    let title: String
    let isSelected: Bool
    @ViewBuilder let icon: () -> Icon
    let select: () -> Void

    var body: some View {
        Button { select() } label: {
            HStack(spacing: 10) {
                icon()
                Text(title.uiLocalized).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.ui(size: 13))
            .sidebarRow(isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The vault at the top of the sidebar, as Craft shows its space: a large rounded tile with its initials (the main
/// window's badge, `VaultBadge`) and its name.
private struct SettingsVaultHeader: View {
    let name: String
    let isSafeMode: Bool
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                // The icon has a margin of about a tenth of its size around the tile, so it is drawn bigger.
                Image(nsImage: AppIcon.shared.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 76, height: 76)
                    .padding(-8)
                if isSafeMode {
                    Text("Safe")
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange, in: ThemeCapsule())
                        .offset(x: 10, y: 6)
                }
            }
            Text(name)
                .font(.ui(size: 15, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
        }
    }
}
