import Foundation
import PluginKit

/// Provides the `files` service and the `files.*` commands: the logic behind the file explorer.
/// Uses the note graph when it is there, so moves and renames keep links working.
public final class FileExplorerPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "files",
            name: "Files",
            version: "0.1.0",
            description: "Creates, renames, moves and trashes notes and folders.",
            icon: "doc.on.doc",
            provides: ["files"],
            optionalRequires: ["note-graph", "trash"],
            permissions: ["vault.read", "vault.write"]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let files = FileExplorer(
            vault: context.vault,
            noteGraph: { [weak context] in context?.service(.noteGraph) },
            trashService: { [weak context] in context?.service(.trash) },
            emit: { [weak context] willMove, moves in
                if willMove { context?.emit(NotesWillMove(moves: moves)) } else { context?.emit(NotesMoved(moves: moves)) }
            }
        )
        try context.provide(.files, files)

        try context.registerCommand(Command(
            id: "files.new-note",
            title: "Pick the path of a new note",
            summary: "Returns the path of a new note, \"Untitled\" or a free \"Name 2\" variant, and writes nothing: "
                + "empty notes never exist, so the note is created when its first content is written to that path. "
                + "Optional arguments: folder (default \"Inbox\", \"\" for the root), name (without .md).",
            isInPalette: false
        ) { arguments in
            let path = try files.newNotePath(in: arguments["folder"] ?? VaultPath.inbox, name: arguments["name"], isTaken: { _ in false })
            return try JSON.string(["path": path])
        })

        try context.registerCommand(Command(
            id: "files.new-folder",
            title: "New folder",
            summary: "Creates a folder, \"New folder\" or a free \"Name 2\" variant. Writes to the vault. "
                + "Optional arguments: folder, name. Returns its path.",
            isInPalette: false
        ) { arguments in
            try JSON.string(["path": try files.newFolder(in: arguments["folder"] ?? "", name: arguments["name"])])
        })

        try context.registerCommand(Command(
            id: "files.move",
            title: "Move or rename",
            summary: "Moves or renames a note, attachment or folder, rewriting links when the note graph is on. "
                + "Writes to the vault. Arguments: from, to.",
            isInPalette: false
        ) { arguments in
            try JSON.string(try files.move(try arguments.require("from"), to: try arguments.require("to")))
        })

        try context.registerCommand(Command(
            id: "files.trash",
            title: "Move to trash",
            summary: "Moves a note, attachment or folder into the vault's .trash/, keeping its folder path; links are "
                + "left as they are. It stays there 30 days (see trash.list), then is deleted for good. Writes to the "
                + "vault. Argument: path. Returns the trash path.",
            isInPalette: false
        ) { arguments in
            try JSON.string(["path": try files.trash(try arguments.require("path"))])
        })

        try context.registerCommand(Command(
            id: "files.list",
            title: "List folder",
            summary: "Lists the files and folders directly inside a folder, folders first. Optional argument: folder.",
            isInPalette: false
        ) { arguments in
            try JSON.string(try files.list(arguments["folder"] ?? ""))
        })

        try context.registerCommand(Command(
            id: "files.tree",
            title: "File tree",
            summary: "The whole vault as a tree of folders and files, folders first, hidden ones skipped.",
            isInPalette: false
        ) { _ in
            try JSON.string(try files.tree())
        })
    }
}
