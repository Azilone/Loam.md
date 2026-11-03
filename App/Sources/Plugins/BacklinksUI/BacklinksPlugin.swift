import Foundation
import PluginKitUI
import SwiftUI

/// The "Links" tab of a note's right sidebar: the notes linking to the open note, with the lines where they do, and
/// the notes mentioning its title without a link. Reads the `note-graph` service; writes nothing.
public final class BacklinksPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "backlinks",
        name: "Backlinks",
        version: "0.1.0",
        description: "The notes that link to the open note, and its unlinked mentions.",
        icon: "link",
        requires: ["note-graph"],
        optionalRequires: ["note-boards"],
        permissions: ["ui", "vault.read"]
    )

    static let sectionID = "backlinks.linked"
    /// Internal: lets the tests reach the panel's model, which the view drives. Not a contract.
    static var modelKey: ServiceKey<BacklinksModel> { ServiceKey("backlinks.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let graph = context.service(.noteGraph) else {
            throw BacklinksError.noteGraphMissing
        }
        let model = BacklinksModel(
            vault: context.vault,
            graph: graph,
            workspace: { [weak context] in context?.workspace },
            boards: { [weak context] in context?.service(.noteBoards) }
        )
        model.activeChanged(context.workspace?.activeResource)
        try context.provide(Self.modelKey, model)

        let isNote: @MainActor @Sendable (Resource) -> Bool = { $0.kind == .file && $0.pathExtension == "md" }
        let links = InspectorSection.Placement.tab(InspectorPage(id: "links", title: "Links", order: 20))
        try context.addInspectorSection(InspectorSection(
            id: Self.sectionID, placement: links, order: 10, appliesTo: isNote
        ) { _ in AnyView(BacklinksSectionView(model: model, part: .linked)) })
        // The boards and the unlinked mentions only while there are some: an empty group is noise.
        try context.addInspectorSection(InspectorSection(
            id: "backlinks.boards", placement: links, order: 20,
            appliesTo: { [weak model] in isNote($0) && !(model?.boards.isEmpty ?? true) }
        ) { _ in AnyView(BacklinksSectionView(model: model, part: .boards)) })
        try context.addInspectorSection(InspectorSection(
            id: "backlinks.mentions", placement: links, order: 30,
            appliesTo: { [weak model] in isNote($0) && !(model?.mentions.isEmpty ?? true) }
        ) { _ in AnyView(BacklinksSectionView(model: model, part: .mentions)) })

        try context.registerCommand(Command(
            id: "backlinks.mentions",
            title: "Unlinked mentions",
            summary: "Lists the notes that mention a note's title as a whole word (case-insensitive) without linking "
                + "to it, at most 20, as JSON with the matching lines. Optional argument: path (default: the open "
                + "note). Writes nothing."
        ) { arguments in
            let path = arguments["path"].flatMap { $0.isEmpty ? nil : $0 }
            return try await MainActor.run { try model.mentionsReport(for: path) }
        })

        context.on(VaultChanged.self) { [weak model] event in
            guard !event.noteChanges.isEmpty else { return }
            onMainThread { model?.refresh() }
        }
        context.on(NoteGraphLoaded.self) { [weak model] _ in
            onMainThread { model?.graphLoaded() }
        }
        context.on(NotesMoved.self) { [weak model] event in
            let moves = event.moves
            onMainThread { model?.notesMoved(moves) }
        }
        context.on(ActiveResourceChanged.self) { [weak model] event in
            let resource = event.resource
            onMainThread { model?.activeChanged(resource) }
        }
    }
}

enum BacklinksError: Error, Equatable {
    /// The host activates this plugin after `note-graph` (it is in `requires`), so this means a broken host.
    case noteGraphMissing
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
