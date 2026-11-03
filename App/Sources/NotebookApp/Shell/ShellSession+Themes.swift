import Foundation
import PluginKit
import LoamCore

/// The theme commands: they reach the palette, the CLI and agents, so an agent can write a theme and apply it.
extension ShellSession {
    func registerThemeCommands() throws {
        let themes = self.themes
        try registerShell(Command(
            id: "themes.install-examples",
            title: "Install example themes",
            summary: "Writes two example themes, Paper and Night, to .loam/themes/ as templates; existing files are kept."
        ) { _ in
            let written = try await MainActor.run { try themes.installExamples() }
            return written.isEmpty ? "The example themes are already installed." : "Wrote \(written.joined(separator: ", "))."
        })
        try registerShell(Command(
            id: "themes.use",
            title: "Use theme",
            summary: "Writes the theme `name` (a file of .loam/themes/ without .json, or \"system\" for the default theme) to .loam/config.json and applies it.",
            isInPalette: false
        ) { arguments in
            let name = try arguments.require("name")
            return try await MainActor.run {
                try themes.select(name.lowercased() == "system" ? nil : name)
                if let error = themes.error { return error }
                return "Using \(themes.current?.name ?? "the default theme")."
            }
        })
        try registerShell(Command(
            id: "themes.catalog",
            title: "Theme catalog",
            summary: "Lists the themes of the community catalog (network), installable with themes.install id=. Optional: "
                + "query (matches id, name, author and description), catalog (another catalog's URL or path). Returns JSON "
                + "[{id, name, author, description, appearance, installed}].",
            isInPalette: false
        ) { arguments in
            let catalog = try await ThemeCatalog.fetch(arguments["catalog"].flatMap(ThemeCatalog.url) ?? ThemeCatalog.defaultURL)
            let query = arguments["query"]?.lowercased() ?? ""
            let entries = catalog.themes.filter { $0.matches(query) }
            let rows = await MainActor.run {
                entries.map { ThemeCatalogRow(entry: $0, installed: themes.isInstalled($0.id)) }
            }
            return try JSON.string(rows)
        })
        try registerShell(Command(
            id: "themes.install",
            title: "Install theme",
            summary: "Downloads the theme `id` of the community catalog to .loam/themes/<id>.json (network, writes a file), "
                + "then themes.use name=<id> applies it. An existing file is kept unless force=true. Optional: catalog "
                + "(another catalog's URL or path).",
            isInPalette: false
        ) { arguments in
            let id = try arguments.require("id")
            let catalogURL = arguments["catalog"].flatMap(ThemeCatalog.url) ?? ThemeCatalog.defaultURL
            let json = try await ThemeCatalog.fetchTheme(id: id, catalog: catalogURL)
            let force = arguments["force"] == "true"
            let path = try await MainActor.run { try themes.install(id: id, json: json, force: force) }
            return "Wrote \(path). Apply it with themes.use name=\(id)."
        })
    }
}

/// A theme of the catalog, as `themes.catalog` returns it.
private struct ThemeCatalogRow: Encodable {
    let id: String
    let name: String
    let author: String?
    let description: String?
    let appearance: String?
    let installed: Bool

    init(entry: ThemeCatalog.Entry, installed: Bool) {
        id = entry.id
        name = entry.name
        author = entry.author
        description = entry.description
        appearance = entry.appearance
        self.installed = installed
    }
}
