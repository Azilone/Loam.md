import Foundation
import PluginKitUI
import SwiftUI
import TasksPlugin

/// A note's "Stats" tab in the right sidebar (its word, character and task counts, reading time and dates), and the
/// `note-info.show` command, which also describes its properties, tags, backlinks and boards. Reads the
/// `note-graph`, the `tasks` service when there is one, and the editor's unsaved text; writes nothing.
public final class NoteInfoPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "note-info",
        name: "Note Info",
        version: "0.1.0",
        description: "The properties, backlinks and statistics of the open note.",
        icon: "info.circle",
        requires: ["note-graph", "note-query"],
        optionalRequires: ["tasks", "editor", "note-boards"],
        permissions: ["ui", "vault.read"]
    )

    static let statisticsID = "note-info.statistics"
    /// Internal: lets the tests reach the panel's model, which the view drives. Not a contract.
    static var modelKey: ServiceKey<NoteInfoModel> { ServiceKey("note-info.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let graph = context.service(.noteGraph), let query = context.service(.noteQuery) else {
            throw NoteInfoError.serviceMissing
        }
        let model = NoteInfoModel(
            vault: context.vault,
            graph: graph,
            query: query,
            tasks: { [weak context] in context?.service(.tasks) },
            editor: { [weak context] in context?.editor },
            workspace: { [weak context] in context?.workspace },
            boards: { [weak context] in context?.service(.noteBoards) }
        )
        model.activeChanged(context.workspace?.activeResource)
        try context.provide(Self.modelKey, model)

        let isNote: @MainActor @Sendable (Resource) -> Bool = { $0.kind == .file && $0.pathExtension == "md" }
        try context.addInspectorSection(InspectorSection(
            id: Self.statisticsID, placement: .tab(InspectorPage(id: "stats", title: "Stats", order: 30)),
            appliesTo: isNote
        ) { _ in AnyView(NoteStatisticsSection(model: model)) })

        try context.registerCommand(Command(
            id: "note-info.show",
            title: "Note info",
            summary: "Describes a note as JSON: title, frontmatter properties, tags, the notes linking to it, the boards "
                + "showing it, its word and character counts, done and total tasks, and reading time in minutes. "
                + "Optional argument: "
                + "path (default: the open note). Writes nothing.",
            isInPalette: false
        ) { arguments in
            let path = arguments["path"].flatMap { $0.isEmpty ? nil : $0 }
            return try await MainActor.run { try model.report(for: path) }
        })

        context.on(VaultChanged.self) { [weak model] event in
            guard !event.noteChanges.isEmpty else { return }
            MainThread.run { model?.refresh() }
        }
        context.on(NotesMoved.self) { [weak model] event in
            let moves = event.moves
            MainThread.run { model?.notesMoved(moves) }
        }
        context.on(ActiveResourceChanged.self) { [weak model] event in
            let resource = event.resource
            MainThread.run { model?.activeChanged(resource) }
        }
        context.on(DocumentTextChanged.self) { [weak model] event in
            let path = event.path
            MainThread.run { model?.textChanged(path) }
        }
    }
}

enum NoteInfoError: Error, Equatable {
    /// The host activates this plugin after `note-graph` and `note-query` (both in `requires`), so this means a
    /// broken host.
    case serviceMissing
}

