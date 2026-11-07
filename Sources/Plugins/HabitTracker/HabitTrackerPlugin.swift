import Foundation
import PluginKit

/// A small example plugin: a habit tracker over plain Markdown notes. Provides the `habits` service (used by the
/// habits board, `HabitsUI`) and the `habits.*` commands.
public final class HabitTrackerPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "habit-tracker",
            name: "Habit tracker",
            version: "0.2.0",
            description: "Habits kept in plain notes, one task line per day.",
            icon: "flame",
            provides: ["habits"],
            permissions: ["vault.read", "vault.write"],
            settings: [
                SettingDescription(
                    "folder", title: "Folder", help: "Where habit notes are, from the vault's root.",
                    default: .string(HabitTrackerSettings().folder)
                ),
            ]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let tracker = HabitTracker(
            vault: context.vault, folder: context.settings.value(default: HabitTrackerSettings()).resolvedFolder
        )
        try context.provide(.habits, tracker)
        let id = context.pluginID
        context.intercept(ManagedFolders.self) { event, next in
            var event = event
            event.paths.insert(tracker.folder)
            return next(event)
        }
        context.on(PluginSettingsChanged.self) { [weak context] event in
            guard event.pluginID == id, let context else { return }
            tracker.folder = context.settings.value(default: HabitTrackerSettings()).resolvedFolder
            context.emit(HabitsFolderChanged())
            context.emit(ManagedFoldersChanged())
        }

        try context.registerCommand(Command(
            id: "habits.check",
            title: "Check in a habit",
            summary: "Records a day for a habit, creating its note. Writes to the vault. Arguments: name; "
                + "optional: date (YYYY-MM-DD, default today).",
            isInPalette: false
        ) { arguments in
            try JSON.string(try tracker.check(name: try arguments.require("name"), date: arguments["date"]))
        })

        try context.registerCommand(Command(
            id: "habits.uncheck",
            title: "Uncheck a habit",
            summary: "Removes a day from a habit's check-ins, keeping the rest of its note. Writes to the vault. "
                + "Arguments: name; optional: date (YYYY-MM-DD, default today). Returns the new status.",
            isInPalette: false
        ) { arguments in
            let name = try arguments.require("name")
            try tracker.uncheck(name, date: arguments["date"])
            return try JSON.string(try tracker.status(name: name))
        })

        try context.registerCommand(Command(
            id: "habits.create",
            title: "New habit",
            summary: "Creates the note <name>.md in the habits folder (Habits unless the plugin's settings say "
                + "otherwise) with a short header; fails if it exists. Writes to the vault. Argument: name. Returns "
                + "its path.",
            isInPalette: false
        ) { arguments in
            try JSON.string(["path": try tracker.create(try arguments.require("name"))])
        })

        try context.registerCommand(Command(
            id: "habits.set",
            title: "Set a habit's colour, icon or archive",
            summary: "Sets a frontmatter property of a habit's note, keeping the rest. Writes to the vault. Arguments: "
                + "name, key (color, icon or archived), value (a colour name such as orange or blue, an emoji, true; "
                + "empty removes it).",
            isInPalette: false
        ) { arguments in
            let key = try arguments.require("key")
            guard ["color", "icon", "archived"].contains(key) else { throw HabitError.invalidName(key) }
            let value = arguments["value"].flatMap { $0.isEmpty ? nil : $0 }
            try tracker.setProperty(try arguments.require("name"), key: key, value: value)
            return "Done."
        })

        try context.registerCommand(Command(
            id: "habits.status",
            title: "Habit status",
            summary: "Check-ins and streaks of a habit. Argument: name.",
            isInPalette: false
        ) { arguments in
            try JSON.string(try tracker.status(name: try arguments.require("name")))
        })

        try context.registerCommand(Command(
            id: "habits.list",
            title: "List habits",
            summary: "Status of every habit note in the habits folder (Habits unless the plugin's settings say "
                + "otherwise).",
            isInPalette: false
        ) { _ in
            try JSON.string(try tracker.all())
        })
    }
}
