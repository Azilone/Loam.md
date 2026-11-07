import Foundation
import PluginKit

/// Search by name, content and meaning: provides the `search` service and the `search.*` commands.
///
/// Uses the Truffle daemon (https://github.com/Azilone/truffle) when it runs. Without it, names and content fall
/// back to a built-in scan of the vault's Markdown files; meaning needs Truffle. This plugin never indexes
/// anything itself and never writes.
public final class TruffleSearchPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "truffle-search",
            name: "Search",
            version: "0.2.0",
            description: "Finds notes by name, content and meaning (meaning needs Truffle).",
            icon: "magnifyingglass",
            provides: ["search"],
            permissions: ["vault.read", "local-service"]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let service = VaultSearchService(vault: context.vault)
        service.followChanges()
        context.on(VaultChanged.self) { _ in service.vaultChanged() }
        try context.provide(.search, service)

        func register(_ kind: SearchKind, title: String, summary: String) throws {
            try context.registerCommand(Command(
                id: "search.\(kind.rawValue)", title: title, summary: summary, isInPalette: false
            ) { arguments in
                let query = try arguments.require("q")
                let limit = arguments["limit"].flatMap(Int.init) ?? 20
                return try JSON.string(SearchResults(hits: try service.search(query, kind: kind, limit: limit)))
            })
        }

        try register(
            .names,
            title: "Search file names",
            summary: "Fuzzy search of note file names in the vault (Truffle, or a built-in scan without it). "
                + "Arguments: q; optional: limit (20). Returns hits with path and title."
        )
        try register(
            .content,
            title: "Search file contents",
            summary: "Case-insensitive text search in the vault's notes (Truffle, or a built-in scan without it). "
                + "Arguments: q; optional: limit (20). Returns one hit per matching line: path, line, snippet."
        )
        try register(
            .meaning,
            title: "Search by meaning",
            summary: "Finds notes by what they say, in any language. Needs Truffle running. "
                + "Arguments: q; optional: limit (20). Returns hits with path and the passage that matched."
        )

        try context.registerCommand(Command(
            id: "search.status",
            title: "Search status",
            summary: "Tells whether the Truffle daemon is running and what it has indexed, and so whether search by "
                + "meaning is available."
        ) { _ in try JSON.string(service.status()) })
    }
}

/// What the `search.names`, `search.content` and `search.meaning` commands return.
struct SearchResults: Codable {
    let hits: [SearchHit]
}
