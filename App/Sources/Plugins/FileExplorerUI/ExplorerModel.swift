import AppKit
import FileExplorerPlugin
import Foundation
import Observation
import PluginKitUI
import SwiftUI

/// The Files panel's state and actions: the tree, the recent notes, which folders are open, the row being
/// renamed, the delete waiting for confirmation and the last error. The view only reads it and calls its methods,
/// so tests drive the panel through it.
///
/// Every change on disk goes through `FilesService`; the model refreshes after each action it performs, because
/// an empty folder does not trigger `VaultChanged` (which only tracks files).
@MainActor
@Observable
final class ExplorerModel {
    enum Kind: Sendable { case folder, note, attachment }

    /// One file or folder of the tree, with the name shown for it.
    struct Item: Identifiable, Hashable, Sendable {
        var id: String { path }
        let path: String
        /// The note's title (from the note graph, else the file name without `.md`), or the file or folder name.
        let name: String
        let kind: Kind
        /// Nil for a file.
        let children: [Item]?

        var resource: Resource { kind == .folder ? .folder(path) : .file(path) }
    }

    /// A visible row of the tree: an item and its depth, the children of collapsed folders left out.
    struct Row: Identifiable, Hashable, Sendable {
        var id: String { item.path }
        let item: Item
        let depth: Int
    }

    /// A note of the "Recent" section.
    struct Recent: Identifiable, Hashable, Sendable {
        /// Distinct from the tree row of the same note: both sit in one list, and SwiftUI blanks duplicate ids.
        var id: String { "recent:" + path }
        let path: String
        let title: String
        /// The folder it is in, empty at the root.
        let folder: String
    }

    static let recentCount = 5
    /// How long an error stays on screen.
    static let messageSeconds: Double = 4

    private(set) var items: [Item] = []
    private(set) var recent: [Recent] = []
    /// When each note last changed, from the last `refresh`: a folder page draws its cards again when one changes.
    private(set) var noteStamps: [String: FileStamp] = [:]
    /// The card of each note, kept with the stamp it was read at: a folder page reads only the notes that changed.
    @ObservationIgnored var noteCards: [String: (stamp: FileStamp?, card: NoteCard)] = [:]
    /// The notes of "All Notes", the last edited first, for the tree and stamps they were sorted from: sorting every
    /// note again on each pass over the page cost more than the rest of it.
    @ObservationIgnored var sortedNotes: (tree: [Item], stamps: [String: FileStamp], notes: [Item])?
    /// The files of each page of one kind (`Resource.notes(titled:openedBy:)`), by title, for the tree they were
    /// picked from: asking the view registry for every file of the vault is not for each pass over the page.
    @ObservationIgnored var sortedFiles: [Resource: (tree: [Item], stamps: [String: FileStamp], files: [Item])] = [:]
    /// The starred notes and folders, by path, for the "Favorites" section.
    var favorites: [String] = []
    /// Writes the favorites to the plugin's settings. Set by the plugin.
    @ObservationIgnored var saveFavorites: @MainActor ([String]) -> Void = { _ in }
    /// Writes the folders' icons and colours to the plugin's settings. Set by the plugin.
    @ObservationIgnored var saveFolderStyles: @MainActor ([String: FolderStyle]) -> Void = { _ in }
    /// Asks the plugins for the icons of their folders, on each `refresh`: plugins activated after the explorer
    /// answer too. Set by the plugin.
    @ObservationIgnored var askFolderIcons: @MainActor () -> Void = {}
    /// The folder whose "Icon & Color" popover is open.
    var stylingFolder: String?
    /// Whether "Folders" lists every top-level folder rather than the first `folderLimit`.
    var showsAllFolders = false
    /// How many top-level folders "Folders" lists before "N more folders".
    static let folderLimit = 5
    /// The open folders, kept for the session.
    var expanded: Set<String> = []
    /// The folder opened or closed last, so its children unfold one after the other.
    @ObservationIgnored private(set) var lastToggled: String?
    /// The row of the note in the focused tab, or the last row clicked.
    private(set) var selected: String?
    /// The path whose row shows a name field, and what is typed in it.
    private(set) var renaming: String?
    var renameText = ""
    /// The path waiting for the user to confirm the move to the trash.
    var pendingDelete: String?
    /// Days the trash keeps an item (0: until deleted by hand); nil when the trash plugin is not there. Set by the plugin.
    @ObservationIgnored var trashRetentionDays: () -> Int? = { nil }
    /// The last error, shown in the panel for a few seconds.
    private(set) var message: String?

    @ObservationIgnored private let files: FilesService
    @ObservationIgnored let vault: VaultAccess
    @ObservationIgnored private let graph: @MainActor () -> NoteGraphService?
    @ObservationIgnored let workspace: @MainActor () -> (any Workspace)?
    /// The editor, which keeps a new note off the disk until it has text. Set by the plugin.
    @ObservationIgnored var editor: @MainActor () -> (any EditorService)? = { nil }
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    /// The view types, for each note's icon (a mindmap shows as one). Set by the plugin.
    @ObservationIgnored var views: @MainActor () -> (any ViewRegistry)? = { nil }
    /// The embedded views shown on cards, by note, kept so a card keeps its view's state as the grid redraws.
    @ObservationIgnored var cardEmbedContexts: [String: ViewContext] = [:]
    /// The other kinds of notes plugins can create, for the folder menu ("New Mindmap"). Set by the plugin.
    @ObservationIgnored var newItems: @MainActor () -> [NewItem] = { [] }
    /// The folders plugins keep out of the tree (`HiddenFolders`, the attachments folder). Set by the plugin.
    @ObservationIgnored var hiddenFolders: @MainActor () -> Set<String> = { [] }
    /// The folders plugins own (`ManagedFolders`: daily notes, habits, projects…). Set by the plugin.
    @ObservationIgnored var managedFolders: @MainActor () -> ManagedFolders = { ManagedFolders() }
    /// What plugins add to a row's menu ("Turn into Collection"). Set by the plugin.
    @ObservationIgnored var actions: @MainActor (Resource) -> [ResourceAction] = { _ in [] }
    /// Where a rename asked for from a menu outside the panel says it failed.
    @ObservationIgnored var toasts: @MainActor () -> Toasts? = { nil }

    /// A folder's icon as drawn: the one the user picked, else the one a plugin gives its folder (the inbox's tray),
    /// else `symbol(forFolder:open:)`.
    func icon(forFolder path: String, open: Bool) -> FolderIcon {
        FolderStyles.shared.icon(for: path, fallback: symbol(forFolder: path, open: open))
    }

    /// The icon and colour the user gave `path`.
    func folderStyle(_ path: String) -> FolderStyle {
        FolderStyles.shared.custom[path] ?? FolderStyle()
    }

    /// Gives `path` an icon and a colour; an empty style puts the default back.
    func setFolderStyle(_ path: String, _ style: FolderStyle) {
        var styles = FolderStyles.shared.custom
        styles[path] = style.isEmpty ? nil : style
        guard styles != FolderStyles.shared.custom else { return }
        FolderStyles.shared.custom = styles
        saveFolderStyles(styles)
    }

    /// A folder, filled when open: a folder a plugin opens as a collection looks like any other in the tree.
    func symbol(forFolder path: String, open: Bool) -> String {
        return open ? "folder.fill" : "folder"
    }

    /// A note's icon: the one of the view it opens with by default, else a plain document.
    func symbol(forNote path: String) -> String {
        views()?.symbol(for: .file(path)) ?? "doc.text"
    }

    /// Another file's icon: the one of the view type that opens it (a `.canvas` board), else a plain file.
    func symbol(forFile path: String) -> String {
        views()?.symbol(for: .file(path)) ?? "doc"
    }

    /// Whether a view type opens the file in Loam as one of its own formats (a board). Such a file shows and renames
    /// without its extension, as a note does; other attachments, and files a viewer shows (`keepsExtension`), keep
    /// their whole name.
    func opensInApp(_ path: String) -> Bool {
        guard let first = views()?.viewTypes(for: .file(path)).first else { return false }
        return !first.keepsExtension
    }

    /// The name a row shows. Asked when drawing rather than stored in the tree, so a file follows the view types
    /// of plugins enabled after the explorer.
    func title(of item: Item) -> String {
        item.kind == .attachment && opensInApp(item.path) ? Resource.file(item.path).name : item.name
    }

    init(
        files: FilesService,
        vault: VaultAccess,
        graph: @escaping @MainActor () -> NoteGraphService?,
        workspace: @escaping @MainActor () -> (any Workspace)?
    ) {
        self.files = files
        self.vault = vault
        self.graph = graph
        self.workspace = workspace
    }

    // MARK: Reading

    /// The rows to show: depth first, the children of open folders only.
    var rows: [Row] {
        var rows: [Row] = []
        appendRows(of: items, depth: 0, to: &rows)
        return rows
    }

    /// The top-level folders, without the notes at the vault's root (they show in "All Notes"): the inbox first
    /// (where new notes land), then the user's own folders by name, then the folders plugins own (Daily, Projects,
    /// attachments…), which have their own way in, so the first places go to the user's folders.
    var topFolders: [Item] {
        let folders = items.filter { $0.kind == .folder }
        let managed = managedFolders()
        let inbox = folders.filter { $0.path == VaultPath.inbox }
        let own = folders.filter { $0.path != VaultPath.inbox && !managed.contains($0.path) }
        return inbox + own + folders.filter { $0.path != VaultPath.inbox && managed.contains($0.path) }
    }

    /// The rows of "Folders": the top-level folders (the first `folderLimit` until "more" is clicked) and the
    /// contents of the open ones.
    var folderRows: [Row] {
        let folders = topFolders
        var rows: [Row] = []
        appendRows(of: showsAllFolders ? folders : Array(folders.prefix(Self.folderLimit)), depth: 0, to: &rows)
        return rows
    }

    /// The top-level folders "Folders" leaves out until "more" is clicked.
    var hiddenFolderCount: Int { showsAllFolders ? 0 : max(topFolders.count - Self.folderLimit, 0) }

    /// The favorites still in the vault, with their names.
    var favoriteItems: [Item] {
        favorites.compactMap { path in
            if let item = find(path, in: items) { return item }
            return nil
        }
    }

    private func find(_ path: String, in items: [Item]) -> Item? {
        for item in items {
            if item.path == path { return item }
            if path.hasPrefix(item.path + "/"), let found = find(path, in: item.children ?? []) { return found }
        }
        return nil
    }

    func isFavorite(_ path: String) -> Bool { favorites.contains(path) }

    /// Stars `path`, or unstars it when it already is.
    func toggleFavorite(_ path: String) {
        if let index = favorites.firstIndex(of: path) { favorites.remove(at: index) } else { favorites.append(path) }
        saveFavorites(favorites)
    }

    private func appendRows(of items: [Item], depth: Int, to rows: inout [Row]) {
        for item in items {
            rows.append(Row(item: item, depth: depth))
            if item.kind == .folder, expanded.contains(item.path) {
                appendRows(of: item.children ?? [], depth: depth + 1, to: &rows)
            }
        }
    }

    /// The place of each row inside the folder toggled last (0 for its first child), for the cascade; nil for the
    /// other rows, which slide without delay.
    func cascadeIndex(in rows: [Row]) -> [String: Int] {
        guard let folder = lastToggled else { return [:] }
        let prefix = folder + "/"
        var indices: [String: Int] = [:]
        for row in rows where row.item.path.hasPrefix(prefix) {
            indices[row.item.path] = indices.count
        }
        return indices
    }

    /// Reads the tree and the recent notes again.
    func refresh() {
        askFolderIcons()
        // At launch the graph may still be reading the vault: file names until then, titles on `NoteGraphLoaded`.
        let graph = graph().flatMap { ($0 as? NoteGraphLoading)?.isLoaded == false ? nil : $0 }
        do {
            let tree = Self.removing(hiddenFolders(), from: try files.tree())
            let newItems = tree.map { Self.item(from: $0, graph: graph) }
            if newItems != items { items = newItems }
        } catch {
            show(error)
        }
        let stamps = (try? vault.stamps())?.filter { Self.isNote($0.key) } ?? [:]
        let paths = stamps.keys.sorted { first, second in
            let a = stamps[first]!.modified
            let b = stamps[second]!.modified
            return a != b ? a > b : first < second
        }
        let newRecent = paths.prefix(Self.recentCount).map { path in
            Recent(path: path, title: Self.noteTitle(path, graph: graph), folder: VaultPath.directory(of: path))
        }
        if newRecent != recent { recent = newRecent }
        if stamps != noteStamps { noteStamps = stamps }
    }

    /// `nodes` without the folders at `hidden`, at any depth.
    static func removing(_ hidden: Set<String>, from nodes: [FileNode]) -> [FileNode] {
        guard !hidden.isEmpty else { return nodes }
        return nodes.filter { !($0.isFolder && hidden.contains($0.path)) }.map { node in
            FileNode(path: node.path, isFolder: node.isFolder, children: node.children.map { removing(hidden, from: $0) })
        }
    }

    private static func item(from node: FileNode, graph: NoteGraphService?) -> Item {
        let kind: Kind = node.isFolder ? .folder : (isNote(node.path) ? .note : .attachment)
        return Item(
            path: node.path,
            name: kind == .note ? noteTitle(node.path, graph: graph) : lastComponent(node.path),
            kind: kind,
            children: node.children?.filter { !isOwnCollection($0.path, of: node.path) }.map { item(from: $0, graph: graph) }
        )
    }

    static func isNote(_ path: String) -> Bool { path.lowercased().hasSuffix(".md") }

    /// A folder's own collection, `<Folder>/<Folder>.base`: the folder opens as it, so the tree does not list it.
    static func isOwnCollection(_ path: String, of folder: String) -> Bool {
        path == folder + "/" + lastComponent(folder) + ".base"
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func noteTitle(_ path: String, graph: NoteGraphService?) -> String {
        if let title = graph?.note(at: path)?.title, !title.isEmpty { return title }
        return String(lastComponent(path).dropLast(3))
    }

    func kind(of path: String) -> Kind? {
        func find(_ items: [Item]) -> Kind? {
            for item in items {
                if item.path == path { return item.kind }
                if let found = find(item.children ?? []) { return found }
            }
            return nil
        }
        return find(items)
    }

    /// Where a new note goes: the folder of the note in the focused tab or the focused folder, unless that is the
    /// root or a folder a plugin owns (a daily note's, a project's, the attachments'), then the inbox
    /// (`ManagedFolders.newItemFolder`).
    var activeFolder: String {
        guard let resource = workspace()?.activeResource else { return VaultPath.inbox }
        switch resource.kind {
        case .file: return managedFolders().newItemFolder(from: VaultPath.directory(of: resource.path))
        case .folder: return managedFolders().newItemFolder(from: resource.path)
        case .virtual: return VaultPath.inbox
        }
    }

    /// `folder`, or the inbox for the root: new notes do not land at the root.
    static func newNoteFolder(_ folder: String) -> String {
        folder.isEmpty ? VaultPath.inbox : folder
    }

    // MARK: Clicks and selection

    /// A click on a row: a folder opens or closes in the tree and leaves the page alone, so the sidebar finds another
    /// note without losing this one; Cmd-click shows its page of cards in a new tab. Anything else opens, in the
    /// focused tab or a new one.
    func click(_ item: Item, newTab: Bool) {
        // A click elsewhere ends a rename, as Finder does: the name typed so far is kept.
        if renaming != nil, renaming != item.path { commitRename() }
        if item.kind == .folder {
            if newTab {
                selected = item.path
                workspace()?.open(.folder(item.path), placement: .newTab)
            } else {
                toggle(item.path)
            }
        } else {
            open(item.path, newTab: newTab)
        }
    }

    func open(_ path: String, newTab: Bool = false, from origin: OpenOrigin? = nil) {
        selected = path
        workspace()?.open(.file(path), placement: newTab ? .newTab : .replace, from: origin)
    }

    /// In one transaction for the whole sidebar, so the sections below the folders (Tags…) slide with the rows
    /// instead of jumping: the folders' own `.animation` reaches only their section.
    func toggle(_ folder: String) {
        lastToggled = folder
        Motion.with(FolderUnfold.slide) {
            if expanded.contains(folder) { expanded.remove(folder) } else { expanded.insert(folder) }
        }
    }

    func collapseAll() {
        lastToggled = nil
        Motion.with(FolderUnfold.slide) { expanded.removeAll() }
    }

    /// Follows the focused tab. (A new note left empty is not thrown away here: it has no file until it holds text,
    /// and the editor removes one it wrote when it is closed.)
    func activeChanged(_ resource: Resource?) {
        guard let resource else { return }
        // A page that is no file (All Notes, Tasks) has no row: the last note's row lets go of the selection, so
        // the sidebar never shows two places as current.
        selected = resource.kind == .virtual ? nil : resource.path
    }

    /// Opens the folders down to the note in the focused tab and selects it. Returns its path, nil without one.
    @discardableResult
    func revealActive() -> String? {
        guard let resource = workspace()?.activeResource, resource.kind != .virtual else { return nil }
        expandAncestors(of: resource.path)
        selected = resource.path
        return resource.path
    }

    /// Shows the row of `folder`: its parents open, and every top-level folder listed when it is past the first five.
    func revealFolder(_ folder: String) {
        expandAncestors(of: folder)
        let top = folder.split(separator: "/").first.map(String.init) ?? folder
        if !folderRows.contains(where: { $0.item.path == top }) { showsAllFolders = true }
    }

    private func expandAncestors(of path: String) {
        var folder = VaultPath.directory(of: path)
        while !folder.isEmpty {
            expanded.insert(folder)
            folder = VaultPath.directory(of: folder)
        }
    }

    // MARK: Creating

    /// Opens a new "Untitled" in `folder` (the inbox for the root) in the focused tab, or in a new one, and returns
    /// its path. With an editor the note is a draft: no file exists until text is typed, and one left empty never
    /// reaches the disk. Without an editor the file is written at once. Throws what `FilesService` throws.
    func createNote(in folder: String, newTab: Bool = false) throws -> String {
        let folder = Self.newNoteFolder(folder)
        guard let editor = editor() else {
            let path = try files.newNote(in: folder, name: nil)
            expandAncestors(of: path)
            refresh()
            open(path, newTab: newTab)
            Sounds.play(.created)
            return path
        }
        let path = try files.newNotePath(in: folder, name: nil, isTaken: { editor.isDraft($0) })
        editor.beginDraft(at: path)
        open(path, newTab: newTab)
        Sounds.play(.created)
        return path
    }

    /// The panel's "New Note": errors go to the message line.
    func newNote(in folder: String) {
        do { _ = try createNote(in: folder) } catch { show(error) }
    }

    /// Creates "New folder" in `folder` and starts renaming it.
    func newFolder(in folder: String) {
        do {
            let path = try files.newFolder(in: folder, name: nil)
            Sounds.play(.created)
            expandAncestors(of: path)
            refresh()
            // A folder past the first `folderLimit` would be renamed out of sight, under "N more folders".
            let top = String(path.split(separator: "/").first ?? "")
            if topFolders.prefix(Self.folderLimit).allSatisfy({ $0.path != top }) { showsAllFolders = true }
            beginRename(path)
        } catch {
            show(error)
        }
    }

    // MARK: Renaming

    /// The name the rename field starts with: the file name without its extension for a note or a file a view type
    /// opens, else the whole name.
    func editableName(_ path: String, kind: Kind) -> String {
        switch kind {
        case .note: String(Self.lastComponent(path).dropLast(noteSuffix(path).count))
        case .attachment where opensInApp(path): Resource.file(path).name
        case .folder, .attachment: Self.lastComponent(path)
        }
    }

    /// The end of a note's name that a rename keeps: `.excalidraw.md` for a note a view type opens by that second
    /// extension (a drawing), so it stays one; `.md` for any other note.
    func noteSuffix(_ path: String) -> String {
        let inner = (String(Self.lastComponent(path).dropLast(3)) as NSString).pathExtension
        guard !inner.isEmpty, inner.allSatisfy(\.isLetter), let views = views(),
              let opener = views.viewTypes(for: .file(path)).first?.id,
              opener != views.viewTypes(for: .file("note.md")).first?.id
        else { return ".md" }
        return "." + inner + ".md"
    }

    func beginRename(_ path: String) {
        renameText = editableName(path, kind: kind(of: path) ?? .attachment)
        renaming = path
    }

    func cancelRename() {
        renaming = nil
    }

    /// "Rename…" from a tab's or a page's menu, away from the panel: asks for the new name in a sheet on the window,
    /// the name selected as in Finder, then renames; a failure says why in a toast.
    func promptRename(_ path: String) {
        let field = NSTextField(string: editableName(path, kind: kind(of: path) ?? .attachment))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename")
        alert.informativeText = String(localized: "Links to it follow the new name.")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let failure = message
            if rename(path, to: field.stringValue) == nil, let toasts = toasts() {
                toasts.show(message ?? failure ?? String(localized: "It could not be renamed."), kind: .error)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Return in the name field.
    func commitRename() {
        guard let path = renaming else { return }
        renaming = nil
        _ = rename(path, to: renameText)
    }

    /// Renames in place, keeping `.md` on a note and the extension of a file a view type opens (links follow when
    /// the note graph is on). Returns the new path, the old one when the name did not change, nil on error (shown in
    /// the panel).
    func rename(_ path: String, to name: String) -> String? {
        let kind = kind(of: path) ?? (Self.isNote(path) ? .note : .attachment)
        var newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != editableName(path, kind: kind) else { return path }
        if kind == .note {
            let suffix = noteSuffix(path)
            if !newName.lowercased().hasSuffix(suffix.lowercased()) {
                if Self.isNote(newName) { newName.removeLast(3) }
                newName += suffix
            }
        }
        let ext = (path as NSString).pathExtension
        if kind == .attachment, !ext.isEmpty, opensInApp(path), (newName as NSString).pathExtension.lowercased() != ext.lowercased() {
            newName += "." + ext
        }
        let folder = VaultPath.directory(of: path)
        let destination = folder.isEmpty ? newName : folder + "/" + newName
        return move(path, to: destination)
    }

    // MARK: Moving

    /// Moves `path` into `folder` (`""` is the root), keeping its name. Nothing happens when it is already there.
    @discardableResult
    func move(_ path: String, into folder: String) -> String? {
        guard VaultPath.directory(of: path) != folder, path != folder else { return path }
        let name = Self.lastComponent(path)
        return move(path, to: folder.isEmpty ? name : folder + "/" + name)
    }

    /// Set by the plugin: the popup list "Move to…" picks a folder in.
    @ObservationIgnored var quickPick: @MainActor () -> (any QuickPick)? = { nil }

    /// "Move to…": a popup list of the vault's folders (never the root), filtered as one types; the choice moves
    /// `path` there, links following. The quick way to empty the inbox.
    func askMove(_ path: String) {
        guard let picker = quickPick() else { return }
        let here = VaultPath.directory(of: path)
        let folders = ((try? files.tree()).map { Self.folders(in: Self.removing(hiddenFolders(), from: $0)) } ?? [])
            .filter { $0 != here && $0 != path && !$0.hasPrefix(path + "/") }
        let rows = folders.map { folder in
            QuickPickItem(id: folder, title: Self.lastComponent(folder),
                          subtitle: VaultPath.directory(of: folder).isEmpty ? nil : VaultPath.directory(of: folder),
                          symbol: "folder")
        }
        picker.show(placeholder: "Move “\(Self.lastComponent(path))” to…", items: { query in
            query.isEmpty ? rows : Fuzzy.rank(rows, query: query) { $0.id }
        }, choose: { [weak self] row in
            if let moved = self?.move(path, into: row.id), moved != path { Sounds.play(.dropped) }
        })
    }

    /// Every folder of a tree, depth first.
    static func folders(in nodes: [FileNode]) -> [String] {
        nodes.flatMap { node -> [String] in
            guard node.isFolder else { return [] }
            return [node.path] + folders(in: node.children ?? [])
        }
    }

    /// A drop on a folder row (or the empty area, `""`).
    func drop(_ payload: DragPayload, into folder: String) {
        guard case .resource(let resource) = payload, resource.kind != .virtual else { return }
        if move(resource.path, into: folder) != resource.path { Sounds.play(.dropped) }
    }

    private func move(_ path: String, to destination: String) -> String? {
        do {
            _ = try files.move(path, to: destination)
        } catch {
            show(error)
            return nil
        }
        // An open folder stays open under its new path.
        expanded = Set(expanded.map { folder in
            folder == path || folder.hasPrefix(path + "/") ? destination + folder.dropFirst(path.count) : folder
        })
        if let selected, selected == path || selected.hasPrefix(path + "/") {
            self.selected = destination + selected.dropFirst(path.count)
        }
        // A folder keeps its icon and colour under its new path.
        let styles = FolderStyles.shared.custom
        // A stale style left at the destination by a folder that no longer exists gives way to the moved one: two
        // equal keys would trap `Dictionary(uniqueKeysWithValues:)`.
        var moved = styles.filter { folder, _ in !(folder == path || folder.hasPrefix(path + "/")) }
        for (folder, style) in styles where folder == path || folder.hasPrefix(path + "/") {
            moved[destination + folder.dropFirst(path.count)] = style
        }
        if moved != styles {
            FolderStyles.shared.custom = moved
            saveFolderStyles(moved)
        }
        expandAncestors(of: destination)
        refresh()
        return destination
    }

    // MARK: Trash

    func requestDelete(_ path: String) {
        pendingDelete = path
    }

    func confirmDelete() {
        guard let path = pendingDelete else { return }
        pendingDelete = nil
        trash(path)
    }

    /// Moves `path` into the vault's `.trash/`. Returns the trash path, nil on error.
    @discardableResult
    func trash(_ path: String) -> String? {
        do {
            let destination = try files.trash(path)
            Sounds.play(.trashed)
            expanded = expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
            refresh()
            return destination
        } catch {
            show(error)
            return nil
        }
    }

    // MARK: Finder

    func revealInFinder(_ path: String) {
        let url = path.isEmpty ? vault.rootURL : vault.rootURL.appendingPathComponent(path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Errors

    /// Shows `error` for a few seconds; a newer one replaces it.
    func show(_ error: Error) {
        message = Self.describe(error)
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.messageSeconds))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case VaultError.alreadyExists(let path): "“\(lastComponent(path))” already exists there."
        case VaultError.notFound(let path): "“\(lastComponent(path))” no longer exists."
        case VaultError.outsideVault: "That place is outside the vault."
        case FilesError.invalidName(let name): "“\(name)” is not a valid name."
        case FilesError.hiddenPath: "Hidden folders cannot be used here."
        case FilesError.moveIntoItself: "A folder cannot move into itself."
        case FilesError.alreadyInTrash: "This is already in the trash."
        default: error.localizedDescription
        }
    }
}
