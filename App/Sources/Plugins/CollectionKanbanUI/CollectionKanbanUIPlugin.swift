import FileExplorerPlugin
import PluginKit
import PluginKitUI
import SwiftUI

/// The board view of collections (`type: kanban`), as Craft draws it: one tinted column per option of the field it
/// groups by (a pill and a count on top), white cards with the shown fields and the note's checklist ("1/3"), "+" under each column to add an entry
/// there, "+" on the right to add a column. Cards are dragged within a column to order them and to another column
/// to write that field in the note; a card can be deleted, and the deletion taken back. The board, its cards and
/// the drag are AppKit (`BoardView`, `BoardCards`).
public final class CollectionKanbanUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "collection-kanban",
        name: "Collection board",
        version: "0.1.0",
        description: "The Kanban view of a collection: drag cards between columns.",
        icon: "rectangle.split.3x1",
        optionalRequires: ["collections.views", "files", "trash"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        // Looked up when used: the file and trash services may be activated after this plugin.
        let checklists = BoardChecklists(vault: context.vault)
        let services = BoardServices(
            trash: { [weak context] path in
                guard let files = context?.service(.files) else { throw BoardError.unavailable("The Files plugin is not active.") }
                return try files.trash(path)
            },
            restore: { [weak context] path in
                guard let trash = context?.service(.trash) else { throw BoardError.unavailable("The Trash plugin is not active.") }
                return try trash.restore(path)
            },
            report: { [weak context] text in context?.toasts?.show(text, isError: true) },
            checklist: { checklists.checklist(of: $0) })
        // The board is AppKit (`BoardScrollView`), in a page and in a note alike.
        var type = CollectionViewType(
            id: "kanban",
            title: "Kanban",
            symbol: "rectangle.split.3x1",
            order: 1,
            groupsEntries: true,
            defaults: Self.defaults
        ) { model in
            AnyView(NativeView { BoardScrollView(model: model, services: services) })
        }
        type.makeNSView = { model in BoardScrollView(model: model, services: services) }
        context.addCollectionView(type)
    }

    /// A new board groups by the first select field, else by a new `status` with Craft's three columns.
    static func defaults(_ definition: CollectionDefinition, _ view: String) -> [CollectionEdit] {
        let order: [PropertyRef]
        let groupBy: PropertyRef
        var edits: [CollectionEdit] = []
        if let select = definition.properties.first(where: { $0.kind == .select || ($0.kind == nil && !$0.options.isEmpty) }) {
            groupBy = select.ref
        } else {
            groupBy = PropertyRef("status")
            var status = definition.property(groupBy)
            status.kind = .select
            if status.options.isEmpty { status.options = ["To do", "In progress", "Done"] }
            edits.append(.setProperty(property: status))
        }
        order = [.title, groupBy]
        return edits + [.setGroupBy(view: view, groupBy: CollectionSort(property: groupBy)), .setOrder(view: view, order: order)]
    }
}
