import Foundation
import PluginKit

/// Projects: the notes of a folder (`Projects/`), each with a status, a due date and its tasks. Provides the
/// `projects` service (used by `ProjectsUI`) and the `projects.*` commands. A project's fields are frontmatter, its
/// tasks the notes of its folder, shown as a Kanban in it: docs/PROJECTS.md.
public final class ProjectsPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "projects",
            name: "Projects",
            version: "0.1.0",
            description: "Projects as notes, each with a Kanban of task notes, a status and a due date.",
            icon: "square.stack.3d.up",
            provides: ["projects"],
            requires: ["note-query"],
            optionalRequires: ["collections"],
            permissions: ["vault.read", "vault.write"],
            settings: [
                SettingDescription(
                    "folder", title: "Folder", help: "Where project notes are, from the vault's root.",
                    default: .string(ProjectsSettings().folder), folder: true
                ),
            ]
        )
    }

    public required init() {}

    /// A collection made from the folder before it held projects has no type for `due`, so a project's due date was
    /// text: it becomes a date, with its picker and its pill.
    static func typeDue(_ path: String, context: PluginContext) {
        guard let collections = context.service(.collections),
              let definition = try? collections.definition(.file(path)) else { return }
        let due = PropertyRef("due")
        var property = definition.property(due)
        guard property.kind != .date else { return }
        property.kind = .date
        if property.displayName == nil { property.displayName = "Due" }
        _ = try? collections.apply([.setProperty(property: property)], to: .file(path))
    }

    public func activate(context: PluginContext) throws {
        let store = ProjectStore(
            vault: context.vault,
            folder: context.settings.value(default: ProjectsSettings()).folder,
            noteQuery: { [weak context] in context?.service(.noteQuery) },
            didWrite: { [weak context] change in context?.emit(VaultChanged(changes: [change])) }
        )
        try context.provide(.projects, store)
        // A collection written for the old layout follows the folders now, however the folder is opened.
        if context.vault.exists(store.collectionPath) {
            _ = try? store.ensureCollection()
            Self.typeDue(store.collectionPath, context: context)
        }
        _ = try? store.mendBoards()
        let id = context.pluginID
        context.intercept(ManagedFolders.self) { event, next in
            var event = event
            event.paths.insert(store.folder)
            return next(event)
        }
        context.on(PluginSettingsChanged.self) { [weak context] event in
            guard event.pluginID == id, let context else { return }
            store.folder = context.settings.value(default: ProjectsSettings()).folder
            context.emit(ProjectsFolderChanged(folder: store.folder))
            context.emit(ManagedFoldersChanged())
        }

        // A note just created empty in the folder (the collection's "+", "New Note") starts as an active project.
        context.on(VaultChanged.self) { [weak context] event in
            for change in event.changes where change.kind == .added {
                if let path = try? store.adoptNewNote(change.path), path != change.path {
                    context?.emit(NotesMoved(moves: [change.path: path]))
                }
            }
        }
        // A project's note and folder keep one name.
        context.on(NotesMoved.self) { [weak context] event in
            let made = store.follow(event.moves)
            if !made.isEmpty { context?.emit(NotesMoved(moves: made)) }
        }

        try context.registerCommand(Command(
            id: "projects.list",
            title: "List projects",
            summary: "Lists the projects (Projects/<name>/<name>.md, Projects being the folder setting) as JSON: "
                + "path, title, status, due, overdue, and tasks {done, total, inProgress, late} counted from the task "
                + "notes beside it in its folder, by their status. Optional argument: status.",
            isInPalette: false
        ) { arguments in
            var projects = store.projects()
            if let status = arguments["status"], !status.isEmpty {
                projects = projects.filter { $0.status?.caseInsensitiveCompare(status) == .orderedSame }
            }
            return try JSON.string(projects)
        })

        try context.registerCommand(Command(
            id: "projects.due",
            title: "List project tasks due",
            summary: "Lists the open task notes of every project due on a day (default today; today also lists the "
                + "late ones) as JSON: path, title, project, status, due. Optional argument: day (YYYY-MM-DD).",
            isInPalette: false
        ) { arguments in
            let day = arguments["day"].flatMap { $0.isEmpty ? nil : $0 } ?? store.today
            guard ProjectStore.day(day) == day else { throw ProjectsError.invalidArgument(name: "day") }
            return try JSON.string(store.tasks(dueOn: day))
        })

        try context.registerCommand(Command(
            id: "projects.tidy",
            title: "Tidy the projects folder",
            summary: "Moves each note directly in the projects folder into a folder of its own (Projects/X.md becomes "
                + "Projects/X/X.md), so it is a project with its tasks beside it; an older board follows. Writes to the "
                + "vault. Returns the moves as JSON.",
            isInPalette: false
        ) { [weak context] _ in
            let moves = try store.tidy()
            if !moves.isEmpty { context?.emit(NotesMoved(moves: moves)) }
            return try JSON.string(moves)
        })

        try context.registerCommand(Command(
            id: "projects.new",
            title: "New project (agent)",
            summary: "Creates a project note in the projects folder with status (default Active) and due "
                + "(YYYY-MM-DD) in its frontmatter and the Kanban of its tasks, as Projects/<title>/<title>.md, and "
                + "the folder's collection if missing. Writes to the vault. Arguments: title; optional: status, due. "
                + "Returns its path. A task is another note in that folder with status (To do, In progress, Done) and "
                + "optional due.",
            isInPalette: false
        ) { arguments in
            try JSON.string(["path": try store.create(
                title: try arguments.require("title"), status: arguments["status"], due: arguments["due"]
            )])
        })

        try context.registerCommand(Command(
            id: "projects.add-task",
            title: "Add a task to a project (agent)",
            summary: "Adds a task card to a project's Kanban: a note in the project's folder with status (To do, "
                + "In progress or Done; default To do) and optional due (YYYY-MM-DD). Writes to the vault. Arguments: "
                + "project (its path or title), title; optional: status, due, text (the note's body). Returns its path.",
            isInPalette: false
        ) { arguments in
            try JSON.string(["path": try store.addTask(
                project: try arguments.require("project"), title: try arguments.require("title"),
                status: arguments["status"], due: arguments["due"], text: arguments["text"]
            )])
        })
    }
}
