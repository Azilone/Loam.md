import Foundation
import PluginKit

/// Provides the `collections` service and the `collection.*` commands: views over notes defined by Obsidian Bases
/// `.base` files (or the same YAML in a ` ```base ` block). Entries are notes from `note-query`; the plugin writes
/// `.base` files only when asked, and follows folders that move.
public final class CollectionsPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "collections",
            name: "Collections",
            version: "0.1.0",
            description: "Notes gathered as a collection, from a .base file or a folder.",
            icon: "square.stack.3d.up",
            provides: ["collections"],
            requires: ["note-query"],
            permissions: ["vault.read", "vault.write"]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let engine = CollectionEngine(
            vault: context.vault,
            noteQuery: { [weak context] in context?.service(.noteQuery) },
            didWrite: { [weak context] changes in context?.emit(VaultChanged(changes: changes)) }
        )
        try context.provide(.collections, engine)
        context.on(VaultChanged.self) { event in
            if event.changes.contains(where: { !$0.isNote && $0.kind != .modified }) { engine.invalidate() }
        }
        context.on(NotesMoved.self) { engine.follow($0.moves) }

        try context.registerCommand(Command(
            id: "collection.list",
            title: "List collections",
            summary: "Lists every collection (.base file) of the vault, as a JSON array of paths.",
            isInPalette: false
        ) { _ in
            try JSON.string(engine.collections())
        })

        try context.registerCommand(Command(
            id: "collection.show",
            title: "Show collection",
            summary: "Shows a collection's definition as JSON: name, home folder, fields (kind, options) and views. "
                + Self.sourceArguments,
            isInPalette: false
        ) { arguments in
            try JSON.string(engine.definition(try Self.source(arguments)))
        })

        try context.registerCommand(Command(
            id: "collection.entries",
            title: "Collection entries",
            summary: "Runs one view of a collection: its notes (path, title, properties, tags), filtered, sorted, "
                + "and grouped for a board, with each field's kind. Optional: view (its name; default the first). "
                + Self.sourceArguments,
            isInPalette: false
        ) { arguments in
            try JSON.string(engine.entries(try Self.source(arguments), view: arguments["view"].flatMap(Self.nonEmpty)))
        })

        try context.registerCommand(Command(
            id: "collection.create",
            title: "Turn folder into collection",
            summary: "Turns a folder into a collection: writes <folder>/<name>.base with a table of the folder's "
                + "notes (or keeps the existing one); the folder then opens as that collection. Writes to the vault. "
                + "Argument: folder. Returns the path.",
            isInPalette: false
        ) { arguments in
            try engine.create(folder: try arguments.require("folder"))
        })

        try context.registerCommand(Command(
            id: "collection.adopt",
            title: "Move collection into its folder",
            summary: "Moves a .base kept apart from its notes into the folder its filter shows, as "
                + "<folder>/<folder name>.base, so the folder opens as that collection. Writes to the vault. "
                + "Argument: path (the .base). Returns the new path.",
            isInPalette: false
        ) { arguments in
            try engine.adopt(try VaultPath.normalize(try arguments.require("path")))
        })

        try context.registerCommand(Command(
            id: "collection.edit",
            title: "Edit collection",
            summary: "Applies edits to a collection's YAML, keeping the keys Loam does not know. Writes to the vault "
                + "(a .base). Argument: edits, a JSON array such as [{\"addView\":{\"type\":\"kanban\",\"name\":"
                + "\"Board\"}}, {\"setGroupBy\":{\"view\":\"Board\",\"groupBy\":{\"property\":\"status\","
                + "\"descending\":false}}}, {\"setProperty\":{\"property\":{\"ref\":\"status\",\"kind\":\"select\","
                + "\"options\":[\"To do\",\"Done\"]}}}]. Edits: addView, removeView, renameView, moveView, setOrder, "
                + "setSort, setGroupBy, setLimit, setViewOption, setProperty, removeProperty, addFilter, removeFilter. "
                + "Returns the definition (for a block, its new yaml too). " + Self.sourceArguments,
            isInPalette: false
        ) { arguments in
            let source = try Self.source(arguments)
            let edits = try Self.decode([CollectionEdit].self, try arguments.require("edits"), argument: "edits")
            let edited = try engine.apply(edits, to: source)
            return try JSON.string(engine.definition(edited))
        })

        try context.registerCommand(Command(
            id: "collection.add-view",
            title: "Add collection view",
            summary: "Adds a view to a collection. Writes to the vault. Arguments: type (table, kanban, cards or a "
                + "plugin's), optional name. A kanban groups by the first select field, or creates a status field "
                + "with To do, In progress and Done. " + Self.sourceArguments,
            isInPalette: false
        ) { arguments in
            let source = try Self.source(arguments)
            let type = try arguments.require("type")
            let definition = try engine.definition(source)
            let name = arguments["name"].flatMap(Self.nonEmpty) ?? Self.defaultName(of: type)
            var edits: [CollectionEdit] = [.addView(type: type, name: name)]
            let added = Self.uniqueName(name, among: definition.views.map(\.name))
            if type == "kanban" { edits += Self.kanbanDefaults(view: added, definition) }
            return try JSON.string(engine.definition(try engine.apply(edits, to: source)))
        })

        try context.registerCommand(Command(
            id: "collection.set-property",
            title: "Set collection field",
            summary: "Sets a field's settings in a collection: optional type (text, number, checkbox, date, url, "
                + "select, multiselect), options (a JSON array or comma-separated, in order), display-name. Writes to "
                + "the vault. Argument: property (status, file.name…). " + Self.sourceArguments,
            isInPalette: false
        ) { arguments in
            let source = try Self.source(arguments)
            let ref = PropertyRef(try arguments.require("property"))
            var property = try engine.definition(source).property(ref)
            if let type = arguments["type"].flatMap(Self.nonEmpty) {
                guard let kind = PropertyKind(rawValue: type.lowercased()) else {
                    throw CollectionError.invalidArgument("type")
                }
                property.kind = kind
            }
            if let options = arguments["options"] {
                property.options = (try? JSONDecoder().decode([String].self, from: Data(options.utf8)))
                    ?? options.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            if let name = arguments["display-name"] { property.displayName = Self.nonEmpty(name) }
            return try JSON.string(engine.definition(try engine.apply([.setProperty(property: property)], to: source)))
        })

        try context.registerCommand(Command(
            id: "collection.new-entry",
            title: "New collection entry",
            summary: "Writes a new note in a collection's home folder (else the Inbox) with what its filter asks for "
                + "(tags, x == value). Writes to the vault. Optional: title, values (a JSON object of frontmatter "
                + "properties). Returns the path. " + Self.sourceArguments,
            isInPalette: false
        ) { arguments in
            let source = try Self.source(arguments)
            let values = try arguments["values"].flatMap(Self.nonEmpty).map {
                try Self.decode([String: PropertyValue].self, $0, argument: "values")
            } ?? [:]
            return try engine.newEntry(in: source, title: arguments["title"].flatMap(Self.nonEmpty), values: values)
        })
    }

    static let sourceArguments = "Argument: path (a .base file), or yaml (a ```base block's YAML) with optional host "
        + "(the note holding it)."

    static func source(_ arguments: [String: String]) throws -> CollectionSource {
        if let path = arguments["path"].flatMap(nonEmpty) { return .file(try VaultPath.normalize(path)) }
        if let yaml = arguments["yaml"] { return .inline(yaml: yaml, host: arguments["host"].flatMap(nonEmpty)) }
        throw CommandError.missingArgument(name: "path")
    }

    static func defaultName(of type: String) -> String {
        switch type {
        case "cards": return "Gallery"
        case "kanban": return "Kanban"
        case "table": return "Table"
        default: return type.capitalized
        }
    }

    static func uniqueName(_ name: String, among names: [String]) -> String {
        var unique = name
        var number = 2
        while names.contains(unique) {
            unique = "\(name) \(number)"
            number += 1
        }
        return unique
    }

    /// A new board groups by the first select field, else by a new `status` with Craft's three columns.
    static func kanbanDefaults(view: String, _ definition: CollectionDefinition) -> [CollectionEdit] {
        if let select = definition.properties.first(where: { $0.kind == .select || (!$0.options.isEmpty && $0.kind == nil) }) {
            return [.setGroupBy(view: view, groupBy: CollectionSort(property: select.ref))]
        }
        let status = PropertyRef("status")
        return [
            .setProperty(property: CollectionProperty(
                ref: status, displayName: definition.property(status).displayName, kind: .select,
                options: ["To do", "In progress", "Done"]
            )),
            .setGroupBy(view: view, groupBy: CollectionSort(property: status)),
        ]
    }

    static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String, argument: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            throw CollectionError.invalidArgument(argument)
        }
    }
}
