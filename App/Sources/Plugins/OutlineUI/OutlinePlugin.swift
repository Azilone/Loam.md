import Foundation
import PluginKitUI
import SwiftUI

/// The Outline panel in the right sidebar: the headings of the active note, live while typing (from the
/// `editor` service's `text(of:)` and `DocumentTextChanged`), a click jumps to one (`reveal(line:in:)`).
/// `outline.headings` gives agents the same list. A long note also shows its headings as ticks at the right edge
/// of the page (`OutlineTicks`), a page overlay of the `editor` service.
public final class OutlinePlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "outline",
        name: "Outline",
        version: "0.1.0",
        description: "The headings of the open note, to jump to one.",
        icon: "list.bullet.indent",
        optionalRequires: ["editor"],
        permissions: ["ui", "vault.read"]
    )

    static let sectionID = "outline.section"
    static let ticksID = "outline.ticks"
    /// Internal: lets the tests reach the panel's model. Not a contract.
    static var modelKey: ServiceKey<OutlineModel> { ServiceKey("outline.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let model = OutlineModel(
            vault: context.vault,
            editor: { [weak context] in context?.editor },
            workspace: { [weak context] in context?.workspace }
        )
        model.follow(context.workspace?.activeResource)
        try context.provide(Self.modelKey, model)

        // The headings show as ticks beside the page (`OutlineTicks`), not again as a tab of the right sidebar.
        context.addPageOverlay(PageOverlay(id: Self.ticksID) { page in AnyView(OutlineTicks(page: page)) })

        try context.registerCommand(Command(
            id: "outline.headings",
            title: "Outline: list headings",
            summary: "Lists the headings of a note as JSON [{level, text, line}] (line is 1-based), including "
                + "unsaved typing. Argument: path (optional, defaults to the active note). Read-only.",
            isInPalette: false
        ) { args in
            try await MainActor.run {
                guard let path = args["path"].flatMap({ $0.isEmpty ? nil : $0 }) ?? model.path else {
                    throw CommandError.missingArgument(name: "path")
                }
                guard let headings = model.headings(of: path) else { throw OutlineError.noteNotFound(path: path) }
                return try JSON.string(headings)
            }
        })

        context.on(ActiveResourceChanged.self) { [weak model] event in
            let resource = event.resource
            onMainThread { model?.follow(resource) }
        }
        context.on(DocumentTextChanged.self) { [weak model] event in
            let path = event.path
            onMainThread { model?.documentChanged(path) }
        }
        context.on(VaultChanged.self) { [weak model] event in
            let paths = event.changes.map(\.path)
            onMainThread { model?.vaultChanged(paths) }
        }
        context.on(NotesMoved.self) { [weak model] event in
            let moves = event.moves
            onMainThread { model?.moved(moves) }
        }
    }
}

enum OutlineError: Error, Equatable {
    case noteNotFound(path: String)
}

/// Runs main-actor code from an event listener, which Swift cannot prove runs on the main thread. The kernel is
/// main-thread only, so this is normally a direct call.
private func onMainThread(_ body: @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
