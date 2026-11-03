import Foundation
import PluginKit

/// The `import.obsidian` command: copies an Obsidian vault into the current vault as plain Markdown. Also lists the
/// vaults Obsidian knows (`import.obsidian.vaults`) and offers both as the `obsidian-import` service.
public final class ObsidianImportPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "obsidian-import",
            name: "Obsidian import",
            version: "0.1.0",
            description: "Copies an Obsidian vault into this one as plain Markdown.",
            icon: "square.and.arrow.down",
            provides: ["obsidian-import"],
            permissions: ["vault.read", "vault.write", "disk.read"]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let importer = ObsidianImporter(vault: context.vault)
        try context.provide(.obsidianImport, importer)
        try context.registerCommand(Command(
            id: "import.obsidian.vaults",
            title: "List Obsidian vaults",
            summary: "Lists the Obsidian vaults on this Mac, from Obsidian's own list, most recently opened first. "
                + "Returns JSON: name, path, notes, opened.",
            isInPalette: false
        ) { _ in
            try JSON.string(importer.vaults())
        })
        try context.registerCommand(Command(
            id: "import.obsidian",
            title: "Import an Obsidian vault",
            summary: """
                Converts an Obsidian vault into plain Markdown in the current vault: wikilinks and embeds become \
                standard links, callouts become GitHub alerts, comments are removed. The source is never \
                modified and existing files are never overwritten unless overwrite=true. \
                Arguments: source (path to the Obsidian vault); optional: into (folder of the current vault), \
                dry-run=true, overwrite=true.
                """,
            isInPalette: false
        ) { arguments in
            let source = URL(fileURLWithPath: (try arguments.require("source") as NSString).expandingTildeInPath)
            let options = ImportOptions(
                source: source,
                into: arguments["into"] ?? "",
                dryRun: arguments["dry-run"] == "true",
                overwrite: arguments["overwrite"] == "true"
            )
            return try JSON.string(try importer.run(options))
        })
    }
}
