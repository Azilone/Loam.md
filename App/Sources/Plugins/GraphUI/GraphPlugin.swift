import Foundation
import PluginKitUI
import SwiftUI

/// The graph view: the notes of the vault as dots and their links as lines, laid out by a force-directed layout
/// (`GraphLayout`). `graph:` shows the whole vault; `graph:<path>` the local graph of a note (its links and
/// backlinks, one or two steps away). Reads the `note-graph` service; writes nothing.
public final class GraphPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "graph",
        name: "Graph view",
        version: "0.1.0",
        description: "A map of the vault: every note and the links between them.",
        icon: "point.3.connected.trianglepath.dotted",
        requires: ["note-graph"],
        permissions: ["ui", "vault.read"]
    )

    static let viewTypeID = "graph.vault"
    static let scheme = "graph:"
    /// The resource `graph.open` opens.
    static let vaultResource = Resource.virtual(scheme)
    /// Internal: lets the tests reach the shared store. Not a contract.
    static var storeKey: ServiceKey<GraphStore> { ServiceKey("graph.store") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let graph = context.service(.noteGraph) else { throw GraphError.noteGraphMissing }
        let store = GraphStore(graph: graph, workspace: { [weak context] in context?.workspace })
        try context.provide(Self.storeKey, store)

        try context.registerView(ViewType(
            id: Self.viewTypeID,
            title: "Graph",
            canOpen: { Self.isGraph($0) },
            makeView: { view in AnyView(GraphTab(store: store, view: view)) }
        ))

        try context.addSidebarLink(SidebarLink(
            id: "graph.vault-link",
            title: "Graph view",
            symbol: "point.3.connected.trianglepath.dotted",
            resource: Self.vaultResource,
            order: 30
        ))

        try context.registerCommand(Command(
            id: "graph.open",
            title: "Open graph",
            summary: "Opens the graph of the whole vault (notes as dots, links as lines) in a new tab. Writes "
                + "nothing; returns what it did."
        ) { _ in
            await MainActor.run {
                store.open(Self.vaultResource, placement: .newTab)
                return "Opened the graph of the vault."
            }
        })

        try context.registerCommand(Command(
            id: "graph.open-local",
            title: "Open local graph",
            summary: "Opens the local graph of a note (the notes it links to and the notes linking to it) beside "
                + "the focused tab. Argument: path (optional, defaults to the active note). Writes nothing."
        ) { args in
            try await MainActor.run {
                let path = try Self.notePath(args["path"], active: store.activeResource)
                store.open(.virtual(Self.scheme + path), placement: .beside)
                return "Opened the local graph of \(path)."
            }
        })

        context.on(VaultChanged.self) { [weak store] event in
            guard !event.noteChanges.isEmpty else { return }
            MainThread.run { store?.vaultChanged() }
        }
        context.on(NotesMoved.self) { [weak store] _ in
            MainThread.run { store?.vaultChanged() }
        }
    }

    /// `graph:` or `graph:<path of a note>`.
    static func isGraph(_ resource: Resource) -> Bool {
        resource.kind == .virtual && resource.path.hasPrefix(scheme)
    }

    /// The note a `graph:<path>` resource is centred on; nil for `graph:` (the vault).
    static func center(of resource: Resource) -> String? {
        guard isGraph(resource) else { return nil }
        let rest = String(resource.path.dropFirst(scheme.count))
        return rest.isEmpty ? nil : rest
    }

    /// The `path` argument, or the active note.
    static func notePath(_ argument: String?, active: Resource?) throws -> String {
        if let argument, !argument.isEmpty { return argument }
        guard let active, active.kind == .file, active.pathExtension == "md" else {
            throw CommandError.missingArgument(name: "path")
        }
        return active.path
    }
}

/// Builds the tab's model once for the life of the view.
private struct GraphTab: View {
    let view: ViewContext
    @State private var model: GraphTabModel

    init(store: GraphStore, view: ViewContext) {
        self.view = view
        _model = State(wrappedValue: store.makeTab(view))
    }

    var body: some View {
        GraphView(model: model)
            .onAppear { [model] in
                view.setInspector(viewType: GraphPlugin.viewTypeID, tabs: [
                    InspectorTab(id: "graph.options", title: "Graph") { AnyView(GraphInspector(model: model)) },
                ])
            }
    }
}

enum GraphError: Error, Equatable {
    /// The host activates this plugin after `note-graph` (it is in `requires`), so this means a broken host.
    case noteGraphMissing
}

