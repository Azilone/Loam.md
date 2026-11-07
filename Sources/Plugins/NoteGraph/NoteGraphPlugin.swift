import Foundation
import PluginKit

/// Provides the `note-graph` service and the `notes.*` commands.
public final class NoteGraphPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "note-graph",
            name: "Note graph",
            version: "0.1.0",
            description: "Keeps the links, backlinks, tags and properties of every note.",
            icon: "point.3.filled.connected.trianglepath.dotted",
            provides: ["note-graph"],
            permissions: ["vault.read", "vault.write"]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let index = NoteGraphIndex(
            vault: context.vault,
            willMove: { [weak context] in context?.emit(NotesWillMove(moves: $0)) },
            didMove: { [weak context] in context?.emit(NotesMoved(moves: $0)) }
        )
        index.loadInBackground { [weak context] in context?.emit(NoteGraphLoaded()) }
        try context.provide(.noteGraph, index)
        context.on(VaultChanged.self) { index.apply($0.changes) }

        try context.registerCommand(Command(
            id: "notes.list",
            title: "List notes",
            summary: "Lists notes with title, tags, properties and links. Optional argument: tag.",
            isInPalette: false
        ) { arguments in
            if let tag = arguments["tag"] { return try JSON.string(index.notes(tagged: tag)) }
            return try JSON.string(index.notes)
        })

        try context.registerCommand(Command(
            id: "notes.backlinks",
            title: "Backlinks",
            summary: "Lists the notes that link to a note. Argument: path.",
            isInPalette: false
        ) { arguments in
            let path = try VaultPath.normalize(try arguments.require("path"))
            return try JSON.string(index.backlinks(to: path))
        })

        try context.registerCommand(Command(
            id: "notes.rename",
            title: "Rename note",
            summary: "Renames or moves a note and rewrites the links to it. Writes to the vault. Arguments: from, to.",
            isInPalette: false
        ) { arguments in
            try JSON.string(try index.rename(from: try arguments.require("from"), to: try arguments.require("to")))
        })

        try context.registerCommand(Command(
            id: "notes.move",
            title: "Move note or folder",
            summary: "Moves a note, an attachment or a folder and rewrites the links to and inside what moved. "
                + "Writes to the vault. Arguments: from, to.",
            isInPalette: false
        ) { arguments in
            try JSON.string(try index.move([try arguments.require("from"): try arguments.require("to")]))
        })

        try context.registerCommand(Command(
            id: "notes.reindex",
            title: "Reindex notes",
            summary: "Rebuilds the note graph from the files on disk.",
            isInPalette: false
        ) { _ in
            try index.reindex()
            return try JSON.string(["notes": index.notes.count])
        })
    }
}
