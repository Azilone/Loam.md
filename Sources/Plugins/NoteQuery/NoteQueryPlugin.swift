import Foundation
import PluginKit

/// Provides the `note-query` service and the `query.*` commands: notes found by folder, tag and property, sorted,
/// and one property set in place. Reads the note graph's current state; after `setProperty` writes a note it sends
/// `VaultChanged` for that note, so the graph (and every query after it) sees the new value at once.
public final class NoteQueryPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "note-query",
            name: "Note query",
            version: "0.1.0",
            description: "Finds notes by folder, tag and property, for boards, galleries and tasks.",
            icon: "line.3.horizontal.decrease.circle",
            provides: ["note-query"],
            requires: ["note-graph"],
            permissions: ["vault.read", "vault.write"]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let engine = NoteQueryEngine(
            vault: context.vault,
            noteGraph: { [weak context] in context?.service(.noteGraph) },
            didWrite: { [weak context] path in
                context?.emit(VaultChanged(changes: [VaultChange(kind: .modified, path: path)]))
            }
        )
        try context.provide(.noteQuery, engine)
        context.on(VaultChanged.self) { engine.update($0.changes) }

        try context.registerCommand(Command(
            id: "query.run",
            title: "Query notes",
            summary: "Finds notes by folder, tag and frontmatter property, sorted; returns path, title, properties, "
                + "tags and modified time. Optional arguments: query (a JSON NoteQuery: folder, tags, filters, sort, "
                + "limit), or folder, tag (comma-separated), where (JSON array of {key, op, value}; op is exists, "
                + "missing, equals, notEquals, contains, lessThan or greaterThan), sort (comma-separated keys, "
                + "-key for descending; title, path, modified or a property), limit.",
            isInPalette: false
        ) { arguments in
            try JSON.string(engine.run(try Self.query(from: arguments)))
        })

        try context.registerCommand(Command(
            id: "query.values",
            title: "Property values",
            summary: "Lists the distinct values of a frontmatter property across the notes a query matches. "
                + "Argument: key. Optional: query (JSON NoteQuery) or folder, tag, where, as in query.run.",
            isInPalette: false
        ) { arguments in
            try JSON.string(engine.values(of: try arguments.require("key"), in: try Self.query(from: arguments)))
        })

        try context.registerCommand(Command(
            id: "query.set-property",
            title: "Set property",
            summary: "Sets one frontmatter property of a note, leaving the rest of the file as it was; an empty "
                + "value removes it. Writes to the vault. Arguments: path, key, value (JSON such as 3, true or "
                + "[\"a\",\"b\"], else taken as plain text).",
            isInPalette: false
        ) { arguments in
            let path = try VaultPath.normalize(try arguments.require("path"))
            let key = try arguments.require("key")
            let value = arguments["value"].flatMap { $0.isEmpty ? nil : Self.propertyValue($0) }
            try engine.setProperty(key, to: value, in: path)
            return try JSON.string(engine.run(NoteQuery()).first { $0.path == path })
        })
    }

    /// A query from command arguments: `query` as JSON, then the simple arguments on top of it.
    static func query(from arguments: [String: String]) throws -> NoteQuery {
        var query = NoteQuery()
        if let json = arguments["query"], !json.isEmpty {
            query = try decode(NoteQuery.self, json, argument: "query")
        }
        if let folder = arguments["folder"], !folder.isEmpty { query.folder = folder }
        if let tag = arguments["tag"], !tag.isEmpty {
            query.tags += tag.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let filters = arguments["where"], !filters.isEmpty {
            query.filters += try decode([PropertyFilter].self, filters, argument: "where")
        }
        if let sort = arguments["sort"], !sort.isEmpty {
            query.sort = sort.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { $0.hasPrefix("-") ? SortKey(key: String($0.dropFirst()), descending: true) : SortKey(key: $0) }
        }
        if let limit = arguments["limit"], !limit.isEmpty {
            guard let number = Int(limit) else { throw NoteQueryError.invalidArgument(name: "limit") }
            query.limit = number
        }
        return query
    }

    /// JSON when it parses (numbers, booleans, lists, quoted strings), else the text itself.
    static func propertyValue(_ text: String) -> PropertyValue {
        (try? JSONDecoder().decode(PropertyValue.self, from: Data(text.utf8))) ?? .string(text)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String, argument: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            throw NoteQueryError.invalidArgument(name: argument)
        }
    }
}
