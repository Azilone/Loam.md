import AssistantPlugin
import Foundation
import ObsidianImportPlugin
import PluginKitUI
import SwiftUI

/// The import page (`import:`, `import.open`): a prompt the user pastes into their own agent, which migrates any app's
/// notes into a new vault by following `loam guide migrate`. The onboarding's `ObsidianImportRequested` opens it on an
/// Obsidian vault and imports it at once through the `obsidian-import` service, then lets the user's agent, through
/// the `assistant` service, finish what plain Markdown loses.
public final class ImportUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "import-ui",
        name: "Import",
        version: "0.2.0",
        description: "Brings your notes from any app, moved by your agent.",
        icon: "square.and.arrow.down",
        optionalRequires: ["obsidian-import", "assistant"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    static let viewTypeID = "import.page"
    static let resource = Resource.virtual("import:")
    /// Internal: lets the tests reach the shared model. Not a contract.
    static var modelKey: ServiceKey<ImportModel> { ServiceKey("import-ui.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let model = ImportModel(
            importer: { [weak context] in context?.service(.obsidianImport) },
            assistant: { [weak context] in context?.service(.assistant) },
            vault: { [weak context] in context?.vault },
            workspace: { [weak context] in context?.workspace }
        )
        try context.provide(Self.modelKey, model)

        try context.registerView(ViewType(
            id: Self.viewTypeID,
            title: "Import",
            symbol: "square.and.arrow.down",
            canOpen: { $0 == Self.resource },
            makeView: { _ in AnyView(ImportView(model: model)) }
        ))

        model.report = { [weak context] progress in context?.emit(progress) }
        context.on(ObsidianImportRequested.self) { [weak model] event in
            Task { @MainActor in await model?.importRequested(event.path, useAgent: event.useAgent, page: Self.resource) }
        }

        try context.registerCommand(Command(
            id: "import.open",
            title: "Import from Another App…",
            summary: "Opens the import page, which gives the user a prompt for their own agent: it migrates the notes "
                + "of any app (Notion, Obsidian, Bear, Evernote…) into a new vault. An agent already here reads "
                + "`loam guide migrate` instead."
        ) { _ in
            await MainActor.run {
                model.show(Self.resource)
                return "Opened the import page."
            }
        })
    }
}
