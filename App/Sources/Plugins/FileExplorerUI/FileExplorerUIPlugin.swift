import FileExplorerPlugin
import Foundation
import PluginKitUI
import SwiftUI

/// The left sidebar's Favorites, Folders and Recent sections; create, rename, move and
/// trash through the `files` service of its logic module, so every action is also a `files.*` command. Folders and
/// "All Notes" open as a grid of note cards (Craft's folder view).
public final class FileExplorerUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "file-explorer",
        name: "File explorer",
        version: "0.1.0",
        description: "Your folders and notes in the left sidebar.",
        icon: "folder",
        requires: ["files"],
        optionalRequires: ["note-graph", "editor"],
        permissions: ["ui", "vault.read", "vault.write"],
        settings: []
    )

    static let favoritesSectionID = "explorer.favorites"
    static let foldersSectionID = "explorer.folders"
    static let recentSectionID = "explorer.recent"
    static let folderViewID = "explorer.folder"
    static let renameActionID = "explorer.rename"
    /// Internal: lets the tests reach the panel's model, which the view drives. Not a contract.
    static var modelKey: ServiceKey<ExplorerModel> { ServiceKey("file-explorer.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let files = context.service(.files) else {
            throw ExplorerError.filesServiceMissing
        }
        let model = ExplorerModel(
            files: files,
            vault: context.vault,
            graph: { [weak context] in context?.service(.noteGraph) },
            workspace: { [weak context] in context?.workspace }
        )
        model.favorites = context.settings.value(default: ExplorerSettings()).favorites
        model.saveFavorites = { [weak context] favorites in
            guard let context else { return }
            var settings = context.settings.value(default: ExplorerSettings())
            settings.favorites = favorites
            try? context.settings.update(settings)
        }
        FolderStyles.shared.custom = context.settings.value(default: ExplorerSettings()).folderStyles
        model.saveFolderStyles = { [weak context] styles in
            guard let context else { return }
            var settings = context.settings.value(default: ExplorerSettings())
            settings.folderStyles = styles
            try? context.settings.update(settings)
        }
        model.askFolderIcons = { [weak context] in Self.askFolderIcons(context) }
        model.trashRetentionDays = { [weak context] in context?.service(.trash)?.retentionDays }
        model.editor = { [weak context] in context?.service(.editor) }
        model.views = { [weak context] in context?.service(.views) }
        model.newItems = { [weak context] in context?.service(.panels)?.newItems ?? [] }
        model.hiddenFolders = { [weak context] in context?.waterfall(HiddenFolders()).paths ?? [] }
        model.quickPick = { [weak context] in context?.quickPick }
        model.managedFolders = { [weak context] in context?.waterfall(ManagedFolders()) ?? ManagedFolders() }
        // The panel has its own Rename, in place in the row.
        model.actions = { [weak context] in
            context?.service(.resourceActions)?.actions(for: $0).filter { $0.id != Self.renameActionID } ?? []
        }
        model.toasts = { [weak context] in context?.service(.toasts) }
        model.refresh()
        try context.provide(Self.modelKey, model)

        var favorites = SidebarSection(id: Self.favoritesSectionID, title: "Favorites", order: 0) {
            AnyView(FavoritesSection(model: model))
        }
        favorites.isEmpty = { model.favoriteItems.isEmpty }
        try context.addSidebarSection(favorites)
        try context.addSidebarSection(SidebarSection(
            id: Self.foldersSectionID, title: "Folders", order: 10,
            add: SidebarSectionAdd(title: "New Folder") { model.newFolder(in: "") }
        ) {
            AnyView(FoldersSection(model: model))
        })
        try context.addSidebarSection(SidebarSection(
            id: Self.recentSectionID, title: "Recent", order: 30, isShownByDefault: false
        ) {
            AnyView(RecentSection(model: model))
        })

        try context.registerView(ViewType(
            id: Self.folderViewID,
            title: "Folder",
            symbol: "square.grid.2x2",
            canOpen: { ExplorerModel.isPage($0) }
        ) { view in
            AnyView(FolderGridView(model: model, resource: view.resource))
        })
        // "Rename…" in a tab's and a page's right-click menu, for every note, drawing, board or folder.
        context.addResourceAction(ResourceAction(
            id: Self.renameActionID, title: "Rename…", symbol: "pencil", order: -100,
            appliesTo: { [weak model] resource in
                resource.kind != .virtual && !resource.path.isEmpty && model?.kind(of: resource.path) != nil
            },
            perform: { [weak model] resource in model?.promptRename(resource.path) }
        ))

        try context.addSidebarLink(SidebarLink(
            id: "explorer.all-notes", title: "All Notes", symbol: "doc.on.doc", resource: ExplorerModel.allNotes, order: 0
        ))

        try context.registerCommand(Command(
            id: "explorer.new-note",
            title: "New note",
            summary: "Opens a new note, \"Untitled\" (or \"Untitled 2\"...), in the folder of the active note "
                + "or in \"Inbox\" (never at the vault root). The file is only written once text is typed in it, and "
                + "a note left empty never reaches the disk. Returns its path."
        ) { _ in
            try await MainActor.run { try model.createNote(in: model.activeFolder) }
        })

        // Cmd+N: the same note as "New note", in a tab of its own so the one being read stays.
        try context.registerCommand(Command(
            id: "explorer.new-note-in-tab",
            title: "New note in new tab",
            summary: "Like \"New note\" (the folder of the active note or \"Inbox\", an unwritten draft), but "
                + "opens it in a new tab after the selected one instead of the focused tab. Returns its path.",
            shortcut: KeyShortcut("n", [.command])
        ) { _ in
            try await MainActor.run { try model.createNote(in: model.activeFolder, newTab: true) }
        })

        try context.registerCommand(Command(
            id: "explorer.reveal-active",
            title: "Reveal active note in file explorer",
            summary: "Opens the file explorer's folders down to the note of the focused tab and selects it. "
                + "Returns its path, or says that no note is open."
        ) { _ in
            await MainActor.run { model.revealActive() ?? "No note is open." }
        })

        try context.registerCommand(Command(
            id: "explorer.folder-style",
            title: "Folder icon and color",
            summary: "Gives a folder (argument: path) an icon (icon: an SF Symbol name or an emoji) and a color "
                + "(color: #RRGGBB); \"default\" puts back the default. Without icon and color, opens the folder's "
                + "\"Icon & Color\" picker in the sidebar."
        ) { arguments in
            try await MainActor.run {
                guard let path = arguments["path"], model.kind(of: path) == .folder else {
                    throw ExplorerError.notAFolder(arguments["path"] ?? "")
                }
                guard arguments["icon"] != nil || arguments["color"] != nil else {
                    model.revealFolder(path)
                    model.stylingFolder = path
                    return "Opened the picker of \(path)."
                }
                var style = model.folderStyle(path)
                for (key, value) in [("icon", arguments["icon"]), ("color", arguments["color"])] {
                    guard let value else { continue }
                    let new = value == "default" || value.isEmpty ? nil : value
                    if key == "icon" { style.icon = new } else { style.color = new }
                }
                model.setFolderStyle(path, style)
                return "\(path): icon \(style.icon ?? "default"), color \(style.color ?? "default")."
            }
        })

        // Settings > Plugins > File explorer writes the same settings.
        let id = context.pluginID
        context.on(PluginSettingsChanged.self) { [weak model, weak context] event in
            // Any plugin's settings may move the folder it gives an icon to.
            onMainThread { model?.askFolderIcons() }
            guard event.pluginID == id, let settings = context?.settings.value(default: ExplorerSettings()) else { return }
            onMainThread {
                if model?.favorites != settings.favorites { model?.favorites = settings.favorites }
                if FolderStyles.shared.custom != settings.folderStyles { FolderStyles.shared.custom = settings.folderStyles }
            }
        }
        context.on(NoteGraphLoaded.self) { [weak model] _ in
            onMainThread { model?.refresh() }
        }
        context.on(VaultChanged.self) { [weak model] _ in
            onMainThread { model?.refresh() }
        }
        context.on(NotesMoved.self) { [weak model] _ in
            onMainThread { model?.refresh() }
        }
        context.on(HiddenFoldersChanged.self) { [weak model] _ in
            onMainThread { model?.refresh() }
        }
        context.on(ManagedFoldersChanged.self) { [weak model] _ in
            onMainThread { model?.refresh() }
        }
        context.on(ActiveResourceChanged.self) { [weak model] event in
            let resource = event.resource
            onMainThread { model?.activeChanged(resource) }
        }
    }
}

extension FileExplorerUIPlugin {
    /// Asks the plugins for the icons of the folders they own (`FolderIcons`).
    @MainActor static func askFolderIcons(_ context: PluginContext?) {
        guard let context else { return }
        // The inbox, where new notes land, shows the tray of Craft's "Unsorted".
        let symbols = context.waterfall(FolderIcons(symbols: [VaultPath.inbox: "tray"])).symbols
        if FolderStyles.shared.pluginSymbols != symbols { FolderStyles.shared.pluginSymbols = symbols }
    }
}

/// The explorer's settings, in `.loam/config.json` under `plugins.file-explorer.settings`.
struct ExplorerSettings: Codable, Equatable {
    /// The notes and folders of the "Favorites" section, in the order they were starred.
    var favorites: [String] = []
    /// The icons and colours given to folders, by path.
    var folderStyles: [String: FolderStyle] = [:]

    init(favorites: [String] = [], folderStyles: [String: FolderStyle] = [:]) {
        self.favorites = favorites
        self.folderStyles = folderStyles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favorites = try container.decodeIfPresent([String].self, forKey: .favorites) ?? []
        folderStyles = try container.decodeIfPresent([String: FolderStyle].self, forKey: .folderStyles) ?? [:]
    }
}

enum ExplorerError: Error, Equatable {
    /// The host activates this plugin after `files` (it is in `requires`), so this means a broken host.
    case filesServiceMissing
    case notAFolder(String)
}

/// Runs main-actor code from an event listener, which Swift cannot prove runs on the main thread. The kernel is
/// main-thread only, so this is normally a direct call.
func onMainThread(_ body: @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
