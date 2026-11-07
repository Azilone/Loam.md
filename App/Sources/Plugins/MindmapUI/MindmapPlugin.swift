import FileExplorerPlugin
import Foundation
import PluginKitUI
import SwiftUI

/// Mindmaps that are plain Markdown notes: a `# central topic` and a nested list, flagged `mindmap-plugin: basic`
/// in the frontmatter (the format of the Obsidian "Native Mindmap" plugin). Flagged notes open as a map; any note
/// can be shown as one (`mindmap:<path>` resources), read only when it has sections. Editing the map writes the
/// note; it follows typing in the editor live.
public final class MindmapPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "mindmap",
        name: "Mindmap",
        version: "0.3.0",
        description: "Shows a note's headings and lists as a mindmap you can edit.",
        icon: LoamSymbol.mindmap,
        optionalRequires: ["editor", "files"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    static let viewTypeID = "mindmap.note"
    static let fileViewTypeID = "mindmap.file"
    static let scheme = "mindmap:"
    static let symbol = LoamSymbol.mindmap
    /// Internal: lets the tests reach the shared store. Not a contract.
    static var storeKey: ServiceKey<MindmapStore> { ServiceKey("mindmap.store") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let store = MindmapStore(
            vault: context.vault,
            editor: { [weak context] in context?.editor },
            workspace: { [weak context] in context?.workspace }
        )
        try context.provide(Self.storeKey, store)
        store.managedFolders = { [weak context] in context?.waterfall(ManagedFolders()) ?? ManagedFolders() }
        // A new one left untouched goes to Recently Deleted once the focus moves away.
        let vault = context.vault
        let drafts = UntouchedDrafts(read: { try? vault.read($0) }, discard: { [weak context] path in
            _ = try? context?.service(.files)?.trash(path)
        })
        store.drafts = drafts
        context.on(ActiveResourceChanged.self) { event in
            MainThread.run { drafts.focusMoved(to: event.resource) }
        }
        context.on(NotesMoved.self) { event in
            MainThread.run { drafts.moved(event.moves) }
        }

        var noteView = ViewType(
            id: Self.viewTypeID,
            title: "Mindmap",
            canOpen: { $0.kind == .virtual && Self.notePath(of: $0) != nil },
            makeView: { view in AnyView(NativeView { Self.makeMap(store: store, view: view, viewType: Self.viewTypeID) }) }
        )
        // The map is AppKit (`MindmapCanvasView`): SwiftUI laid out every topic at each frame of a pan or a zoom.
        noteView.makeNSView = { view in Self.makeMap(store: store, view: view, viewType: Self.viewTypeID) }
        try context.registerView(noteView)
        // Any note in the mindmap format can be shown as a map (the page's view switcher); a flagged note opens as
        // one, and its icon is the map's.
        var fileView = ViewType(
            id: Self.fileViewTypeID,
            title: "Mindmap",
            symbol: Self.symbol,
            canOpen: { store.format(of: $0).isCompatible },
            prefers: { store.format(of: $0) == .flagged },
            makeView: { view in AnyView(NativeView { Self.makeMap(store: store, view: view, viewType: Self.fileViewTypeID) }) }
        )
        fileView.makeNSView = { view in Self.makeMap(store: store, view: view, viewType: Self.fileViewTypeID) }
        // On a board a map is drawn at its own size, with no card round it.
        fileView.sizesToContent = true
        try context.registerView(fileView)
        try context.addNewItem(NewItem(
            id: "mindmap.new", title: "New Mindmap", symbol: Self.symbol, order: 10, viewType: Self.fileViewTypeID
        ) { folder in
            _ = try? store.createMap(in: folder)
        })
        try context.addSidebarLink(SidebarLink(
            id: "mindmap.link", title: "Mindmaps", symbol: Self.symbol,
            resource: .notes(titled: "Mindmaps", openedBy: Self.fileViewTypeID), order: 33
        ))

        try context.registerCommand(Command(
            id: "mindmap.new",
            title: "New mindmap",
            summary: "Creates a mindmap note (a central topic and a nested list, flagged `mindmap-plugin: basic`) "
                + "and opens it. Arguments: folder (optional, defaults to the active note's folder, else Inbox; Inbox "
                + "too when that folder belongs to a plugin), title "
                + "(optional). Writes a new note."
        ) { args in
            try await MainActor.run {
                let folder: String
                if let argument = args["folder"] {
                    folder = argument
                } else {
                    // Never the root, never a plugin's folder: the same rule as a new note.
                    let active = store.workspace()?.activeResource
                    folder = store.managedFolders().newItemFolder(from: active.flatMap { $0.kind == .file ? VaultPath.directory(of: $0.path) : nil })
                }
                let path = try store.createMap(in: folder, title: args["title"].flatMap { $0.isEmpty ? nil : $0 })
                return "Created \(path)."
            }
        })

        try context.registerCommand(Command(
            id: "mindmap.open",
            title: "Open mindmap",
            summary: "Opens a note as a mindmap beside the focused tab. Argument: path (optional, defaults to the "
                + "active note). Editing the map writes the note."
        ) { args in
            try await MainActor.run {
                let path: String
                if let argument = args["path"], !argument.isEmpty {
                    path = argument
                } else if let active = store.workspace()?.activeResource, active.kind == .file,
                    active.pathExtension == "md" {
                    path = active.path
                } else {
                    throw CommandError.missingArgument(name: "path")
                }
                store.workspace()?.open(.virtual(Self.scheme + path), placement: .beside)
                return "Opened the mindmap of \(path)."
            }
        })

        try MindmapCommands.register(in: context, store: store)

        context.on(DocumentTextChanged.self) { [weak store] event in
            let path = event.path
            MainThread.run { store?.documentChanged(path) }
        }
        context.on(VaultChanged.self) { [weak store] event in
            let paths = event.changes.map(\.path)
            MainThread.run { store?.vaultChanged(paths) }
        }
        context.on(NotesMoved.self) { [weak store] event in
            let moves = event.moves
            MainThread.run { store?.moved(moves) }
        }
    }

    /// A path for a new note named `name` in `folder` that is not taken yet.
    static func freePath(folder: String, name: String, vault: VaultAccess) -> String {
        let base = folder.isEmpty ? name : folder + "/" + name
        var path = base + ".md"
        var n = 2
        while vault.exists(path) {
            path = "\(base) \(n).md"
            n += 1
        }
        return path
    }

    /// A map's view, in a page or on a board's card, and its inspector tab.
    @MainActor static func makeMap(store: MindmapStore, view: ViewContext, viewType: String) -> NSView {
        let model = store.makeTab(view)
        view.setInspector(viewType: viewType, tabs: [
            InspectorTab(id: "mindmap.style", title: "Style") { AnyView(MindmapInspector(model: model)) },
        ])
        return MindmapCanvasView(model: model)
    }

    /// The note a `mindmap:<path>` resource or a flagged note's tab shows; nil for anything else.
    static func notePath(of resource: Resource) -> String? {
        if resource.kind == .file { return resource.path }
        guard resource.kind == .virtual, resource.path.hasPrefix(scheme) else { return nil }
        let rest = String(resource.path.dropFirst(scheme.count))
        return rest.isEmpty ? nil : rest
    }
}

