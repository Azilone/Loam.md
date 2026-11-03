import Foundation
import PluginKit

/// Provides the `daily-notes` service and the `daily.*` commands.
public final class DailyNotesPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "daily-notes",
            name: "Daily notes",
            version: "0.1.0",
            description: "A note for each day, in a folder of its own, started from a template.",
            icon: "calendar.day.timeline.left",
            provides: ["daily-notes"],
            permissions: ["vault.read", "vault.write"],
            settings: [
                SettingDescription(
                    "folder", title: "Folder", help: "Where daily notes go, from the vault's root.",
                    default: .string(DailyNotesSettings().folder)
                ),
                SettingDescription(
                    "template", title: "Template",
                    help: "A note whose text starts each new daily note; {{date}} becomes the day.",
                    default: .string(DailyNotesSettings().template)
                ),
            ]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let daily = DailyNotes(vault: context.vault, layout: context.settings.value(default: DailyNotesSettings()).layout)
        try context.provide(.dailyNotes, daily)
        let id = context.pluginID
        context.intercept(FolderIcons.self) { event, next in
            var event = event
            if !daily.layout.folder.isEmpty { event.symbols[daily.layout.folder] = "calendar" }
            return next(event)
        }
        context.intercept(ManagedFolders.self) { event, next in
            var event = event
            if !daily.layout.folder.isEmpty { event.paths.insert(daily.layout.folder) }
            return next(event)
        }
        context.on(PluginSettingsChanged.self) { [weak context] event in
            guard event.pluginID == id, let context else { return }
            daily.layout = context.settings.value(default: DailyNotesSettings()).layout
            context.emit(DailyNotesLayoutChanged())
            context.emit(ManagedFoldersChanged())
        }

        try context.registerCommand(Command(
            id: "daily.path",
            title: "Daily note path",
            summary: "Path of the daily note, even if it does not exist yet. Optional argument: date (YYYY-MM-DD).",
            isInPalette: false
        ) { arguments in
            try daily.path(for: arguments["date"])
        })

        try context.registerCommand(Command(
            id: "daily.read",
            title: "Read daily note",
            summary: "Text of the daily note, empty if there is none. Optional argument: date.",
            isInPalette: false
        ) { arguments in
            try daily.read(date: arguments["date"]) ?? ""
        })

        try context.registerCommand(Command(
            id: "daily.append",
            title: "Append to daily note",
            summary: "Appends text to the daily note, creating it from the template. Arguments: text; optional: date.",
            isInPalette: false
        ) { arguments in
            try daily.append(try arguments.require("text"), date: arguments["date"])
        })

        try context.registerCommand(Command(
            id: "daily.prepend",
            title: "Prepend to daily note",
            summary: "Adds text at the top of the daily note, below its title. Arguments: text; optional: date.",
            isInPalette: false
        ) { arguments in
            try daily.prepend(try arguments.require("text"), date: arguments["date"])
        })

        try context.registerCommand(Command(
            id: "daily.ensure",
            title: "Create daily note",
            summary: "Creates the daily note from the template if it does not exist yet (writes a file, unless the "
                + "template is empty or absent: an empty note is never kept); leaves an existing note unchanged. "
                + "Returns its path. Optional argument: date (YYYY-MM-DD).",
            isInPalette: false
        ) { arguments in
            try daily.ensure(date: arguments["date"])
        })

        try context.registerCommand(Command(
            id: "daily.list",
            title: "List daily notes",
            summary: "Days that have a daily note, as a JSON array of YYYY-MM-DD, oldest first. Optional argument: "
                + "month (YYYY-MM) to keep one month.",
            isInPalette: false
        ) { arguments in
            let dates = try daily.existingDates(in: arguments["month"])
            let data = try JSONEncoder().encode(dates)
            return String(decoding: data, as: UTF8.self)
        })
    }
}
