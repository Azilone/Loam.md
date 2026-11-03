import Foundation
import PluginKitUI
import SwiftUI

/// Collections in the workspace: a `.base` file, or a folder with its own `<Folder>/<Folder>.base`, opens as
/// Craft's collection page (its views as tabs, search, new entry, view settings). Provides `collections.views`,
/// where the Table, Kanban and Gallery plugins (and anyone's) add their kind of view, and "Turn into Collection"
/// on folders.
public final class CollectionsUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "collections-ui",
        name: "Collections",
        version: "0.1.0",
        description: "The collection page, with its views as tabs.",
        icon: "square.stack",
        provides: ["collections.views"],
        requires: ["collections", "note-query"],
        optionalRequires: ["editor"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    static let folderViewID = "collection.folder"
    static let fileViewID = "collection.file"
    static let tagViewID = "collection.tag"
    static let symbol = "square.grid.3x1.below.line.grid.1x2"
    /// Internal: lets the tests reach the pages' models. Not a contract.
    static var storeKey: ServiceKey<CollectionStore> { ServiceKey("collections-ui.store") }
    static var fieldsKey: ServiceKey<NoteFieldsStore> { ServiceKey("collections-ui.fields") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let views = CollectionViewStore()
        try context.provide(.collectionViews, views as any CollectionViewRegistry)
        let store = CollectionStore(
            collections: { [weak context] in context?.service(.collections) },
            noteQuery: { [weak context] in context?.service(.noteQuery) },
            workspace: { [weak context] in context?.workspace }
        )
        try context.provide(Self.storeKey, store)
        let fields = NoteFieldsStore(
            collections: { [weak context] in context?.service(.collections) },
            noteQuery: { [weak context] in context?.service(.noteQuery) },
            workspace: { [weak context] in context?.workspace }
        )
        try context.provide(Self.fieldsKey, fields)
        // Craft's fields under the title of a note in a collection; other notes show none.
        try context.addNoteHeader(NoteHeader(
            id: "collections.fields",
            placement: .underTitle,
            appliesTo: { $0.kind == .file && fields.collection(containing: $0.path) != nil },
            makeView: { viewContext in
                guard let model = fields.model(for: viewContext) else { return AnyView(EmptyView()) }
                return AnyView(NoteFieldsView(model: model))
            }
        ))

        try context.registerView(ViewType(
            id: Self.folderViewID,
            title: "Collection",
            priority: 1,
            symbol: Self.symbol,
            canOpen: { $0.kind == .folder && store.collection(of: $0) != nil },
            prefers: { $0.kind == .folder && store.collection(of: $0) != nil }
        ) { viewContext in
            AnyView(CollectionPage(model: store.model(for: viewContext), views: views, context: viewContext, viewType: Self.folderViewID))
        })
        try context.registerView(ViewType(
            id: Self.fileViewID,
            title: "Collection",
            priority: 1,
            symbol: Self.symbol,
            canOpen: { $0.kind == .file && $0.pathExtension == "base" }
        ) { viewContext in
            AnyView(CollectionPage(model: store.model(for: viewContext), views: views, context: viewContext, viewType: Self.fileViewID))
        })

        try context.registerView(ViewType(
            id: Self.tagViewID,
            title: "Collection",
            symbol: Self.symbol,
            canOpen: { CollectionStore.tag(of: $0) != nil }
        ) { viewContext in
            AnyView(CollectionPage(model: store.model(for: viewContext), views: views, context: viewContext, viewType: Self.tagViewID))
        })

        context.addCodeBlockView(CodeBlockView(id: "collections.base", languages: ["base"]) { block in
            AnyView(CollectionBlock(model: store.model(for: block), views: views, block: block))
        })
        for item in CollectionBlocks.slashItems { context.addSlashItem(item) }

        context.addResourceAction(ResourceAction(
            id: "collection.turn-into",
            title: "Turn into Collection",
            symbol: Self.symbol,
            appliesTo: { $0.kind == .folder && !$0.path.isEmpty && store.collection(of: $0) == nil },
            perform: { [weak context] resource in
                guard (try? context?.service(.collections)?.create(folder: resource.path)) != nil else { return }
                context?.workspace?.open(resource, placement: .replace)
            }
        ))

        try context.registerCommand(Command(
            id: "collection.open",
            title: "Open collection",
            summary: "Opens a collection page in the focused tab: path (a .base file) or folder (a folder that is a "
                + "collection); without either, the active folder's or file's collection."
        ) { arguments in
            try await MainActor.run { try store.open(arguments) }
        })

        context.on(VaultChanged.self) { [weak store, weak fields] _ in
            onMainThread {
                store?.reloadAll()
                fields?.vaultChanged()
            }
        }
        context.on(NotesMoved.self) { [weak store, weak fields] _ in
            onMainThread {
                store?.reloadAll()
                fields?.vaultChanged()
            }
        }
    }
}

/// The open collection pages' models, one per tab, reloaded when the vault changes.
@MainActor
final class CollectionStore {
    private let collections: @MainActor () -> CollectionService?
    private let noteQuery: @MainActor () -> NoteQueryService?
    private let workspace: @MainActor () -> (any Workspace)?
    private let models = NSMapTable<ViewContext, CollectionViewModel>.weakToStrongObjects()
    private let blocks = NSMapTable<CodeBlockContext, CollectionViewModel>.weakToStrongObjects()

    init(
        collections: @escaping @MainActor () -> CollectionService?,
        noteQuery: @escaping @MainActor () -> NoteQueryService?,
        workspace: @escaping @MainActor () -> (any Workspace)?
    ) {
        self.collections = collections
        self.noteQuery = noteQuery
        self.workspace = workspace
    }

    /// The `.base` a resource opens: the file itself, or a folder's own `<Folder>/<Folder>.base`.
    func collection(of resource: Resource) -> String? {
        switch resource.kind {
        case .file:
            return resource.pathExtension == "base" ? resource.path : nil
        case .folder:
            guard let name = resource.path.split(separator: "/").last else { return nil }
            let path = resource.path + "/" + name + ".base"
            return collections()?.collections().contains(path) == true ? path : nil
        case .virtual:
            return nil
        }
    }

    /// The tag of a tag page, `collection:#tag`.
    static func tag(of resource: Resource) -> String? {
        guard resource.kind == .virtual, resource.path.hasPrefix("collection:#") else { return nil }
        let tag = String(resource.path.dropFirst("collection:#".count))
        return tag.isEmpty ? nil : tag
    }

    /// The unsaved collection of a tag's notes: a gallery and a table.
    static func tagSource(_ tag: String) -> CollectionSource {
        let quoted = tag.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return .inline(yaml: """
        filters: 'file.hasTag("\(quoted.replacingOccurrences(of: "'", with: "''"))")'
        views:
          - type: cards
            name: Gallery
            order: [file.name]
          - type: table
            name: Table
            order: [file.name, file.folder]
        """, host: nil)
    }

    func model(for context: ViewContext) -> CollectionViewModel {
        if let model = models.object(forKey: context) { return model }
        let source: CollectionSource
        if let tag = Self.tag(of: context.resource) {
            source = Self.tagSource(tag)
        } else {
            source = .file(collection(of: context.resource) ?? context.resource.path)
        }
        let model = CollectionViewModel(source: source, collections: collections, noteQuery: noteQuery,
                                        workspace: workspace)
        if let state = context.state(PageState.self) { model.viewName = state.view }
        models.setObject(model, forKey: context)
        return model
    }

    /// `collection.open`: a `.base` path, a folder, or the active resource, in the focused tab.
    func open(_ arguments: [String: String]) throws -> String {
        let resource: Resource
        if let path = arguments["path"], !path.isEmpty {
            resource = .file(try VaultPath.normalize(path))
        } else if let folder = arguments["folder"], !folder.isEmpty {
            resource = .folder(try VaultPath.normalize(folder))
        } else if let active = workspace()?.activeResource {
            resource = active.kind == .file && active.pathExtension != "base"
                ? .folder(VaultPath.directory(of: active.path)) : active
        } else {
            throw CommandError.missingArgument(name: "path")
        }
        guard collection(of: resource) != nil else { throw CollectionError.notACollection(resource.path) }
        workspace()?.open(resource, placement: .replace)
        return resource.path
    }

    /// The model of a ` ```base ` block in a note: its YAML, with the note as `this`; edits go back into the block.
    func model(for block: CodeBlockContext) -> CollectionViewModel {
        if let model = blocks.object(forKey: block) { return model }
        let model = CollectionViewModel(source: .inline(yaml: block.code, host: block.notePath), isEmbedded: true,
                                        collections: collections, noteQuery: noteQuery, workspace: workspace)
        model.onInlineChange = { [weak block] source in
            if case .inline(let yaml, _) = source { block?.replaceCode(yaml) }
        }
        blocks.setObject(model, forKey: block)
        return model
    }

    var openModels: [CollectionViewModel] {
        (models.objectEnumerator()?.allObjects as? [CollectionViewModel] ?? [])
            + (blocks.objectEnumerator()?.allObjects as? [CollectionViewModel] ?? [])
    }

    func reloadAll() {
        for model in openModels { model.reload() }
    }
}

/// What a collection tab saves: the selected view.
struct PageState: Codable, Equatable {
    var view: String?
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
