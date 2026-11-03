import Foundation
import PluginKitUI
import LoamCore
import WorkspaceModel

/// One open vault in the app: the root `Runtime` with the shell's host services in place, the workspace, and the
/// layout saved per machine.
///
/// The session is the host, not a plugin: it provides `ui.views`, `ui.panels`, `ui.inspector`, `ui.workspace`, `ui.quick-pick`, `ui.toasts` and `ui.commands`
/// before any plugin starts and removes them after the last one stops (`Runtime.close`), and it registers the
/// `workspace.*`, `sidebar.*`, `settings.*` and `palette.open` commands under the owner "shell".
@MainActor
public final class ShellSession {
    public let runtime: Runtime
    public let views: ViewRegistryStore
    public let panels: PanelRegistryStore
    /// The sections plugins add to the right sidebar (`ui.inspector`).
    public let inspector: InspectorStore
    public let windowOverlays: WindowOverlayStore
    public let settingsSections: SettingsSectionStore
    /// The items plugins add to the menu of a file or folder (`ui.resourceActions`): the tab's and the page's menus.
    public let resourceActions: ResourceActionStore
    public let workspace: WorkspaceController
    public let quickPick: QuickPickController
    /// Runs commands for the palette and the keyboard shortcuts, and shows their answer.
    public let commandRunner: CommandRunner
    /// The programs the plugins need: what is missing, and installing it (`start` in the app only).
    public let toolSetup: ToolSetup
    /// The themes of `.loam/themes/` and the one in use.
    public let themes: ThemeStore
    /// Which panels the side columns show (Settings > Sidebars).
    public let panelVisibility: PanelVisibility
    /// What the left sidebar shows and in which order (its Customize mode).
    public let sidebarLayout: SidebarLayout

    /// Opens the settings window on a pane (nil: where it was left), and on the Plugins pane a plugin's page: set by
    /// the window, which can open it. The `settings.open` and `settings.plugins` commands go through it.
    public var openSettings: ((SettingsPane?, String?) -> Void)?

    /// The app that opened this vault: the vault switcher opens, makes and lists vaults through it.
    weak var host: AppModel?

    public var rootURL: URL { runtime.kernel.vault.rootURL }
    public var name: String { rootURL.lastPathComponent }
    /// True when only the safe mode allowlist (and what it requires) may run.
    public var isSafeMode: Bool { runtime.safeMode != nil }
    /// The ids of the built-in plugins with an interface (`ShellConfiguration.uiPlugins`): Settings > Plugins lists
    /// them as features, the others as the services they build on.
    public let uiPluginIDs: Set<String>

    /// What the last check found about the vault's plugins (ShellSession+PluginUpdates.swift).
    public internal(set) var pluginUpdates: [PluginUpdateInfo] = []
    var pluginUpdateTask: Task<Void, Never>?

    private let layoutStore: LayoutStore
    private let layoutSaveDelay: Duration
    private var saveTask: Task<Void, Never>?
    private var shellCommandIDs: [String] = []
    private var removeListeners: [() -> Void] = []
    private var watcher: FileWatcher?
    private var isClosed = false

    /// - Parameters:
    ///   - machineID: names the layout file; tests pass a fixed one.
    ///   - layoutSaveDelay: how long the layout waits after a change before it is written.
    ///   - safeMode: starts only `configuration.safeModePlugins` and what they require.
    public init(
        rootURL: URL,
        configuration: ShellConfiguration,
        machineID: String = MachineID.current(),
        layoutSaveDelay: Duration = .seconds(1),
        safeMode: Bool = false
    ) throws {
        let views = ViewRegistryStore()
        let panels = PanelRegistryStore()
        let noteHeaders = NoteHeaderStore()
        let windowOverlays = WindowOverlayStore()
        let settingsSections = SettingsSectionStore()
        let inspector = InspectorStore()
        let resourceActions = ResourceActionStore()
        let quickPick = QuickPickController()
        let toasts = ToastBridge()
        let commandBridge = CommandBridge()
        layoutStore = LayoutStore(vault: Vault(rootURL: rootURL), machineID: machineID)
        let workspace = WorkspaceController(snapshot: layoutStore.load() ?? WorkspaceSnapshot())
        self.views = views
        self.panels = panels
        self.inspector = inspector
        self.windowOverlays = windowOverlays
        self.settingsSections = settingsSections
        self.resourceActions = resourceActions
        self.quickPick = quickPick
        self.workspace = workspace
        self.layoutSaveDelay = layoutSaveDelay
        uiPluginIDs = Set(configuration.uiPlugins.map { $0.manifest.id })

        runtime = try Runtime(
            rootURL: rootURL,
            plugins: configuration.logicPlugins + configuration.uiPlugins,
            hostServices: { kernel in
                let events = kernel.events
                workspace.onActiveResourceChange = { events.emit(ActiveResourceChanged(resource: $0)) }
                return [
                    try kernel.services.provide(.views, views as any ViewRegistry),
                    try kernel.services.provide(.panels, panels as any PanelRegistry),
                    try kernel.services.provide(.noteHeaders, noteHeaders as any NoteHeaderRegistry),
                    try kernel.services.provide(.windowOverlays, windowOverlays as any WindowOverlayRegistry),
                    try kernel.services.provide(.settingsSections, settingsSections as any SettingsSectionRegistry),
                    try kernel.services.provide(.inspector, inspector as any InspectorRegistry),
                    try kernel.services.provide(.resourceActions, resourceActions as any ResourceActionRegistry),
                    try kernel.services.provide(.workspace, workspace as any Workspace),
                    try kernel.services.provide(.quickPick, quickPick as any QuickPick),
                    try kernel.services.provide(.toasts, toasts as any Toasts),
                    try kernel.services.provide(.commands, commandBridge as any CommandLauncher),
                ]
            },
            safeMode: safeMode ? configuration.safeModePlugins : nil,
            thirdPartyPlugins: configuration.thirdPartyPlugins,
            pluginTrust: configuration.pluginTrust
        )
        let commands = runtime.kernel.commands
        let runner = CommandRunner { commands.command(id: $0) }
        commandRunner = runner
        let tools = runtime.kernel.tools
        toolSetup = ToolSetup(
            run: { id, arguments in
                guard let command = commands.command(id: id) else { throw ShellError.unknownCommand(id) }
                return try await command.handler(arguments)
            },
            show: { [weak runner] text, kind in runner?.show(text, kind: kind) },
            locate: { tools.locate($0) }
        )
        toasts.runner = commandRunner
        commandBridge.runner = commandRunner
        commandBridge.commands = { commands.all }
        commandBridge.revision = { commands.revision }
        let config = runtime.config
        commandBridge.overrides = { config.config.shortcuts }
        themes = ThemeStore(rootURL: rootURL, config: runtime.config)
        panelVisibility = PanelVisibility(config: runtime.config)
        sidebarLayout = SidebarLayout(config: runtime.config)

        settingsSections.open = { [weak self] plugin in self?.openSettings?(.plugins, plugin) }

        do {
            // Records the starting point, so the first refresh reports what changed since now.
            try runtime.kernel.refreshVault()
            try registerShellCommands()
            try registerPaletteCommand()
            try registerThemeCommands()
            try registerSettingsCommands()
            configureQuickPickTabs()
        } catch {
            close()
            throw error
        }
        removeListeners.append(runtime.kernel.events.on(NotesMoved.self) { @Sendable [weak self] event in
            // Not main-actor: commands (files.trash, files.move) emit from any executor, and a closure written in this
            // main-actor init would otherwise assert the main queue before `MainThread.sync` could hop.
            let moves = event.moves
            MainThread.sync { self?.workspace.retarget(moves) }
        })
        workspace.onChange = { [weak self] in self?.scheduleLayoutSave() }
        workspace.onNewTab = { [weak self] in
            Task { @MainActor in _ = try? await self?.run("switcher.open") }
        }
        workspace.onNewTabLeft = { [weak self] in self?.quickPick.dismiss() }
        workspace.newTabResource = { [weak self] in self?.homeResource }
        // A window with nothing open shows the home page, when a plugin draws one.
        if workspace.layout.activeTab == nil, !views.viewTypes(for: .home).isEmpty {
            workspace.open(.home, placement: .replace)
        }
    }

    /// What the house button and a new tab show: the home page (`Resource.home`) when a plugin draws it, else the
    /// first link of the left sidebar.
    public var homeResource: Resource? {
        views.viewTypes(for: .home).isEmpty ? panels.links.first?.resource : .home
    }

    /// Calls `vaultDidChange` whenever something changes under the vault folder (FSEvents), until `close`. The walk of
    /// the folder runs off the main thread, and events that arrive meanwhile are folded into one more refresh.
    public func startWatching() {
        guard watcher == nil, !isClosed else { return }
        watcher = FileWatcher(url: rootURL) { [weak self] in self?.vaultChangedOnDisk() }
    }

    private var isRefreshingVault = false
    private var vaultChangedAgain = false

    private func vaultChangedOnDisk() {
        guard !isClosed else { return }
        if isRefreshingVault {
            vaultChangedAgain = true
            return
        }
        isRefreshingVault = true
        let root = rootURL
        Task { [weak self] in
            let stamps = await Task.detached(priority: .userInitiated) { try? Vault(rootURL: root).stamps() }.value
            guard let self else { return }
            isRefreshingVault = false
            if let stamps {
                applyVaultChange(runtime.kernel.refreshVault(applying: stamps))
            } else {
                vaultDidChange()
            }
            if vaultChangedAgain {
                vaultChangedAgain = false
                vaultChangedOnDisk()
            }
        }
    }

    /// Brings everything up to date with the disk: plugins learn what changed (`VaultChanged`), a config edited
    /// outside the app (the CLI, a sync) starts or stops plugins, and the tabs of deleted files close.
    public func vaultDidChange() {
        guard !isClosed else { return }
        applyVaultChange((try? runtime.kernel.refreshVault()) ?? [])
    }

    private func applyVaultChange(_ changes: [VaultChange]) {
        guard !isClosed else { return }
        let before = runtime.config.config
        if (try? runtime.config.reload()) == true {
            runtime.applyConfig()
            runtime.announceSettingChanges(since: before)
        }
        themes.reload()
        panelVisibility.reload()
        sidebarLayout.reload()
        // An open note the editor emptied and removed is still a draft in its tab.
        let editor = runtime.kernel.services.service(.editor)
        let removed = Set(changes.filter { $0.kind == .removed && editor?.isDraft($0.path) != true }.map(\.path))
        if !removed.isEmpty { workspace.closeTabs { $0.kind == .file && removed.contains($0.path) } }
    }

    /// Saves the layout, stops every plugin (which saves their pending work) and the file watcher.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        quickPick.dismiss()
        toolSetup.stop()
        watcher?.stop()
        watcher = nil
        pluginUpdateTask?.cancel()
        pluginUpdateTask = nil
        saveTask?.cancel()
        saveTask = nil
        saveLayout()
        for remove in removeListeners { remove() }
        removeListeners = []
        for id in shellCommandIDs { runtime.kernel.commands.unregister(id: id) }
        shellCommandIDs = []
        runtime.close()
    }

    // MARK: Layout

    /// Saves after `layoutSaveDelay` without a further change, so dragging a divider writes once.
    private func scheduleLayoutSave() {
        guard !isClosed else { return }
        saveTask?.cancel()
        let delay = layoutSaveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveLayout()
        }
    }

    /// Writes the layout now. A failure is not worth an alert: the cache only remembers the open tabs.
    public func saveLayout() {
        do {
            try layoutStore.save(workspace.snapshot)
        } catch {
            NSLog("Loam: could not save the workspace layout: \(error)")
        }
    }

    func registerShell(_ command: Command) throws {
        try runtime.kernel.commands.register(command, owner: "shell")
        shellCommandIDs.append(command.id)
    }
}
