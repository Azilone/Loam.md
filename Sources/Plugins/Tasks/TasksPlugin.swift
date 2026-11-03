import Foundation
import PluginKit

/// Tasks across notes: every GFM task-list line of the vault (`- [ ] text`), with its due date, priority, tags and
/// project. Provides the `tasks` service (used by the Tasks UI, `TasksUI`) and the `tasks.*` commands. The syntax
/// is in docs/TASKS.md. After a write it sends `VaultChanged` for the note, so open editors and the note graph
/// follow at once.
public final class TasksPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "tasks",
            name: "Tasks",
            version: "0.1.0",
            description: "Every task in your notes, with its due date, priority and tags.",
            icon: "checkmark.circle",
            provides: ["tasks"],
            permissions: ["vault.read", "vault.write"]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let index = TaskIndex(vault: context.vault, didWrite: { [weak context] path in
            context?.emit(VaultChanged(changes: [VaultChange(kind: .modified, path: path)]))
        })
        try context.provide(.tasks, index)

        try context.registerCommand(Command(
            id: "tasks.list",
            title: "List tasks",
            summary: "Lists the task-list lines (- [ ] / - [x]) of every note, sorted by due date, priority, path and "
                + "line; returns path, line, text, done, due, completed, priority, tags and project as JSON. Optional "
                + "arguments: done (true or false), dueBefore, dueOn (YYYY-MM-DD or today), project, tag, path (a "
                + "note or folder), text (contained), or filter (a JSON TaskFilter with the same fields).",
            isInPalette: false
        ) { arguments in
            try JSON.string(try index.tasks(try Self.filter(from: arguments, today: index.today), liveText: nil))
        })

        try context.registerCommand(Command(
            id: "tasks.toggle",
            title: "Toggle a task",
            summary: "Checks or unchecks one task line, adding or removing its ✅ completion date. Writes to the vault. "
                + "Arguments: path, line (1-based), text (the task's text as tasks.list returned it); refuses, writing "
                + "nothing, when that line no longer holds this task. Returns the task after the change.",
            isInPalette: false
        ) { arguments in
            guard let line = Int(try arguments.require("line")) else { throw TasksError.invalidArgument(name: "line") }
            return try JSON.string(try index.toggle(
                path: try arguments.require("path"), line: line, expectedText: try arguments.require("text")
            ))
        })

        try context.registerCommand(Command(
            id: "tasks.add",
            title: "Add a task to a note",
            summary: "Adds \"- [ ] text\" to a note, at the end of its \"## Tasks\" section if it has one, else at the "
                + "end; creates the note if missing. Writes to the vault. Arguments: path, text (may hold "
                + "📅 YYYY-MM-DD, !high, #tags). Returns the new task.",
            isInPalette: false
        ) { arguments in
            try JSON.string(try index.add(try arguments.require("text"), to: try arguments.require("path")))
        })
    }

    /// A filter from command arguments: `filter` as JSON, then the simple arguments on top of it. Dates may be
    /// `today`.
    static func filter(from arguments: [String: String], today: String) throws -> TaskFilter {
        var filter = TaskFilter()
        if let json = arguments["filter"], !json.isEmpty {
            do {
                filter = try JSONDecoder().decode(TaskFilter.self, from: Data(json.utf8))
            } catch {
                throw TasksError.invalidArgument(name: "filter")
            }
        }
        if let done = arguments["done"], !done.isEmpty {
            switch done.lowercased() {
            case "true", "yes", "1": filter.done = true
            case "false", "no", "0": filter.done = false
            default: throw TasksError.invalidArgument(name: "done")
            }
        }
        for key in ["project", "tag", "path", "text"] {
            guard let value = arguments[key], !value.isEmpty else { continue }
            switch key {
            case "project": filter.project = value
            case "tag": filter.tag = value
            case "path": filter.path = value
            default: filter.text = value
            }
        }
        if let value = arguments["dueBefore"], !value.isEmpty { filter.dueBefore = value }
        if let value = arguments["dueOn"], !value.isEmpty { filter.dueOn = value }
        filter.dueBefore = try filter.dueBefore.map { try day($0, today: today) }
        filter.dueOn = try filter.dueOn.map { try day($0, today: today) }
        return filter
    }

    private static func day(_ text: String, today: String) throws -> String {
        if text.lowercased() == "today" { return today }
        guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
            throw TasksError.invalidDate(text)
        }
        return text
    }
}
