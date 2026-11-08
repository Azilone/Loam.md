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
            optionalRequires: ["note-graph"],
            permissions: ["vault.read", "vault.write"],
            settings: [
                SettingDescription(
                    "folder", title: "Folder", help: "Where daily notes go, from the vault's root.",
                    default: .string(DailyNotesSettings().folder), folder: true
                ),
                SettingDescription(
                    "template", title: "Template",
                    help: "A note whose text starts each new daily note; {{date}} becomes the day.",
                    default: .string(DailyNotesSettings().template)
                ),
                SettingDescription(
                    "subfolders", title: "Subfolders",
                    help: "Folders for new daily notes, written from the day's date: yyyy, MM, MMM, MMMM, dd. "
                        + "Leave it empty for no subfolders. Notes already written stay where they are and are "
                        + "still found.",
                    default: .string(DailyNotesSettings().subfolders.rawValue)
                ),
            ]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        Self.keepLegacyLayout(context)
        // Every pattern the vault used, the current one included: a note written under an older one is still found.
        let settings = context.settings.value(default: DailyNotesSettings())
        var history = DailyPatternHistory.read(context.vault)
        if history.patterns.first != settings.subfolders.rawValue {
            history.remember(settings.subfolders.rawValue)
            history.write(context.vault)
        }
        let daily = DailyNotes(
            vault: context.vault, layout: settings.layout,
            previousPatterns: history.patterns.map { DailyFolderPattern($0) }
        )
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
        // A journal reads newest first: its notes are named after their day, so by name, Z to A.
        context.intercept(FolderOrder.self) { event, next in
            var event = event
            if !daily.layout.folder.isEmpty { event.orders[daily.layout.folder] = .nameDescending }
            return next(event)
        }
        context.on(PluginSettingsChanged.self) { [weak context] event in
            guard event.pluginID == id, let context else { return }
            let settings = context.settings.value(default: DailyNotesSettings())
            let previous = daily.layout.subfolders
            daily.layout = settings.layout
            if settings.subfolders != previous {
                var history = DailyPatternHistory.read(context.vault)
                history.remember(settings.subfolders.rawValue)
                history.write(context.vault)
                daily.previousPatterns = history.patterns.map { DailyFolderPattern($0) }
            }
            context.emit(DailyNotesLayoutChanged())
            context.emit(ManagedFoldersChanged())
            context.emit(FolderOrderChanged())
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

        try context.registerCommand(Command(
            id: "daily.reorganize",
            title: "Sort daily notes into subfolders",
            summary: "Moves every daily note, with its .assets folder, where the Subfolders setting puts it, and "
                + "rewrites the links to them. Writes to the vault. Returns JSON {moved}: the notes moved."
        ) { [weak context] _ in
            let moves = try daily.reorganizationMoves()
            if let graph = context?.service(.noteGraph) {
                _ = try graph.move(moves)
            } else {
                for (from, to) in moves.sorted(by: { $0.key < $1.key }) { try context?.vault.move(from, to: to) }
            }
            context?.emit(DailyNotesLayoutChanged())
            return try JSON.string(["moved": moves.keys.filter { $0.hasSuffix(".md") }.count])
        })
    }

    /// The defaults were `Daily`, flat, before they became `Journal` sorted by month. Settings keep one key per
    /// change, so a vault whose `subfolders` was never written gets it now, once: flat (and `Daily` when no folder was
    /// chosen) if it was made before, from its settings or its `Daily` folder, so its notes stay where new ones go.
    static func keepLegacyLayout(_ context: PluginContext) {
        struct Stored: Codable, Equatable { var folder: String?; var subfolders: String? }
        let stored = context.settings.value(default: Stored())
        guard stored.subfolders == nil else { return }
        var settings = context.settings.value(default: DailyNotesSettings())
        if stored.folder != nil || context.vault.exists("Daily") {
            if stored.folder == nil { settings.folder = "Daily" }
            settings.subfolders = .none
        }
        try? context.settings.update(settings)
    }
}
