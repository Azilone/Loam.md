import Foundation
import PluginKitUI
import SwiftUI
import TruffleSearchPlugin

/// The Search panel in the left sidebar, and `search.focus` (Shift+Cmd+F), a popup of content hits as you type.
/// Presents the `search` service of its logic module: Truffle when it runs, a built-in scan otherwise.
public final class SearchUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "search-ui",
        name: "Search panel",
        version: "0.1.0",
        description: "The Search panel, and Shift-Cmd-F to search as you type.",
        icon: "text.magnifyingglass",
        requires: ["search"],
        permissions: ["ui", "vault.read"]
    )

    static let panelID = "search.panel"
    /// Internal: lets the tests reach the panel's model, which the view drives. Not a contract.
    static var modelKey: ServiceKey<SearchModel> { ServiceKey("search-ui.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let service = context.service(.search) else {
            throw SearchUIError.searchServiceMissing
        }
        let model = SearchModel(
            service: service,
            workspace: { [weak context] in context?.workspace },
            quickPick: { [weak context] in context?.quickPick }
        )
        model.refreshStatus()
        try context.provide(Self.modelKey, model)

        try context.registerPanel(Panel(
            id: Self.panelID, title: "Search", symbol: "magnifyingglass", slot: .leading, order: 1
        ) {
            AnyView(SearchPanel(model: model))
        })

        try context.registerCommand(Command(
            id: "search.focus",
            title: "Search in notes",
            summary: "Shows a popup that searches the notes' content as you type (Truffle, or a built-in scan); "
                + "choosing a line opens its note. For a scripted search use search.content.",
            shortcut: KeyShortcut("f", [.command, .shift])
        ) { _ in
            await MainActor.run { model.showQuickPick() }
        })

        context.on(VaultChanged.self) { [weak model] event in
            guard !event.noteChanges.isEmpty else { return }
            MainThread.run { model?.rerun() }
        }
    }
}

enum SearchUIError: Error, Equatable {
    /// The host activates this plugin after `search` (it is in `requires`), so this means a broken host.
    case searchServiceMissing
}

